import Foundation

/// One minute of flight as judged by the turbulence detector.
struct TurbulenceMinute: Sendable, Equatable {
    /// Start of the minute, seconds since 1970.
    var start: Double
    /// Corrected spread of the fast fluctuations, ft/min.
    var spread: Double
    /// Roughly straight and level cruise, the only regime the detector is meant for.
    var passesChecks: Bool
    /// At or above the threshold, in a minute that passes the checks.
    var qualifies: Bool
    /// Part of at least two consecutive qualifying minutes.
    var isTurbulent: Bool
}

/// Turbulence detection from Mode S vertical rates, following "Do We See a
/// Trend Towards More Turbulence? Investigating Aviation's Exposure to a
/// Changing Climate" (SIDS 2026).
///
/// The barometric and inertial vertical rates of BDS 6,0 replies are put on a
/// 0.5 s grid; their difference, less its 10 s moving mean, leaves the fast
/// fluctuations; the robust spread of those over each minute is the measure.
///
/// Differences from the paper, which works on years of archive:
/// - the shared threshold is used for every aircraft, since the per-aircraft
///   thresholds need months of data from many aircraft;
/// - minutes are aligned on UTC minutes;
/// - the track-angle range is checked within each minute.
enum Turbulence {
    /// Shared threshold T0 of the paper, ft/min.
    static let threshold = 193.186
    private static let grid = 0.5
    private static let window = 60.0
    /// Rates beyond this are decoding errors, ft/min.
    private static let maxRate = 6000.0
    /// Reporting step of both vertical rates, ft/min.
    private static let step = 32.0
    /// A new segment starts after a gap this long, seconds.
    private static let segmentGap = 300.0
    private static let minReplies = 120
    private static let minSpan = 120.0
    /// Grid points further than this from an observation are left empty, seconds.
    private static let reach = 1.5
    private static let meanWindow = 10.0
    private static let minCoverage = 0.7
    /// 2.5 m/s, in ft/min.
    private static let maxVerticalRate = 2.5 * 196.850394
    private static let maxTrackRange = 10.0
    /// 7,500 m, in ft.
    private static let minAltitude = 7500 / 0.3048

    static func analyse(
        barometric: [Sample], inertial: [Sample],
        verticalRate: [Sample], track: [Sample], altitude: [Sample]
    ) -> [TurbulenceMinute] {
        // Both rates come in the same reply: pair them by timestamp.
        var pairs: [(t: Double, residual: Double)] = []
        var j = 0
        for b in barometric {
            while j < inertial.count, inertial[j].t < b.t { j += 1 }
            guard j < inertial.count, inertial[j].t == b.t else { continue }
            if abs(b.v) <= maxRate, abs(inertial[j].v) <= maxRate {
                pairs.append((b.t, b.v - inertial[j].v))
            }
        }

        var minutes: [TurbulenceMinute] = []
        var start = 0
        for k in 1...max(1, pairs.count) where k >= pairs.count || pairs[k].t - pairs[k - 1].t > segmentGap {
            if k - start >= minReplies, pairs[k - 1].t - pairs[start].t >= minSpan {
                minutes += spreads(Array(pairs[start..<k]))
            }
            start = k
            if k >= pairs.count { break }
        }

        for n in minutes.indices {
            let range = minutes[n].start..<(minutes[n].start + window)
            minutes[n].passesChecks = cruise(range, verticalRate, track, altitude)
            minutes[n].qualifies = minutes[n].passesChecks && minutes[n].spread >= threshold
        }
        for n in minutes.indices where minutes[n].qualifies {
            let before = n > 0 && minutes[n - 1].qualifies && minutes[n].start - minutes[n - 1].start == window
            let after = n + 1 < minutes.count && minutes[n + 1].qualifies && minutes[n + 1].start - minutes[n].start == window
            minutes[n].isTurbulent = before || after
        }
        return minutes
    }

    /// Spread of each usable minute of one segment.
    private static func spreads(_ pairs: [(t: Double, residual: Double)]) -> [TurbulenceMinute] {
        let origin = (pairs[0].t / window).rounded(.down) * window
        let count = Int((pairs[pairs.count - 1].t - origin) / grid) + 1

        // Median of the replies falling in each grid interval.
        var cells: [Int: [Double]] = [:]
        for pair in pairs { cells[Int((pair.t - origin) / grid), default: []].append(pair.residual) }
        var residual = [Double](repeating: .nan, count: count)
        for (k, values) in cells { residual[k] = median(values) }

        // Linear interpolation, only close to an observation.
        let observed = cells.keys.sorted()
        let limit = Int(reach / grid)
        for (a, b) in zip(observed, observed.dropFirst()) where b - a > 1 {
            for k in (a + 1)..<b where min(k - a, b - k) <= limit {
                let f = Double(k - a) / Double(b - a)
                residual[k] = residual[a] + (residual[b] - residual[a]) * f
            }
        }

        // Fast fluctuations: the residual less its centred 10 s moving mean.
        let half = Int(meanWindow / grid / 2)
        var fluctuation = [Double](repeating: .nan, count: count)
        for k in 0..<count where !residual[k].isNaN {
            var sum = 0.0, n = 0.0
            for m in max(0, k - half)...min(count - 1, k + half) where !residual[m].isNaN {
                sum += residual[m]
                n += 1
            }
            fluctuation[k] = residual[k] - sum / n
        }

        // Robust spread per minute, corrected for the rounding of both rates.
        let perWindow = Int(window / grid)
        var minutes: [TurbulenceMinute] = []
        for first in stride(from: 0, to: count, by: perWindow) {
            let values = fluctuation[first..<min(count, first + perWindow)].filter { !$0.isNaN }
            guard Double(values.count) >= minCoverage * Double(perWindow) else { continue }
            let centre = median(values)
            let deviation = median(values.map { abs($0 - centre) }) / 0.67449
            let spread = max(deviation * deviation - 2 * step * step / 12, 0).squareRoot()
            minutes.append(TurbulenceMinute(
                start: origin + Double(first) * grid, spread: spread,
                passesChecks: false, qualifies: false, isTurbulent: false
            ))
        }
        return minutes
    }

    /// Approximately straight and level, at cruise altitude.
    private static func cruise(_ range: Range<Double>, _ verticalRate: [Sample], _ track: [Sample], _ altitude: [Sample]) -> Bool {
        let rates = values(verticalRate, in: range)
        let levels = values(altitude, in: range)
        let tracks = values(track, in: range)
        guard !rates.isEmpty, !levels.isEmpty, let reference = tracks.first else { return false }
        guard abs(median(rates)) <= maxVerticalRate, median(levels) >= minAltitude else { return false }
        // Range of the track angle, across the 0/360 boundary if needed.
        let offsets = tracks.map { ($0 - reference + 540).truncatingRemainder(dividingBy: 360) - 180 }
        return (offsets.max() ?? 0) - (offsets.min() ?? 0) <= maxTrackRange
    }

    private static func values(_ samples: [Sample], in range: Range<Double>) -> [Double] {
        var low = 0, high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].t < range.lowerBound { low = mid + 1 } else { high = mid }
        }
        var result: [Double] = []
        while low < samples.count, samples[low].t < range.upperBound {
            result.append(samples[low].v)
            low += 1
        }
        return result
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}
