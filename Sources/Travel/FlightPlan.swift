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
