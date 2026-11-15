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
}

extension FlightPlan {
    /// The route of field 15 as points: departure airport, the coordinates
    /// written in the route, destination airport. Named points are not placed
    /// yet: they need the AIRAC navigation data (see docs/plan.md).
    func waypoints() -> [Waypoint] {
        var result: [Waypoint] = []
        var last = Airports.position(of: departure)
        if let last { result.append(Waypoint(name: departure, position: last)) }
        for raw in route.split(separator: " ") {
            let token = String(raw.split(separator: "/").first ?? raw)
            guard let kind = Self.classify(token) else { continue }
            var place: LatLon?
            switch kind {
            case let .coordinates(position): place = position
            case .point:
                place = nil
            }
            if let place {
                result.append(Waypoint(name: token, position: place))
                last = place
            }
        }
        if let end = Airports.position(of: destination) {
            result.append(Waypoint(name: destination, position: end))
        }
        return result
    }

    private enum Token {
        case point
        case coordinates(LatLon)
    }

    private static func classify(_ token: String) -> Token? {
        // Named points: 2 to 5 letters (NDB, VOR, fixes); "DCT" is not one.
        if token != "DCT", (2...5).contains(token.count), token.allSatisfy({ $0.isUppercase && $0.isLetter }) {
            return .point
        }
        // Coordinates: 46N001E, 4620N00105E.
        if let match = token.wholeMatch(of: #/(\d{2})(\d{2})?([NS])(\d{3})(\d{2})?([EW])/#) {
            let lat = Double(match.1)! + (match.2.flatMap { Double($0) } ?? 0) / 60
            let lon = Double(match.4)! + (match.5.flatMap { Double($0) } ?? 0) / 60
            return .coordinates(LatLon(latitude: match.3 == "S" ? -lat : lat, longitude: match.6 == "W" ? -lon : lon))
        }
        // Everything else: speed and level (N0410F300), SIDs and STARs
        // (FISTO7B), airways (UT182).
        return nil
    }
}
