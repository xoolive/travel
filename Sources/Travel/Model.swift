import Foundation

enum Kind: String, Sendable, CaseIterable {
    case aircraft
    case ship

    /// A target disappears this long after its last message.
    var timeout: Double { self == .aircraft ? 60 : 360 }
}

/// Numeric time series kept per target.
enum Channel: Int, CaseIterable, Sendable {
    case altitude            // ft
    case selectedAltitude    // ft
    case groundspeed         // kt (speed over ground for ships)
    case ias                 // kt
    case tas                 // kt
    case mach
    case verticalRate        // ft/min
    case vrateBarometric     // ft/min
    case vrateInertial       // ft/min
    case track               // degrees (course over ground for ships)
    case heading             // degrees
    case roll                // degrees
    case nacp
}

struct Sample: Sendable, Equatable {
    var t: Double
    var v: Double
}

struct Position: Sendable {
    var t: Double
    var latitude: Double
    var longitude: Double
}

struct TrackPoint: Sendable, Equatable {
    var timestamp: Double
    var latitude: Double
    var longitude: Double
}

/// A run of track points: received positions, or the dashed bridge across
/// a long reception gap.
struct TrackSegment: Sendable, Equatable {
    enum Mark: Sendable, Equatable {
        /// Spread above the turbulence threshold for a single minute.
        case aboveThreshold
        /// Turbulent: above the threshold for two or more consecutive minutes.
        case turbulent
    }

    var points: [TrackPoint]
    var isGap: Bool
    /// Set on the extra segments drawn over the track where turbulence was measured.
    var mark: Mark?
}

/// An event placed on the selected aircraft's track.
struct TrackMark: Sendable, Equatable, Identifiable {
    enum Kind: Sendable, Equatable {
        case datalinkUp
        case datalinkDown
        case resolution
    }

    var id: String
    var kind: Kind
    var position: LatLon
    var label: String
}

/// Slow-changing text attributes; the latest value wins.
struct Info: Sendable, Equatable {
    /// From the aircraft database.
    var registration: String?
    /// ICAO type designator such as `B789`, from the aircraft database.
    var typecode: String?
    /// Seen in DF 18 messages, which mostly come from airport surface vehicles.
    var isVehicle = false
    var squawk: String?
    var radioCallsign: String?
    var shipType: String?
    var destination: String?
    var status: String?
    var flag: String?
    var country: String?

    mutating func merge(_ other: Info) {
        registration = other.registration ?? registration
        typecode = other.typecode ?? typecode
        isVehicle = isVehicle || other.isVehicle
        squawk = other.squawk ?? squawk
        radioCallsign = other.radioCallsign ?? radioCallsign
        shipType = other.shipType ?? shipType
        destination = other.destination ?? destination
        status = other.status ?? status
        flag = other.flag ?? flag
        country = other.country ?? country
    }
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
    /// The aircraft sent it (true) or received it (false).
    var fromAircraft: Bool
    /// What the frame carries, in a few words.
    var summary: String
    /// Decoded text, for ACARS messages.
    var text: String?
}

/// Everything received about one aircraft or ship, time-ordered.
struct Series: Sendable {
    let id: String
    let kind: Kind
    var name: String?
    var info = Info()
    /// Timestamp of every message.
    var activity: [Double] = []
    var positions: [Position] = []
    /// Indexed by `Channel.rawValue`.
    var channels: [[Sample]] = Array(repeating: [], count: Channel.allCases.count)
    /// Interrogations received for this aircraft, from an uplink file.
    var uplinks: [Uplink] = []
    var datalink: [DatalinkMessage] = []
    /// Coarse positions reported along with datalink messages (Airframes.io
    /// flight tracking, about 0.1°), kept apart from received positions.
    var reported: [Position] = []

    /// Received positions, or the reported ones for an aircraft only heard
    /// on datalink.
    var track: [Position] { positions.isEmpty ? reported : positions }

    mutating func append(_ other: Series) {
        uplinks.append(contentsOf: other.uplinks)
        datalink.append(contentsOf: other.datalink)
        reported.append(contentsOf: other.reported)
        name = other.name ?? name
        info.merge(other.info)
        activity.append(contentsOf: other.activity)
        positions.append(contentsOf: other.positions)
        for i in channels.indices { channels[i].append(contentsOf: other.channels[i]) }
    }

    /// Restores time order after merging files that overlap or arrive unordered.
    mutating func sortIfNeeded() {
        if !zip(activity, activity.dropFirst()).allSatisfy({ $0 <= $1 }) { activity.sort() }
        if !zip(uplinks, uplinks.dropFirst()).allSatisfy({ $0.t <= $1.t }) { uplinks.sort { $0.t < $1.t } }
        if !zip(datalink, datalink.dropFirst()).allSatisfy({ $0.t <= $1.t }) { datalink.sort { $0.t < $1.t } }
        if !zip(positions, positions.dropFirst()).allSatisfy({ $0.t <= $1.t }) { positions.sort { $0.t < $1.t } }
        if !zip(reported, reported.dropFirst()).allSatisfy({ $0.t <= $1.t }) { reported.sort { $0.t < $1.t } }
        for i in channels.indices
        where !zip(channels[i], channels[i].dropFirst()).allSatisfy({ $0.t <= $1.t }) {
            channels[i].sort { $0.t < $1.t }
        }
    }
}

/// State of one target at one instant, as shown on the map and in tables.
struct Entity: Identifiable, Sendable, Equatable {
    let id: String
    let kind: Kind
    var name: String?
    var info: Info
    var latitude: Double?
    var longitude: Double?
    /// Indexed by `Channel.rawValue`; NaN when unknown.
    var values: [Double]
    /// Messages received so far.
    var count: Int
    var firstSeen: Double
    var lastSeen: Double

    subscript(channel: Channel) -> Double? {
        let value = values[channel.rawValue]
        return value.isNaN ? nil : value
    }

    var label: String { name ?? id.uppercased() }
}

// Non-optional keys for sortable table columns.
extension Entity {
    subscript(sort channel: Channel) -> Double {
        let value = values[channel.rawValue]
        return value.isNaN ? -.infinity : value
    }

    var nameKey: String { name ?? "" }
    var squawkKey: String { info.squawk ?? "" }
    var registrationKey: String { info.registration ?? "" }
    var typecodeKey: String { info.typecode ?? "" }
    var latitudeKey: Double { latitude ?? -.infinity }
    var longitudeKey: Double { longitude ?? -.infinity }
    var flagKey: String { info.country ?? "" }
    var shipTypeKey: String { info.shipType ?? "" }
    var statusKey: String { info.status ?? "" }
    var destinationKey: String { info.destination ?? "" }
}
