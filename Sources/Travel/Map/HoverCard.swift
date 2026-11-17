import AppKit
import MapKit

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
    /// A third line, for the user's own aircraft: its flight and runway.
    private let note = NSTextField(labelWithString: "")

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

        note.font = .systemFont(ofSize: 11, weight: .semibold)
        note.textColor = .systemGreen
        note.isHidden = true

        let grid = NSGridView(views: [[primary, origin], [type, address]])
        grid.rowSpacing = 2
        grid.columnSpacing = 18
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .trailing
        let stack = NSStackView(views: [grid, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    func show(_ content: Content, note text: String? = nil) {
        note.stringValue = text ?? ""
        note.isHidden = text == nil
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

extension GlobeView.Coordinator {
    // MARK: Hover

    /// Shows a small identity card while the pointer is over an icon.
    func hover(_ annotation: TargetAnnotation?, on map: MKMapView) {
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

    func placeHoverLabel(on map: MKMapView) {
        // The user's aircraft keeps its own card, hovered or not: only one.
        if let card = mineCard, let id = mineID, let annotation = annotations[id] {
            card.isHidden = false
            place(card, over: annotation, on: map, note: mineNote)
        } else {
            mineCard?.isHidden = true
        }
        guard let hovered, let card = hoverCard else { return }
        if mineCard != nil, hovered.id == mineID {
            card.isHidden = true
            return
        }
        place(card, over: hovered, on: map)
    }

    /// Places a card off the aircraft's right wing tip, as the icon is
    /// drawn on screen: the card sits beyond the tip along the wing, its
    /// nearest edge 6 points away. Without a direction (a dot), it goes
    /// to the right of the icon.
    func place(_ card: HoverCard, over annotation: TargetAnnotation, on map: MKMapView, note: String? = nil) {
        guard let view = map.view(for: annotation) else {
            card.isHidden = true
            return
        }
        card.isHidden = false
        card.show(annotation.summary, note: note)
        let size = card.fittingSize
        let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: map)
        guard let nose = Self.screenAngle(forKey: annotation.iconKey) else {
            let x = center.x + Self.halfWidth(of: view) + 6
            let y = center.y - size.height / 2
            card.frame = NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
            return
        }
        // Right wing: a quarter turn clockwise from the nose (y up).
        let wing = nose - .pi / 2
        let ux = cos(wing), uyUp = sin(wing)
        let tip = Self.extent(of: view, along: wing)
        // Distance from the card's centre to its edge facing the aircraft.
        let reach = size.width / 2 * abs(ux) + size.height / 2 * abs(uyUp)
        let d = tip + 6 + reach
        let uy = map.isFlipped ? -uyUp : uyUp
        let x = center.x + d * ux - size.width / 2
        let y = center.y + d * uy - size.height / 2
        card.frame = NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    /// The on-screen nose direction an icon was drawn with, in radians
    /// counter-clockwise from east, y up; nil for a dot.
    static func screenAngle(forKey key: Int) -> Double? {
        guard key >= 0 else { return nil }
        let style = key / sizes.count / AircraftIcons.capacity
        let bucket = style / 8
        guard bucket < buckets - 1 else { return nil }
        return Double(bucket) * step * .pi / 180
    }

    /// How far the drawn shape reaches from the icon's centre along a
    /// direction (radians, y up): the wing tip for the right-wing direction.
    static func extent(of view: MKAnnotationView, along angle: Double) -> CGFloat {
        guard let image = view.image else { return view.bounds.width / 2 }
        let key = ObjectIdentifier(image)
        if let cached = wingExtents[key] { return cached }
        var extent = image.size.width / 2
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
           cg.bitsPerPixel == 32, cg.width > 0 {
            let alphaOffset: Int = switch cg.alphaInfo {
            case .premultipliedFirst, .first, .noneSkipFirst: 0
            default: 3
            }
            let ux = cos(angle), uy = sin(angle)
            let midX = Double(cg.width) / 2, midY = Double(cg.height) / 2
            var best = 0.0
            for row in 0..<cg.height {
                for column in 0..<cg.width where bytes[row * cg.bytesPerRow + column * 4 + alphaOffset] > 16 {
                    // Rows run top to bottom; y up is the other way.
                    let along = (Double(column) + 0.5 - midX) * ux + (midY - Double(row) - 0.5) * uy
                    best = max(best, along)
                }
            }
            extent = CGFloat(best) * image.size.width / CGFloat(cg.width)
        }
        wingExtents[key] = extent
        return extent
    }
    nonisolated(unsafe) static var wingExtents: [ObjectIdentifier: CGFloat] = [:]

    /// Horizontal half-extent of what an annotation view draws: the
    /// non-transparent part of its image, else its bounds.
    static func halfWidth(of view: MKAnnotationView) -> CGFloat {
        guard let image = view.image else { return view.bounds.width / 2 }
        let key = ObjectIdentifier(image)
        if let cached = extents[key] { return cached }
        var extent = image.size.width / 2
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
           cg.bitsPerPixel == 32, cg.width > 0 {
            let alphaOffset: Int = switch cg.alphaInfo {
            case .premultipliedFirst, .first, .noneSkipFirst: 0
            default: 3
            }
            var maxDistance = 0
            let mid = cg.width / 2
            for row in 0..<cg.height {
                for column in 0..<cg.width where bytes[row * cg.bytesPerRow + column * 4 + alphaOffset] > 16 {
                    maxDistance = max(maxDistance, abs(column - mid))
                }
            }
            extent = CGFloat(maxDistance) * image.size.width / CGFloat(cg.width)
        }
        extents[key] = extent
        return extent
    }
    nonisolated(unsafe) static var extents: [ObjectIdentifier: CGFloat] = [:]
}
