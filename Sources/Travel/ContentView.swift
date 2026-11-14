import AppKit
import SwiftUI

@main
struct TravelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Travel", id: AppDelegate.windowID) {
            ContentView(state: delegate.state)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1000, minHeight: 640)
        }
        // Files and Dock clicks go through the delegate, into the one window.
        .handlesExternalEvents(matching: [])
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Recording…") { chooseFiles(for: delegate.state) }
                    .keyboardShortcut("o")
                Divider()
                Menu("Aircraft Database") {
                    let current = delegate.state.database
                    Button((current.source == .jet1090 ? "✓ " : "") + "jet1090 Database") {
                        delegate.state.useDatabase(.jet1090)
                    }
                    if case let .file(url) = current.source {
                        Button("✓ " + url.lastPathComponent) {}
                    }
                    Button("Choose File…") { chooseDatabase(for: delegate.state) }
                    if !current.problem.isEmpty {
                        Divider()
                        Text(current.problem)
                    }
                }
            }
        }
    }
}

/// Owns the state so that it outlives the window, and handles what reaches
/// the application rather than a window: Dock clicks and files dropped on
/// the icon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let windowID = "main"
    /// Opens the main window; set by the window's content while it exists
    /// and still valid after it closes.
    static var openWindow: () -> Void = {}

    let state = AppState()

    /// Clicking the Dock icon with the window closed brings it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showWindow() }
        return false
    }

    /// Files dropped on the icon behave like files dropped on the window.
    func application(_ application: NSApplication, open urls: [URL]) {
        state.add(urls)
        showWindow()
    }


    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func showWindow() {
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            Self.openWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private func chooseFiles(for state: AppState) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.message = "Choose jet1090 or ship162 recordings (.jsonl, .jsonl.zst or .jsonl.7z)"
    if panel.runModal() == .OK { state.add(panel.urls) }
}

@MainActor
private func chooseDatabase(for state: AppState) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.message = "Choose an aircraft database: CSV (icao24, registration, typecode), .csv.gz, or BaseStation .sqb"
    if panel.runModal() == .OK, let url = panel.url { state.useDatabase(.file(url)) }
}

private let utcFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
    return formatter
}()

/// Sizes of the floating layout.
private enum Layout {
    static let margin: CGFloat = 10
    /// Height of the window header, which appears when the pointer is over it.
    static let header: CGFloat = 30
    static let panelWidth: CGFloat = 330
    /// Left edge of what floats beside the side panel.
    static let contentLeading = panelWidth + 2 * margin
    static let clockHeight: CGFloat = 44
    static let corner: CGFloat = 18
}

private extension View {
    /// The translucent rounded surface shared by everything floating on the map.
    func floatingPanel(corner: CGFloat = Layout.corner) -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(.white.opacity(0.1)))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
    }
}

