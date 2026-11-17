import MapKit
import simd

/// The camera as a perspective view of a spherical Earth. It gives the
/// on-screen direction of a course anywhere on the globe, whatever the camera
/// heading and pitch; MapKit's own point conversion is not reliable there.
/// It assumes the map's centre is the centre of the view: the map must not be
/// given safe area insets, which move one without the other.
struct CameraFrame {
    private let position: SIMD3<Double>
    private let right: SIMD3<Double>
    private let up: SIMD3<Double>
    private let forward: SIMD3<Double>

    private static func unit(_ latitude: Double, _ longitude: Double) -> SIMD3<Double> {
        let lat = latitude * .pi / 180, lon = longitude * .pi / 180
        return SIMD3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
    }

    init(_ camera: MKMapCamera) {
        let lat = camera.centerCoordinate.latitude * .pi / 180
        let lon = camera.centerCoordinate.longitude * .pi / 180
        let heading = camera.heading * .pi / 180
        let pitch = Double(camera.pitch) * .pi / 180
        let zenith = Self.unit(camera.centerCoordinate.latitude, camera.centerCoordinate.longitude)
        let east = SIMD3(-sin(lon), cos(lon), 0)
        let north = SIMD3(-sin(lat) * cos(lon), -sin(lat) * sin(lon), cos(lat))
        let along = cos(heading) * north + sin(heading) * east
        let target = zenith * Geo.earthRadius
        // The camera sits behind the target, opposite to its heading.
        position = target + camera.centerCoordinateDistance * (cos(pitch) * zenith - sin(pitch) * along)
        let direction = target - position
        forward = direction / (direction * direction).sum().squareRoot()
        right = cos(heading) * east - sin(heading) * north
        let x = right, f = forward
        up = SIMD3(x.y * f.z - x.z * f.y, x.z * f.x - x.x * f.z, x.x * f.y - x.y * f.x)
    }

    /// Screen position with x to the right and y up, in arbitrary units.
    func project(_ point: LatLon) -> CGPoint? {
        let v = Self.unit(point.latitude, point.longitude) * Geo.earthRadius - position
        let depth = (v * forward).sum()
        guard depth > 0 else { return nil }
        // Scaled up so that a one kilometre step stays well above rounding noise.
        return CGPoint(x: (v * right).sum() / depth * 1e6, y: (v * up).sum() / depth * 1e6)
    }
}
