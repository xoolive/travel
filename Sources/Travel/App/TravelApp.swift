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
func chooseFiles(for state: AppState) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.message = "Choose jet1090 or ship162 recordings (.jsonl, .jsonl.zst or .jsonl.7z), or flight plans (.flight.json)"
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
