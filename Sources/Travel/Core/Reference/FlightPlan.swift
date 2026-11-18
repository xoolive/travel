import Foundation

/// A filed flight plan from a B2B `.flight.json` file (as collected for each
/// flight), shown with the aircraft it names, live or in a recording.
struct FlightPlan: Sendable, Equatable, Identifiable {
    var callsign: String
    /// ICAO 24-bit address, lowercase, when the plan carries it.
    var address: String?
    var departure: String
    var destination: String
    /// Estimated off-block time, UTC, as written in the plan.
    var eobt: String
    var aircraftType: String?
    var registration: String?
    /// ICAO field 15: speed, level and route.
    var route: String

    var id: String { "\(callsign) \(eobt)" }

    static func isPlan(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased().hasSuffix(".flight.json")
    }

    static func load(_ url: URL) -> FlightPlan? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let identity = root["identity"] as? [String: Any]
        else { return nil }
        let flight = (root["final"] as? [String: Any])?["flightData"] as? [String: Any] ?? [:]
        guard let route = flight["icaoRoute"] as? String, !route.isEmpty else { return nil }
        // The address is a hexadecimal string now, an integer in older files.
        let address: String? = switch flight["aircraftAddress"] {
        case let text as String: text.lowercased()
        case let number as NSNumber: String(format: "%06d", number.intValue)
        default: nil
        }
        return FlightPlan(
            callsign: (identity["callsign"] as? String ?? "").uppercased(),
            address: address,
            departure: identity["departure"] as? String ?? "",
            destination: identity["destination"] as? String ?? "",
            eobt: identity["eobt"] as? String ?? "",
            aircraftType: flight["aircraftType"] as? String,
            registration: flight["filedRegistrationMark"] as? String,
            route: route
        )
    }
}

/// A waypoint of a flight plan, placed on the map.
struct Waypoint: Sendable, Equatable {
    var name: String
    var position: LatLon
    var source: Source = .airac

    enum Source: String, Sendable {
        /// The EUROCONTROL AIXM baseline, or coordinates in the plan.
        case airac
        /// X-Plane's airways (`XPlaneAirways`): older data.
        case xplane
        /// The local procedures file (`Procedures`), typed in from an AIP.
        case local
    }
}

