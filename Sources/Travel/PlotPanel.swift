import Charts
import SwiftUI

/// The plot groups of the tangram aircraft widget.
enum PlotGroup: String, CaseIterable, Identifiable {
    case altitude = "Altitude (ft)"
    case speed = "Speed (kt)"
    case verticalRate = "Vertical rate (ft/min)"
    case directions = "Directions"

    var id: String { rawValue }

    static func available(for kind: Kind) -> [PlotGroup] {
        kind == .ship ? [.speed, .directions] : allCases
    }
}

private struct PlotLine: Identifiable {
    let id: String
    let color: Color
    let points: [Sample]
    var asPoints = false
    /// Index of the unbroken run each point belongs to; a line is not drawn
    /// across reception gaps.
    var runs: [Int] = []
}

/// A second scale drawn on the trailing axis; its series are mapped
/// linearly onto the leading axis.
private struct SecondaryAxis {
    let ticks: [Double]
    let label: (Double) -> String
}

private struct PlotContent {
    var lines: [PlotLine] = []
    var domain: ClosedRange<Double> = 0...1
    var secondary: SecondaryAxis?
}

private let axisTime = Date.FormatStyle(timeZone: .gmt).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)

/// All plots of one target, stacked. Click or drag in a plot to move the clock.
struct PlotStack: View {
    @Bindable var state: AppState
    let id: String
    let kind: Kind

    var body: some View {
        // Reading `revision` redraws the plots when live data arrives.
        let _ = state.revision
        VStack(alignment: .leading, spacing: 18) {
            if kind == .aircraft, let dataset = state.dataset {
                let minutes = dataset.turbulence(for: id)
                if !minutes.isEmpty {
                    TurbulenceChart(state: state, minutes: minutes)
                }
            }
            if kind == .aircraft, let dataset = state.dataset {
                let uplinks = dataset.uplinks(of: id)
                if !uplinks.isEmpty {
                    InterrogationChart(state: state, uplinks: uplinks)
                }
                let messages = dataset.datalink(of: id)
                if !messages.isEmpty {
                    DatalinkList(state: state, messages: messages)
                }
            }
            ForEach(PlotGroup.available(for: kind)) { group in
                let content = build(group)
                if !content.lines.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.rawValue.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        chart(content)
                            .frame(height: 130)
                    }
                }
            }
        }
    }

    private func chart(_ content: PlotContent) -> some View {
        Chart {
            ForEach(content.lines) { line in
                ForEach(line.points.indices, id: \.self) { i in
                    let x = Date(timeIntervalSince1970: line.points[i].t)
                    if line.asPoints {
                        PointMark(x: .value("Time", x), y: .value("Value", line.points[i].v))
                            .symbolSize(8)
                            .foregroundStyle(by: .value("Series", line.id))
                    } else {
                        LineMark(x: .value("Time", x), y: .value("Value", line.points[i].v), series: .value("Run", "\(line.id) \(line.runs[i])"))
                            .foregroundStyle(by: .value("Series", line.id))
                    }
                }
            }
        }
        .chartForegroundStyleScale(domain: content.lines.map(\.id), range: content.lines.map(\.color))
        .chartYScale(domain: content.domain)
        .chartXScale(domain: Date(timeIntervalSince1970: state.rangeStart)...Date(timeIntervalSince1970: max(state.rangeEnd, state.rangeStart + 1)))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: state.rangeEnd - state.rangeStart < 900 ? axisTime.second(.twoDigits) : axisTime)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4))
            AxisMarks(position: .trailing, values: content.secondary?.ticks ?? []) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self), let secondary = content.secondary {
                        Text(secondary.label(v))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            Playhead(state: state, proxy: proxy)
        }
    }

    private func build(_ group: PlotGroup) -> PlotContent {
        guard let dataset = state.dataset else { return PlotContent() }
        func line(_ label: String, _ channel: Channel, _ color: Color, points: Bool = false, map: ((Double) -> Double)? = nil) -> PlotLine? {
            let thinned = dataset.samples(for: id, channel, gap: kind.timeout)
            guard !thinned.isEmpty else { return nil }
            let samples = thinned.map { item in
                map.map { Sample(t: item.sample.t, v: $0(item.sample.v)) } ?? item.sample
            }
            let runs = thinned.map(\.run)
            return PlotLine(id: label, color: color, points: samples, asPoints: points, runs: runs)
        }

        var content = PlotContent()
        switch group {
        case .altitude:
            content.lines = [
                line("Barometric", .altitude, .blue),
                line("Selected", .selectedAltitude, .orange),
            ].compactMap { $0 }
        case .speed:
            if kind == .ship {
                content.lines = [line("Speed over ground", .groundspeed, .blue)].compactMap { $0 }
            } else {
                content.lines = [
                    line("Ground speed", .groundspeed, .blue),
                    line("IAS", .ias, .orange),
                    line("TAS", .tas, .green),
                    line("Mach", .mach, .yellow) { $0 * 600 },
                ].compactMap { $0 }
                if content.lines.contains(where: { $0.id == "Mach" }) {
                    content.secondary = SecondaryAxis(ticks: [0, 300, 600]) { String(format: "M%.1f", $0 / 600) }
                }
            }
        case .verticalRate:
            content.lines = [
                line("Vertical rate", .verticalRate, .blue),
                line("Barometric", .vrateBarometric, .orange),
                line("Inertial", .vrateInertial, .green),
            ].compactMap { $0 }
        case .directions:
            content.lines = [
                line(kind == .ship ? "Course" : "Track", .track, .blue, points: true),
                line("Heading", .heading, .orange, points: true),
                // Roll -45...45 degrees drawn on the 0...360 scale.
                line("Roll", .roll, .green) { ($0 + 45) * 4 },
            ].compactMap { $0 }
            if content.lines.contains(where: { $0.id == "Roll" }) {
                content.secondary = SecondaryAxis(ticks: [0, 180, 360]) { String(format: "%.0f°", $0 / 4 - 45) }
            }
        }

        let values = content.lines.flatMap { $0.points.map(\.v) }
        if group == .directions {
            content.domain = 0...360
        } else if let low = values.min(), let high = values.max() {
            let top = content.secondary == nil ? high : max(high, 600)
            let bottom = group == .verticalRate ? low : min(0, low)
            let margin = max(1, (top - bottom) * 0.05)
            content.domain = (bottom - (bottom < 0 ? margin : 0))...(top + margin)
        }
        return content
    }
}

