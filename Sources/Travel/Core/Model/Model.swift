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
    /// From a surface position message (BDS 0,6): the aircraft is on the ground.
    var surface = false
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
    /// Latest received signal level (jet1090 metadata), dBFS for SDR sources.
    var rssi: Double?

    mutating func merge(_ other: Info) {
        rssi = other.rssi ?? rssi
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
    /// Interrogations received for this aircraft, from an uplink file.
    var uplinks: [Uplink] = []
    var datalink: [DatalinkMessage] = []
    /// All-call replies (DF 11) and the interrogator code they answer.
    var replies: [InterrogatorReply] = []
    /// Coarse positions reported along with datalink messages (Airframes.io
    /// flight tracking, about 0.1°), kept apart from received positions.
    var reported: [Position] = []
    /// Ground stations heard, on the series `Series.groundStations` only.
    var stations: [StationReport] = []

    /// Ground station reports travel from the builders to the dataset in a
    /// series of their own, under this identifier.
    static let groundStations = "#ground-stations"
    /// Messages naming an aircraft by registration only (VHF ACARS) travel
    /// under this prefix; the dataset turns it into the ICAO address.
    static let registrationPrefix = "#reg:"

    /// Received positions, or the reported ones for an aircraft only heard
    /// on datalink.
    var track: [Position] { positions.isEmpty ? reported : positions }

    /// Appends newer data. Live sources do not always arrive in time order
    /// (two decoders, a recording read in afterwards): an array that would
    /// go back in time is sorted again, checked at the joint only.
    mutating func append(_ other: Series) {
        func join<T>(_ items: inout [T], _ more: [T], _ t: (T) -> Double) {
            guard let first = more.first else { return }
            let ordered = items.last.map { t($0) <= t(first) } ?? true
            items.append(contentsOf: more)
            if !ordered || !zip(more, more.dropFirst()).allSatisfy({ t($0) <= t($1) }) {
                items.sort { t($0) < t($1) }
            }
        }
        join(&uplinks, other.uplinks, \.t)
        join(&datalink, other.datalink, \.t)
        join(&replies, other.replies, \.t)
        join(&reported, other.reported, \.t)
        join(&stations, other.stations, \.t)
        name = other.name ?? name
        info.merge(other.info)
        join(&activity, other.activity) { $0 }
        join(&positions, other.positions, \.t)
        for i in channels.indices { join(&channels[i], other.channels[i], \.t) }
    }

    /// Drops messages present twice, once from a recording and once received
    /// live: same time and same content. Call after `sortIfNeeded`.
    mutating func removeDuplicates() {
        func dedupe<T>(_ items: inout [T], _ t: (T) -> Double, _ same: (T, T) -> Bool) {
            guard items.count > 1 else { return }
            var out: [T] = []
            out.reserveCapacity(items.count)
            for item in items {
                var k = out.count - 1
                var duplicate = false
                while k >= 0, t(out[k]) == t(item) {
                    if same(out[k], item) { duplicate = true; break }
                    k -= 1
                }
                if !duplicate { out.append(item) }
            }
            if out.count != items.count { items = out }
        }
        func samePosition(_ a: Position, _ b: Position) -> Bool {
            a.latitude == b.latitude && a.longitude == b.longitude && a.surface == b.surface
        }
        dedupe(&activity, { $0 }, ==)
        dedupe(&positions, \.t, samePosition)
        dedupe(&reported, \.t, samePosition)
        dedupe(&uplinks, \.t, ==)
        dedupe(&datalink, \.t, ==)
        dedupe(&replies, \.t, ==)
        dedupe(&stations, \.t, ==)
        for i in channels.indices { dedupe(&channels[i], \.t, ==) }
    }

    /// Restores time order after merging files that overlap or arrive unordered.
    mutating func sortIfNeeded() {
        if !zip(activity, activity.dropFirst()).allSatisfy({ $0 <= $1 }) { activity.sort() }
        if !zip(uplinks, uplinks.dropFirst()).allSatisfy({ $0.t <= $1.t }) { uplinks.sort { $0.t < $1.t } }
        if !zip(datalink, datalink.dropFirst()).allSatisfy({ $0.t <= $1.t }) { datalink.sort { $0.t < $1.t } }
        if !zip(replies, replies.dropFirst()).allSatisfy({ $0.t <= $1.t }) { replies.sort { $0.t < $1.t } }
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
