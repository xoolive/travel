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
        for suffix in [".zst", ".jsonl", ".json"] where stem.lowercased().hasSuffix(suffix) {
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
    private(set) var rangeStart = 0.0
    private(set) var rangeEnd = 1.0
    /// 0...1 while files are loading.
    private(set) var loadProgress: Double?
    var loadError: String?

    var selectedID: String? {
        didSet { if oldValue != selectedID { refreshTrack() } }
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
    @ObservationIgnored private var liveDataset = Dataset(name: "Live", isLive: true)
    @ObservationIgnored private var feeds: [UUID: LiveFeed] = [:]
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var loading: Task<Void, Never>?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.liveSourcesKey),
           let saved = try? JSONDecoder().decode([LiveSource].self, from: data) {
            liveSources = saved
        } else {
            liveSources = LiveSource.defaults
        }
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
            loadError = "Drop jet1090 or ship162 recordings (.jsonl or .jsonl.zst)."
            return
        }
        for url in urls where !sources.contains(where: { $0.id == url.path }) {
            sources.append(SourceItem(url: url))
        }
        selection = Set(urls.map(\.path))
    }

    func remove(_ item: SourceItem) {
        sources.removeAll { $0.id == item.id }
        selection.remove(item.id)
    }

    // MARK: Live sources

    func status(of source: LiveSource) -> LiveStatus {
        liveStatus[source.id] ?? .off
    }

    func isRunning(_ source: LiveSource) -> Bool {
        feeds[source.id] != nil
    }

    func toggle(_ source: LiveSource) {
        if isRunning(source) { stop(source) } else { start(source) }
    }

    /// Starts receiving from a source and displays the live view.
    func start(_ source: LiveSource) {
        guard feeds[source.id] == nil else { return }
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
        liveDataset = Dataset(name: "Live", isLive: true)
        if wasDisplayed {
            selectedID = nil
            show(liveDataset)
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
                let series = try await Task.detached(priority: .userInitiated) {
                    try RecordingLoader.load(urls) { fraction in
                        Task { @MainActor in
                            if self.loadProgress != nil { self.loadProgress = fraction }
                        }
                    }
                }.value
                guard !Task.isCancelled else { return }
                let dataset = Dataset(name: name, isLive: false)
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
    }

    private func refreshTrack() {
        guard let dataset, let id = selectedID else {
            if !selectedTrack.isEmpty { selectedTrack = [] }
            return
        }
        let track = dataset.track(for: id, until: currentTime)
        if track != selectedTrack { selectedTrack = track }
    }
}
