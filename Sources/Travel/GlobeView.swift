import AppKit
import MapKit
import SwiftUI

enum GlobeStyle: String, CaseIterable, Identifiable {
    case satellite = "Satellite"
    case hybrid = "Hybrid"
    case standard = "Standard"

    var id: String { rawValue }

    var configuration: MKMapConfiguration {
        switch self {
        case .satellite: MKImageryMapConfiguration(elevationStyle: .realistic)
        case .hybrid: MKHybridMapConfiguration(elevationStyle: .realistic)
        case .standard: MKStandardMapConfiguration(elevationStyle: .realistic)
        }
    }
}

/// Where the camera should go; a new `id` triggers the move.
struct MapFocus: Equatable {
    let id: UUID
    let center: LatLon
    /// Metres.
    let extent: Double
}

final class TargetAnnotation: NSObject, MKAnnotation {
    let id: String
    let kind: Kind
    @objc dynamic var coordinate: CLLocationCoordinate2D
    /// Degrees; nil when the direction is unknown.
    var track: Double?
    var iconKey = -1

    init(id: String, kind: Kind, coordinate: CLLocationCoordinate2D, track: Double?) {
        self.id = id
        self.kind = kind
        self.coordinate = coordinate
        self.track = track
    }
}

/// The camera as a perspective view of a spherical Earth. It gives the
/// on-screen direction of a course anywhere on the globe, whatever the camera
/// heading and pitch; MapKit's own point conversion is not reliable there.
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

/// MapKit globe showing aircraft, ships and the selected target's track.
struct GlobeView: NSViewRepresentable {
    var entities: [Entity]
    var selectedID: String?
    var track: [TrackSegment]
    var style: GlobeStyle
    var focus: MapFocus?
    /// Incremented to frame the data closely.
    var zoomRequest = 0
    var onSelect: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsZoomControls = true
        map.isPitchEnabled = true
        map.register(MKAnnotationView.self, forAnnotationViewWithReuseIdentifier: Coordinator.reuseID)
        map.camera = MKMapCamera(
            lookingAtCenter: CLLocationCoordinate2D(latitude: 46, longitude: 4),
            fromDistance: 14_000_000,
            pitch: 0,
            heading: 0
        )
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        if coordinator.style != style {
            coordinator.style = style
            map.preferredConfiguration = style.configuration
        }
        coordinator.syncFocus(focus, zoomRequest: zoomRequest, on: map)
        coordinator.syncTargets(entities, on: map)
        coordinator.syncSelection(selectedID, on: map)
        coordinator.syncTrack(track, on: map)
        coordinator.refreshIcons(on: map)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        static let reuseID = "target"
        private static let gapTitle = "gap"
        /// Direction buckets of 5 degrees, plus one for "unknown".
        private static let buckets = 73

        var onSelect: (String?) -> Void = { _ in }
        var style: GlobeStyle?

        private var annotations: [String: TargetAnnotation] = [:]
        private var selectedID: String?
        private var isSyncingSelection = false
        private var trackOverlays: [(signature: [Double], line: MKPolyline)] = []
        private var focusID: UUID?
        private var zoomRequest = 0
        private var icons: [Int: NSImage] = [:]

        // MARK: Sync from SwiftUI

        /// A new dataset turns the globe towards the data without zooming in;
        /// a zoom request frames the data.
        func syncFocus(_ focus: MapFocus?, zoomRequest: Int, on map: MKMapView) {
            let zoom = zoomRequest != self.zoomRequest
            self.zoomRequest = zoomRequest
            guard let focus, zoom || focus.id != focusID else { return }
            focusID = focus.id
            let fitting = min(20_000_000, max(30_000, focus.extent * 1.6))
            let camera = MKMapCamera(
                lookingAtCenter: CLLocationCoordinate2D(latitude: focus.center.latitude, longitude: focus.center.longitude),
                fromDistance: zoom ? fitting : max(fitting, map.camera.centerCoordinateDistance),
                pitch: 0,
                heading: 0
            )
            map.setCamera(camera, animated: true)
        }

