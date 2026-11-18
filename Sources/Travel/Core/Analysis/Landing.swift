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
    /// Still aligned at the latest position.
    var ongoing: Bool
    /// Farthest distance (NM) from the threshold in the aligned stretch.
    var distance: Double
}

/// The aligned-on-ILS method of the traffic library, reproduced as written
/// (`traffic.algorithms.navigation.landing.LandingAlignedOnILS.apply`):
///
/// - for each threshold, keep the points where
///   `distance × |radians(bearing − threshold.bearing)| < 0.1` (distance in
///   NM, bearing from the point to the threshold in [0, 360), the
///   difference not wrapped) and `cos(bearing − track) > 0`; a point without
///   a track fails the second test, as NaN does in pandas;
/// - split them where consecutive points are more than 20 s apart;
/// - keep a chunk longer than one minute whose lowest known altitude is
///   below the airport elevation plus 5,000 ft (a chunk without altitude
///   is dropped);
/// - the chunks of all thresholds, ordered by start; traffic's `final` (the
///   landing) is the one that starts last.
enum Landing {
    static let angleTolerance = 0.1
    static let minDuration = 60.0
    static let maxFeetAboveAirport = 5000.0
    static let split = 20.0

    /// Every aligned chunk, ordered by start.
    static func chunks(_ path: [PathPoint], thresholds: [Threshold], airportElevation: Double) -> [Alignment] {
        var result: [Alignment] = []
        for threshold in thresholds {
            var chunk: [(PathPoint, Double)] = []
            func close() {
                defer { chunk = [] }
                guard let first = chunk.first, let last = chunk.last, last.0.t - first.0.t > minDuration,
                      let lowest = chunk.compactMap(\.0.altitude).min(),
                      lowest < airportElevation + maxFeetAboveAirport
                else { return }
                result.append(Alignment(threshold: threshold, start: first.0.t, end: last.0.t, ongoing: false,
                                        distance: chunk.map(\.1).max() ?? 0))
            }
            for p in path {
                let bearing = Geo.bearing(p.position, threshold.position)
                let nm = Geo.distance(p.position, threshold.position) / 1852
                let bDiff = nm * abs((bearing - threshold.bearing) * .pi / 180)
                guard bDiff < angleTolerance, let track = p.track, cos((bearing - track) * .pi / 180) > 0 else { continue }
                if let last = chunk.last, p.t - last.0.t > split { close() }
                chunk.append((p, nm))
            }
            close()
        }
        return result.sorted { $0.start < $1.start }
    }

    /// The chunk that starts last, marked ongoing when it reaches the end of
    /// the path (within 20 s).
    static func latest(_ path: [PathPoint], thresholds: [Threshold], airportElevation: Double) -> Alignment? {
        guard var found = chunks(path, thresholds: thresholds, airportElevation: airportElevation).last else { return nil }
        found.ongoing = (path.last?.t ?? 0) - found.end <= split
        return found
    }
}
