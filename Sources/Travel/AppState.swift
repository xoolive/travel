import Foundation
import Observation

/// A recording file listed in the sidebar.
struct SourceItem: Identifiable, Hashable {
    let id: String
    let url: URL
    let title: String
    let subtitle: String

    init(url: URL) {
        id = url.path
        self.url = url
        var stem = url.lastPathComponent
        for suffix in [".zst", ".7z", ".jsonl", ".json"] where stem.lowercased().hasSuffix(suffix) {
            stem.removeLast(suffix.count)
        }
        // Names such as 20260903_AA87049241_LFBO_EHAM or 20260617_rotterdam_kinderdijk.
        var parts = stem.split(separator: "_").map(String.init)
        var date = ""
        if let first = parts.first, first.count == 8, first.allSatisfy(\.isNumber) {
            date = "\(first.prefix(4))-\(first.dropFirst(4).prefix(2))-\(first.suffix(2))"
            parts.removeFirst()
        }
        let isAirport: (String) -> Bool = { $0.count == 4 && $0.allSatisfy { $0.isLetter && $0.isUppercase } }
        if parts.count >= 2, isAirport(parts[parts.count - 1]), isAirport(parts[parts.count - 2]) {
            title = "\(parts[parts.count - 2]) → \(parts[parts.count - 1])"
        } else {
            title = parts.isEmpty ? stem : parts.joined(separator: " ")
        }
        subtitle = date
    }
}

/// UI-side state: sources, the displayed dataset, the clock and the selection.
@MainActor
@Observable
final class AppState {
    private static let livePrefix = "live:"
    private static let liveSourcesKey = "liveSources"
    private static let databaseKey = "aircraftDatabase"

    enum LiveStatus: Equatable {
        case off
        case connecting
        case connected
        case failed(String)
    }

    /// Sidebar tag of a live source row.
    static func tag(_ source: LiveSource) -> String { livePrefix + source.id.uuidString }

    private(set) var sources: [SourceItem] = []
    private(set) var liveSources: [LiveSource] = []
    private(set) var liveStatus: [UUID: LiveStatus] = [:]

    /// Sidebar selection: recordings (several are merged) or live sources.
    /// Selecting any live source displays the live view.
    var selection: Set<String> = [] {
        didSet { if oldValue != selection { activate() } }
    }

    /// The displayed dataset: a recording or the live one.
    private(set) var dataset: Dataset?
    /// Mirrors `dataset.revision` so views refresh when data arrives.
    private(set) var revision = 0
    private(set) var entities: [Entity] = []
    private(set) var selectedTrack: [TrackSegment] = []
    /// Datalink and TCAS events of the selected aircraft, up to now.
    private(set) var selectedMarks: [TrackMark] = []
    /// Ground stations heard so far.
    private(set) var stationMarks: [TrackMark] = []
    /// Interrogators heard recently, at their candidate site.
    private(set) var radarMarks: [RadarMark] = []
    /// Aircraft interrogated by the hovered interrogator.
    private(set) var highlighted: Set<String> = []
    /// The interrogators under the pointer, on the map or in the chart.
    var hoveredInterrogators: [String] = [] {
        didSet { if hoveredInterrogators != oldValue { refreshInterrogators() } }
    }
    /// The user's own flights, from the Flighty app.
    private(set) var ownFlights: [OwnFlight] = []
    /// The aircraft that should be the user's at the displayed time, and its flight.
    private(set) var mineID: String?
    private(set) var mineFlight: OwnFlight?
    /// From the user's aircraft, when selected, to its destination (or to the
    /// runway threshold once aligned).
    private(set) var mineRoute: [LatLon] = []
    /// The runway the user's aircraft is aligned with, or was in the last 5 minutes.
    private(set) var mineAlignment: Alignment?
    /// Confirmed runway alignments, by flight: the flight has landed after them.
    @ObservationIgnored private var landed: [String: Alignment] = [:]
    @ObservationIgnored private var scanned: [String: Double] = [:]
    /// The third line of the user's aircraft card.
    var mineNote: String? {
        guard let flight = mineFlight else { return nil }
        guard let a = mineAlignment else { return "\(flight.number) → \(flight.destination)" }
        let runway = a.threshold.name
        if a.ongoing {
            return a.confirmed ? "\(flight.number) · aligned on \(a.threshold.airport) \(runway)" : "\(flight.number) · aligning on \(runway)"
        }
        let until = Date(timeIntervalSince1970: a.end).formatted(Date.FormatStyle(timeZone: .gmt).hour(.twoDigits(amPM: .omitted)).minute())
        return "\(flight.number) · was on \(a.threshold.airport) \(runway) until \(until)"
    }
    /// Ten nautical miles of extended centreline before that threshold.
    private(set) var mineCenterline: [LatLon] = []
    /// The radar whose card is open, by site name.
    var selectedRadar: String? {
        didSet { if selectedRadar != oldValue { refreshInterrogators() } }
    }
    /// The open radar card's content, kept when the radar falls silent.
    private(set) var selectedRadarMark: RadarMark?
    /// Aircraft interrogated by the selected radar now.
    private(set) var selectedRadarCount = 0
    private(set) var rangeStart = 0.0
    private(set) var rangeEnd = 1.0
    /// 0...1 while files are loading.
    private(set) var loadProgress: Double?
    var loadError: String?

