import SwiftUI

private let utcFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
    return formatter
}()

/// Replay controls, or the live indicator with a way back in time.
struct ClockBar: View {
    @Bindable var state: AppState

    private static let speeds: [Double] = [1, 10, 60, 300, 1000]

    var body: some View {
        HStack(spacing: 14) {
            if state.isLive {
                Button(action: state.followLive) {
                    Text("LIVE")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(state.following ? Color.red : Color.gray.opacity(0.4), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Return to the present")
            } else {
                Button(action: state.togglePlayback) {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
            }

            Slider(
                value: Binding(get: { state.currentTime }, set: { state.seek(to: $0) }),
                in: state.rangeStart...max(state.rangeEnd, state.rangeStart + 1)
            )

            Text(utcFormatter.string(from: Date(timeIntervalSince1970: state.currentTime)))
                .font(.callout.monospacedDigit())
                .fixedSize()

            if !state.isLive {
                Picker("Speed", selection: $state.speed) {
                    ForEach(Self.speeds, id: \.self) { Text("\(Int($0))×").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Layout.clockHeight)
        .floatingPanel(corner: Layout.clockHeight / 2)
    }
}
