import AppKit
import SwiftUI

@main
struct TravelApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("Travel") {
            ContentView(state: state)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Recording…") { chooseFiles(for: state) }
                    .keyboardShortcut("o")
            }
        }
    }
}

@MainActor
private func chooseFiles(for state: AppState) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.message = "Choose jet1090 or ship162 recordings (.jsonl or .jsonl.zst)"
    if panel.runModal() == .OK { state.add(panel.urls) }
}

private let utcFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
    return formatter
}()

enum MainTab: String, CaseIterable, Identifiable {
    case map = "Map"
    case table = "Table"

    var id: String { rawValue }
}

struct ContentView: View {
    @Bindable var state: AppState
    @State private var tab: MainTab = .map
    @State private var style: GlobeStyle = .satellite
    @State private var showPlots = true
    @State private var isDropTarget = false
    @State private var zoomRequest = 0

    var body: some View {
        NavigationSplitView {
            SourceList(state: state)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 340)
        } detail: {
            VStack(spacing: 0) {
                VSplitView {
                    ZStack {
                        // The map stays alive under the table to keep its camera.
                        MapPane(state: state, style: style, zoomRequest: zoomRequest)
                            .opacity(tab == .map ? 1 : 0)
                            .allowsHitTesting(tab == .map)
                        if tab == .table {
                            EntityTable(state: state)
                                .background(.background)
                        }
                    }
                    .frame(minHeight: 260)
                    .layoutPriority(1)

                    if showPlots, state.selectedID != nil {
                        PlotPanel(state: state)
                    }
                }
                if state.dataset != nil {
                    Divider()
                    ClockBar(state: state)
                }
            }
            .overlay { StatusOverlay(state: state) }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $tab) {
                        ForEach(MainTab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                ToolbarItemGroup {
                    Toggle(isOn: $showPlots) {
                        Label("Plots", systemImage: "chart.xyaxis.line")
                    }
                    .help("Show plots for the selected target")
                    Button {
                        tab = .map
                        zoomRequest += 1
                    } label: {
                        Label("Zoom to Data", systemImage: "scope")
                    }
                    .help("Frame the recording on the map")
                    .disabled(state.dataset?.hasPositions != true)
                    Picker("Map style", selection: $style) {
                        ForEach(GlobeStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .help("Map style")
                }
            }
        }
        .task {
            // Recordings passed on the command line: ./scripts/run.sh file.jsonl.zst
            let urls = CommandLine.arguments.dropFirst()
                .map { URL(fileURLWithPath: $0) }
                .filter(RecordingLoader.isSupported)
            if !urls.isEmpty, state.sources.isEmpty { state.add(urls) }
            // ./scripts/run.sh --live starts the first live source.
            if CommandLine.arguments.contains("--live"), let first = state.liveSources.first { state.start(first) }
            // --source redis://host:6379/jet1090,ship162
            let arguments = CommandLine.arguments
            for (i, argument) in arguments.enumerated() where argument == "--source" && i + 1 < arguments.count {
                if let source = LiveSource(url: arguments[i + 1]) {
                    // Not remembered across launches.
                    state.save(source, persist: false)
                    state.start(source)
                }
            }
            if CommandLine.arguments.contains("--table") { tab = .table }
            // --select <icao24 or mmsi> and --speed <factor> apply to the first source shown.
            let options = CommandLine.arguments
            if let i = options.firstIndex(of: "--speed"), i + 1 < options.count, let speed = Double(options[i + 1]) {
                state.speed = speed
            }
            if let i = options.firstIndex(of: "--select"), i + 1 < options.count {
                while state.dataset == nil { try? await Task.sleep(for: .milliseconds(200)) }
                state.selectedID = options[i + 1]
            }
        }
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
}

// MARK: Sidebar

/// The sidebar lists where data comes from: live sources and recordings.
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
                    Text("Drop .jsonl or .jsonl.zst files here")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .sheet(item: $draft) { source in
            LiveSourceEditor(
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
            .padding(10)
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
                Text(source.name)
                    .lineLimit(1)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button {
                state.toggle(source)
            } label: {
                Image(systemName: running ? "stop.fill" : "play.fill")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help(running ? "Stop" : "Start")
        }
        .help("Redis \(source.address) · \(source.channels)")
        .contextMenu {
            Button(running ? "Stop" : "Start") { state.toggle(source) }
            Button("Edit…", action: onEdit)
            Button("Remove") { state.remove(source) }
            Divider()
            Button("Clear Live Data") { state.clearLive() }
        }
    }

    private var color: Color {
        switch state.status(of: source) {
        case .off: .gray
        case .connecting: .yellow
        case .connected: .green
        case .failed: .red
        }
    }

    private var caption: String {
        switch state.status(of: source) {
        case .off: source.address
        case .connecting: "Connecting…"
        case .connected: "Connected · \(source.address)"
        case let .failed(message): "\(message) · retrying"
        }
    }
}

private struct LiveSourceEditor: View {
    @State var source: LiveSource
    let isNew: Bool
    let onSave: (LiveSource) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Redis Source" : "Edit Redis Source")
                .font(.headline)
            Form {
                TextField("Name", text: $source.name, prompt: Text("Redis"))
                TextField("Address", text: $source.address, prompt: Text("127.0.0.1:6379"))
                TextField("Channels", text: $source.channels, prompt: Text("jet1090 ship162"))
            }
            Text("Redis pub/sub channels carrying jet1090 or ship162 decoded JSON.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    var saved = source
                    saved.address = saved.address.trimmingCharacters(in: .whitespaces)
                    saved.name = saved.name.trimmingCharacters(in: .whitespaces)
                    if saved.name.isEmpty { saved.name = "Redis" }
                    onSave(saved)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(source.address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
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
            style: style,
            focus: focus,
            zoomRequest: zoomRequest,
            onSelect: { state.selectedID = $0 }
        )
        .overlay(alignment: .topLeading) {
            if let entity = state.selected {
                EntityCard(entity: entity) { state.selectedID = nil }
                    .padding(14)
                    .transition(.opacity)
            }
        }
        .animation(.snappy, value: state.selectedID)
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
                Text("Drop a recording, or pick Live").font(.title2.weight(.semibold))
                Text("jet1090 and ship162 · .jsonl or .jsonl.zst").foregroundStyle(.secondary)
                Button("Open…") { chooseFiles(for: state) }
            }
        }
    }

    private func panel(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 10, content: content)
            .padding(26)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: Card

private struct EntityCard: View {
    let entity: Entity
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entity.label)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

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
        .padding(16)
        .frame(width: 330)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(radius: 12)
    }

    private var subtitle: String {
        var parts = [entity.id.uppercased()]
        if entity.kind == .ship {
            parts.append(contentsOf: [entity.info.flag, entity.info.country].compactMap { $0 })
        }
        return parts.joined(separator: " ")
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