    var selectedID: String? {
        didSet {
            if oldValue != selectedID {
                refreshTrack()
                refreshInterrogators()
                refreshMine()
            }
        }
    }

    /// Displayed instant, seconds since 1970.
    var currentTime: Double = 0 {
        didSet { if oldValue != currentTime { refresh() } }
    }

    var isPlaying = false
    /// Live only: the displayed instant tracks the present.
    private(set) var following = true
    /// Replay seconds per wall-clock second.
    var speed: Double = 60

    /// Everything received from all live sources; it keeps filling while a
    /// recording is displayed.
    @ObservationIgnored private var liveDataset: Dataset
    /// Registrations and type codes of aircraft.
    private(set) var database: AircraftDatabase
    @ObservationIgnored private var feeds: [UUID: LiveFeed] = [:]
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var loading: Task<Void, Never>?

    init() {
        // A chosen CSV table is read in the background; jet1090's meanwhile.
        let database = AircraftDatabase(source: .jet1090)
        self.database = database
        liveDataset = Dataset(name: "Live", isLive: true, database: database)
        if let path = UserDefaults.standard.string(forKey: Self.databaseKey) {
            useDatabase(.file(URL(fileURLWithPath: path)))
        }
        if let data = UserDefaults.standard.data(forKey: Self.liveSourcesKey),
           let saved = try? JSONDecoder().decode([LiveSource].self, from: data) {
            liveSources = saved
        } else {
            liveSources = LiveSource.defaults
        }
        reloadOwnFlights()
    }

    /// Reads the user's flights from Flighty in the background.
    func reloadOwnFlights() {
        Task {
            let flights = await Task.detached(priority: .utility) { Flighty.ownFlights() }.value
            if flights != ownFlights {
                ownFlights = flights
                refreshMine()
            }
        }
    }

    /// Runway alignment of the user's aircraft over the last 15 minutes, on
    /// the runways of its destination. Kept 5 minutes after it ends.
    ///
    /// A confirmed alignment is remembered for the flight: after it, the
    /// aircraft has landed and no route is drawn any more, however long ago.
    /// Going back in time before it shows the flight as before.
    private func alignment(of id: String, flight: OwnFlight, at t: Double) -> Alignment? {
        guard let dataset, let thresholds = Runways.byAirport[flight.destination] else { return nil }
        let key = "\(flight.number)@\(Int(flight.departure))"
        let path = dataset.recentPath(of: id, from: t - 900, to: t)
        if let found = Landing.latest(path, thresholds: thresholds) {
            if found.confirmed { landed[key] = found }
            if found.ongoing || t - found.end < 300 { return found }
        }
        // Jumped past the landing in a replay: look back over the whole
        // flight, at most once per minute of displayed time.
        if landed[key] == nil, t - 900 > flight.departure - 1800, abs(t - (scanned[key] ?? -.infinity)) > 60 {
            scanned[key] = t
            let whole = dataset.recentPath(of: id, from: flight.departure - 1800, to: t)
            if let found = Landing.latest(whole, thresholds: thresholds), found.confirmed { landed[key] = found }
        }
        if var past = landed[key], t >= past.start {
            past.ongoing = false
            return past
        }
        return nil
    }

