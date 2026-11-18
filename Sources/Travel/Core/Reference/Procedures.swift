import Foundation

/// SIDs and STARs the EUROCONTROL AIXM baseline does not carry (the RJTT
/// arrivals), typed in from the published AIP into a local text file. Each
/// block of lines in the file says where it comes from.
///
/// One line per point: `KIND AIRPORT DESIGNATOR SEQ FIX LAT LON [ALT [SPEED]]`,
/// KIND being `SID` or `STAR`; `#` starts a comment.
enum Procedures {
    struct Fix: Sendable {
        var name: String
        var position: LatLon
    }

    /// `TRAVEL_PROCEDURES`, else `~/Documents/data/travel/procedures.txt`.
    static var url: URL {
        if let path = ProcessInfo.processInfo.environment["TRAVEL_PROCEDURES"] {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/data/travel/procedures.txt")
    }

    /// Points of each procedure in order, keyed `KIND DESIGNATOR@AIRPORT`.
    static let table: [String: [Fix]] = load()

    private static func load() -> [String: [Fix]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var points: [String: [(Int, Fix)]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 7, let seq = Int(parts[3]),
                  let latitude = Double(parts[5]), let longitude = Double(parts[6]) else { continue }
            points["\(parts[0]) \(parts[2])@\(parts[1])", default: []].append(
                (seq, Fix(name: String(parts[4]), position: LatLon(latitude: latitude, longitude: longitude)))
            )
        }
        return points.mapValues { $0.sorted { $0.0 < $1.0 }.map(\.1) }
    }

    /// The STAR's points after the one named `from` (all of them when it
    /// does not start there); nil when the file does not have it.
    static func arrival(_ designator: String, at airport: String, from: String?) -> [Fix]? {
        guard let fixes = table["STAR \(designator)@\(airport)"] else { return nil }
        if let from, let k = fixes.firstIndex(where: { $0.name == from }) { return Array(fixes[(k + 1)...]) }
        return fixes
    }

    /// The SID's points up to the one named `to` (all of them when it does
    /// not reach it); nil when the file does not have it.
    static func departure(_ designator: String, at airport: String, to: String?) -> [Fix]? {
        guard let fixes = table["SID \(designator)@\(airport)"] else { return nil }
        if let to, let k = fixes.firstIndex(where: { $0.name == to }) { return Array(fixes[...k]) }
        return fixes
    }
}
