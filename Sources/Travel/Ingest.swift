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

        if let format = message["uf"] as? String {
            uplink(message, format: Int(format) ?? -1, t: t)
        } else if message["bearer"] is String {
            datalink(message, t: t)
        } else if let mmsi = message["mmsi"] as? NSNumber {
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

    /// Interrogations carry the target address in their parity; "ffffff"
    /// is the broadcast address of all-calls. A series created here has no
    /// activity: it only shows once the aircraft itself is heard.
    private func uplink(_ message: NSDictionary, format: Int, t: Double) {
        var target = message["icao24"] as? String
        let kind = message["kind"] as? String
        // ACAS broadcasts name their sender in `mid`.
        if format == 16, let sender = message["mid"] as? String { target = sender }
        guard let target, target != "ffffff" else { return }
        let origin: Uplink.Origin
        switch format {
        case 0: origin = .acas
        case 16: origin = kind == "resolution" ? .resolution : .acas
        case 24: origin = .elm
        default: origin = .radar(text(message, "interrogator"))
        }
        let i = slot(target, .aircraft)
        series[i].uplinks.append(Uplink(t: t, uplinkFormat: format, origin: origin, register: text(message, "bds")))
    }

    /// Reads the three layouts datalink has written: flat (current, with
    /// `icao24`, `direction` and the layers side by side), and the earlier
    /// `{"message": {"avlc": …}}` and `{"message": {"kind": "avlc", "data": …}}`.
    private func datalink(_ message: NSDictionary, t: Double) {
        if let airframes = message["airframes"] as? NSDictionary {
            relayed(message, airframes, t: t)
            return
        }
        let body = message["message"] as? NSDictionary
        guard let avlc = message["avlc"] as? NSDictionary ?? body.flatMap({ Self.layer($0, "avlc") })
        else { return }
        let source = avlc["src"] as? NSDictionary
        let destination = avlc["dst"] as? NSDictionary
        let fromAircraft = (message["direction"] as? String).map { $0 == "downlink" }
            ?? (source?["addr_type"] as? String == "aircraft")
        let aircraft = message["icao24"] as? String
            ?? (message["aircraft"] as? NSDictionary)?["icao24"] as? String
            ?? (fromAircraft ? source : destination)?["icao24"] as? String
        guard let aircraft else { return }
        let station = message["station"] as? String ?? (fromAircraft ? destination : source)?["icao24"] as? String
        let hertz = ((message["metadata"] as? NSArray)?.firstObject as? NSDictionary)?["channel_hz"] as? NSNumber
            ?? (message["receiver"] as? NSDictionary)?["channel_hz"] as? NSNumber
        let channel = hertz.map { $0.doubleValue / 1e6 }

        // Layers carried by the frame: beside `avlc` now, in its payload before.
        let payload = avlc["payload"] as? NSDictionary
        func carried(_ name: String) -> NSDictionary? {
            message[name] as? NSDictionary ?? payload.flatMap { Self.layer($0, name) }
        }

        // The innermost known layer names the message.
        var summary = "Frame"
        var text: String?
        if let acars = carried("acars") {
            let label = acars["label"] as? String ?? ""
            summary = "ACARS \(label)".trimmingCharacters(in: .whitespaces)
            text = (acars["msg_text"] ?? acars["text"] ?? acars["message"]) as? String
        } else if let x25 = carried("x25") {
            summary = "X.25 " + (x25["packet_type"] as? String ?? "packet")
        } else if carried("xid") != nil {
            summary = "XID"
        } else if let payload {
            summary = ((payload["kind"] ?? payload.allKeys.first) as? String)?.uppercased() ?? summary
        } else if let control = avlc["lcf"] as? String {
            // Flat layouts name the frame type, with its function beside it.
            if let function = (avlc["sfunc"] ?? avlc["mfunc"] ?? avlc["ufunc"]) as? String {
                summary = Self.spaced(function)
            } else {
                summary = ["S": "Supervisory", "I": "Information", "U": "Unnumbered"][control] ?? "Frame"
            }
        } else if let control = avlc["lcf"] as? NSDictionary {
            if let supervisory = control["S"] as? NSDictionary {
                summary = (supervisory["sfunc"] as? String).map(Self.spaced) ?? "Supervisory"
            } else if control["I"] != nil {
                summary = "Information"
            } else if let unnumbered = control["U"] as? NSDictionary {
                summary = (unnumbered["mfunc"] as? String).map(Self.spaced) ?? "Unnumbered"
            }
        }

        let arinc = message["arinc622"] as? NSDictionary
        if let arinc { summary += " · " + Self.application(arinc) }

        let i = slot(aircraft, .aircraft)
        series[i].datalink.append(DatalinkMessage(
            t: t, channel: channel, station: station,
            stationName: self.text(message, "station_name") ?? arinc.flatMap { self.text($0, "atsu_address") },
            fromAircraft: fromAircraft, summary: summary, text: text
        ))
        let reported = arinc.map { adsc($0, into: i, t: t) } ?? false
        kinematics(message, into: i, t: t, position: !reported)
    }

    /// The application of an ARINC 622 message, from its interline message identifier.
    private static func application(_ arinc: NSDictionary) -> String {
        let imi = arinc["imi"] as? String ?? ""
        let names = ["ADS": "ADS-C", "DIS": "ADS-C disconnect", "AT1": "CPDLC", "CR1": "CPDLC logon",
                     "CC1": "CPDLC connect", "DR1": "CPDLC disconnect", "AB1": "AOC"]
        return names[imi] ?? "ARINC 622 \(imi)"
    }

    private static let positionReports = [
        "basic_report", "emergency_basic_report", "lateral_deviation_change_event",
        "vertical_rate_change_event", "altitude_range_event", "waypoint_change_event",
    ]

    /// Reads the tags of an ADS-C report (`arinc622.payload.adsc`); returns
    /// whether it gave a position.
    private func adsc(_ arinc: NSDictionary, into i: Int, t: Double) -> Bool {
        guard let tags = (arinc["payload"] as? NSDictionary)?["adsc"] as? NSArray else { return false }
        var found = false
        // Reports are stamped in seconds past the hour, before reception.
        var at = t
        for case let tag as NSDictionary in tags {
            if let callsign = (tag["flight_id"] as? NSDictionary).flatMap({ text($0, "callsign") }) {
                series[i].name = callsign
            }
            // Event and emergency reports share the layout of the basic report.
            if let basic = Self.positionReports.lazy.compactMap({ tag[$0] as? NSDictionary }).first,
               let latitude = number(basic, "latitude"), let longitude = number(basic, "longitude"),
               abs(latitude) <= 90, abs(longitude) <= 180 {
                if let seconds = number(basic, "timestamp_seconds_past_hour") {
                    var stamp = (t / 3600).rounded(.down) * 3600 + seconds
                    if stamp > t + 60 { stamp -= 3600 }
                    if t - stamp < 3600 { at = stamp }
                }
                series[i].reported.append(Position(t: at, latitude: latitude, longitude: longitude))
                series[i].activity.append(at)
                if let altitude = number(basic, "altitude_ft") {
                    series[i].channels[Channel.altitude.rawValue].append(Sample(t: at, v: altitude))
                }
                found = true
            }
            if let earth = tag["earth_reference_data"] as? NSDictionary {
                collect(earth, [("true_track_degrees", .track), ("ground_speed_kt", .groundspeed),
                                ("vertical_speed_ft_per_min", .verticalRate)], into: i, t: at)
            }
            if let air = tag["air_reference_data"] as? NSDictionary {
                collect(air, [("true_heading_degrees", .heading), ("mach", .mach)], into: i, t: at)
            }
        }
        return found
    }

    /// A message relayed from Airframes.io, on any bearer (VDL2, VHF ACARS,
    /// HFDL…). Its `kinematics` give a coarse position of the aircraft.
    private func relayed(_ message: NSDictionary, _ airframes: NSDictionary, t: Double) {
        let payload = airframes["payload"] as? NSDictionary ?? [:]
        let source = airframes["src"] as? NSDictionary
        let destination = airframes["dst"] as? NSDictionary
        let fromHex = (payload["from_hex"] as? String)?.lowercased()
        let toHex = (payload["to_hex"] as? String)?.lowercased()
        guard let aircraft = (message["icao24"] as? String)?.lowercased()
                ?? (payload["airframe"] as? NSDictionary).flatMap({ ($0["icao"] as? String)?.lowercased() })
        else { return }
        let fromAircraft: Bool
        switch (source?["addr_type"] as? String, payload["link_direction"] as? String) {
        case ("aircraft", _), (_, "downlink"): fromAircraft = true
        case ("ground_station", _), (_, "uplink"): fromAircraft = false
        default: fromAircraft = toHex != aircraft
        }
        let station = (fromAircraft ? destination : source)?["icao24"] as? String ?? (fromAircraft ? toHex : fromHex)

        let bearer = (message["bearer"] as? String).flatMap { $0 == "unknown" ? nil : $0.uppercased() }
        let label = (payload["label"] as? String)?.trimmingCharacters(in: .whitespaces)
        var summary = ["ACARS", label].compactMap { $0 }.joined(separator: " ")
        // The decoded application, such as atis_request, when it is not plain text.
        let application = airframes["app"] as? NSDictionary
        let arinc = application?["arinc622"] as? NSDictionary
        if let arinc {
            summary += " · " + Self.application(arinc)
        } else if let app = application?.allKeys.first as? String, app != "text" {
            summary += " · " + app.replacingOccurrences(of: "_", with: " ").capitalized(with: nil)
        }
        if let bearer, !["VDL2", "ACARS", "DECODED"].contains(bearer) { summary = "\(bearer) \(summary)" }

        let i = slot(aircraft, .aircraft)
        if let registration = text(message, "registration") ?? text(payload, "tail"), series[i].info.registration == nil {
            series[i].info.registration = registration
        }
        series[i].datalink.append(DatalinkMessage(
            t: t, channel: number(payload, "frequency"), station: station,
            stationName: arinc.flatMap { text($0, "atsu_address") },
            fromAircraft: fromAircraft, summary: summary, text: text(payload, "text")
        ))
        // An ADS-C report is more precise and more recent than what
        // `kinematics` holds, which Airframes.io flight tracking overrides.
        let reported = arinc.map { adsc($0, into: i, t: t) } ?? false
        kinematics(message, into: i, t: t, position: !reported)
    }

    /// Where the aircraft reported itself, in a datalink message: ADS-C and
    /// CPDLC position reports, AOC and label 32 positions, VDL2 XID, HFDL,
    /// or Airframes.io flight tracking (`airframes_flight`, coarse).
    private func kinematics(_ message: NSDictionary, into i: Int, t: Double, position wanted: Bool = true) {
        guard let kinematics = message["kinematics"] as? NSDictionary else { return }
        let origin = kinematics["derived_from"] as? String
        // Squitters give the position of the ground station.
        guard origin != "squitter", wanted else { return }
        if let position = kinematics["position"] as? NSDictionary,
           let latitude = number(position, "latitude"), let longitude = number(position, "longitude"),
           abs(latitude) <= 90, abs(longitude) <= 180, latitude != 0 || longitude != 0 {
            series[i].reported.append(Position(t: t, latitude: latitude, longitude: longitude))
            series[i].activity.append(t)
        }
        if let track = number(kinematics, "track") {
            series[i].channels[Channel.track.rawValue].append(Sample(t: t, v: track))
        }
        // Airframes.io tracking altitudes are sometimes ten times too large.
        if origin != "airframes_flight", let altitude = number(kinematics, "altitude_ft"), (-2000...60000).contains(altitude) {
            series[i].channels[Channel.altitude.rawValue].append(Sample(t: t, v: altitude))
        }
        if let speed = number(kinematics, "ground_speed_knots") {
            series[i].channels[Channel.groundspeed.rawValue].append(Sample(t: t, v: speed))
        }
    }

    /// A protocol layer, written `{"avlc": {…}}` now and
    /// `{"kind": "avlc", "data": {…}}` in older recordings.
    private static func layer(_ container: NSDictionary, _ name: String) -> NSDictionary? {
        if let layer = container[name] as? NSDictionary { return layer }
        if container["kind"] as? String == name { return container["data"] as? NSDictionary }
        return nil
    }

    /// "ReceiveReady" becomes "Receive ready".
    private static func spaced(_ name: String) -> String {
        var result = ""
        for character in name {
            if character.isUppercase, !result.isEmpty { result.append(" ") }
            result.append(result.isEmpty ? character : Character(character.lowercased()))
        }
        return result
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