        func syncTargets(_ entities: [Entity], on map: MKMapView) {
            var seen = Set<String>()
            var added: [TargetAnnotation] = []
            for entity in entities {
                guard let latitude = entity.latitude, let longitude = entity.longitude else { continue }
                seen.insert(entity.id)
                let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                if let annotation = annotations[entity.id] {
                    if annotation.coordinate.latitude != latitude || annotation.coordinate.longitude != longitude {
                        annotation.coordinate = coordinate
                    }
                    annotation.track = entity[.track]
                } else {
                    let annotation = TargetAnnotation(id: entity.id, kind: entity.kind, coordinate: coordinate, track: entity[.track])
                    annotations[entity.id] = annotation
                    added.append(annotation)
                }
            }
            // Targets coming and going must not change the selection.
            isSyncingSelection = true
            defer { isSyncingSelection = false }
            let gone = annotations.filter { !seen.contains($0.key) }
            if !gone.isEmpty {
                map.removeAnnotations(Array(gone.values))
                for id in gone.keys { annotations[id] = nil }
            }
            if !added.isEmpty {
                map.addAnnotations(added)
                if let selected = added.first(where: { $0.id == selectedID }) {
                    map.selectAnnotation(selected, animated: false)
                }
            }
        }

        func syncSelection(_ id: String?, on map: MKMapView) {
            guard id != selectedID else { return }
            selectedID = id
            isSyncingSelection = true
            defer { isSyncingSelection = false }
            let current = map.selectedAnnotations.first as? TargetAnnotation
            guard current?.id != id else { return }
            if let id, let annotation = annotations[id] {
                // Selected from a table: bring it into view.
                map.setCenter(annotation.coordinate, animated: true)
                map.selectAnnotation(annotation, animated: true)
            } else {
                for annotation in map.selectedAnnotations {
                    map.deselectAnnotation(annotation, animated: false)
                }
            }
        }

        func syncTrack(_ track: [TrackSegment], on map: MKMapView) {
            for (i, segment) in track.enumerated() {
                let signature: [Double] = [
                    Double(segment.points.count),
                    segment.points.first?.timestamp ?? 0,
                    segment.points.last?.timestamp ?? 0,
                    segment.isGap ? 1 : 0,
                ]
                if i < trackOverlays.count {
                    if trackOverlays[i].signature == signature { continue }
                    map.removeOverlay(trackOverlays[i].line)
                }
                let coordinates = segment.points.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
                // Bridges across gaps follow the great circle.
                let line: MKPolyline = segment.isGap
                    ? MKGeodesicPolyline(coordinates: coordinates, count: coordinates.count)
                    : MKPolyline(coordinates: coordinates, count: coordinates.count)
                line.title = segment.isGap ? Self.gapTitle : nil
                map.addOverlay(line, level: .aboveLabels)
                if i < trackOverlays.count {
                    trackOverlays[i] = (signature, line)
                } else {
                    trackOverlays.append((signature, line))
                }
            }
            if trackOverlays.count > track.count {
                map.removeOverlays(trackOverlays[track.count...].map(\.line))
                trackOverlays.removeSubrange(track.count...)
            }
        }

        /// Point each icon along its track as seen on screen, which on a globe
        /// depends on camera heading, pitch and where the target sits.
        func refreshIcons(on map: MKMapView) {
            let frame = CameraFrame(map.camera)
            for annotation in annotations.values {
                guard let view = map.view(for: annotation) else { continue }
                let key = iconKey(for: annotation, frame: frame)
                if annotation.iconKey != key {
                    annotation.iconKey = key
                    view.image = icon(for: key)
                }
            }
        }

