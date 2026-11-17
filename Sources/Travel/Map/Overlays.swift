import AppKit
import MapKit

extension GlobeView.Coordinator {
    /// Points per polyline. A live track grows at its end: cut into
    /// fixed chunks, only the last one is replaced at each update, and
    /// MapKit has time to draw the others.
    static let chunkSize = 200

    func syncTrack(_ segments: [TrackSegment], on map: MKMapView) {
        var track: [TrackSegment] = []
        for segment in segments {
            guard !segment.isGap, segment.mark == nil, segment.points.count > Self.chunkSize else {
                track.append(segment)
                continue
            }
            var start = 0
            while start < segment.points.count - 1 {
                let end = min(start + Self.chunkSize, segment.points.count - 1)
                // Chunks share their boundary point, so the line is unbroken.
                track.append(TrackSegment(points: Array(segment.points[start...end]), isGap: false))
                start = end
            }
        }
        for (i, segment) in track.enumerated() {
            let signature: [Double] = [
                Double(segment.points.count),
                segment.points.first?.timestamp ?? 0,
                segment.points.last?.timestamp ?? 0,
                segment.isGap ? 1 : 0,
                segment.mark == nil ? 0 : (segment.mark == .turbulent ? 2 : 1),
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
            if let mark = segment.mark { line.title = mark == .turbulent ? Self.turbulentTitle : Self.aboveTitle }
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

    // MARK: Track marks

    final class MarkAnnotation: NSObject, MKAnnotation {
        let mark: TrackMark
        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: mark.position.latitude, longitude: mark.position.longitude)
        }
        var title: String? { mark.label }

        init(_ mark: TrackMark) { self.mark = mark }
    }

    static let downlinkTitle = "link-down"
    static let uplinkTitle = "link-up"

    func syncMarks(_ marks: [TrackMark], on map: MKMapView) {
        let wanted = Dictionary(uniqueKeysWithValues: marks.map { ($0.id, $0) })
        let stale = markAnnotations.filter { wanted[$0.key] != $0.value.mark }
        if !stale.isEmpty {
            map.removeAnnotations(Array(stale.values))
            let lines = stale.keys.compactMap { markLinks.removeValue(forKey: $0) }
            if !lines.isEmpty { map.removeOverlays(lines) }
            for id in stale.keys { markAnnotations[id] = nil }
        }
        let added = marks.filter { markAnnotations[$0.id] == nil }.map(MarkAnnotation.init)
        for annotation in added { markAnnotations[annotation.mark.id] = annotation }
        if !added.isEmpty { map.addAnnotations(added) }
        var lines: [MKPolyline] = []
        for annotation in added {
            guard let link = annotation.mark.link else { continue }
            let ends = [annotation.coordinate, CLLocationCoordinate2D(latitude: link.latitude, longitude: link.longitude)]
            let line = MKGeodesicPolyline(coordinates: ends, count: 2)
            line.title = annotation.mark.kind == .datalinkUp ? Self.uplinkTitle : Self.downlinkTitle
            markLinks[annotation.mark.id] = line
            lines.append(line)
        }
        if !lines.isEmpty { map.addOverlays(lines, level: .aboveLabels) }
    }

    // MARK: Flight plans

    static let planTitle = "plan"

    func syncPlans(_ plans: [[LatLon]], on map: MKMapView) {
        let signature = plans.flatMap { [Double($0.count)] + $0.flatMap { [$0.latitude, $0.longitude] } }
        guard signature != planSignature else { return }
        planSignature = signature
        map.removeOverlays(planLines)
        planLines = plans.filter { $0.count >= 2 }.map { points in
            let coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            let line = MKGeodesicPolyline(coordinates: coordinates, count: coordinates.count)
            line.title = Self.planTitle
            return line
        }
        map.addOverlays(planLines, level: .aboveLabels)
    }

    /// A small dot with the waypoint's name beside it.
    static func waypointImage(_ name: String) -> NSImage {
        let text = NSAttributedString(string: name, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold), .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black.withAlphaComponent(0.7), .strokeWidth: -3.0,
        ])
        let dot: CGFloat = 7
        let width = dot + 3 + ceil(text.size().width)
        let height = max(dot, ceil(text.size().height))
        return NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let circle = NSRect(x: 0, y: (rect.height - dot) / 2, width: dot, height: dot)
            NSColor.systemPurple.setFill()
            NSBezierPath(ovalIn: circle).fill()
            NSColor.white.setStroke()
            NSBezierPath(ovalIn: circle.insetBy(dx: 0.5, dy: 0.5)).stroke()
            text.draw(at: NSPoint(x: dot + 3, y: (rect.height - text.size().height) / 2))
            return true
        }
    }

    // MARK: Radars

    func syncRadars(_ radars: [RadarMark], on map: MKMapView) {
        let wanted = Dictionary(uniqueKeysWithValues: radars.map { ($0.id, $0) })
        let gone = radarAnnotations.filter { wanted[$0.key] == nil }
        if !gone.isEmpty {
            map.removeAnnotations(Array(gone.values))
            for code in gone.keys { radarAnnotations[code] = nil }
        }
        var added: [RadarAnnotation] = []
        for mark in radars {
            if let annotation = radarAnnotations[mark.id],
               annotation.mark.label == mark.label, annotation.mark.selected == mark.selected {
                annotation.mark = mark
                (map.view(for: annotation) as? RadarView)?.blink(every: mark.blinking ? mark.period ?? 4 : nil)
            } else {
                // New, or its codes changed: the badge is redrawn.
                if let old = radarAnnotations[mark.id] { map.removeAnnotation(old) }
                let annotation = RadarAnnotation(mark)
                radarAnnotations[mark.id] = annotation
                added.append(annotation)
            }
        }
        if !added.isEmpty { map.addAnnotations(added) }
    }

    /// A teal badge with a radar glyph and the interrogator code beside it.
    static func radarImage(_ code: String, selected: Bool) -> NSImage {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        let text = NSAttributedString(string: code, attributes: [
            .font: font, .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black.withAlphaComponent(0.7), .strokeWidth: -3.0,
        ])
        let badge: CGFloat = 18
        let width = badge + 2 + ceil(text.size().width)
        let glyph = NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white])))
        return NSImage(size: NSSize(width: width, height: badge), flipped: false) { rect in
            let circle = NSRect(x: 0, y: 0, width: badge, height: badge).insetBy(dx: 1, dy: 1)
            Self.radarColor.setFill()
            NSBezierPath(ovalIn: circle).fill()
            // The selected radar gets a white ring.
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: selected ? 0.75 : 0, dy: selected ? 0.75 : 0))
            ring.lineWidth = selected ? 2 : 1
            (selected ? NSColor.white : NSColor.black.withAlphaComponent(0.5)).setStroke()
            ring.stroke()
            if let glyph {
                glyph.draw(in: NSRect(x: circle.midX - glyph.size.width / 2, y: circle.midY - glyph.size.height / 2,
                                      width: glyph.size.width, height: glyph.size.height))
            }
            text.draw(at: NSPoint(x: badge + 2, y: (rect.height - text.size().height) / 2))
            return true
        }
    }

    static let radarColor = NSColor.systemTeal

    /// A small antenna badge with the station's code beside it.
    static func stationImage(_ code: String) -> NSImage {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        let text = NSAttributedString(string: code, attributes: [
            .font: font, .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black.withAlphaComponent(0.7), .strokeWidth: -3.0,
        ])
        let badge: CGFloat = 16
        let width = badge + 3 + ceil(text.size().width)
        let glyph = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white])))
        return NSImage(size: NSSize(width: width, height: badge), flipped: false) { rect in
            let circle = NSRect(x: 0, y: 0, width: badge, height: badge).insetBy(dx: 1, dy: 1)
            NSColor.systemGray.setFill()
            NSBezierPath(ovalIn: circle).fill()
            NSColor.black.withAlphaComponent(0.5).setStroke()
            NSBezierPath(ovalIn: circle).stroke()
            if let glyph {
                glyph.draw(in: NSRect(x: circle.midX - glyph.size.width / 2, y: circle.midY - glyph.size.height / 2,
                                      width: glyph.size.width, height: glyph.size.height))
            }
            text.draw(at: NSPoint(x: badge + 2, y: (rect.height - text.size().height) / 2))
            return true
        }
    }

    static func markImage(_ kind: TrackMark.Kind) -> NSImage {
        let color: NSColor = switch kind {
        case .datalinkDown: .systemOrange
        case .datalinkUp: .systemCyan
        case .resolution: .systemRed
        case .groundStation: .systemGray
        case .waypoint: .systemPurple
        }
        let symbol = kind == .resolution ? "exclamationmark.triangle.fill" : "envelope.fill"
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        return NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            NSColor.black.withAlphaComponent(0.5).setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).stroke()
            if let glyph {
                let size = glyph.size
                glyph.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            }
            return true
        }
    }
}
