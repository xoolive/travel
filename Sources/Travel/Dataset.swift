import Foundation

/// All series of the active source (a recording or a live feed), queried by time.
@MainActor
final class Dataset {
    /// Track points closer than this to the simplified line are dropped, metres.
    static let trackTolerance = 3.0
    /// Below this speed (100 kt, in m/s) the track is kept nearly whole.
    static let slowSpeed = 51.4
    /// Smallest movement kept at low speed, metres.
    static let slowStep = 1.5
    /// Received positions further apart than this are joined by a curve, seconds.
    static let sparseInterval = 6.0
    /// Spacing of the points drawn along such a curve, seconds.
    static let curveStep = 3.0
    /// The same for plots, as a fraction of the range of values.
    static let plotTolerance = 0.003
    static let maxPlotPoints = 3000
    /// Longer position gaps are drawn dashed.
    static let dashedGap = 300.0
    /// A target is kept on the map across position gaps up to this long.
    static let maxBridge = 7200.0
    /// Reported values are shown this long after they were received.
    static let valueTimeout = 300.0

    let id = UUID()
    let name: String
    let isLive: Bool

    private(set) var series: [Series] = []
    private(set) var start = Double.infinity
    private(set) var end = -Double.infinity
    /// Bumped on every merge.
    private(set) var revision = 0

    private var index: [String: Int] = [:]
    private var trackCache: (id: String, revision: Int, runs: [[Position]])?
    private var turbulenceCache: (id: String, revision: Int, minutes: [TurbulenceMinute])?
    private var plotCache: (revision: Int, entries: [String: [(sample: Sample, run: Int)]]) = (0, [:])
    private var south = 90.0, north = -90.0, west = 180.0, east = -180.0

    /// Where registrations and type codes of aircraft come from.
    private var database: AircraftDatabase?

    init(name: String, isLive: Bool, database: AircraftDatabase?) {
        self.name = name
        self.isLive = isLive
        self.database = database
    }

    /// Looks every aircraft up again in another database.
    func use(_ database: AircraftDatabase?) {
        self.database = database
        for i in series.indices where series[i].kind == .aircraft { identify(i) }
        revision += 1
    }

    var hasPositions: Bool { south <= north }

    var center: LatLon {
        LatLon(latitude: (south + north) / 2, longitude: (west + east) / 2)
    }

    /// Diagonal of the bounding box, metres.
    var extent: Double {
        Geo.distance(LatLon(latitude: south, longitude: west), LatLon(latitude: north, longitude: east))
    }

    func count(of kind: Kind) -> Int {
        series.reduce(0) { $0 + ($1.kind == kind && !$1.activity.isEmpty ? 1 : 0) }
    }

    func uplinks(of id: String) -> [Uplink] {
        index[id].map { series[$0].uplinks } ?? []
    }

    /// The same frame is often decoded on neighbouring channels at once:
    /// such copies are merged, keeping the list of channels.
    func datalink(of id: String) -> [DatalinkMessage] {
        guard let i = index[id] else { return [] }
        var merged: [DatalinkMessage] = []
        for message in series[i].datalink {
            if let last = merged.last, message.t - last.t < 1,
               last.summary == message.summary, last.text == message.text,
               last.station == message.station, last.fromAircraft == message.fromAircraft {
                if let channel = message.channel { merged[merged.count - 1].channels.append(channel) }
                continue
            }
            var first = message
            first.channels = message.channel.map { [$0] } ?? []
            merged.append(first)
        }
        return merged
    }

    /// Where an aircraft was at time `t`, between received positions.
    func position(of id: String, at t: Double) -> LatLon? {
        guard let i = index[id] else { return nil }
        let positions = series[i].positions
        let after = Self.upperBound(positions.count) { positions[$0].t <= t }
        guard after > 0 else { return positions.first.map { LatLon(latitude: $0.latitude, longitude: $0.longitude) } }
        let p = positions[after - 1]
        guard after < positions.count, positions[after].t - p.t <= Self.maxBridge else {
            return LatLon(latitude: p.latitude, longitude: p.longitude)
        }
        return Self.interpolate(p, positions[after], at: t)
    }

    func kind(of id: String) -> Kind? {
        index[id].map { series[$0].kind }
    }

    func name(of id: String) -> String? {
        index[id].flatMap { series[$0].name }
    }

    /// Fills in what the aircraft database and the address ranges say.
    private func identify(_ i: Int) {
        let record = database?.lookup(series[i].id)
        series[i].info.registration = record?.registration
        series[i].info.typecode = record?.typecode
        if let origin = Countries.lookup(icao24: series[i].id, registration: record?.registration) {
            series[i].info.country = origin.country
            series[i].info.flag = origin.flag
        }
    }