        private func iconKey(for annotation: TargetAnnotation, frame: CameraFrame) -> Int {
            var bucket = Self.buckets - 1
            if let track = annotation.track {
                let here = LatLon(latitude: annotation.coordinate.latitude, longitude: annotation.coordinate.longitude)
                let ahead = Geo.destination(here, bearing: track, distance: 1000)
                // Degrees counter-clockwise from screen east.
                var degrees = 90 - track
                if let p0 = frame.project(here), let p1 = frame.project(ahead) {
                    let dx = p1.x - p0.x, dy = p1.y - p0.y
                    if dx.isFinite, dy.isFinite, dx != 0 || dy != 0 {
                        degrees = atan2(dy, dx) * 180 / .pi
                    }
                }
                bucket = Int(((degrees.truncatingRemainder(dividingBy: 360) + 360) / 5).rounded()) % 72
            }
            let selected = annotation.id == selectedID ? 1 : 0
            let kind = annotation.kind == .ship ? 1 : 0
            return (bucket * 2 + selected) * 2 + kind
        }

        private func icon(for key: Int) -> NSImage {
            if let cached = icons[key] { return cached }
            let isShip = key % 2 == 1
            let selected = (key / 2) % 2 == 1
            let bucket = key / 4
            let hasDirection = bucket < Self.buckets - 1
            let angle = Double(bucket) * 5 * .pi / 180
            let scale: CGFloat = selected ? 1.35 : 1
            let side = 30 * scale
            let color: NSColor = selected ? .systemYellow : (isShip ? .systemTeal : .white)
            let symbol: NSImage? = isShip ? nil : NSImage(systemSymbolName: "airplane", accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 15 * scale, weight: .bold)
                        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
                )

            let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                context.translateBy(x: rect.midX, y: rect.midY)
                context.setShadow(offset: .zero, blur: 3, color: NSColor.black.withAlphaComponent(0.8).cgColor)
                guard hasDirection else {
                    // Direction unknown: a dot.
                    let radius = 4 * scale
                    context.setFillColor(color.cgColor)
                    context.fillEllipse(in: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
                    return true
                }
                // Both shapes point east before rotation.
                context.rotate(by: angle)
                if let symbol {
                    let size = symbol.size
                    symbol.draw(in: NSRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
                } else {
                    let hull = CGMutablePath()
                    hull.move(to: CGPoint(x: -8 * scale, y: -3.5 * scale))
                    hull.addLine(to: CGPoint(x: 3 * scale, y: -3.5 * scale))
                    hull.addLine(to: CGPoint(x: 9 * scale, y: 0))
                    hull.addLine(to: CGPoint(x: 3 * scale, y: 3.5 * scale))
                    hull.addLine(to: CGPoint(x: -8 * scale, y: 3.5 * scale))
                    hull.closeSubpath()
                    context.addPath(hull)
                    context.setFillColor(color.cgColor)
                    context.fillPath()
                }
                return true
            }
            icons[key] = image
            return image
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let annotation = annotation as? TargetAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: Self.reuseID, for: annotation)
            view.canShowCallout = false
            view.displayPriority = .required
            let key = iconKey(for: annotation, frame: CameraFrame(mapView.camera))
            annotation.iconKey = key
            view.image = icon(for: key)
            return view
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line)
            renderer.strokeColor = .systemYellow
            renderer.lineWidth = 3
            if line.title == Self.gapTitle {
                renderer.lineDashPattern = [2, 9]
                renderer.strokeColor = NSColor.systemYellow.withAlphaComponent(0.75)
            }
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard !isSyncingSelection, let annotation = view.annotation as? TargetAnnotation else { return }
            selectedID = annotation.id
            onSelect(annotation.id)
            refreshIcons(on: mapView)
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            guard !isSyncingSelection,
                  let annotation = view.annotation as? TargetAnnotation,
                  annotation.id == selectedID
            else { return }
            selectedID = nil
            onSelect(nil)
            refreshIcons(on: mapView)
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            refreshIcons(on: mapView)
        }
    }
}
