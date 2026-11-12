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

final class TargetAnnotation: NSObject, MKAnnotation {
    let id: String
    let kind: Kind
    @objc dynamic var coordinate: CLLocationCoordinate2D
    /// Degrees; nil when the direction is unknown.
    var track: Double?
    /// Silhouette in the aircraft icon set.
    var symbol: Int
    /// Shown when the pointer is over the icon.
    var summary: HoverCard.Content
    var iconKey = -1

    init(
        id: String, kind: Kind, coordinate: CLLocationCoordinate2D, track: Double?, symbol: Int,
        summary: HoverCard.Content
    ) {
        self.id = id
        self.kind = kind
        self.coordinate = coordinate
        self.track = track
        self.symbol = symbol
        self.summary = summary
    }
}

/// An icon that reports when the pointer enters or leaves it.
final class TargetView: MKAnnotationView {
    var onHover: (TargetAnnotation?) -> Void = { _ in }
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover(annotation as? TargetAnnotation)
    }

    override func mouseExited(with event: NSEvent) {
        onHover(nil)
    }
}

/// The card shown above an icon under the pointer, as a two by two grid:
/// callsign and flag with tail number on top, type and address below, the
/// left column aligned left and the right column aligned right.
final class HoverCard: NSVisualEffectView {
    struct Content: Equatable {
        var name: String?
        var flag: String?
        var registration: String?
        var typecode: String?
        var address: String
    }

    private let primary = NSTextField(labelWithString: "")
    private let origin = NSTextField(labelWithString: "")
    private let type = NSTextField(labelWithString: "")
    private let address = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        primary.font = .systemFont(ofSize: 14, weight: .bold)
        primary.textColor = .white
        origin.font = .systemFont(ofSize: 12, weight: .medium)
        origin.textColor = .white
        for field in [type, address] {
            field.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
            field.textColor = NSColor.white.withAlphaComponent(0.65)
        }

        let grid = NSGridView(views: [[primary, origin], [type, address]])
        grid.rowSpacing = 2
        grid.columnSpacing = 18
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    func show(_ content: Content) {
        // Without a callsign the tail number, or else the address, leads.
        let lead = content.name ?? content.registration ?? content.address
        primary.stringValue = lead
        let tail = content.name == nil ? nil : content.registration
        origin.stringValue = [content.flag, tail].compactMap { $0 }.joined(separator: " ")
        type.stringValue = content.typecode ?? ""
        address.stringValue = lead == content.address ? "" : content.address
    }

    /// The pointer must keep reaching the icon underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

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

/// MapKit globe showing aircraft, ships and the selected target's track.
struct GlobeView: NSViewRepresentable {
    var entities: [Entity]
    var selectedID: String?
    var track: [TrackSegment]
    var style: GlobeStyle
    var focus: MapFocus?
    /// Incremented to frame the data closely.
    var zoomRequest = 0
    var onSelect: (String) -> Void

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
        /// Degrees per direction bucket.
        private static let step = 3.0
        /// Direction buckets, plus one for "unknown".
        private static let buckets = Int(360 / step) + 1
        /// Icon sizes between the globe and an airport apron.
        private static let sizes: [CGFloat] = [0.72, 0.8, 0.9, 1.0, 1.12, 1.26, 1.42]

        var onSelect: (String) -> Void = { _ in }
        var style: GlobeStyle?

        private var annotations: [String: TargetAnnotation] = [:]
        private var selectedID: String?
        private var trackOverlays: [(signature: [Double], line: MKPolyline)] = []
        private var focusID: UUID?
        private var zoomRequest = 0
        private var icons: [Int: NSImage] = [:]
        private var hovered: TargetAnnotation?
        private var hoverCard: HoverCard?

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
                } else {
                    let annotation = TargetAnnotation(
                        id: entity.id, kind: entity.kind, coordinate: coordinate,
                        track: entity[.track], symbol: symbol, summary: summary
                    )
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

        // MARK: Icons

        /// Points each icon along its track as seen on screen, which on a globe
        /// depends on camera heading, pitch and where the target sits, and
        /// sizes it for the zoom level.
        func refreshIcons(on map: MKMapView) {
            let frame = CameraFrame(map.camera)
            let size = sizeLevel(for: map.camera.centerCoordinateDistance)
            for annotation in annotations.values {
                guard let view = map.view(for: annotation) else { continue }
                let key = iconKey(for: annotation, frame: frame, size: size)
                if annotation.iconKey != key {
                    annotation.iconKey = key
                    view.image = icon(for: key)
                    view.zPriority = annotation.id == selectedID ? .max : .defaultUnselected
                }
            }
            placeHoverLabel(on: map)
        }

        /// Small on the globe, growing as the camera comes down to an airport:
        /// the size follows the logarithm of the camera distance.
        private func sizeLevel(for distance: CLLocationDistance) -> Int {
            let far = log(3_000_000.0), near = log(4_000.0)
            let f = (far - log(max(distance, 1))) / (far - near)
            return Int((min(1, max(0, f)) * Double(Self.sizes.count - 1)).rounded())
        }

        private func iconKey(for annotation: TargetAnnotation, frame: CameraFrame, size: Int) -> Int {
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
                bucket = Int(((degrees.truncatingRemainder(dividingBy: 360) + 360) / Self.step).rounded()) % (Self.buckets - 1)
            }
            let selected = annotation.id == selectedID ? 1 : 0
            let kind = annotation.kind == .ship ? 1 : 0
            let style = (bucket * 2 + selected) * 2 + kind
            return (style * AircraftIcons.capacity + annotation.symbol) * Self.sizes.count + size
        }

