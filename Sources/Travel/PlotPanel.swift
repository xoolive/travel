import Charts
import SwiftUI

/// The plot groups of the tangram aircraft widget.
enum PlotGroup: String, CaseIterable, Identifiable {
    case altitude = "Altitude (ft)"
    case speed = "Speed (kt)"
    case verticalRate = "Vertical rate (ft/min)"
    case directions = "Directions"

    var id: String { rawValue }
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

/// Time series of the selected target. Click or drag to move the clock.
struct PlotPanel: View {
    @Bindable var state: AppState
    @State private var group: PlotGroup = .altitude

    var body: some View {
        // Reading `revision` redraws the plot when live data arrives.
        let _ = state.revision
        let kind = state.selectedID.flatMap { state.dataset?.kind(of: $0) } ?? .aircraft
        let groups: [PlotGroup] = kind == .ship ? [.speed, .directions] : PlotGroup.allCases
        let active = groups.contains(group) ? group : groups[0]
        let content = build(active, kind)

        VStack(alignment: .leading, spacing: 6) {
            Picker("Plot", selection: $group) {
                ForEach(groups) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if content.lines.isEmpty {
                Text("No data for this target")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                chart(content)
            }
        }
        .padding(10)
        .frame(minHeight: 180, idealHeight: 240)
        .background(.background)
    }

    private func chart(_ content: PlotContent) -> some View {
        Chart {
            ForEach(content.lines) { line in
                ForEach(line.points.indices, id: \.self) { i in
                    let x = Date(timeIntervalSince1970: line.points[i].t)
                    if line.asPoints {
                        PointMark(x: .value("Time", x), y: .value("Value", line.points[i].v))
                            .symbolSize(10)
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
            AxisMarks { _ in
                AxisGridLine()
                AxisValueLabel(format: state.rangeEnd - state.rangeStart < 900 ? axisTime.second(.twoDigits) : axisTime)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading)
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

    private func build(_ group: PlotGroup, _ kind: Kind) -> PlotContent {
        guard let dataset = state.dataset, let id = state.selectedID else { return PlotContent() }
        func line(_ label: String, _ channel: Channel, _ color: Color, points: Bool = false, map: ((Double) -> Double)? = nil) -> PlotLine? {
            var samples = dataset.samples(for: id, channel)
            guard !samples.isEmpty else { return nil }
            if let map { samples = samples.map { Sample(t: $0.t, v: map($0.v)) } }
            var runs = [Int](repeating: 0, count: samples.count)
            for i in samples.indices.dropFirst() {
                runs[i] = runs[i - 1] + (samples[i].t - samples[i - 1].t > kind.timeout ? 1 : 0)
            }
            return PlotLine(id: label, color: color, points: samples, asPoints: points, runs: runs)
        }

        var content = PlotContent()
        switch group {
        case .altitude:
            content.lines = [
                line("Barometric altitude", .altitude, .blue),
                line("Selected altitude", .selectedAltitude, .orange),
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
                content.secondary = SecondaryAxis(ticks: [0, 150, 300, 450, 600]) { String(format: "M %.2f", $0 / 600) }
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
                line(kind == .ship ? "Heading" : "Magnetic heading", .heading, .orange, points: true),
                // Roll -45...45 degrees drawn on the 0...360 scale.
                line("Roll angle", .roll, .green) { ($0 + 45) * 4 },
            ].compactMap { $0 }
            if kind == .aircraft {
                content.secondary = SecondaryAxis(ticks: [0, 90, 180, 270, 360]) { String(format: "%.0f°", $0 / 4 - 45) }
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
