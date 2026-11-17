import AppKit
import MapKit
import SwiftUI

enum GlobeStyle: String, CaseIterable, Identifiable {
    case standard = "Standard"
    case hybrid = "Hybrid"
    case satellite = "Satellite"

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

/// MapKit globe showing aircraft, ships and the selected target's track.
struct GlobeView: NSViewRepresentable {
    var entities: [Entity]
    var selectedID: String?
    var track: [TrackSegment]
    var marks: [TrackMark] = []
    var radars: [RadarMark] = []
    /// Aircraft drawn in the highlight colour.
    var highlighted: Set<String> = []
    /// The user's own aircraft: its card stays shown.
    var mineID: String?
    /// Dashed great circle from the user's aircraft to its destination.
    var route: [LatLon] = []
    /// Routes of dropped flight plans, departure to destination.
    var plans: [[LatLon]] = []
    /// Third line of the user's aircraft card (flight, runway alignment).
    var mineNote: String?
    /// Extended centreline of the runway the user's aircraft is aligned with.
    var centerline: [LatLon] = []
    var style: GlobeStyle
    var focus: MapFocus?
    /// Incremented to frame the data closely.
    var zoomRequest = 0
    var onSelect: (String) -> Void
    var onHoverRadar: ([String]) -> Void = { _ in }
    var onSelectRadar: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsZoomControls = true
        map.isPitchEnabled = true
        map.register(TargetView.self, forAnnotationViewWithReuseIdentifier: Coordinator.reuseID)
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
        coordinator.onHoverRadar = onHoverRadar
        coordinator.onSelectRadar = onSelectRadar
        if coordinator.style != style {
            coordinator.style = style
            coordinator.applyStyle(to: map)
        }
        coordinator.syncFocus(focus, zoomRequest: zoomRequest, on: map)
        coordinator.syncTargets(entities, highlighted: highlighted, on: map)
        coordinator.syncSelection(selectedID, on: map)
        coordinator.syncTrack(track, on: map)
        coordinator.syncMarks(marks, on: map)
        coordinator.syncPlans(plans, on: map)
        coordinator.syncRadars(radars, on: map)
        coordinator.syncMine(mineID, route: route, note: mineNote, centerline: centerline, on: map)
        coordinator.refreshIcons(on: map)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        static let reuseID = "target"
        static let gapTitle = "gap"
        static let aboveTitle = "above"
        static let turbulentTitle = "turbulent"
        /// Degrees per direction bucket.
        static let step = 3.0
        /// Direction buckets, plus one for "unknown".
        static let buckets = Int(360 / step) + 1
        /// Icon sizes between the globe and an airport apron.
        static let sizes: [CGFloat] = [0.72, 0.8, 0.9, 1.0, 1.12, 1.26, 1.42]

        var onSelect: (String) -> Void = { _ in }
        var onHoverRadar: ([String]) -> Void = { _ in }
        var onSelectRadar: (String) -> Void = { _ in }
        var style: GlobeStyle?

        var annotations: [String: TargetAnnotation] = [:]
        var selectedID: String?
        var trackOverlays: [(signature: [Double], line: MKPolyline)] = []
        var focusID: UUID?
        var zoomRequest = 0
        var icons: [Int: NSImage] = [:]
        var hovered: TargetAnnotation?
        var hoverCard: HoverCard?

        /// What is drawn now, which differs from `style` far out: MapKit only
        /// draws a globe with imagery, so the Standard style hands over to the
        /// hybrid one when the camera is far enough to see the Earth as a whole.
        var drawn: GlobeStyle?
        var showsGlobe = true
        /// Camera distances between which the hand-over happens, metres. Two
        /// values so that it does not flicker around a single limit.
        static let globeAbove = 4_500_000.0
        static let flatBelow = 3_000_000.0

