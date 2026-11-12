import Foundation
import Network

/// A configured live source: Redis pub/sub channels carrying jet1090 or
/// ship162 JSON messages, or an SDR receiver plugged in locally.
struct LiveSource: Identifiable, Codable, Hashable {
    /// A local receiver, recognised again when plugged back in.
    struct Device: Codable, Hashable {
        var vendorID: Int
        var productID: Int
        /// Not always unique: RTL-SDR dongles often share theirs.
        var serial: String?
        /// Where it was plugged, to tell identical devices apart.
        var locationID: Int
        var model: String

        init(_ device: UsbDevice) {
            vendorID = device.vendorID
            productID = device.productID
            serial = device.serial
            locationID = device.locationID
            model = device.sdr?.name ?? device.product
        }

        /// The plugged device this refers to: same model and serial number,
        /// preferring the same port when several match.
        func match(in receivers: [UsbDevice]) -> UsbDevice? {
            let candidates = receivers.filter {
                $0.vendorID == vendorID && $0.productID == productID && $0.serial == serial
            }
            return candidates.first { $0.locationID == locationID } ?? candidates.first
        }
    }

    var id = UUID()
    var name: String
    /// host:port; the port defaults to 6379.
    var address: String
    /// Channel names separated by spaces or commas.
    var channels: String
    /// Set for a local receiver; nil for Redis.
    var device: Device?

    var isDevice: Bool { device != nil }

    static let defaults = [template]

    /// Prefilled values for a new source.
    static var template: LiveSource {
        LiveSource(name: "Redis", address: "127.0.0.1:6379", channels: "jet1090 ship162")
    }

    var channelList: [String] {
        channels.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
    }
}

extension LiveSource {
    /// Parses redis://host:port/channel1,channel2.
    init?(url text: String) {
        guard let url = URL(string: text), url.scheme == "redis", let host = url.host else { return nil }
        let channels = url.path.split(separator: "/").joined(separator: " ").replacingOccurrences(of: ",", with: " ")
        self.init(
            name: "Redis \(host)",
            address: url.port.map { "\(host):\($0)" } ?? host,
            channels: channels.isEmpty ? LiveSource.template.channels : channels
        )
    }
}

/// Subscribes to one live source, parses what arrives and delivers batches
/// twice a second. Reconnects after failures until stopped.
final class LiveFeed: @unchecked Sendable {
    enum Status: Sendable, Equatable {
        case connecting
        case connected
        case failed(String)
    }

    private enum Node {
        case bulk(Range<Int>)
        case array([Node])
        case other
    }

    private static let retryDelay = 3.0

    private let source: LiveSource
    private let queue = DispatchQueue(label: "travel.live")
    private let onStatus: @Sendable (Status) -> Void
    private let onBatch: @Sendable ([Series]) -> Void

    // Touched only on `queue`.
    private var stopped = false
    private var attempt = 0
    private var buffer: [UInt8] = []
    private let builder = Builder()
    private var timer: DispatchSourceTimer?
    private var connection: NWConnection?

