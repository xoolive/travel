import Foundation

/// Turns decoded JSON lines from jet1090 (Mode S / ADS-B) and ship162 (AIS)
/// into per-target series. Used for both files and live feeds.
/// Not thread-safe: use one builder per thread.
final class Builder {
    private static let aircraftChannels: [(String, Channel)] = [
        ("altitude", .altitude),
        ("selected_altitude", .selectedAltitude),
        ("selected_mcp", .selectedAltitude),
        ("groundspeed", .groundspeed),
        ("IAS", .ias),
        ("TAS", .tas),
        ("Mach", .mach),
        ("vertical_rate", .verticalRate),
        ("vrate_barometric", .vrateBarometric),
        ("vrate_inertial", .vrateInertial),
        ("track", .track),
        ("heading", .heading),
        ("roll", .roll),
        ("NACp", .nacp),
    ]
    private static let commB = ["bds40", "bds50", "bds60"]
    private static let shipChannels: [(String, Channel)] = [
        ("speed", .groundspeed),
        ("course", .track),
        ("heading", .heading),
    ]

    private var series: [Series] = []
    private var index: [String: Int] = [:]

    /// Returns what was collected so far and starts afresh.
    func take() -> [Series] {
        defer {
            series = []
            index = [:]
        }
        return series
    }

    func merge(_ batch: [Series]) {
        for item in batch {
            if let i = index[item.id] {
                series[i].append(item)
            } else {
                index[item.id] = series.count
                series.append(item)
            }
        }
    }

    /// Ingests a block of complete lines.
    func ingest(block: UnsafeRawBufferPointer) {
        guard let base = block.baseAddress else { return }
        var start = 0
        while start < block.count {
            let end: Int
            if let newline = memchr(base + start, 0x0A, block.count - start) {
                end = base.distance(to: UnsafeRawPointer(newline))
            } else {
                end = block.count
            }
            ingest(line: UnsafeRawBufferPointer(rebasing: block[start..<end]))
            start = end + 1
        }
    }

    func ingest(line: UnsafeRawBufferPointer) {
        guard line.count > 2, let base = line.baseAddress else { return }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: line.count, deallocator: .none)
        guard let message = try? JSONSerialization.jsonObject(with: data) as? NSDictionary,
              let t = number(message, "timestamp")
        else { return }

        if let mmsi = message["mmsi"] as? NSNumber {
            ship(message, id: String(mmsi.int64Value), t: t)
        } else if let icao24 = message["icao24"] as? String {
            aircraft(message, id: icao24, t: t)
        }
    }

    private func slot(_ id: String, _ kind: Kind) -> Int {
        if let i = index[id] { return i }
        index[id] = series.count
        series.append(Series(id: id, kind: kind))
        return series.count - 1
    }

    private func number(_ dictionary: NSDictionary, _ key: String) -> Double? {
        (dictionary[key] as? NSNumber)?.doubleValue
    }

    private func text(_ dictionary: NSDictionary, _ key: String) -> String? {
        guard let value = (dictionary[key] as? String)?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty
        else { return nil }
        return value
    }

    private func aircraft(_ message: NSDictionary, id: String, t: Double) {
        let i = slot(id, .aircraft)
        series[i].activity.append(t)

        let callsign = text(message, "callsign")
            ?? (message["bds20"] as? NSDictionary).flatMap { text($0, "callsign") }
        if let callsign, !callsign.contains("#") { series[i].name = callsign }
        if let squawk = text(message, "squawk") { series[i].info.squawk = squawk }
        if message["df"] as? String == "18" { series[i].info.isVehicle = true }

        if let latitude = number(message, "latitude"), let longitude = number(message, "longitude") {
            series[i].positions.append(Position(t: t, latitude: latitude, longitude: longitude))
            // Surface position messages carry no altitude.
            if message["bds"] as? String == "06" {
                series[i].channels[Channel.altitude.rawValue].append(Sample(t: t, v: 0))
            }
        }

        collect(message, Self.aircraftChannels, into: i, t: t)
        for key in Self.commB {
            if let register = message[key] as? NSDictionary {
                collect(register, Self.aircraftChannels, into: i, t: t)
            }
        }
    }

    private func ship(_ message: NSDictionary, id: String, t: Double) {
        let i = slot(id, .ship)
        series[i].activity.append(t)

        if let name = text(message, "shipname") ?? text(message, "name") { series[i].name = name }
        var info = Info()
        info.radioCallsign = text(message, "callsign")
        info.shipType = text(message, "ship_type") ?? text(message, "mmsi_type").flatMap { $0 == "Ship" ? nil : $0 }
        info.destination = text(message, "destination")
        info.status = text(message, "status")
        info.flag = text(message, "flag")
        info.country = text(message, "country")
        series[i].info.merge(info)

        if let latitude = number(message, "latitude"), let longitude = number(message, "longitude"),
           abs(latitude) <= 90, abs(longitude) <= 180 {
            series[i].positions.append(Position(t: t, latitude: latitude, longitude: longitude))
        }
        collect(message, Self.shipChannels, into: i, t: t)
    }

    private func collect(_ dictionary: NSDictionary, _ keys: [(String, Channel)], into i: Int, t: Double) {
        for (key, channel) in keys {
            if let value = number(dictionary, key) {
                series[i].channels[channel.rawValue].append(Sample(t: t, v: value))
            }
        }
    }
}
