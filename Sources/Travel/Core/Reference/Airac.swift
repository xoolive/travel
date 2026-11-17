import Foundation

/// Navigation data from a EUROCONTROL AIXM baseline (one zip per feature
/// type, as in ~/Documents/data/airac/AIRAC_2606/), read the way thrust
/// does (crates/thrust/src/data/eurocontrol/aixm/): designated points,
/// navaids, airports, airways (route segments) and SIDs/STARs (legs). Read
/// once in the background and kept as a compact index in the cache folder.
struct AiracIndex: Codable, Sendable {
    struct Point: Codable, Sendable {
        var name: String
        var latitude: Double
        var longitude: Double
        var position: LatLon { LatLon(latitude: latitude, longitude: longitude) }
    }

    /// Points by AIXM UUID: designated points, navaids, airport reference points.
    var points: [String: Point] = [:]
    /// Airway segments by airway name (UT182): pairs of point UUIDs.
    var airways: [String: [[String]]] = [:]
    /// SID and STAR legs by "designator@airport" (FISTO7B@LFBO): pairs of point UUIDs.
    var departures: [String: [[String]]] = [:]
    var arrivals: [String: [[String]]] = [:]

    /// Point UUIDs by name, built after loading.
    var byName: [String: [String]] {
        var result: [String: [String]] = [:]
        for (id, point) in points { result[point.name, default: []].append(id) }
        return result
    }
}

enum Airac {
    /// The latest AIRAC_* folder under ~/Documents/data/airac.
    static var folder: URL? {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/data/airac")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return names.filter { $0.hasPrefix("AIRAC_") }.sorted().last.map { base.appendingPathComponent($0) }
    }

    private static let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("travel", isDirectory: true)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded: (AiracIndex, [String: [String]])?

    /// The index and point UUIDs by name, read from the cache or built from
    /// the AIXM zips (a minute or so, once per AIRAC). Blocking.
    static func index() -> (AiracIndex, [String: [String]])? {
        lock.lock()
        defer { lock.unlock() }
        if let loaded { return loaded }
        guard let folder else { return nil }
        let file = cache.appendingPathComponent("\(folder.lastPathComponent).json")
        var index: AiracIndex?
        if let data = try? Data(contentsOf: file) {
            index = try? JSONDecoder().decode(AiracIndex.self, from: data)
        }
        if index == nil {
            index = build(from: folder)
            if let index, let data = try? JSONEncoder().encode(index) {
                try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                try? data.write(to: file)
            }
        }
        guard let index else { return nil }
        loaded = (index, index.byName)
        return loaded
    }

    // MARK: Reading the AIXM zips

    private static func build(from folder: URL) -> AiracIndex? {
        var index = AiracIndex()
        func each(_ feature: String, _ handle: (Feature) -> Void) {
            let zip = folder.appendingPathComponent("\(feature).BASELINE.zip")
            guard let data = unzip(zip) else { return }
            let reader = FeatureReader(feature: feature)
            let parser = XMLParser(data: data)
            parser.shouldProcessNamespaces = false
            parser.delegate = reader
            parser.parse()
            reader.features.forEach(handle)
        }
        each("DesignatedPoint") { f in
            if let name = f.text["designator"] ?? f.text["name"], let p = f.position {
                index.points[f.id] = .init(name: name, latitude: p.latitude, longitude: p.longitude)
            }
        }
        each("Navaid") { f in
            if let name = f.text["designator"], let p = f.position {
                index.points[f.id] = .init(name: name, latitude: p.latitude, longitude: p.longitude)
            }
        }
        each("AirportHeliport") { f in
            if let name = f.text["locationIndicatorICAO"] ?? f.text["designator"], let p = f.position {
                index.points[f.id] = .init(name: name, latitude: p.latitude, longitude: p.longitude)
            }
        }
        var routeNames: [String: String] = [:]
        each("Route") { f in
            let name = ["designatorPrefix", "designatorSecondLetter", "designatorNumber", "multipleIdentifier"]
                .compactMap { f.text[$0] }.joined()
            if !name.isEmpty { routeNames[f.id] = name }
        }
        each("RouteSegment") { f in
            if let route = f.refs["routeFormed"].flatMap({ routeNames[$0] }), let a = f.refs["start"], let b = f.refs["end"] {
                index.airways[route, default: []].append([a, b])
            }
        }
        func procedures(_ feature: String) -> [String: String] {
            var names: [String: String] = [:]
            each(feature) { f in
                if let designator = f.text["designator"], let airport = f.refs["airportHeliport"].flatMap({ index.points[$0]?.name }) {
                    names[f.id] = "\(designator)@\(airport)"
                }
            }
            return names
        }
        let sids = procedures("StandardInstrumentDeparture")
        each("DepartureLeg") { f in
            if let key = f.refs["departure"].flatMap({ sids[$0] }), let a = f.refs["startPoint"], let b = f.refs["endPoint"] {
                index.departures[key, default: []].append([a, b])
            }
        }
        let stars = procedures("StandardInstrumentArrival")
        each("ArrivalLeg") { f in
            if let key = f.refs["arrival"].flatMap({ stars[$0] }), let a = f.refs["startPoint"], let b = f.refs["endPoint"] {
                index.arrivals[key, default: []].append([a, b])
            }
        }
        return index.points.isEmpty ? nil : index
    }