    /// Appends new data; within a series it must be newer than what is stored.
    func merge(_ batch: [Series]) {
        for item in batch {
            // Interrogations and datalink also extend the time range, so that
            // a file of either alone can be replayed.
            let times = [item.activity.first, item.activity.last, item.uplinks.first?.t, item.uplinks.last?.t,
                         item.datalink.first?.t, item.datalink.last?.t].compactMap { $0 }
            if let first = times.min() { start = min(start, first) }
            if let last = times.max() { end = max(end, last) }
            for p in item.positions {
                south = min(south, p.latitude); north = max(north, p.latitude)
                west = min(west, p.longitude); east = max(east, p.longitude)
            }
            if let i = index[item.id] {
                series[i].append(item)
            } else {
                index[item.id] = series.count
                series.append(item)
                if item.kind == .aircraft { identify(series.count - 1) }
            }
        }
        revision += 1
    }

    /// Targets heard from within their timeout before `t`.
    func entities(at t: Double) -> [Entity] {
        var result: [Entity] = []
        for item in series {
            if let entity = entity(of: item, at: t) { result.append(entity) }
        }
        return result
    }

    /// Track of one target up to time `t`. Reception gaps longer than
    /// `dashedGap` become separate dashed segments. Points are thinned where
    /// the path is straight and kept where it bends.
    func track(for id: String, until t: Double) -> [TrackSegment] {
        guard let i = index[id] else { return [] }
        let positions = series[i].positions
        let count = Self.upperBound(positions.count) { positions[$0].t <= t }
        guard count > 0 else { return [] }
        func point(_ p: Position) -> TrackPoint {
            TrackPoint(timestamp: p.t, latitude: p.latitude, longitude: p.longitude)
        }

        var segments: [TrackSegment] = []
        var previous: Position?
        for run in simplifiedRuns(id, positions) {
            guard let first = run.first, first.t <= t else { break }
            if let previous { segments.append(TrackSegment(points: [point(previous), point(first)], isGap: true)) }
            let shown = Self.upperBound(run.count) { run[$0].t <= t }
            segments.append(TrackSegment(points: run[..<shown].map(point), isGap: false))
            guard shown == run.count else { break }
            previous = run.last
        }

        // Up to the exact position now, between or beyond the kept points.
        let last = positions[count - 1]
        if let tail = segments.last?.points.last, tail.timestamp < last.t {
            segments[segments.count - 1].points.append(point(last))
        }
        if count < positions.count, t > last.t {
            let next = positions[count]
            let gap = next.t - last.t
            if gap <= Self.maxBridge {
                let here = Self.interpolate(last, next, at: t)
                let now = TrackPoint(timestamp: t, latitude: here.latitude, longitude: here.longitude)
                if gap > Self.dashedGap {
                    segments.append(TrackSegment(points: [point(last), now], isGap: true))
                } else {
                    segments[segments.count - 1].points.append(now)
                }
            }
        }
        // Minutes above the turbulence threshold are drawn over the track.
        for minute in turbulence(for: id) where minute.qualifies && minute.start <= t {
            let from = Self.upperBound(positions.count) { positions[$0].t < minute.start }
            let to = Self.upperBound(positions.count) { positions[$0].t <= min(t, minute.start + 60) }
            guard to - from >= 2 else { continue }
            segments.append(TrackSegment(
                points: positions[from..<to].map(point), isGap: false,
                mark: minute.isTurbulent ? .turbulent : .aboveThreshold
            ))
        }
        return segments
    }

    /// Minute-by-minute turbulence measure of an aircraft; cached for the
    /// target last asked for.
    func turbulence(for id: String) -> [TurbulenceMinute] {
        if let cache = turbulenceCache, cache.id == id, cache.revision == revision { return cache.minutes }
        guard let i = index[id], series[i].kind == .aircraft else { return [] }
        let channels = series[i].channels
        let minutes = Turbulence.analyse(
            barometric: channels[Channel.vrateBarometric.rawValue],
            inertial: channels[Channel.vrateInertial.rawValue],
            verticalRate: channels[Channel.verticalRate.rawValue],
            track: channels[Channel.track.rawValue],
            altitude: channels[Channel.altitude.rawValue]
        )
        turbulenceCache = (id, revision, minutes)
        return minutes
    }

    /// The whole track of a target, split at long gaps and prepared for
    /// drawing; cached for the target last asked for.
    private func simplifiedRuns(_ id: String, _ positions: [Position]) -> [[Position]] {
        if let cache = trackCache, cache.id == id, cache.revision == revision { return cache.runs }
        var runs: [[Position]] = []
        var start = 0
        for j in 1...positions.count {
            guard j == positions.count || positions[j].t - positions[j - 1].t > Self.dashedGap else { continue }
            runs.append(Self.prepare(positions, start..<j))
            start = j
        }
        trackCache = (id, revision, runs)
        return runs
    }