    /// The aircraft flying one of the user's flights now: its tail number,
    /// turned into an ICAO address by the aircraft database, among what is heard.
    private func refreshMine() {
        var id: String?
        var flight: OwnFlight?
        let t = currentTime
        let flying = ownFlights.filter { $0.covers(t) }
        for candidate in flying {
            guard let tail = candidate.tail, let address = database.address(ofRegistration: tail),
                  entities.contains(where: { $0.id == address && $0.latitude != nil })
            else { continue }
            id = address
            flight = candidate
            break
        }
        // Tail unknown (not assigned yet, or not in the aircraft database):
        // the callsign, when it is the airline's ICAO code and the flight
        // number (AF162 → AFR162). Signal level is no help: on board, the
        // receiver does not hear its own aircraft louder than the others.
        if id == nil {
            for candidate in flying {
                guard let callsign = candidate.callsign,
                      let entity = entities.first(where: { $0.latitude != nil && $0.name?.uppercased() == callsign })
                else { continue }
                id = entity.id
                flight = candidate
                break
            }
        }
        if id != mineID { mineID = id }
        if flight != mineFlight { mineFlight = flight }
        let alignment = id.flatMap { id in flight.flatMap { alignment(of: id, flight: $0, at: t) } }
        if alignment != mineAlignment { mineAlignment = alignment }
        var centerline: [LatLon] = []
        if let threshold = alignment.map(\.threshold) {
            let outer = Geo.destination(threshold.position, bearing: threshold.bearing + 180, distance: 10 * 1852)
            centerline = [outer, threshold.position]
        }
        if centerline != mineCenterline { mineCenterline = centerline }
        // The dashed route stops once the aircraft is confirmed on a runway:
        // the aligned segment shows the rest, and after landing nothing more.
        var route: [LatLon] = []
        if let id, id == selectedID, let flight, alignment?.confirmed != true,
           let entity = entities.first(where: { $0.id == id }),
           let latitude = entity.latitude, let longitude = entity.longitude {
            let target = alignment.flatMap { $0.ongoing ? $0.threshold.position : nil } ?? flight.destinationPosition
            route = [LatLon(latitude: latitude, longitude: longitude), target]
        }
        if route != mineRoute { mineRoute = route }
    }

    var isLive: Bool { dataset?.isLive ?? false }

    var selected: Entity? {
        guard let selectedID else { return nil }
        return entities.first { $0.id == selectedID }
    }

    // MARK: Recordings

    /// Adds files to the sidebar and shows them.
    func add(_ urls: [URL]) {
        let urls = urls.filter(RecordingLoader.isSupported).sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !urls.isEmpty else {
            loadError = "Drop jet1090 or ship162 recordings (.jsonl, .jsonl.zst or .jsonl.7z)."
            return
        }
        for url in urls where !sources.contains(where: { $0.id == url.path }) {
            sources.append(SourceItem(url: url))
        }
        let wanted = Set(urls.map(\.path))
        if selection == wanted {
            // Opening the displayed recording again reloads it.
            activate()
        } else {
            selection = wanted
        }
    }

    func remove(_ item: SourceItem) {
        sources.removeAll { $0.id == item.id }
        selection.remove(item.id)
    }

    // MARK: Live sources

    func status(of source: LiveSource) -> LiveStatus {
        liveStatus[source.id] ?? .off
    }

    /// USB devices, kept up to date as they are plugged and unplugged.
    let usb = UsbMonitor()