extension FlightPlan {
    /// The route of field 15 as points, resolved against the AIRAC data
    /// (Airac): departure airport, its SID, named points (each nearest the
    /// previous one: names repeat worldwide), airways expanded along their
    /// segments, coordinates, the STAR, destination airport. What the data
    /// does not know is skipped, which gives a straight leg.
    func waypoints() -> [Waypoint] {
        let airac = Airac.index()
        var result: [Waypoint] = []
        func add(_ name: String, _ position: LatLon, _ source: Waypoint.Source = .airac) {
            if result.last.map({ $0.position != position }) ?? true {
                result.append(Waypoint(name: name, position: position, source: source))
            }
        }
        if let start = airport(departure, airac) { add(departure, start) }

        // Elements of field 15, without speed/level groups and DCT.
        var elements = route.split(separator: " ").map { String($0.split(separator: "/").first ?? $0) }
        if let first = elements.first, first.wholeMatch(of: #/[NKM]\d{3,4}[FASM]\d{3,4}/#) != nil { elements.removeFirst() }
        elements.removeAll { $0 == "DCT" }

        var pendingAirway: String?
        for (n, token) in elements.enumerated() {
            let here = result.last?.position
            if n == 0, let airac, let legs = Self.procedure(token, at: departure, in: airac.0.departures) {
                // SID: from the airport to the next route point.
                let next = elements.dropFirst().first
                for point in Self.walk(legs, airac.0, to: next) { add(point.name, point.position) }
                continue
            }
            if n == 0, let fixes = Procedures.departure(token, at: departure, to: elements.dropFirst().first) {
                for fix in fixes { add(fix.name, fix.position, .local) }
                continue
            }
            if n == elements.count - 1, let airac, let legs = Self.procedure(token, at: destination, in: airac.0.arrivals) {
                for point in Self.walk(legs, airac.0, from: result.last?.name) { add(point.name, point.position) }
                continue
            }
            if n == elements.count - 1, let fixes = Procedures.arrival(token, at: destination, from: result.last?.name) {
                for fix in fixes { add(fix.name, fix.position, .local) }
                continue
            }
            if let position = Self.coordinates(token) {
                add(token, position)
                continue
            }
            if let airac, airac.0.airways[token] != nil {
                pendingAirway = token
                continue
            }
            // Not in the AIRAC data: X-Plane's airways, when it has one.
            if airac?.1[token] == nil, XPlaneAirways.has(token) {
                pendingAirway = token
                continue
            }
            guard let airac, let ids = airac.1[token], let here else { continue }
            let target = ids.compactMap { id in airac.0.points[id].map { (id, $0) } }
                .min { Geo.distance($0.1.position, here) < Geo.distance($1.1.position, here) }
            guard let target else { continue }
            if let airway = pendingAirway, let from = result.last?.name {
                if airac.0.airways[airway] != nil,
                   let path = Self.along(airway, from: from, near: here, to: target.0, airac.0) {
                    for point in path { add(point.name, point.position) }
                } else if let last = result.last,
                          let fixes = XPlaneAirways.between(airway, from: last, to: Waypoint(name: token, position: target.1.position)) {
                    for fix in fixes { add(fix.name, fix.position, .xplane) }
                }
            }
            pendingAirway = nil
            add(token, target.1.position)
        }
        if let end = airport(destination, airac) { add(destination, end) }
        return result
    }

    private func airport(_ code: String, _ airac: (AiracIndex, [String: [String]])?) -> LatLon? {
        airac?.1[code]?.compactMap { airac?.0.points[$0] }.first?.position ?? Airports.position(of: code)
    }

    /// The legs of a SID or STAR (LANVI7A at LFPG). When the AIRAC data is
    /// older or newer than the plan, the revision number differs (LANVI6A):
    /// the same point and suffix letter with another number is taken.
    private static func procedure(_ designator: String, at airport: String, in table: [String: [[String]]]) -> [[String]]? {
        if let legs = table["\(designator)@\(airport)"] { return legs }
        guard let match = designator.wholeMatch(of: #/([A-Z]{2,5})\d([A-Z]?)/#) else { return nil }
        let candidates = table.keys.filter { key in
            guard let m = key.wholeMatch(of: #/([A-Z]{2,5})\d([A-Z]?)@([A-Z0-9]{4})/#) else { return false }
            return m.1 == match.1 && m.2 == match.2 && m.3 == airport
        }
        return candidates.sorted().last.flatMap { table[$0] }
    }

    /// Points of an airway strictly between the point named `from` (nearest
    /// `near`) and the point `to`, along its segments (either direction).
    private static func along(_ airway: String, from: String, near: LatLon, to: String, _ index: AiracIndex) -> [AiracIndex.Point]? {
        guard let segments = index.airways[airway] else { return nil }
        var graph: [String: [String]] = [:]
        for s in segments where s.count == 2 {
            graph[s[0], default: []].append(s[1])
            graph[s[1], default: []].append(s[0])
        }
        let starts = graph.keys.filter { index.points[$0]?.name == from }
            .sorted { Geo.distance(index.points[$0]!.position, near) < Geo.distance(index.points[$1]!.position, near) }
        guard let start = starts.first else { return nil }
        let targetName = index.points[to]?.name
        var previous: [String: String] = [start: start]
        var queue = [start]
        while !queue.isEmpty {
            let node = queue.removeFirst()
            if node == to || index.points[node]?.name == targetName, node != start {
                var path: [String] = []
                var cursor = previous[node]!
                while cursor != start { path.append(cursor); cursor = previous[cursor]! }
                return path.reversed().compactMap { index.points[$0] }
            }
            for next in graph[node] ?? [] where previous[next] == nil {
                previous[next] = node
                queue.append(next)
            }
        }
        return nil
    }

    /// Points of a procedure, following its legs: a SID from where it starts
    /// to the point named `to`, a STAR from the point named `from` to its end.
    private static func walk(_ legs: [[String]], _ index: AiracIndex, to: String? = nil, from: String? = nil) -> [AiracIndex.Point] {
        var next: [String: [String]] = [:]
        var incoming = Set<String>()
        for leg in legs where leg.count == 2 {
            next[leg[0], default: []].append(leg[1])
            incoming.insert(leg[1])
        }
        let sources = from.map { name in next.keys.filter { index.points[$0]?.name == name } }
            ?? next.keys.filter { !incoming.contains($0) }
        for source in sources.sorted() {
            var previous: [String: String] = [source: source]
            var queue = [source]
            var end: String?
            while !queue.isEmpty {
                let node = queue.removeFirst()
                if let to, index.points[node]?.name == to { end = node; break }
                if to == nil, next[node] == nil { end = node; break }
                for n in next[node] ?? [] where previous[n] == nil {
                    previous[n] = node
                    queue.append(n)
                }
            }
            guard let end else { continue }
            var path = [end]
            var cursor = end
            while cursor != source { cursor = previous[cursor]!; path.append(cursor) }
            return path.reversed().compactMap { index.points[$0] }
        }
        return []
    }

    /// 46N001E, 4620N00105E.
    private static func coordinates(_ token: String) -> LatLon? {
        guard let match = token.wholeMatch(of: #/(\d{2})(\d{2})?([NS])(\d{3})(\d{2})?([EW])/#) else { return nil }
        let lat = Double(match.1)! + (match.2.flatMap { Double($0) } ?? 0) / 60
        let lon = Double(match.4)! + (match.5.flatMap { Double($0) } ?? 0) / 60
        return LatLon(latitude: match.3 == "S" ? -lat : lat, longitude: match.6 == "W" ? -lon : lon)
    }
}