        func applyStyle(to map: MKMapView) {
            guard let style else { return }
            let distance = map.camera.centerCoordinateDistance
            if distance > Self.globeAbove { showsGlobe = true }
            if distance < Self.flatBelow { showsGlobe = false }
            let wanted: GlobeStyle = style == .standard && showsGlobe ? .hybrid : style
            guard wanted != drawn else { return }
            drawn = wanted
            map.preferredConfiguration = wanted.configuration
        }

        // Stored here for the extensions: Overlays.swift, Mine.swift.
        var markAnnotations: [String: MarkAnnotation] = [:]
        /// Dashed lines from datalink envelopes to their ground station.
        var markLinks: [String: MKPolyline] = [:]

        var planLines: [MKPolyline] = []
        var planSignature: [Double] = []

        var radarAnnotations: [String: RadarAnnotation] = [:]

        var mineID: String?
        var mineNote: String?
        var mineCard: HoverCard?
        var centerlineLine: MKPolyline?
        var centerlineSignature: [Double] = []
        var routeLine: MKPolyline?
        var routeSignature: [Double] = []

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

        func syncTargets(_ entities: [Entity], highlighted: Set<String>, on map: MKMapView) {
            var seen = Set<String>()
            var added: [TargetAnnotation] = []
            for entity in entities {
                guard let latitude = entity.latitude, let longitude = entity.longitude else { continue }
                seen.insert(entity.id)
                let symbol: Int
                if entity.kind == .ship {
                    symbol = 0
                } else if entity.info.isVehicle {
                    symbol = AircraftIcons.vehicle
                } else {
                    symbol = AircraftIcons.symbol(for: entity.info.typecode)
                }
                let summary = HoverCard.Content(
                    name: entity.name, flag: entity.info.flag, registration: entity.info.registration,
                    typecode: entity.info.typecode, address: entity.id.uppercased()
                )
                let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                if let annotation = annotations[entity.id] {
                    if annotation.coordinate.latitude != latitude || annotation.coordinate.longitude != longitude {
                        annotation.coordinate = coordinate
                    }
                    annotation.track = entity[.track]
                    annotation.symbol = symbol
                    annotation.summary = summary
                    annotation.highlighted = highlighted.contains(entity.id)
                } else {
                    let annotation = TargetAnnotation(
                        id: entity.id, kind: entity.kind, coordinate: coordinate,
                        track: entity[.track], symbol: symbol, summary: summary
                    )
                    annotation.highlighted = highlighted.contains(entity.id)
                    annotations[entity.id] = annotation
                    added.append(annotation)
                }
            }
            let gone = annotations.filter { !seen.contains($0.key) }
            if !gone.isEmpty {
                if let hovered, gone[hovered.id] != nil { hover(nil, on: map) }
                map.removeAnnotations(Array(gone.values))
                for id in gone.keys { annotations[id] = nil }
            }
            if !added.isEmpty { map.addAnnotations(added) }
        }

