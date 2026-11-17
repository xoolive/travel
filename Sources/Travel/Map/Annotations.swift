import AppKit
import MapKit

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
    /// Interrogated by the interrogator under the pointer.
    var highlighted = false
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

/// An interrogator at its candidate site.
final class RadarAnnotation: NSObject, MKAnnotation {
    var mark: RadarMark
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: mark.position.latitude, longitude: mark.position.longitude)
    }

    init(_ mark: RadarMark) { self.mark = mark }
}

/// A radar badge that reports hovering and can blink with its antenna.
final class RadarView: MKAnnotationView {
    var onHover: ([String]) -> Void = { _ in }
    private var area: NSTrackingArea?
    private var blinkPeriod: Double?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) { onHover((annotation as? RadarAnnotation)?.mark.codes ?? []) }
    override func mouseExited(with event: NSEvent) { onHover([]) }

    /// Fades out and back once per rotation of the antenna.
    func blink(every period: Double?) {
        guard period != blinkPeriod else { return }
        blinkPeriod = period
        wantsLayer = true
        layer?.removeAnimation(forKey: "blink")
        guard let period else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0.15
        animation.duration = period / 2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(animation, forKey: "blink")
    }
}