    init(
        source: LiveSource,
        onStatus: @escaping @Sendable (Status) -> Void,
        onBatch: @escaping @Sendable ([Series]) -> Void
    ) {
        self.source = source
        self.onStatus = onStatus
        self.onBatch = onBatch
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let batch = self.builder.take()
                if !batch.isEmpty { self.onBatch(batch) }
            }
            timer.resume()
            self.timer = timer
            self.connect()
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.timer?.cancel()
            self.timer = nil
            self.disconnect()
        }
    }

    // MARK: Connection (on `queue`)

    private func connect() {
        guard !stopped else { return }
        attempt += 1
        let current = attempt
        buffer.removeAll()
        onStatus(.connecting)

        let parts = source.address.split(separator: ":")
        guard let host = parts.first, parts.count <= 2,
              let port = parts.count == 2 ? UInt16(parts[1]) : 6379,
              let endpoint = NWEndpoint.Port(rawValue: port)
        else {
            fail("Address must be host:port", attempt: current, retry: false)
            return
        }
        guard !source.channelList.isEmpty else {
            fail("No channel to subscribe to", attempt: current, retry: false)
            return
        }

        let connection = NWConnection(host: NWEndpoint.Host(String(host)), port: endpoint, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, current == self.attempt else { return }
            switch state {
            case .ready:
                let command = "SUBSCRIBE \(self.source.channelList.joined(separator: " "))\r\n"
                connection.send(content: Data(command.utf8), completion: .contentProcessed { _ in })
                self.onStatus(.connected)
                self.receive(connection, attempt: current)
            case let .waiting(error), let .failed(error):
                self.fail(error.localizedDescription, attempt: current)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func disconnect() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    /// Reports the failure and retries later, unless it is from a stale attempt.
    private func fail(_ message: String, attempt failed: Int, retry: Bool = true) {
        guard !stopped, failed == attempt else { return }
        disconnect()
        onStatus(.failed(message))
        guard retry else { return }
        queue.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
            guard let self, failed == self.attempt else { return }
            self.connect()
        }
    }

    private func receive(_ connection: NWConnection, attempt current: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] data, _, isComplete, error in
            guard let self, current == self.attempt, !self.stopped else { return }
            if let data, !data.isEmpty {
                self.buffer.append(contentsOf: data)
                self.drain()
            }
            if isComplete || error != nil {
                self.fail(error?.localizedDescription ?? "Connection closed", attempt: current)
            } else {
                self.receive(connection, attempt: current)
            }
        }
    }

    // MARK: Parsing (on `queue`)

    /// Parses every complete RESP value in the buffer and ingests message payloads.
    private func drain() {
        var consumed = 0
        buffer.withUnsafeBytes { bytes in
            while consumed < bytes.count {
                var position = consumed
                guard let node = Self.parse(bytes, &position) else { break }
                consumed = position
                // Pushed messages are ["message", channel, payload].
                if case let .array(items) = node, items.count == 3,
                   case let .bulk(kind) = items[0], kind.count == 7, bytes[kind.lowerBound] == UInt8(ascii: "m"),
                   case let .bulk(payload) = items[2] {
                    builder.ingest(line: UnsafeRawBufferPointer(rebasing: bytes[payload]))
                }
            }
        }
        buffer.removeFirst(consumed)
    }

    /// Returns nil when the value is not complete yet.
    private static func parse(_ bytes: UnsafeRawBufferPointer, _ position: inout Int) -> Node? {
        guard position < bytes.count else { return nil }
        let type = bytes[position]
        guard let line = readLine(bytes, &position) else { return nil }
        switch type {
        case UInt8(ascii: "*"):
            let count = integer(bytes, line)
            guard count > 0 else { return .other }
            var items: [Node] = []
            for _ in 0..<count {
                guard let item = parse(bytes, &position) else { return nil }
                items.append(item)
            }
            return .array(items)
        case UInt8(ascii: "$"):
            let length = integer(bytes, line)
            guard length >= 0 else { return .other }
            guard position + length + 2 <= bytes.count else { return nil }
            let range = position..<(position + length)
            position += length + 2
            return .bulk(range)
        default:
            return .other
        }
    }

    /// Reads up to CRLF; returns the content after the type byte.
    private static func readLine(_ bytes: UnsafeRawBufferPointer, _ position: inout Int) -> Range<Int>? {
        var i = position
        while i + 1 < bytes.count {
            if bytes[i] == 0x0D, bytes[i + 1] == 0x0A {
                let range = (position + 1)..<i
                position = i + 2
                return range
            }
            i += 1
        }
        return nil
    }

    private static func integer(_ bytes: UnsafeRawBufferPointer, _ range: Range<Int>) -> Int {
        Int(String(decoding: UnsafeRawBufferPointer(rebasing: bytes[range]), as: UTF8.self)) ?? -1
    }
}
