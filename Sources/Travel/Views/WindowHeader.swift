import AppKit
import SwiftUI

/// A strip protecting the top of the window: when the pointer is over it, a
/// translucent bar fades in together with the close, minimise and zoom buttons.
struct WindowHeader: View {
    let title: String
    @Binding var isHovered: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                }
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 90)
        }
        .opacity(isHovered ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .background(HeaderTracker(isHovered: $isHovered))
        .frame(height: Layout.header)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }
}

/// Tracks the pointer over the header strip and fades the window buttons with it.
struct HeaderTracker: NSViewRepresentable {
    @Binding var isHovered: Bool

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = { hovered in isHovered = hovered }
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {}

    final class TrackingView: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var area: NSTrackingArea?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            setButtons(visible: false, animated: false)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            self.area = area
        }

        override func mouseEntered(with event: NSEvent) {
            onChange(true)
            setButtons(visible: true, animated: true)
        }

        override func mouseExited(with event: NSEvent) {
            onChange(false)
            setButtons(visible: false, animated: true)
        }

        private func setButtons(visible: Bool, animated: Bool) {
            guard let window else { return }
            // In full screen the system shows and hides the title bar itself.
            let alpha: CGFloat = visible || window.styleMask.contains(.fullScreen) ? 1 : 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animated ? 0.2 : 0
                for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    window.standardWindowButton(kind)?.animator().alphaValue = alpha
                }
            }
        }
    }
}