    /// Thins one run where the path is straight, keeps nearly everything at
    /// low speed, and rounds the path where reception was sparse.
    private static func prepare(_ positions: [Position], _ range: Range<Int>) -> [Position] {
        func location(_ p: Position) -> LatLon { LatLon(latitude: p.latitude, longitude: p.longitude) }
        var keep = [Bool](repeating: false, count: range.count)
        for k in Simplify.keep(range, tolerance: trackTolerance, deviation: { a, b, p in
            offset(of: positions[p], from: positions[a], to: positions[b])
        }) {
            keep[k - range.lowerBound] = true
        }

        // On the ground and at low speed every movement is kept, down to
        // `slowStep` metres, so that taxiing is drawn as it happened.
        var anchor = positions[range.lowerBound]
        for k in range.dropFirst() {
            let dt = positions[k].t - positions[k - 1].t
            let speed = dt > 0 ? Geo.distance(location(positions[k - 1]), location(positions[k])) / dt : 0
            if keep[k - range.lowerBound] {
                anchor = positions[k]
            } else if speed < slowSpeed, Geo.distance(location(anchor), location(positions[k])) >= slowStep {
                keep[k - range.lowerBound] = true
                anchor = positions[k]
            }
        }
        let kept = range.filter { keep[$0 - range.lowerBound] }

        // Where two consecutive received positions are far apart in time, a
        // straight line cuts the turn: a curve through the neighbouring
        // points, at their speeds, is drawn instead.
        func velocity(_ n: Int) -> (Double, Double) {
            let a = positions[kept[max(0, n - 1)]], b = positions[kept[min(kept.count - 1, n + 1)]]
            let dt = max(b.t - a.t, 1e-6)
            return ((b.latitude - a.latitude) / dt, (b.longitude - a.longitude) / dt)
        }
        var result: [Position] = []
        result.reserveCapacity(kept.count)
        for n in kept.indices {
            let a = positions[kept[n]]
            result.append(a)
            guard n + 1 < kept.count, kept[n + 1] == kept[n] + 1 else { continue }
            let b = positions[kept[n + 1]]
            let dt = b.t - a.t
            guard dt > sparseInterval, Geo.distance(location(a), location(b)) > 200 else { continue }
            let (va, vb) = (velocity(n), velocity(n + 1))
            let steps = min(40, Int(dt / curveStep))
            for step in 1..<max(1, steps) {
                let u = Double(step) / Double(steps)
                let h00 = 2 * u * u * u - 3 * u * u + 1, h10 = u * u * u - 2 * u * u + u
                let h01 = -2 * u * u * u + 3 * u * u, h11 = u * u * u - u * u
                result.append(Position(
                    t: a.t + u * dt,
                    latitude: h00 * a.latitude + h10 * dt * va.0 + h01 * b.latitude + h11 * dt * vb.0,
                    longitude: h00 * a.longitude + h10 * dt * va.1 + h01 * b.longitude + h11 * dt * vb.1
                ))
            }
        }
        return result
    }

    /// Distance in metres from `p` to the segment `a`–`b`, on a local flat Earth.
    private static func offset(of p: Position, from a: Position, to b: Position) -> Double {
        let k = cos((a.latitude + b.latitude) / 2 * .pi / 180) * 111_320
        func wrapped(_ degrees: Double) -> Double { (degrees + 540).truncatingRemainder(dividingBy: 360) - 180 }
        let bx = wrapped(b.longitude - a.longitude) * k, by = (b.latitude - a.latitude) * 110_540
        let px = wrapped(p.longitude - a.longitude) * k, py = (p.latitude - a.latitude) * 110_540
        let length = bx * bx + by * by
        let f = length > 0 ? min(1, max(0, (px * bx + py * by) / length)) : 0
        return ((px - f * bx) * (px - f * bx) + (py - f * by) * (py - f * by)).squareRoot()
    }