        private func icon(for key: Int) -> NSImage {
            if let cached = icons[key] { return cached }
            let size = Self.sizes[key % Self.sizes.count]
            let symbol = (key / Self.sizes.count) % AircraftIcons.capacity
            let style = key / Self.sizes.count / AircraftIcons.capacity
            let isShip = style % 2 == 1
            let selected = (style / 2) % 2 == 1
            let bucket = style / 4
            let hasDirection = bucket < Self.buckets - 1
            let angle = Double(bucket) * Self.step * .pi / 180
            // The box of a sprite, of which the silhouette fills about two thirds.
            let side = (38 * size * (selected ? 1.2 : 1)).rounded()
            let fill = selected ? Self.selectedColor : (isShip ? Self.shipColor : Self.aircraftColor)

            // Drawn into a plain bitmap, independent of the view it ends up in.
            let pixels = Int((side * Self.bitmapScale).rounded())
            guard let context = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return NSImage() }
            context.scaleBy(x: Self.bitmapScale, y: Self.bitmapScale)
            context.translateBy(x: side / 2, y: side / 2)
            // A soft dark halo instead of an outline keeps the shape readable
            // on both bright and dark maps.
            context.setShadow(offset: .zero, blur: 2.5 * Self.bitmapScale, color: CGColor(gray: 0, alpha: 0.85))
            context.setFillColor(fill)
            if !hasDirection {
                // Direction unknown: a dot.
                let radius = side * 0.12
                context.fillEllipse(in: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
            } else {
                // Shapes are drawn nose up; angles are counter-clockwise from east.
                context.rotate(by: angle - .pi / 2)
                let box = CGRect(x: -side / 2, y: -side / 2, width: side, height: side)
                if !isShip, let sprite = AircraftIcons.sprite(symbol) {
                    // The sprite gives the shape; its own colours are replaced.
                    context.beginTransparencyLayer(auxiliaryInfo: nil)
                    context.draw(sprite, in: box)
                    context.setBlendMode(.sourceIn)
                    context.fill(box)
                    context.endTransparencyLayer()
                } else {
                    let scale = side / 38 * (isShip ? 0.75 : 0.8)
                    context.scaleBy(x: scale, y: scale)
                    context.addPath(isShip ? Self.shipShape : Self.aircraftShape)
                    context.fillPath()
                }
            }
            let image = context.makeImage().map { NSImage(cgImage: $0, size: NSSize(width: side, height: side)) } ?? NSImage()
            icons[key] = image
            return image
        }

        private static let bitmapScale: CGFloat = 2
        // The tangram palette.
        private static let aircraftColor = CGColor(srgbRed: 0.976, green: 0.992, blue: 0.082, alpha: 1)
        private static let selectedColor = CGColor(srgbRed: 1, green: 0.392, blue: 0.392, alpha: 1)
        private static let shipColor = CGColor(srgbRed: 0.25, green: 0.78, blue: 0.82, alpha: 1)

        /// Used when the icon atlas is missing: tangram's medium jet, centred, nose up.
        private static let aircraftShape: CGPath = polygon([
            (12, 28), (13, 26), (14, 23), (14, 18), (16, 17), (16, 19), (18, 19), (18, 16), (24, 11), (24, 10),
            (23, 10), (15, 13), (14, 13), (13, 6), (13, 5), (16, 2), (16, 0), (13, 2), (12, 0), (11, 2),
            (8, 0), (8, 2), (11, 5), (11, 6), (10, 13), (9, 13), (1, 10), (0, 10), (0, 11), (6, 16),
            (6, 19), (8, 19), (8, 17), (10, 18), (10, 23), (11, 26),
        ], width: 24, height: 28)

        /// A hull, centred, bow up.
        private static let shipShape: CGPath = polygon(
            [(6, 24), (11, 16), (11, 2), (9, 0), (3, 0), (1, 2), (1, 16)], width: 12, height: 24
        )

        private static func polygon(_ points: [(CGFloat, CGFloat)], width: CGFloat, height: CGFloat) -> CGPath {
            let path = CGMutablePath()
            for (i, point) in points.enumerated() {
                let p = CGPoint(x: point.0 - width / 2, y: point.1 - height / 2)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
            return path
        }

        // MARK: Hover

        /// Shows a small identity card while the pointer is over an icon.
        private func hover(_ annotation: TargetAnnotation?, on map: MKMapView) {
            hovered = annotation
            guard annotation != nil else {
                hoverCard?.removeFromSuperview()
                hoverCard = nil
                return
            }
            if hoverCard == nil {
                let card = HoverCard()
                map.addSubview(card)
                hoverCard = card
            }
            placeHoverLabel(on: map)
        }

        private func placeHoverLabel(on map: MKMapView) {
            guard let hovered, let card = hoverCard, let view = map.view(for: hovered) else { return }
            card.show(hovered.summary)
            let size = card.fittingSize
            let anchor = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: map)
            let above = view.bounds.height / 2 + 2
            // Above the icon, whichever way the map's coordinates run.
            let y = map.isFlipped ? anchor.y - above - size.height : anchor.y + above
            card.frame = NSRect(x: (anchor.x - size.width / 2).rounded(), y: y.rounded(), width: size.width, height: size.height)
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
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
    }
}
