import Foundation
import SwiftUI

extension ContentView {
    @MainActor private static var launchOptionsApplied = false

    /// Files passed at launch can also arrive as open-document events, which
    /// load them again: waits until the same recording has stayed loaded for 3 s.
    func waitForStableLoad() async {
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
    /// --zoom, --select <icao24 or mmsi>, --speed <factor>,
    /// --backfill <recording> (repeatable: read into the live view, so that it
    /// starts with the history recorded so far).
    func applyLaunchOptions() async {
        let options = CommandLine.arguments
        let backfill = options.indices.dropLast()
            .filter { options[$0] == "--backfill" }
            .map { URL(fileURLWithPath: (options[$0 + 1] as NSString).expandingTildeInPath) }
        let urls = options.dropFirst()
            .map { URL(fileURLWithPath: $0) }
            .filter { RecordingLoader.isSupported($0) || FlightPlan.isPlan($0) }
            .filter { url in !backfill.contains { $0.path == url.path } }
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
        if !backfill.isEmpty { state.backfill(backfill) }
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
        // --plan FILE: print the route of a flight plan, resolved against the AIRAC data.
        if let i = options.firstIndex(of: "--plan"), i + 1 < options.count {
            let url = URL(fileURLWithPath: (options[i + 1] as NSString).expandingTildeInPath)
            if let plan = FlightPlan.load(url) {
                let started = Date()
                let points = await Task.detached { plan.waypoints() }.value
                print("\(plan.callsign) \(plan.departure)-\(plan.destination): \(points.count) points in \(Int(Date().timeIntervalSince(started))) s")
                for point in points {
                    print(String(format: "%@\t%.5f\t%.5f%@", point.name, point.position.latitude, point.position.longitude, point.source == .airac ? "" : "\t\(point.source.rawValue)"))
                }
            } else {
                print("no flight plan in \(url.path)")
            }
            fflush(stdout)
        }
        // --flights: print the user's flights read from Flighty, and the match now.
        if options.contains("--flights") {
            let flights = await Task.detached { Flighty.ownFlights() }.value
            print("\(flights.count) own flights read from Flighty")
            if !options.contains("--time") {
                for flight in flights.suffix(3) {
                    print(flight.number, flight.origin, flight.destination, flight.tail ?? "-",
                          flight.tail.flatMap { state.database.address(ofRegistration: $0) } ?? "-")
                }
            }
            fflush(stdout)
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
        // --radar NAME: open the card of the first radar whose site name contains NAME.
        if let i = options.firstIndex(of: "--radar"), i + 1 < options.count {
            await waitForStableLoad()
            try? await Task.sleep(for: .seconds(1))
            let name = options[i + 1].lowercased()
            state.selectedRadar = state.radarMarks.first { $0.name.lowercased().contains(name) }?.id
        }
    }
}