/// Spread of the vertical-rate fluctuations per minute, against the
/// turbulence threshold.
private struct TurbulenceChart: View {
    let state: AppState
    let minutes: [TurbulenceMinute]

    private enum Level: String, CaseIterable {
        case turbulent = "Turbulent (2 min or more)"
        case above = "Above threshold"
        /// Above the threshold, but climbing, descending or turning: the
        /// method does not count these minutes.
        case aboveExcluded = "Above, not level cruise"
        case below = "Below"
        case excluded = "Not level cruise"

        var color: Color {
            switch self {
            case .turbulent: .red
            case .above: .orange
            case .aboveExcluded: .orange.opacity(0.45)
            case .below: .blue
            case .excluded: .gray.opacity(0.7)
            }
        }
    }

    private func level(_ minute: TurbulenceMinute) -> Level {
        if minute.isTurbulent { return .turbulent }
        if minute.qualifies { return .above }
        if !minute.passesChecks { return minute.spread >= Turbulence.threshold ? .aboveExcluded : .excluded }
        return .below
    }

    var body: some View {
        let levels = Level.allCases.filter { candidate in minutes.contains { level($0) == candidate } }
        VStack(alignment: .leading, spacing: 6) {
            Text("TURBULENCE · VERTICAL RATE SPREAD (FT/MIN)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Chart {
                ForEach(minutes.indices, id: \.self) { i in
                    RectangleMark(
                        xStart: .value("Start", Date(timeIntervalSince1970: minutes[i].start + 3)),
                        xEnd: .value("End", Date(timeIntervalSince1970: minutes[i].start + 57)),
                        yStart: .value("Zero", 0),
                        yEnd: .value("Spread", minutes[i].spread)
                    )
                    .foregroundStyle(by: .value("Level", level(minutes[i]).rawValue))
                }
                RuleMark(y: .value("Threshold", Turbulence.threshold))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .chartForegroundStyleScale(domain: levels.map(\.rawValue), range: levels.map(\.color))
            .chartYScale(domain: 0...max(Turbulence.threshold * 1.25, (minutes.map(\.spread).max() ?? 0) * 1.1))
            .chartXScale(domain: Date(timeIntervalSince1970: state.rangeStart)...Date(timeIntervalSince1970: max(state.rangeEnd, state.rangeStart + 1)))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: state.rangeEnd - state.rangeStart < 900 ? axisTime.second(.twoDigits) : axisTime)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4))
            }
            .chartOverlay { proxy in
                Playhead(state: state, proxy: proxy)
            }
            .frame(height: 130)
        }
    }
}

/// Who interrogated the aircraft, and for what: one row per interrogator
/// (radars by their II or SI code, other aircraft's TCAS), one tick per
/// interrogation, coloured by what it asked for.
private struct InterrogationChart: View {
    let state: AppState
    let uplinks: [Uplink]

    /// Rows beyond this are grouped.
    private static let maxRows = 8
    private static let palette: [Color] = [.blue, .orange, .green, .pink, .purple, .yellow, .cyan, .brown, .gray]