    /// One channel of one target over the whole dataset, thinned for plotting:
    /// flat stretches keep few points, changes keep their detail.
    /// `run` numbers the stretches of continuous reception: it increases
    /// whenever two consecutive samples are more than `gap` seconds apart.
    func samples(for id: String, _ channel: Channel, gap: Double) -> [(sample: Sample, run: Int)] {
        let key = "\(id) \(channel.rawValue) \(gap)"
        if plotCache.revision != revision { plotCache = (revision, [:]) }
        if let cached = plotCache.entries[key] { return cached }
        guard let i = index[id] else { return [] }
        var all = series[i].channels[channel.rawValue]
        guard !all.isEmpty else { return [] }
        if channel == .altitude, all.count >= 3 {
            // Corrupted Mode S replies give isolated wild altitudes:
            // a median of three removes them.
            let raw = all
            for j in 1..<(raw.count - 1) {
                let (a, b, c) = (raw[j - 1].v, raw[j].v, raw[j + 1].v)
                all[j].v = max(min(a, b), min(max(a, b), c))
            }
        }

        var bounds: [Range<Int>] = []
        var start = 0
        for j in 1...all.count where j == all.count || all[j].t - all[j - 1].t > gap {
            bounds.append(start..<j)
            start = j
        }
        let low = all.map(\.v).min() ?? 0, high = all.map(\.v).max() ?? 0
        // Noisy series would keep everything: loosen until the plot is light.
        var tolerance = max(1e-9, (high - low) * Self.plotTolerance)
        var result: [(sample: Sample, run: Int)] = []
        for _ in 0..<8 {
            result.removeAll(keepingCapacity: true)
            for (run, range) in bounds.enumerated() {
                let kept = Simplify.keep(range, tolerance: tolerance) { a, b, p in
                    // Vertical distance from the straight line between a and b.
                    let f = (all[p].t - all[a].t) / max(all[b].t - all[a].t, 1e-9)
                    return abs(all[p].v - (all[a].v + (all[b].v - all[a].v) * f))
                }
                result.append(contentsOf: kept.map { (all[$0], run) })
            }
            if result.count <= Self.maxPlotPoints { break }
            tolerance *= 2
        }
        plotCache.entries[key] = result
        return result
    }

    /// Position between two samples; along the great circle when they are far apart in time.
    private static func interpolate(_ p: Position, _ q: Position, at t: Double) -> LatLon {
        let f = min(1, max(0, (t - p.t) / max(q.t - p.t, 1e-6)))
        if q.t - p.t > 60 {
            return Geo.interpolate(
                LatLon(latitude: p.latitude, longitude: p.longitude),
                LatLon(latitude: q.latitude, longitude: q.longitude),
                fraction: f
            )
        }
        return LatLon(
            latitude: p.latitude + (q.latitude - p.latitude) * f,
            longitude: p.longitude + (q.longitude - p.longitude) * f
        )
    }

    private func entity(of item: Series, at t: Double) -> Entity? {
        let timeout = item.kind.timeout
        guard let first = item.activity.first, first <= t else { return nil }
        let heard = Self.upperBound(item.activity.count) { item.activity[$0] <= t }
        guard heard > 0 else { return nil }
        let recentlyHeard = t - item.activity[heard - 1] <= timeout

        // A target that is silent now but whose position is known again later
        // stays on the map, moved along the bridge between both positions.
        let positions = item.positions
        let after = Self.upperBound(positions.count) { positions[$0].t <= t }
        var latitude: Double?, longitude: Double?
        var bridging = false
        var derivedTrack = Double.nan
        if after > 0 {
            let p = positions[after - 1]
            if after < positions.count, positions[after].t - p.t <= Self.maxBridge {
                let q = positions[after]
                let here = Self.interpolate(p, q, at: t)
                latitude = here.latitude
                longitude = here.longitude
                bridging = q.t - p.t > timeout
                let to = LatLon(latitude: q.latitude, longitude: q.longitude)
                if Geo.distance(here, to) > 20 { derivedTrack = Geo.bearing(here, to) }
            } else if t - p.t <= timeout {
                latitude = p.latitude
                longitude = p.longitude
            }
        }
        guard recentlyHeard || bridging else { return nil }

        var values = [Double](repeating: .nan, count: Channel.allCases.count)
        for c in values.indices {
            let samples = item.channels[c]
            guard !samples.isEmpty else { continue }
            let k = Self.upperBound(samples.count) { samples[$0].t <= t }
            if k > 0, t - samples[k - 1].t <= Self.valueTimeout { values[c] = samples[k - 1].v }
        }
        // Across a gap the last reported track is stale: follow the bridge.
        if bridging || values[Channel.track.rawValue].isNaN, !derivedTrack.isNaN {
            values[Channel.track.rawValue] = derivedTrack
        }

        return Entity(
            id: item.id,
            kind: item.kind,
            name: item.name,
            info: item.info,
            latitude: latitude,
            longitude: longitude,
            values: values,
            count: heard,
            firstSeen: first,
            lastSeen: item.activity[heard - 1]
        )
    }

    /// Number of leading elements for which `predicate` holds (it must be monotonic).
    private static func upperBound(_ count: Int, _ predicate: (Int) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if predicate(mid) { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
