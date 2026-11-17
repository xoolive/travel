import Foundation

/// One point of a recent trajectory, with what the alignment test needs.
struct PathPoint: Sendable {
    var t: Double
    var position: LatLon
    /// Feet, barometric.
    var altitude: Double?
    /// Degrees, true.
    var track: Double?
    /// From a surface position message (BDS 0,6).
    var onGround: Bool
}

/// A stretch of trajectory aligned with a runway's extended centreline.
struct Alignment: Sendable, Equatable {
    var threshold: Threshold
    var start: Double
    var end: Double
    /// Long enough (one minute) to be trusted, as in the traffic library.
    var confirmed: Bool
    /// Still aligned at the latest position.
    var ongoing: Bool
}

/// The aligned-on-ILS method of the traffic library
/// (`traffic.algorithms.navigation.landing.LandingAlignedOnILS`), run on a
/// recent trajectory so that it works on live data:
///
/// - lateral offset from the extended centreline, distance to the threshold
///   (NM) times the bearing difference (radians), below 0.1 NM;
/// - heading towards the threshold: cos(bearing to threshold − track) > 0;
/// - below the airport elevation plus 5,000 ft when the altitude is known;
/// - in the air: surface positions (BDS 0,6) are left out, unlike in traffic,
///   since a live trajectory goes on with the taxi;
/// - aligned positions split at gaps over 20 s; a stretch counts once it
///   lasts a minute, and is reported earlier as not yet confirmed.
enum Landing {
    static let tolerance = 0.1
    static let ceiling = 5000.0
    static let gap = 20.0
    static let minimum = 60.0

    /// The latest alignment on any of the thresholds, if any.
    static func latest(_ path: [PathPoint], thresholds: [Threshold]) -> Alignment? {
        var best: Alignment?
        for threshold in thresholds {
            var start: Double?, end = 0.0
            var last: Alignment?
            for p in path {
                // Only in the air, as told by surface position messages (BDS
                // 0,6), not by altitude: taxiing back along a runway after
                // landing would otherwise read as its opposite end.
                guard !p.onGround else { continue }
                if let altitude = p.altitude, altitude >= threshold.elevation + ceiling { continue }
                let toThreshold = Geo.bearing(p.position, threshold.position)
                let nm = Geo.distance(p.position, threshold.position) / 1852
                let difference = abs(((toThreshold - threshold.bearing + 540).truncatingRemainder(dividingBy: 360)) - 180)
                let towards = p.track.map { cos((toThreshold - $0) * .pi / 180) > 0 } ?? true
                guard nm * difference * .pi / 180 < tolerance, towards else { continue }
                if let s = start, p.t - end <= gap {
                    end = p.t
                    last = Alignment(threshold: threshold, start: s, end: end, confirmed: end - s >= minimum, ongoing: false)
                } else {
                    start = p.t
                    end = p.t
                    last = Alignment(threshold: threshold, start: p.t, end: p.t, confirmed: false, ongoing: false)
                }
            }
            if var candidate = last {
                candidate.ongoing = (path.last?.t ?? 0) - candidate.end <= gap
                if best.map({ candidate.end > $0.end }) ?? true { best = candidate }
            }
        }
        return best
    }
}
