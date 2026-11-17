import SwiftUI

/// Sizes of the floating layout.
enum Layout {
    static let margin: CGFloat = 10
    /// Height of the window header, which appears when the pointer is over it.
    static let header: CGFloat = 30
    static let panelWidth: CGFloat = 330
    /// Left edge of what floats beside the side panel.
    static let contentLeading = panelWidth + 2 * margin
    static let clockHeight: CGFloat = 44
    static let corner: CGFloat = 18
}

extension View {
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
    @State var showTable = false
    /// The sources panel is shown on request only.
    @State private var showSources = false
    @State private var isDropTarget = false
    @State var zoomRequest = 0
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
                if let radar = state.selectedRadarMark {
                    HStack {
                        Spacer()
                        RadarCard(radar: radar, aircraft: state.selectedRadarCount) { state.selectedRadar = nil }
                            .frame(width: 300)
                            .floatingPanel(corner: 14)
                    }
                    .transition(.opacity)
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
}