    /// The plugged receiver a device source refers to, if any.
    func receiver(for source: LiveSource) -> UsbDevice? {
        source.device?.match(in: usb.receivers)
    }

    func isRunning(_ source: LiveSource) -> Bool {
        feeds[source.id] != nil
    }

    func toggle(_ source: LiveSource) {
        if isRunning(source) { stop(source) } else { start(source) }
    }

    /// Starts receiving from a source and displays the live view.
    func start(_ source: LiveSource) {
        // Receivers are not connected to a decoder yet.
        guard feeds[source.id] == nil, !source.isDevice else { return }
        let id = source.id
        let feed = LiveFeed(
            source: source,
            onStatus: { [weak self] status in
                Task { @MainActor in
                    guard let self, self.feeds[id] != nil else { return }
                    switch status {
                    case .connecting: self.liveStatus[id] = .connecting
                    case .connected: self.liveStatus[id] = .connected
                    case let .failed(message): self.liveStatus[id] = .failed(message)
                    }
                }
            },
            onBatch: { [weak self] batch in
                Task { @MainActor in
                    guard let self, self.feeds[id] != nil else { return }
                    let live = self.liveDataset
                    live.merge(batch)
                    if self.dataset === live {
                        self.revision = live.revision
                        if live.start.isFinite { self.rangeStart = live.start }
                    }
                }
            }
        )
        feeds[id] = feed
        liveStatus[id] = .connecting
        feed.start()
        if !isLive { selection = [Self.tag(source)] }
    }

    func stop(_ source: LiveSource) {
        feeds[source.id]?.stop()
        feeds[source.id] = nil
        liveStatus[source.id] = nil
    }

    /// Adds a source, or replaces the one with the same id; a running one restarts.
    func save(_ source: LiveSource, persist: Bool = true) {
        if let i = liveSources.firstIndex(where: { $0.id == source.id }) {
            let wasRunning = isRunning(liveSources[i])
            stop(liveSources[i])
            liveSources[i] = source
            if wasRunning { start(source) }
        } else {
            liveSources.append(source)
        }
        if persist { persistLiveSources() }
    }

    func remove(_ source: LiveSource) {
        stop(source)
        liveSources.removeAll { $0.id == source.id }
        selection.remove(Self.tag(source))
        persistLiveSources()
    }

    /// Forgets everything received live so far; sources keep running.
    func clearLive() {
        let wasDisplayed = isLive
        liveDataset = Dataset(name: "Live", isLive: true, database: database)
        if wasDisplayed {
            selectedID = nil
            show(liveDataset)
        }
    }

    // MARK: Aircraft database

    /// Switches to another database and looks all aircraft up again.
    func useDatabase(_ source: AircraftDatabase.Source) {
        switch source {
        case .jet1090: UserDefaults.standard.removeObject(forKey: Self.databaseKey)
        case let .file(url): UserDefaults.standard.set(url.path, forKey: Self.databaseKey)
        }
        Task {
            var table: [String: AircraftDatabase.Record]?
            if case let .file(url) = source, AircraftDatabase.isTable(url) {
                table = await Task.detached(priority: .userInitiated) { AircraftDatabase.readTable(url) }.value
            }
            let database = AircraftDatabase(source: source, table: table)
            self.database = database
            liveDataset.use(database)
            if let dataset, dataset !== liveDataset { dataset.use(database) }
            revision = dataset?.revision ?? 0
            refresh()
        }
    }

    private func persistLiveSources() {
        if let data = try? JSONEncoder().encode(liveSources) {
            UserDefaults.standard.set(data, forKey: Self.liveSourcesKey)
        }
    }

    // MARK: Display