/// The map fills the window; everything else floats on it.
struct ContentView: View {
    @Bindable var state: AppState
    @State private var style: GlobeStyle = .standard
    @State private var showTable = false
    /// The sources panel is shown on request only.
    @State private var showSources = false
    @State private var isDropTarget = false
    @State private var zoomRequest = 0
    @State private var headerHovered = false
    @State private var windowHeight: CGFloat = 800
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack(alignment: .topLeading) {
            MapPane(state: state, style: style, zoomRequest: zoomRequest)

            WindowHeader(title: state.dataset?.name ?? "Travel", isHovered: $headerHovered)

            // Table, controls and clock share the area beside the side panel.
            VStack(spacing: Layout.margin) {
                HStack {
                    Spacer()
                    controls
                }
                Spacer(minLength: 0)
                if showTable {
                    // A drawer above the clock: at most half the window.
                    EntityTable(state: state, maxHeight: windowHeight / 2)
                        .clipShape(RoundedRectangle(cornerRadius: Layout.corner, style: .continuous))
                        .floatingPanel()
                }
                if state.dataset != nil {
                    ClockBar(state: state)
                        .frame(maxWidth: 900)
                        // Clear of the map's compass and zoom buttons.
                        .padding(.trailing, 110)
                }
            }
            .padding(.leading, panelVisible ? Layout.contentLeading : Layout.margin)
            .padding([.trailing, .bottom], Layout.margin)
            .padding(.top, Layout.header + 4)

            if panelVisible {
                SidePanel(state: state, showSources: $showSources)
                    .frame(width: Layout.panelWidth)
                    .padding([.leading, .trailing], Layout.margin)
                    .padding(.top, Layout.header + 4)
                    // The map's logo and legal link stay visible under the panel.
                    .padding(.bottom, Layout.margin + 26)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            StatusOverlay(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.leading, panelVisible ? Layout.contentLeading : 0)
        }
        .animation(.snappy(duration: 0.25), value: panelVisible)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onChange(of: geometry.size.height, initial: true) { _, height in windowHeight = height }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            let open = openWindow
            AppDelegate.openWindow = { open(id: AppDelegate.windowID) }
        }
        .task { await applyLaunchOptions() }
        .dropDestination(for: URL.self) { urls, _ in
            state.add(urls)
            return true
        } isTargeted: {
            isDropTarget = $0
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 4)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
    }

    /// The side panel exists for a selected target, or when sources are asked for.
    private var panelVisible: Bool {
        showSources || state.selectedID != nil
    }

    private var controls: some View {
        HStack(spacing: 2) {
            Toggle(isOn: $showSources) {
                Image(systemName: "sidebar.left")
            }
            .toggleStyle(.button)
            .help("Show live sources and recordings")

            Toggle(isOn: $showTable) {
                Image(systemName: "tablecells")
            }
            .toggleStyle(.button)
            .help("Show the table of aircraft and ships")

            Button {
                showTable = false
                zoomRequest += 1
            } label: {
                Image(systemName: "scope")
            }
            .help("Frame the data on the map")
            .disabled(state.dataset?.hasPositions != true)

            Menu {
                Picker("Map style", selection: $style) {
                    ForEach(GlobeStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "map")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Map style")
        }
        .buttonStyle(.borderless)
        .font(.title3)
        .padding(.horizontal, 10)
        .frame(height: 36)
        .floatingPanel(corner: 12)
    }

    private static var launchOptionsApplied = false

    /// Files passed at launch can also arrive as open-document events, which
    /// load them again: waits until the same recording has stayed loaded for 3 s.
    private func waitForStableLoad() async {
        var stable = 0
        var last: UUID?
        while stable < 15 {
            try? await Task.sleep(for: .milliseconds(200))
            let current = state.loadProgress == nil ? state.dataset?.id : nil
            stable = current != nil && current == last ? stable + 1 : 0
            last = current
        }
    }

    /// Command-line options, mostly for testing:
    /// recordings, --live, --source redis://host:6379/a,b, --table,
    /// --zoom, --select <icao24 or mmsi>, --speed <factor>.
    private func applyLaunchOptions() async {
        let options = CommandLine.arguments
        let urls = options.dropFirst()
            .map { URL(fileURLWithPath: $0) }
            .filter(RecordingLoader.isSupported)
        if !urls.isEmpty, !Self.launchOptionsApplied { state.add(urls) }
        // A reopened window must not replay the launch options.
        guard !Self.launchOptionsApplied else { return }
        Self.launchOptionsApplied = true
        if options.contains("--live"), let first = state.liveSources.first { state.start(first) }
        for (i, option) in options.enumerated() where option == "--source" && i + 1 < options.count {
            if let source = LiveSource(url: options[i + 1]) {
                // Not remembered across launches.
                state.save(source, persist: false)
                state.start(source)
            }
        }
        if options.contains("--table") { showTable = true }
        if options.contains("--zoom") {
            while state.dataset == nil { try? await Task.sleep(for: .milliseconds(200)) }
            zoomRequest += 1
        }
        if let i = options.firstIndex(of: "--speed"), i + 1 < options.count, let speed = Double(options[i + 1]) {
            state.speed = speed
        }
        if let i = options.firstIndex(of: "--select"), i + 1 < options.count {
            while state.dataset == nil { try? await Task.sleep(for: .milliseconds(200)) }
            state.selectedID = options[i + 1]
        }
        // --interrogators: print how each interrogator code fits the catalogue.
        if options.contains("--interrogators") {
            await waitForStableLoad()
            if let dataset = state.dataset {
                var lines: [String] = []
                for (code, interrogator) in dataset.interrogators.sorted(by: { $0.key < $1.key }) {
                    let period = interrogator.period.map { String(format: "%.3f s", $0) } ?? "-"
                    var line = "\(code)\tperiod \(period)\tlocated \(interrogator.located)\tunexplained \(interrogator.unexplained)"
                    if interrogator.isShared { line += "\tshared code" }
                    for fit in interrogator.fits {
                        line += String(format: "\n\t%@ (%@): %d aircraft, median %.0f km, 90%% %.0f km, period %@, %@",
                                       fit.site.name, fit.site.basis, fit.aircraft, fit.medianDistance / 1000, fit.farDistance / 1000,
                                       fit.period.map { String(format: "%.3f s", $0) } ?? "-", fit.consistent ? "consistent" : "weak")
                    }
                    lines.append(line)
                }
                print(lines.joined(separator: "\n"))
                fflush(stdout)
            }
        }
        // --time HH:MM[:SS]: pause at that UTC time on the recording's first day.
        if let i = options.firstIndex(of: "--time"), i + 1 < options.count {
            let parts = options[i + 1].split(separator: ":").compactMap { Double($0) }
            if parts.count >= 2 {
                await waitForStableLoad()
                let day = (state.rangeStart / 86400).rounded(.down) * 86400
                state.isPlaying = false
                state.seek(to: day + parts[0] * 3600 + parts[1] * 60 + (parts.count > 2 ? parts[2] : 0))
            }
        }
    }
}

// MARK: Window header

/// A strip protecting the top of the window: when the pointer is over it, a
/// translucent bar fades in together with the close, minimise and zoom buttons.
private struct WindowHeader: View {
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
private struct HeaderTracker: NSViewRepresentable {
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

// MARK: Map

private struct MapPane: View {
    @Bindable var state: AppState
    let style: GlobeStyle
    let zoomRequest: Int

    var body: some View {
        GlobeView(
            entities: state.entities,
            selectedID: state.selectedID,
            track: state.selectedTrack,
            marks: state.stationMarks + state.selectedMarks,
            radars: state.radarMarks,
            highlighted: state.highlighted,
            style: style,
            focus: focus,
            zoomRequest: zoomRequest,
            onSelect: { state.selectedID = $0 },
            onHoverRadar: { state.hoveredInterrogators = $0 }
        )
    }

    private var focus: MapFocus? {
        guard let dataset = state.dataset, dataset.hasPositions else { return nil }
        return MapFocus(id: dataset.id, center: dataset.center, extent: dataset.extent)
    }
}

private struct StatusOverlay: View {
    @Bindable var state: AppState

    var body: some View {
        if let progress = state.loadProgress {
            panel {
                Text("Loading recording…").font(.headline)
                ProgressView(value: progress).frame(width: 240)
            }
        } else if let error = state.loadError {
            panel {
                Text(error).font(.headline)
                Button("Dismiss") { state.loadError = nil }
            }
        } else if state.dataset == nil {
            panel {
                Image(systemName: "square.and.arrow.down").font(.largeTitle)
                Text("Drop a recording here").font(.title2.weight(.semibold))
                Label("Live sources and recordings are in the sources panel", systemImage: "sidebar.left")
                    .foregroundStyle(.secondary)
                Text("jet1090 and ship162 · .jsonl, .jsonl.zst or .jsonl.7z").foregroundStyle(.secondary)
                Button("Open…") { chooseFiles(for: state) }
            }
        }
    }

    private func panel(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 10, content: content)
            .padding(26)
            .floatingPanel()
    }
}

// MARK: Side panel

/// The floating panel: sources, or the selected target with its plots.
private struct SidePanel: View {
    @Bindable var state: AppState
    @Binding var showSources: Bool

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 10)
            if let id = state.selectedID {
                TargetDetail(state: state, id: id)
            } else {
                HStack {
                    Text("Sources")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    CloseButton { showSources = false }
                }
                .padding(.horizontal, 16)
                SourceList(state: state)
            }
        }
        .floatingPanel()
    }
}

private struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("Close")
    }
}

/// Where data comes from: live sources and recordings.
/// Selecting several recordings shows them together.
private struct SourceList: View {
    @Bindable var state: AppState
    @State private var draft: LiveSource?

    var body: some View {
        List(selection: $state.selection) {
            Section {
                ForEach(state.liveSources) { source in
                    LiveRow(state: state, source: source) { draft = source }
                        .tag(AppState.tag(source))
                }
                if state.liveSources.isEmpty {
                    Text("No live source")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Live")
                    Spacer()
                    Button {
                        draft = LiveSource.template
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Add a live source")
                }
            }

            Section("Recordings") {
                ForEach(state.sources) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !item.subtitle.isEmpty {
                            Text(item.subtitle)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .help(item.url.path)
                    .tag(item.id)
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        Button("Remove") { state.remove(item) }
                    }
                }
                if state.sources.isEmpty {
                    Text("Drop recordings here")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .sheet(item: $draft) { source in
            LiveSourceEditor(
                state: state,
                source: source,
                isNew: !state.liveSources.contains { $0.id == source.id },
                onSave: { state.save($0) }
            )
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                if state.dataset != nil {
                    Text(summary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button("Open Recording…") { chooseFiles(for: state) }
                    .controlSize(.small)
            }
            .padding(12)
        }
    }

    private var summary: String {
        let aircraft = state.entities.reduce(0) { $0 + ($1.kind == .aircraft ? 1 : 0) }
        let ships = state.entities.count - aircraft
        return "\(aircraft) aircraft · \(ships) ships"
    }
}

/// One live source: status, and a button to start or stop it.
private struct LiveRow: View {
    @Bindable var state: AppState
    let source: LiveSource
    let onEdit: () -> Void

    var body: some View {
        let running = state.isRunning(source)
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if source.isDevice {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(source.name)
                        .lineLimit(1)
                }
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if !source.isDevice {
                Button {
                    state.toggle(source)
                } label: {
                    Image(systemName: running ? "stop.fill" : "play.fill")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .help(running ? "Stop" : "Start")
            }
        }
        .help(help)
        .contextMenu {
            if !source.isDevice {
                Button(running ? "Stop" : "Start") { state.toggle(source) }
            }
            Button("Edit…", action: onEdit)
            Button("Remove") { state.remove(source) }
            Divider()
            Button("Clear Live Data") { state.clearLive() }
        }
    }

    private var help: String {
        guard let device = source.device else { return "Redis \(source.address) · \(source.channels)" }
        return [device.model, device.serial.map { "serial \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    private var color: Color {
        if source.isDevice {
            guard let receiver = state.receiver(for: source) else { return .gray }
            return receiver.owner == nil ? .blue : .orange
        }
        switch state.status(of: source) {
        case .off: return .gray
        case .connecting: return .yellow
        case .connected: return .green
        case .failed: return .red
        }
    }

    private var caption: String {
        if source.isDevice {
            guard let receiver = state.receiver(for: source) else { return "Unplugged" }
            if let owner = receiver.owner { return "In use by \(owner)" }
            return "Port \(receiver.portPath) · no decoder yet"
        }
        switch state.status(of: source) {
        case .off: return source.address
        case .connecting: return "Connecting…"
        case .connected: return "Connected · \(source.address)"
        case let .failed(message): return "\(message) · retrying"
        }
    }
}

private struct LiveSourceEditor: View {
    enum Mode: String, CaseIterable, Identifiable {
        case receiver = "Receiver"
        case redis = "Redis"

        var id: String { rawValue }
    }

    @Bindable var state: AppState
    @State var source: LiveSource
    let isNew: Bool
    let onSave: (LiveSource) -> Void
    @State private var mode: Mode
    @State private var picked: Int?
    @Environment(\.dismiss) private var dismiss

    init(state: AppState, source: LiveSource, isNew: Bool, onSave: @escaping (LiveSource) -> Void) {
        self.state = state
        var source = source
        // A new source is named after what is picked, unless given a name.
        if isNew { source.name = "" }
        _source = State(initialValue: source)
        self.isNew = isNew
        self.onSave = onSave
        _mode = State(initialValue: source.isDevice || isNew ? .receiver : .redis)
        _picked = State(initialValue: source.device?.match(in: state.usb.receivers)?.locationID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Live Source" : "Edit Live Source")
                .font(.headline)
            if isNew {
                Picker("Kind", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            switch mode {
            case .receiver:
                DeviceTree(state: state, editing: source.id, picked: $picked)
                Form {
                    TextField("Name", text: $source.name, prompt: Text(pickedDevice?.sdr?.name ?? "Receiver"))
                }
                Text("Receivers are listed as they are plugged in. Connecting one to a decoder (jet1090, ship162) comes next.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .redis:
                Form {
                    TextField("Name", text: $source.name, prompt: Text("Redis"))
                    TextField("Address", text: $source.address, prompt: Text("127.0.0.1:6379"))
                    TextField("Channels", text: $source.channels, prompt: Text("jet1090 ship162"))
                }
                Text("Redis pub/sub channels carrying jet1090 or ship162 decoded JSON.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: mode == .receiver ? 560 : 400)
    }

    private var pickedDevice: UsbDevice? {
        state.usb.receivers.first { $0.locationID == picked }
    }

    private var canSave: Bool {
        switch mode {
        case .receiver: pickedDevice != nil
        case .redis: !source.address.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func save() {
        var saved = source
        saved.name = saved.name.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .receiver:
            guard let device = pickedDevice else { return }
            saved.device = LiveSource.Device(device)
            if saved.name.isEmpty {
                saved.name = device.sdr?.name ?? device.product
            }
        case .redis:
            saved.device = nil
            saved.address = saved.address.trimmingCharacters(in: .whitespaces)
            if saved.name.isEmpty { saved.name = "Redis" }
        }
        onSave(saved)
        dismiss()
    }
}

/// The USB devices as a tree, the way `cyme --tree` draws it. Receivers can
/// be picked; hubs and other devices are shown to explain the wiring.
private struct DeviceTree: View {
    private struct Row: Identifiable {
        let id: String
        /// Tree guides drawn before the device.
        let guides: String
        let device: UsbDevice?
        let bus: UsbBus?
    }

    @Bindable var state: AppState
    /// The source being edited, which may keep its own receiver.
    let editing: UUID
    @Binding var picked: Int?

    var body: some View {
        let rows = flatten()
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("USB DEVICES")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    state.usb.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Read the USB devices again")
            }
            .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        if let bus = row.bus {
                            busRow(bus)
                        } else if let device = row.device {
                            deviceRow(device, guides: row.guides)
                        }
                    }
                    if state.usb.receivers.isEmpty {
                        Text("No receiver plugged in")
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 220)
            .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func busRow(_ bus: UsbBus) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu")
                .foregroundStyle(.secondary)
            Text("Bus \(bus.number)")
                .fontWeight(.semibold)
            Text(bus.controller)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.top, 4)
        .frame(height: 24)
    }

    private func deviceRow(_ device: UsbDevice, guides: String) -> some View {
        let taken = takenBy(device)
        let selectable = device.sdr != nil && taken == nil
        let selected = selectable && picked == device.locationID
        return HStack(spacing: 6) {
            Text(guides)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.tertiary)
            Image(systemName: device.sdr != nil ? "antenna.radiowaves.left.and.right" : (device.isHub ? "point.3.connected.trianglepath.dotted" : "cable.connector"))
                .foregroundStyle(device.sdr != nil ? Color.accentColor : .secondary)
                .frame(width: 16)
            Text(device.sdr?.name ?? device.product)
                .fontWeight(device.sdr != nil ? .semibold : .regular)
                .foregroundStyle(device.sdr != nil ? .primary : .secondary)
            if let serial = device.serial, device.sdr != nil {
                Text(serial)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let taken {
                Text("Added as \(taken)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if device.sdr != nil, let owner = device.owner {
                Text("In use by \(owner)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(device.portPath)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(device.identifiers)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .padding(.horizontal, 4)
        .frame(height: 24)
        .background(selected ? Color.accentColor.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { if selectable { picked = device.locationID } }
        .help(device.sdr.map { "\($0.name) · desperado driver: \($0.driver)" } ?? device.product)
    }

    /// Name of another source already using this receiver.
    private func takenBy(_ device: UsbDevice) -> String? {
        state.liveSources.first { $0.id != editing && $0.device?.match(in: state.usb.receivers) == device }?.name
    }

    private func flatten() -> [Row] {
        var rows: [Row] = []
        func walk(_ devices: [UsbDevice], prefix: String) {
            for (i, device) in devices.enumerated() {
                let last = i == devices.count - 1
                rows.append(Row(id: "d\(device.locationID)", guides: prefix + (last ? "└─" : "├─"), device: device, bus: nil))
                walk(device.children, prefix: prefix + (last ? "   " : "│  "))
            }
        }
        for bus in state.usb.buses {
            rows.append(Row(id: "b\(bus.number)", guides: "", device: nil, bus: bus))
            walk(bus.devices, prefix: "")
        }
        return rows
    }
}

// MARK: Target detail

/// The selected aircraft or ship: current state and plots over time.
private struct TargetDetail: View {
    @Bindable var state: AppState
    let id: String

    var body: some View {
        let entity = state.selected
        let kind = entity?.kind ?? state.dataset?.kind(of: id) ?? .aircraft
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                // The only way to deselect: clicking the map does not.
                CloseButton { state.selectedID = nil }
            }
            .padding(.horizontal, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entity?.label ?? state.dataset?.name(of: id) ?? id.uppercased())
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(subtitle(entity))
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let entity {
                        fields(entity)
                    } else {
                        Text("Not received at this time")
                            .foregroundStyle(.secondary)
                    }

                    Divider()
                    PlotStack(state: state, id: id, kind: kind)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }

    private func subtitle(_ entity: Entity?) -> String {
        var parts = [id.uppercased()]
        if let entity, entity.kind == .aircraft {
            parts.append(contentsOf: [entity.info.registration, entity.info.typecode].compactMap { $0 })
        }
        if let entity, entity.kind == .ship, let country = entity.info.country {
            parts.append(country)
        }
        let text = parts.joined(separator: " · ")
        return entity?.info.flag.map { "\($0) \(text)" } ?? text
    }

    @ViewBuilder
    private func fields(_ entity: Entity) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 10) {
            if entity.kind == .aircraft {
                GridRow {
                    field("Altitude", entity[.altitude].map { "\(Int($0).formatted()) ft" })
                    field("Ground speed", entity[.groundspeed].map { "\(Int($0)) kt" })
                }
                GridRow {
                    field("Vertical rate", entity[.verticalRate].map { "\(Int($0).formatted()) ft/min" })
                    field("Track", entity[.track].map(degrees))
                }
                GridRow {
                    field("Squawk", entity.info.squawk)
                    field("Mach", entity[.mach].map { String(format: "%.2f", $0) })
                }
            } else {
                GridRow {
                    field("Speed", entity[.groundspeed].map { String(format: "%.1f kn", $0) })
                    field("Course", entity[.track].map(degrees))
                }
                GridRow {
                    field("Type", entity.info.shipType)
                    field("Destination", entity.info.destination)
                }
                GridRow {
                    field("Status", entity.info.status)
                        .gridCellColumns(2)
                }
            }
        }
    }

    private func degrees(_ value: Double) -> String {
        String(format: "%03d°", Int(value.rounded()) % 360)
    }

    private func field(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value ?? "—")
                .font(.title3.monospacedDigit().weight(.medium))
                .lineLimit(1)
        }
    }
}

// MARK: Clock

/// Replay controls, or the live indicator with a way back in time.
private struct ClockBar: View {
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
