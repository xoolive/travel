import Foundation

/// All series of the active source (a recording or a live feed), queried by time.
@MainActor
final class Dataset {
    static let maxTrackPoints = 3000
    static let maxPlotPoints = 600
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
    private var south = 90.0, north = -90.0, west = 180.0, east = -180.0

    init(name: String, isLive: Bool) {
        self.name = name
        self.isLive = isLive
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
        series.reduce(0) { $0 + ($1.kind == kind ? 1 : 0) }
    }

    func kind(of id: String) -> Kind? {
        index[id].map { series[$0].kind }
    }

    func name(of id: String) -> String? {
        index[id].flatMap { series[$0].name }
    }

    /// Appends new data; within a series it must be newer than what is stored.
    func merge(_ batch: [Series]) {
        for item in batch {
            if let first = item.activity.first { start = min(start, first) }
            if let last = item.activity.last { end = max(end, last) }
            for p in item.positions {
                south = min(south, p.latitude); north = max(north, p.latitude)
                west = min(west, p.longitude); east = max(east, p.longitude)
            }
            if let i = index[item.id] {
                series[i].append(item)
            } else {
                index[item.id] = series.count
                series.append(item)
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

    /// Track of one target up to time `t`, thinned for drawing. Reception
    /// gaps longer than `dashedGap` become separate dashed segments.
    func track(for id: String, until t: Double) -> [TrackSegment] {
        guard let i = index[id] else { return [] }
        let positions = series[i].positions
        let count = Self.upperBound(positions.count) { positions[$0].t <= t }
        guard count > 0 else { return [] }
        let step = max(1, (count + Self.maxTrackPoints - 1) / Self.maxTrackPoints)
        func point(_ p: Position) -> TrackPoint {
            TrackPoint(timestamp: p.t, latitude: p.latitude, longitude: p.longitude)
        }

        var segments: [TrackSegment] = []
        var run: [TrackPoint] = [point(positions[0])]
        var lastKept = 0
        for j in 1..<max(1, count) {
            if positions[j].t - positions[j - 1].t > Self.dashedGap {
                if run.last?.timestamp != positions[j - 1].t { run.append(point(positions[j - 1])) }
                segments.append(TrackSegment(points: run, isGap: false))
                segments.append(TrackSegment(points: [point(positions[j - 1]), point(positions[j])], isGap: true))
                run = [point(positions[j])]
                lastKept = j
            } else if j - lastKept >= step {
                run.append(point(positions[j]))
                lastKept = j
            }
        }
        let last = positions[count - 1]
        if run.last?.timestamp != last.t { run.append(point(last)) }
        segments.append(TrackSegment(points: run, isGap: false))

        // Inside a gap, extend up to where the target is shown now.
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
        return segments
    }

    /// One channel of one target over the whole dataset, thinned for plotting.
    func samples(for id: String, _ channel: Channel) -> [Sample] {
        guard let i = index[id] else { return [] }
        var all = series[i].channels[channel.rawValue]
        if channel == .altitude, all.count >= 3 {
            // Corrupted Mode S replies give isolated wild altitudes:
            // a median of three removes them.
            let raw = all
            for j in 1..<(raw.count - 1) {
                let (a, b, c) = (raw[j - 1].v, raw[j].v, raw[j + 1].v)
                all[j].v = max(min(a, b), min(max(a, b), c))
            }
        }
        let step = max(1, (all.count + Self.maxPlotPoints - 1) / Self.maxPlotPoints)
        guard step > 1 else { return all }
        return stride(from: 0, to: all.count, by: step).map { all[$0] }
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
