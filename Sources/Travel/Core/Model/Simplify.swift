import Foundation

/// Douglas–Peucker line simplification: drops the points that a straight line
/// between their neighbours already describes within a tolerance. Detail stays
/// where the data bends (taxiing, turns, climbs) and goes where it is straight.
enum Simplify {
    /// Indices to keep in `range`, in order; both ends are always kept.
    /// `deviation(a, b, p)` is how far point `p` lies from the line `a`–`b`.
    static func keep(_ range: Range<Int>, tolerance: Double, deviation: (Int, Int, Int) -> Double) -> [Int] {
        guard range.count > 2 else { return Array(range) }
        var kept = [Bool](repeating: false, count: range.count)
        kept[0] = true
        kept[range.count - 1] = true
        var stack = [(range.lowerBound, range.upperBound - 1)]
        while let (a, b) = stack.popLast() {
            guard b - a > 1 else { continue }
            var worst = 0.0, at = a
            for p in (a + 1)..<b {
                let d = deviation(a, b, p)
                if d > worst {
                    worst = d
                    at = p
                }
            }
            if worst > tolerance {
                kept[at - range.lowerBound] = true
                stack.append((a, at))
                stack.append((at, b))
            }
        }
        return range.filter { kept[$0 - range.lowerBound] }
    }
}