    var body: some View {
        let (rows, requests) = categories()
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("INTERROGATIONS (1030 MHZ) · " + span.lowerBound.formatted(axisTime) + "–" + span.upperBound.formatted(axisTime))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(uplinks.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Chart {
                ForEach(uplinks.indices, id: \.self) { i in
                    let uplink = uplinks[i]
                    PointMark(
                        x: .value("Time", Date(timeIntervalSince1970: uplink.t)),
                        y: .value("From", row(uplink, rows))
                    )
                    .symbol(.square)
                    .symbolSize(uplink.origin == .resolution ? 60 : 10)
                    .foregroundStyle(by: .value("Request", request(uplink, requests)))
                }
            }
            .chartForegroundStyleScale(domain: requests, range: Array(Self.palette.prefix(requests.count)))
            .chartYScale(domain: rows)
            // Uplink files often cover part of the flight: show their span.
            .chartXScale(domain: span)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: state.rangeEnd - state.rangeStart < 900 ? axisTime.second(.twoDigits) : axisTime)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisValueLabel()
                }
            }
            .chartOverlay { proxy in
                Playhead(state: state, proxy: proxy)
            }
            .frame(height: CGFloat(rows.count) * 16 + 40)
        }
    }

    private var span: ClosedRange<Date> {
        let first = uplinks.first?.t ?? state.rangeStart, last = uplinks.last?.t ?? state.rangeEnd
        let margin = max(10, (last - first) * 0.03)
        return Date(timeIntervalSince1970: first - margin)...Date(timeIntervalSince1970: last + margin)
    }

    /// The busiest interrogators get a row each, TCAS last.
    private func categories() -> (rows: [String], requests: [String]) {
        var counts: [String: Int] = [:]
        for uplink in uplinks { counts[uplink.originLabel, default: 0] += 1 }
        let airborne = ["TCAS", "TCAS RA"]
        var rows = counts.keys.filter { !airborne.contains($0) }.sorted { counts[$0]! > counts[$1]! }
        if rows.count > Self.maxRows { rows = Array(rows.prefix(Self.maxRows - 1)) + ["Other"] }
        rows += airborne.filter { counts[$0] != nil }

        var requestCounts: [String: Int] = [:]
        for uplink in uplinks { requestCounts[uplink.requestLabel, default: 0] += 1 }
        var requests = requestCounts.keys.sorted { requestCounts[$0]! > requestCounts[$1]! }
        if requests.count > Self.palette.count { requests = Array(requests.prefix(Self.palette.count - 1)) + ["Other"] }
        return (rows, requests)
    }

    private func row(_ uplink: Uplink, _ rows: [String]) -> String {
        rows.contains(uplink.originLabel) ? uplink.originLabel : "Other"
    }

    private func request(_ uplink: Uplink, _ requests: [String]) -> String {
        requests.contains(uplink.requestLabel) ? uplink.requestLabel : "Other"
    }
}

/// Datalink messages up to the current time, newest first.
private struct DatalinkList: View {
    let state: AppState
    let messages: [DatalinkMessage]

    var body: some View {
        let shown = messages.filter { $0.t <= state.currentTime }.reversed()
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("DATALINK")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(shown.count) of \(messages.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if shown.isEmpty {
                Text("None yet at this time")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(shown.prefix(30).enumerated()), id: \.offset) { _, message in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: message.fromAircraft ? "arrow.down.right" : "arrow.up.right")
                            .foregroundStyle(message.fromAircraft ? .orange : .cyan)
                            .help(message.fromAircraft ? "Sent by the aircraft" : "Sent by the ground station")
                        Text(Date(timeIntervalSince1970: message.t), format: axisTime.second(.twoDigits))
                            .monospacedDigit()
                        Text(message.summary)
                            .fontWeight(.medium)
                        Spacer(minLength: 4)
                        Text([message.channels.first.map { String(format: "%.3f", $0) + (message.channels.count > 1 ? " +\(message.channels.count - 1)" : "") },
                              message.stationName?.split(separator: " ").first.map(String.init)
                                ?? message.station?.uppercased()]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                            .help(([message.stationName.map { "\($0) (\(message.station?.uppercased() ?? ""))" }]
                                   + message.channels.sorted().map { String(format: "%.3f MHz", $0) })
                                .compactMap { $0 }.joined(separator: "\n"))
                    }
                    if let text = message.text, !text.isEmpty {
                        Text(text)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                }
                .font(.caption)
            }
        }
    }
}

/// Current-time marker and scrubbing, kept apart so that moving the clock
/// does not redraw the chart itself.
private struct Playhead: View {
    let state: AppState
    let proxy: ChartProxy

    var body: some View {
        GeometryReader { geometry in
            if let anchor = proxy.plotFrame {
                let frame = geometry[anchor]
                let x = proxy.position(forX: Date(timeIntervalSince1970: state.currentTime))
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0).onChanged { value in
                            if let date: Date = proxy.value(atX: value.location.x - frame.minX) {
                                state.seek(to: date.timeIntervalSince1970)
                            }
                        }
                    )
                if let x, x >= 0, x <= frame.width {
                    Rectangle()
                        .fill(.white.opacity(0.7))
                        .frame(width: 1, height: frame.height)
                        .position(x: frame.minX + x, y: frame.midY)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}