    private func activate() {
        let live = selection.filter { $0.hasPrefix(Self.livePrefix) }
        if !live.isEmpty, live.count < selection.count {
            // Live and recordings are not mixed; this re-enters activate().
            selection = live
            return
        }

        loading?.cancel()
        loading = nil
        loadProgress = nil
        loadError = nil

        if !live.isEmpty {
            // With nothing running, selecting a source starts it.
            if feeds.isEmpty {
                for source in liveSources where live.contains(Self.tag(source)) { start(source) }
            }
            if !isLive {
                isPlaying = false
                selectedID = nil
                show(liveDataset)
            }
        } else {
            isPlaying = false
            selectedID = nil
            let items = sources.filter { selection.contains($0.id) }
            if items.isEmpty {
                show(nil)
            } else {
                load(items)
            }
        }
    }

    private func show(_ dataset: Dataset?) {
        self.dataset = dataset
        revision = dataset?.revision ?? 0
        entities = []
        selectedTrack = []
        guard let dataset else { return }
        if dataset.isLive {
            let now = Date().timeIntervalSince1970
            rangeStart = dataset.start.isFinite ? dataset.start : now - 1
            rangeEnd = now
            following = true
            currentTime = now
        } else {
            rangeStart = dataset.start
            rangeEnd = max(dataset.end, dataset.start + 1)
            currentTime = dataset.start
            isPlaying = true
        }
        refresh()
        startTicker()
    }

