import Foundation

/// A runway threshold, from `runways.csv` (OurAirports, via scripts/make-runways.py).
struct Threshold: Sendable, Equatable {
    var airport: String
    /// Runway name at this end, such as 32L.
    var name: String
    var position: LatLon
    /// Feet; 0 when unknown.
    var elevation: Double
    /// Landing direction: true bearing towards the opposite threshold.
    var bearing: Double
}

enum Runways {
    /// Thresholds by airport ICAO code.
    static let byAirport: [String: [Threshold]] = {
        guard let url = Bundle.main.url(forResource: "runways", withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [:] }
        var result: [String: [Threshold]] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") && !line.hasPrefix("airport,") {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 6, let lat = Double(f[2]), let lon = Double(f[3]), let bearing = Double(f[5]) else { continue }
            let threshold = Threshold(
                airport: String(f[0]), name: String(f[1]), position: LatLon(latitude: lat, longitude: lon),
                elevation: Double(f[4]) ?? 0, bearing: bearing
            )
            result[threshold.airport, default: []].append(threshold)
        }
        return result
    }()
}
