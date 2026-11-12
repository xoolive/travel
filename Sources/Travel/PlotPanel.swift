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
