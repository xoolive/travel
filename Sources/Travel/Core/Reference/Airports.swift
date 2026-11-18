import Foundation

/// Airport positions by ICAO code, from jet1090's `airports.json` (rs1090
/// data, copied into the app bundle).
enum Airports {
    private struct Airport: Decodable {
        let icao: String
        let lat: Double
        let lon: Double
        let alt: Double?
    }

    /// Elevation in feet, by ICAO code.
    private static let elevations: [String: Double] = {
        guard let url = Bundle.main.url(forResource: "airports", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let airports = try? JSONDecoder().decode([Airport].self, from: data)
        else { return [:] }
        var result: [String: Double] = [:]
        for airport in airports where airport.icao.count == 4 { result[airport.icao] = airport.alt }
        return result
    }()

    /// Elevation (ft) of the airport with this ICAO code, if known.
    static func elevation(of code: String) -> Double? {
        elevations[code.trimmingCharacters(in: .whitespaces).uppercased()]
    }

    private static let positions: [String: LatLon] = {
        guard let url = Bundle.main.url(forResource: "airports", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let airports = try? JSONDecoder().decode([Airport].self, from: data)
        else { return [:] }
        var result: [String: LatLon] = [:]
        for airport in airports where airport.icao.count == 4 {
            result[airport.icao] = LatLon(latitude: airport.lat, longitude: airport.lon)
        }
        return result
    }()

    /// Where the airport with this four-letter ICAO code is, if known.
    static func position(of code: String) -> LatLon? {
        let code = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard code.count == 4, code.allSatisfy({ $0.isLetter }) else { return nil }
        return positions[code]
    }
}
