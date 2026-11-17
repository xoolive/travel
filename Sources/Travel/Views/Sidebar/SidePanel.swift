import SwiftUI

/// The floating panel: sources, or the selected target with its plots.
struct SidePanel: View {
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

struct CloseButton: View {
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
struct SourceList: View {
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
