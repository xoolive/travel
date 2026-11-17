import Foundation

/// Airways from X-Plane's `earth_awy.dat`, as shipped with the traffic
/// library: a fallback for the airways the EUROCONTROL AIXM baseline does not
/// carry (China, W188 and the like). Older data of unknown provenance: the
/// points it gives are marked as such.
///
/// One line per point: `DESIGNATOR SEQ NAME LAT LON`. One designator mixes
/// airways of several countries in one numbering (W188 runs in Australia,
/// Russia and China): it is cut into sections wherever consecutive points are
/// more than `split` NM apart.
enum XPlaneAirways {
    struct Fix: Sendable {
        var name: String
        var position: LatLon
    }

    static let split = 300.0
    /// A route point matches an airway point of the same name within this
    /// distance, or of any name within `sameFix` (FKG on the plan is DUKOM on
    /// the airway, at the same place).
    static let sameName = 30.0
    static let sameFix = 2.0

    /// `TRAVEL_EARTH_AWY`, else traffic's copy next to this repository.
    static var url: URL {
        if let path = ProcessInfo.processInfo.environment["TRAVEL_EARTH_AWY"] {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/code/traffic/src/traffic/data/navdata/earth_awy.dat")
    }

    static let sections: [String: [[Fix]]] = load()

    static func has(_ designator: String) -> Bool { sections[designator] != nil }

    private static func load() -> [String: [[Fix]]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var points: [String: [(Int, Fix)]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 5, let seq = Int(parts[1]),
                  let latitude = Double(parts[3]), let longitude = Double(parts[4]) else { continue }
            points[String(parts[0]), default: []].append(
                (seq, Fix(name: String(parts[2]), position: LatLon(latitude: latitude, longitude: longitude)))
            )
        }
        var result: [String: [[Fix]]] = [:]
        for (designator, list) in points {
            var sections: [[Fix]] = []
            for (_, fix) in list.sorted(by: { $0.0 < $1.0 }) {
                if let last = sections.last?.last, Geo.distance(last.position, fix.position) / 1852 <= split {
                    sections[sections.count - 1].append(fix)
                } else {
                    sections.append([fix])
                }
            }
            result[designator] = sections
        }
        return result
    }

    /// Points of `designator` strictly between the route points `from` and
    /// `to`, in flight order; nil when no section joins both.
    static func between(_ designator: String, from: Waypoint, to: Waypoint) -> [Fix]? {
        guard let sections = sections[designator] else { return nil }
        func matches(_ fix: Fix, _ point: Waypoint) -> Double? {
            let nm = Geo.distance(fix.position, point.position) / 1852
            if nm <= sameFix || (fix.name == point.name && nm <= sameName) { return nm }
            return nil
        }
        var best: (fixes: [Fix], score: Double)?
        for section in sections {
            var a: (Int, Double)?, b: (Int, Double)?
            for (k, fix) in section.enumerated() {
                if let d = matches(fix, from), d < (a?.1 ?? .infinity) { a = (k, d) }
                if let d = matches(fix, to), d < (b?.1 ?? .infinity) { b = (k, d) }
            }
            guard let a, let b, a.0 != b.0 else { continue }
            let fixes = a.0 < b.0
                ? Array(section[(a.0 + 1)..<b.0])
                : Array(section[(b.0 + 1)..<a.0].reversed())
            if best == nil || a.1 + b.1 < best!.score { best = (fixes, a.1 + b.1) }
        }
        return best?.fixes
    }
}