    private func load(_ items: [SourceItem]) {
        let urls = items.map(\.url)
        let name = items.count == 1 ? items[0].title : "\(items.count) recordings"
        loadProgress = 0
        loading = Task {
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try RecordingLoader.load(urls) { fraction in
                        Task { @MainActor in
                            if self.loadProgress != nil { self.loadProgress = fraction }
                        }
                    }
                }
                // Cancelling the load stops the worker too.
                let series = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled else { return }
                let dataset = Dataset(name: name, isLive: false, database: database)
                dataset.merge(series)
                show(dataset)
            } catch is CancellationError {
                return
            } catch {
                show(nil)
                loadError = error.localizedDescription
            }
            loadProgress = nil
        }
    }

    // MARK: Clock

    func togglePlayback() {
        guard let dataset, !dataset.isLive else { return }
        if !isPlaying, currentTime >= rangeEnd { currentTime = rangeStart }
        isPlaying.toggle()
    }

    /// Jumps to an instant; in live mode this leaves the present.
    func seek(to time: Double) {
        guard dataset != nil else { return }
        if isLive { following = false }
        currentTime = min(rangeEnd, max(rangeStart, time))
    }

    func followLive() {
        guard isLive else { return }
        following = true
        currentTime = Date().timeIntervalSince1970
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                let live = self?.isLive ?? false
                try? await Task.sleep(for: .milliseconds(live ? 500 : 100))
                guard let self else { return }
                let now = ContinuousClock.now
                let elapsed = now - last
                last = now
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
                self.tick(seconds)
            }
        }
    }

    private func tick(_ elapsed: Double) {
        guard dataset != nil else { return }
        if isLive {
            let now = Date().timeIntervalSince1970
            rangeEnd = now
            if following {
                currentTime = now
            }
        } else if isPlaying {
            let next = min(rangeEnd, currentTime + elapsed * speed)
            currentTime = next
            if next >= rangeEnd { isPlaying = false }
        }
    }

    private func refresh() {
        guard let dataset else { return }
        entities = dataset.entities(at: currentTime)
        refreshTrack()
        refreshMine()
        let stations = dataset.groundStations(until: currentTime).map {
            TrackMark(id: "g" + $0.key, kind: .groundStation, position: $0.position, label: "\($0.code)\n\($0.details)")
        }
        if stations != stationMarks { stationMarks = stations }
        refreshInterrogators()
    }

    /// How long after its last interrogation an aircraft counts as
    /// interrogated: two turns of the antenna, at least 15 s.
    private static func window(_ period: Double?) -> Double { max(15, 2 * (period ?? 8)) }

    private func refreshInterrogators() {
        guard let dataset else {
            if !radarMarks.isEmpty { radarMarks = [] }
            if !highlighted.isEmpty { highlighted = [] }
            return
        }
        let interrogators = dataset.interrogators
        let now = currentTime
        let active = dataset.activeInterrogators(from: now - 120, to: now)
        // One badge per site, listing its codes.
        var bySite: [String: RadarMark] = [:]
        for code in active.sorted() {
            guard let interrogator = interrogators[code] else { continue }
            for name in dataset.activeSites(of: code, from: now - 120, to: now).sorted() {
                guard let fit = interrogator.fit(named: name) else { continue }
                let rotation = fit.period ?? interrogator.period
                let window = Self.window(rotation)
                // Blinks when the selected aircraft belongs to this population.
                let blinking = selectedID.map {
                    (interrogator.site(of: $0, at: now) ?? interrogator.site(of: $0, at: now - window)) == name
                        && dataset.interrogated(by: code, from: now - window, to: now).contains($0)
                } ?? false
                let period = rotation.map { max(1, $0.rounded()) }
                var mark = bySite[name] ?? RadarMark(
                    codes: [], name: name, position: fit.site.position, period: nil, blinking: false,
                    basis: fit.site.basis, selected: name == selectedRadar
                )
                mark.codes.append(code)
                if !fit.consistent { mark.doubtful.insert(code) }
                mark.fits.append(RadarCodeFit(
                    code: code, period: rotation, aircraft: fit.aircraft, located: interrogator.located,
                    medianDistance: fit.medianDistance, consistent: fit.consistent
                ))
                if blinking, !mark.blinking || mark.period == nil {
                    mark.blinking = true
                    mark.period = period
                } else if mark.period == nil {
                    mark.period = period
                }
                bySite[name] = mark
            }
        }
        let marks = bySite.values.sorted { $0.name < $1.name }
        if marks != radarMarks { radarMarks = marks }
        func lit(_ codes: [String]) -> Set<String> {
            codes.reduce(into: Set<String>()) { result, code in
                result.formUnion(dataset.interrogated(by: code, from: now - Self.window(interrogators[code]?.period), to: now))
            }
        }
        // The card stays open when its radar falls silent, marked as such.
        var card = selectedRadar.flatMap { name in marks.first { $0.id == name } }
        if card == nil, var previous = selectedRadarMark, previous.id == selectedRadar {
            previous.heard = false
            previous.blinking = false
            card = previous
        }
        if card != selectedRadarMark { selectedRadarMark = card }
        let selectedLit = lit(card?.heard == true ? card!.codes : [])
        if selectedLit.count != selectedRadarCount { selectedRadarCount = selectedLit.count }
        let all = lit(hoveredInterrogators).union(selectedLit)
        if all != highlighted { highlighted = all }
    }

    private func refreshTrack() {
        guard let dataset, let id = selectedID else {
            if !selectedTrack.isEmpty { selectedTrack = [] }
            if !selectedMarks.isEmpty { selectedMarks = [] }
            return
        }
        let track = dataset.track(for: id, until: currentTime)
        if track != selectedTrack { selectedTrack = track }

        var marks: [TrackMark] = []
        let time = Date.FormatStyle(timeZone: .gmt).hour(.twoDigits(amPM: .omitted)).minute().second()
        for (n, message) in dataset.datalink(of: id).enumerated() where message.t <= currentTime {
            guard let position = dataset.position(of: id, at: message.t) else { continue }
            let when = Date(timeIntervalSince1970: message.t).formatted(time)
            marks.append(TrackMark(
                id: "d\(n)", kind: message.fromAircraft ? .datalinkDown : .datalinkUp,
                position: position, label: "\(when)  \(message.summary)",
                link: message.stationPosition
            ))
        }
        for (n, uplink) in dataset.uplinks(of: id).enumerated() where uplink.origin == .resolution && uplink.t <= currentTime {
            guard let position = dataset.position(of: id, at: uplink.t) else { continue }
            let when = Date(timeIntervalSince1970: uplink.t).formatted(time)
            marks.append(TrackMark(id: "r\(n)", kind: .resolution, position: position, label: "\(when)  TCAS resolution coordination"))
        }
        if marks != selectedMarks { selectedMarks = marks }
    }
}