        /// The selection is ours, not MapKit's: it changes only when a target
        /// is clicked or the detail panel is closed.
        func syncSelection(_ id: String?, on map: MKMapView) {
            guard id != selectedID else { return }
            selectedID = id
            if let id, let annotation = annotations[id], !map.visibleMapRect.contains(MKMapPoint(annotation.coordinate)) {
                // Selected from the table: bring it into view.
                map.setCenter(annotation.coordinate, animated: true)
            }
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let radar = annotation as? RadarAnnotation {
                let view = RadarView(annotation: radar, reuseIdentifier: nil)
                let image = Self.radarImage(radar.mark.label, selected: radar.mark.selected)
                view.image = image
                // Weak candidates are drawn faded.
                view.alphaValue = radar.mark.isDoubtful ? 0.55 : 1
                view.centerOffset = CGPoint(x: (image.size.width - 18) / 2, y: 0)
                // Few and meaningful: never hidden behind aircraft.
                view.displayPriority = .required
                view.zPriority = .min
                view.onHover = { [weak self] codes in self?.onHoverRadar(codes) }
                view.blink(every: radar.mark.blinking ? radar.mark.period ?? 4 : nil)
                return view
            }
            if let mark = annotation as? MarkAnnotation {
                let view = MKAnnotationView(annotation: mark, reuseIdentifier: nil)
                if mark.mark.kind == .waypoint {
                    let image = Self.waypointImage(mark.mark.label)
                    view.image = image
                    view.centerOffset = CGPoint(x: (image.size.width - 7) / 2, y: 0)
                    view.displayPriority = .defaultHigh
                    view.zPriority = .min
                    return view
                }
                if mark.mark.kind == .groundStation {
                    let image = Self.stationImage(mark.mark.label.components(separatedBy: "\n")[0])
                    view.image = image
                    // The badge, not the middle of the label, sits on the station.
                    view.centerOffset = CGPoint(x: (image.size.width - 16) / 2, y: 0)
                    // Stations give way to aircraft and to each other when crowded.
                    view.displayPriority = .defaultHigh
                } else {
                    view.image = Self.markImage(mark.mark.kind)
                    view.displayPriority = .required
                }
                view.toolTip = mark.mark.label
                view.zPriority = .min
                return view
            }
            guard let annotation = annotation as? TargetAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: Self.reuseID, for: annotation)
            view.canShowCallout = false
            view.displayPriority = .required
            (view as? TargetView)?.onHover = { [weak self, weak mapView] hovered in
                guard let self, let mapView else { return }
                self.hover(hovered, on: mapView)
            }
            let size = sizeLevel(for: mapView.camera.centerCoordinateDistance)
            let key = iconKey(for: annotation, frame: CameraFrame(mapView.camera), size: size)
            annotation.iconKey = key
            view.image = icon(for: key)
            view.zPriority = annotation.id == selectedID ? .max : .defaultUnselected
            return view
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line)
            if line.title == Self.planTitle {
                renderer.strokeColor = NSColor.systemPurple.withAlphaComponent(0.9)
                renderer.lineWidth = 2
                renderer.lineDashPattern = [6, 4]
                return renderer
            }
            if line.title == Self.centerlineTitle {
                renderer.strokeColor = NSColor.systemGreen.withAlphaComponent(0.9)
                renderer.lineWidth = 2
                renderer.lineDashPattern = [2, 4]
                return renderer
            }
            if line.title == Self.routeTitle {
                renderer.strokeColor = NSColor.white.withAlphaComponent(0.85)
                renderer.lineWidth = 1.5
                renderer.lineDashPattern = [6, 5]
                return renderer
            }
            if line.title == Self.downlinkTitle || line.title == Self.uplinkTitle {
                renderer.strokeColor = (line.title == Self.downlinkTitle ? NSColor.systemOrange : .systemCyan).withAlphaComponent(0.85)
                renderer.lineWidth = 1.2
                renderer.lineDashPattern = [4, 4]
                return renderer
            }
            renderer.strokeColor = .systemYellow
            renderer.lineWidth = 3
            if line.title == Self.gapTitle {
                renderer.lineDashPattern = [2, 9]
                renderer.strokeColor = NSColor.systemYellow.withAlphaComponent(0.75)
            }
            if line.title == Self.aboveTitle || line.title == Self.turbulentTitle {
                renderer.strokeColor = line.title == Self.turbulentTitle ? .systemRed : .systemOrange
                renderer.lineWidth = 6
            }
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let mark = view.annotation as? MarkAnnotation {
                mapView.deselectAnnotation(mark, animated: false)
                return
            }
            if let radar = view.annotation as? RadarAnnotation {
                mapView.deselectAnnotation(radar, animated: false)
                onSelectRadar(radar.mark.id)
                return
            }
            guard let annotation = view.annotation as? TargetAnnotation else { return }
            // MapKit must not keep a selection of its own: clicking the map
            // would clear it, and clicking the same target again would be ignored.
            mapView.deselectAnnotation(annotation, animated: false)
            selectedID = annotation.id
            onSelect(annotation.id)
            refreshIcons(on: mapView)
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            refreshIcons(on: mapView)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // Once the camera has settled, not during a gesture.
            applyStyle(to: mapView)
        }
    }
}
