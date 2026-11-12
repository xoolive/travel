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
    var points: [TrackPoint]
    var isGap: Bool
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

    mutating func append(_ other: Series) {
        name = other.name ?? name
        info.merge(other.info)
        activity.append(contentsOf: other.activity)
        positions.append(contentsOf: other.positions)
        for i in channels.indices { channels[i].append(contentsOf: other.channels[i]) }
    }

    /// Restores time order after merging files that overlap or arrive unordered.
    mutating func sortIfNeeded() {
        if !zip(activity, activity.dropFirst()).allSatisfy({ $0 <= $1 }) { activity.sort() }
        if !zip(positions, positions.dropFirst()).allSatisfy({ $0.t <= $1.t }) { positions.sort { $0.t < $1.t } }
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