    private static func unzip(_ zip: URL) -> Data? {
        guard FileManager.default.fileExists(atPath: zip.path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", zip.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data.isEmpty ? nil : data
    }

    /// One AIXM feature: its UUID, the texts and references we need, the
    /// first position. With several time slices, the last values win.
    struct Feature {
        var id = ""
        var text: [String: String] = [:]
        var refs: [String: String] = [:]
        var position: LatLon?
    }

    private final class FeatureReader: NSObject, XMLParserDelegate {
        let feature: String
        var features: [Feature] = []
        private var current: Feature?
        private var buffer = ""
        private var capturing = false
        /// The enclosing reference element (start, end, startPoint…) for
        /// point choices nested inside it.
        private var container: String?

        private static let texts: Set<String> = [
            "designator", "name", "locationIndicatorICAO", "designatorPrefix",
            "designatorSecondLetter", "designatorNumber", "multipleIdentifier",
        ]
        private static let containers: Set<String> = ["start", "end", "startPoint", "endPoint"]
        private static let directRefs: Set<String> = ["routeFormed", "airportHeliport", "departure", "arrival"]

        init(feature: String) { self.feature = feature }

        private func local(_ name: String) -> String {
            name.split(separator: ":").last.map(String.init) ?? name
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            let element = local(name)
            if element == feature, name.hasPrefix("aixm:") {
                current = Feature()
                return
            }
            guard current != nil else { return }
            if element == "identifier" || element == "pos" || Self.texts.contains(element) {
                capturing = true
                buffer = ""
            }
            if Self.containers.contains(element) { container = element }
            let href = attributes["xlink:href"].map { $0.replacingOccurrences(of: "urn:uuid:", with: "") }
            if let href {
                if Self.directRefs.contains(element), current?.refs[element] == nil || element == "routeFormed" {
                    current?.refs[element] = href
                } else if element.hasPrefix("pointChoice_"), let container {
                    current?.refs[container] = href
                }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if capturing { buffer += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let element = local(name)
            if element == feature, name.hasPrefix("aixm:"), let done = current {
                if !done.id.isEmpty { features.append(done) }
                current = nil
                return
            }
            guard current != nil else { return }
            if Self.containers.contains(element) { container = nil }
            guard capturing else { return }
            capturing = false
            let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            switch element {
            case "identifier": current?.id = value
            case "pos":
                if current?.position == nil {
                    let parts = value.split(separator: " ").compactMap { Double($0) }
                    if parts.count >= 2 { current?.position = LatLon(latitude: parts[0], longitude: parts[1]) }
                }
            default:
                if !value.isEmpty { current?.text[element] = value }
            }
        }
    }
}
