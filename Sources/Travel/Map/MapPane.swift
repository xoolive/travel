import SwiftUI

struct MapPane: View {
    @Bindable var state: AppState
    let style: GlobeStyle
    let zoomRequest: Int

    var body: some View {
        GlobeView(
            entities: state.entities,
            selectedID: state.selectedID,
            track: state.selectedTrack,
            marks: state.stationMarks + state.selectedMarks + planMarks,
            radars: state.radarMarks,
            highlighted: state.highlighted,
            mineID: state.mineID,
            route: state.mineRoute,
            plans: Array(state.planRoutes.values).map { $0.map(\.position) },
            mineNote: state.mineNote,
            centerline: state.mineAlignment?.ongoing == true ? state.mineCenterline : [],
            style: style,
            focus: focus,
            zoomRequest: zoomRequest,
            onSelect: { state.selectedID = $0 },
            onHoverRadar: { state.hoveredInterrogators = $0 },
            onSelectRadar: { state.selectedRadar = state.selectedRadar == $0 ? nil : $0 }
        )
    }

    /// Waypoint names of the dropped flight plans (airports aside).
    private var planMarks: [TrackMark] {
        state.planRoutes.flatMap { id, points in
            points.dropFirst().dropLast().enumerated().map { n, point in
                TrackMark(id: "p\(id)\(n)", kind: .waypoint, position: point.position, label: point.name)
            }
        }
    }

    private var focus: MapFocus? {
        guard let dataset = state.dataset, dataset.hasPositions else { return nil }
        return MapFocus(id: dataset.id, center: dataset.center, extent: dataset.extent)
    }
}

struct StatusOverlay: View {
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
