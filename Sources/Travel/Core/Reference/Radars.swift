import Foundation

/// A candidate site for an interrogator code, from `radars.csv` (built from
/// the uplink1030 radar catalogue). Codes are reused across Europe and the
/// assignments are undated: these are candidates, not verified allocations.
struct RadarSite: Sendable, Equatable {
    var code: String
    var name: String
    var position: LatLon
    /// "located" for a reviewed installation, "approximate" for an area.
    var basis: String
}

@MainActor
enum Radars {
    static let sites: [String: [RadarSite]] = {
        guard let url = Bundle.main.url(forResource: "radars", withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [:] }
        var result: [String: [RadarSite]] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") && !line.hasPrefix("code,") {
            let fields = Self.fields(String(line))
            guard fields.count >= 5, let latitude = Double(fields[2]), let longitude = Double(fields[3]) else { continue }
            let site = RadarSite(code: fields[0], name: fields[1], position: LatLon(latitude: latitude, longitude: longitude), basis: fields[4])
            result[site.code, default: []].append(site)
        }
        return result
    }()

    /// Splits a CSV line, with quoted fields.
    private static func fields(_ line: String) -> [String] {
        var fields: [String] = [], current = "", quoted = false
        for character in line {
            switch character {
            case "\"": quoted.toggle()
            case "," where !quoted: fields.append(current); current = ""
            default: current.append(character)
            }
        }
        fields.append(current)
        return fields
    }
}

/// A catalogue candidate checked against the aircraft a code addresses.
struct SiteFit: Sendable, Equatable {
    var site: RadarSite
    /// Aircraft closer to this candidate than to any other, within range.
    var aircraft: Int
    /// Median and 90th percentile of their distance to the site, metres.
    var medianDistance: Double
    var farDistance: Double
    /// Rotation period of this population, seconds.
    var period: Double?
    /// The aircraft surround it closely enough, and few are left unexplained:
    /// median distance within 350 km, at most a quarter of the located
    /// aircraft beyond range of every candidate. Otherwise the candidate
    /// rests on aircraft at the edge of range, and another radar using the
    /// same code is the likelier source.
    var consistent = false
}

/// What the data says about one interrogator code, rebuilt as data arrives.
struct Interrogator: Sendable, Equatable {
    var code: String
    /// Antenna rotation over all populations, seconds.
    var period: Double?
    /// Candidates supported by the data; several when a reused code is heard
    /// in different places (SI12 north and south of France, for instance).
    var fits: [SiteFit] = []
    /// Located aircraft segments, and those out of range of every candidate.
    var located = 0
    var unexplained = 0
    /// The site each located aircraft belongs to, per `segment`.
    var siteOf: [String: String] = [:]

    /// Evidence is grouped per aircraft and 10-minute window: on a long
    /// flight, the same aircraft meets several radars sharing a code.
    static func segment(_ id: String, _ t: Double) -> String { "\(id)/\(Int(t / 600))" }

    func site(of id: String, at t: Double) -> String? { siteOf[Self.segment(id, t)] }

    /// II0 is a shared code (acquisition with lockout override), used by
    /// several interrogators at once: no single site or rotation.
    var isShared: Bool { code == "II0" }

    /// Mode S coverage, a little beyond 250 NM.
    static let range = 460_000.0

    func fit(named name: String) -> SiteFit? { fits.first { $0.site.name == name } }
}

/// Every interrogation of one code, or reply naming it: when, and which aircraft.
struct InterrogationLog: Sendable {
    var times: [Double] = []
    var targets: [String] = []
    /// Interrogations heard on 1030 MHz, as opposed to DF 11 replies.
    var heard: [Bool] = []

    /// Aircraft interrogated between `start` and `end`.
    func targets(from start: Double, to end: Double) -> Set<String> {
        let first = Self.lowerBound(times, start)
        var result = Set<String>()
        var i = first
        while i < times.count, times[i] <= end {
            result.insert(targets[i])
            i += 1
        }
        return result
    }

    static func lowerBound(_ values: [Double], _ value: Double) -> Int {
        var low = 0, high = values.count
        while low < high {
            let mid = (low + high) / 2
            if values[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The rotation period, with the estimator of the uplink1030 report:
    /// per aircraft, burst onsets more than 0.5 s apart; gaps between
    /// onsets of 2 to 20 s; the mode of a 0.025 s histogram; the median of
    /// the gaps within 0.15 s of it, from at least 10 of them. Only
    /// interrogations heard on 1030 MHz count, from the given aircraft if any.
    func rotationPeriod(among subset: Set<String>? = nil) -> Double? {
        var byTarget: [String: [Double]] = [:]
        for i in times.indices where heard[i] && (subset?.contains(targets[i]) ?? true) {
            byTarget[targets[i], default: []].append(times[i])
        }
        var gaps: [Double] = []
        for times in byTarget.values {
            var previous: Double?
            var onset: Double?
            for t in times {
                defer { previous = t }
                if let previous, t - previous <= 0.5 { continue }
                if let onset, t - onset >= 2, t - onset <= 20 { gaps.append(t - onset) }
                onset = t
            }
        }
        guard gaps.count >= 10 else { return nil }
        var bins = [Int](repeating: 0, count: 720)
        for gap in gaps { bins[min(719, Int((gap - 2) / 0.025))] += 1 }
        guard let best = bins.indices.max(by: { bins[$0] < bins[$1] }) else { return nil }
        let mode = 2 + (Double(best) + 0.5) * 0.025
        let near = gaps.filter { abs($0 - mode) <= 0.15 }.sorted()
        guard near.count >= 10 else { return nil }
        return near[near.count / 2]
    }
}
