import Foundation

/// An all-call reply heard from an aircraft, naming the interrogator it answers.
struct InterrogatorReply: Sendable, Equatable {
    var t: Double
    var code: String
}

/// Interrogators placed at one candidate site; codes sharing a site share a badge.
struct RadarMark: Sendable, Equatable, Identifiable {
    var codes: [String]
    var name: String
    var position: LatLon
    /// Rotation period rounded to the second, of the code that blinks, when known.
    var period: Double?
    /// Interrogating the selected aircraft now.
    var blinking: Bool
    /// How the site is known: located, approximate, historical or airport.
    var basis = ""
    /// How each code fits the data at this site.
    var fits: [RadarCodeFit] = []
    /// Codes whose fit to this site is weak, written with a question mark.
    var doubtful: Set<String> = []
    /// Chosen by a click: its card is open and its aircraft stay coloured.
    var selected = false
    /// False when kept on screen for its card although no longer heard.
    var heard = true
    var id: String { name }
    var label: String { codes.map { doubtful.contains($0) ? $0 + "?" : $0 }.joined(separator: " · ") }
    var isDoubtful: Bool { !codes.isEmpty && codes.allSatisfy(doubtful.contains) }
}

/// One interrogator code at a candidate site, for the radar card.
struct RadarCodeFit: Sendable, Equatable {
    var code: String
    var period: Double?
    /// Aircraft (10-minute segments) supporting the site, out of those located.
    var aircraft: Int
    var located: Int
    var medianDistance: Double
    var consistent: Bool
}

/// A ground station announcing itself: an ACARS squitter (label SQ), or the
/// coordinates in a VDL2 `station_name`.
struct StationReport: Sendable, Equatable {
    var t: Double
    /// Provider and station code (`ARINC AMSN`), or the station address.
    var key: String
    /// What to print next to it: the airport, or the station code.
    var code: String
    var position: LatLon
    /// Provider, link and frequency, in a few words.
    var details: String
}

/// A Mode S interrogation sent to an aircraft, as received on 1030 MHz.
struct Uplink: Sendable, Equatable {
    enum Origin: Sendable, Equatable, Hashable {
        /// A ground radar, with its interrogator code (II or SI) when known.
        case radar(String?)
        /// Another aircraft's collision avoidance system (UF 0 and UF 16).
        case acas
        /// TCAS coordination of a resolution advisory (UF 16).
        case resolution
        /// Extended length message (UF 24, Comm-C).
        case elm
    }

    var t: Double
    var uplinkFormat: Int
    var origin: Origin
    /// Comm-B register requested, such as `40`, when the interrogation asks for one.
    var register: String?

    var originLabel: String {
        switch origin {
        case let .radar(code): code ?? "Radar"
        case .acas: "TCAS"
        case .resolution: "TCAS RA"
        case .elm: "ELM"
        }
    }

    var requestLabel: String {
        if let register { return "BDS \(register.prefix(1)),\(register.dropFirst())" }
        switch uplinkFormat {
        case 4: return "Altitude"
        case 5: return "Identity"
        case 0, 16: return "Air-air"
        case 11: return "All-call"
        case 24: return "Comm-C"
        default: return "UF \(uplinkFormat)"
        }
    }
}

/// A datalink message exchanged with a ground station over VDL mode 2.
struct DatalinkMessage: Sendable, Equatable {
    var t: Double
    /// MHz; when the same frame was decoded on several channels, the first.
    var channel: Double?
    /// Every channel the frame was decoded on, MHz.
    var channels: [Double] = []
    /// ICAO address of the ground station.
    var station: String?
    /// Where the ground station is, when the decoder knows it.
    var stationName: String?
    var stationPosition: LatLon?
    /// The aircraft sent it (true) or received it (false).
    var fromAircraft: Bool
    /// What the frame carries, in a few words.
    var summary: String
    /// Decoded text, for ACARS messages.
    var text: String?
}
