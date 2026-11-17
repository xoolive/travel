import Foundation

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
        case groundStation
        /// A waypoint of a dropped flight plan.
        case waypoint
    }

    var id: String
    var kind: Kind
    var position: LatLon
    var label: String
    /// The other end of a datalink message: its ground station, when known.
    var link: LatLon?
}
