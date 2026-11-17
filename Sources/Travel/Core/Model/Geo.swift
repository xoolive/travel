import Foundation

struct LatLon: Sendable, Equatable {
    var latitude: Double
    var longitude: Double
}

/// Great-circle helpers on a spherical Earth.
enum Geo {
    static let earthRadius = 6_371_000.0

    private static func rad(_ degrees: Double) -> Double { degrees * .pi / 180 }
    private static func deg(_ radians: Double) -> Double { radians * 180 / .pi }

    /// Angular distance in radians.
    static func angle(_ a: LatLon, _ b: LatLon) -> Double {
        let p1 = rad(a.latitude), p2 = rad(b.latitude)
        let dp = p2 - p1, dl = rad(b.longitude - a.longitude)
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * asin(min(1, sqrt(h)))
    }

    /// Distance in metres.
    static func distance(_ a: LatLon, _ b: LatLon) -> Double {
        angle(a, b) * earthRadius
    }

    /// Point at `fraction` (0...1) of the great circle from `a` to `b`.
    static func interpolate(_ a: LatLon, _ b: LatLon, fraction f: Double) -> LatLon {
        let d = angle(a, b)
        guard d > 1e-9 else { return a }
        let p1 = rad(a.latitude), l1 = rad(a.longitude)
        let p2 = rad(b.latitude), l2 = rad(b.longitude)
        let wa = sin((1 - f) * d) / sin(d), wb = sin(f * d) / sin(d)
        let x = wa * cos(p1) * cos(l1) + wb * cos(p2) * cos(l2)
        let y = wa * cos(p1) * sin(l1) + wb * cos(p2) * sin(l2)
        let z = wa * sin(p1) + wb * sin(p2)
        return LatLon(latitude: deg(atan2(z, sqrt(x * x + y * y))), longitude: deg(atan2(y, x)))
    }

    /// Initial bearing from `a` to `b`, degrees clockwise from north, 0..<360.
    static func bearing(_ a: LatLon, _ b: LatLon) -> Double {
        let p1 = rad(a.latitude), p2 = rad(b.latitude)
        let dl = rad(b.longitude - a.longitude)
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return (deg(atan2(y, x)) + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Point reached from `a` after `distance` metres on `bearing` degrees.
    static func destination(_ a: LatLon, bearing: Double, distance: Double) -> LatLon {
        let d = distance / earthRadius, t = rad(bearing)
        let p1 = rad(a.latitude), l1 = rad(a.longitude)
        let p2 = asin(sin(p1) * cos(d) + cos(p1) * sin(d) * cos(t))
        let l2 = l1 + atan2(sin(t) * sin(d) * cos(p1), cos(d) - sin(p1) * sin(p2))
        let lon = (deg(l2) + 540).truncatingRemainder(dividingBy: 360) - 180
        return LatLon(latitude: deg(p2), longitude: lon)
    }
}
