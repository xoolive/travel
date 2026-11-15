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

    /// Thresholds within `radius` metres of a point, for when the destination
    /// is unknown or is not where the aircraft lands.
    static func near(_ point: LatLon, radius: Double) -> [Threshold] {
        byAirport.values.lazy.flatMap { $0 }.filter { Geo.distance($0.position, point) <= radius }
    }
}

/// One point of a recent trajectory, with what the alignment test needs.
struct PathPoint: Sendable {
    var t: Double
    var position: LatLon
    /// Feet, barometric.
    var altitude: Double?
    /// Degrees, true.
    var track: Double?
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
/// - below the airport elevation plus 5,000 ft;
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
                guard let altitude = p.altitude, altitude < threshold.elevation + ceiling else { continue }
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
