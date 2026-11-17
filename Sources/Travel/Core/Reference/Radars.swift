import Foundation

/// A candidate site for an interrogator code, from `radars.csv` (built from
/// the uplink1030 radar catalogue). Codes are reused across Europe and the
/// assignments are undated: these are candidates, not verified allocations.
struct RadarSite: Sendable, Equatable {
    var code: String
    var name: String
    var position: LatLon
    /// "located" for a reviewed installation, "approximate" for an area.
    var basis: String
}

@MainActor
enum Radars {
    static let sites: [String: [RadarSite]] = {
        guard let url = Bundle.main.url(forResource: "radars", withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [:] }
        var result: [String: [RadarSite]] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") && !line.hasPrefix("code,") {
            let fields = Self.fields(String(line))
            guard fields.count >= 5, let latitude = Double(fields[2]), let longitude = Double(fields[3]) else { continue }
            let site = RadarSite(code: fields[0], name: fields[1], position: LatLon(latitude: latitude, longitude: longitude), basis: fields[4])
            result[site.code, default: []].append(site)
        }
        return result
    }()

    /// Splits a CSV line, with quoted fields.
    private static func fields(_ line: String) -> [String] {
        var fields: [String] = [], current = "", quoted = false
        for character in line {
            switch character {
            case "\"": quoted.toggle()
            case "," where !quoted: fields.append(current); current = ""
            default: current.append(character)
            }
        }
        fields.append(current)
        return fields
    }
}
