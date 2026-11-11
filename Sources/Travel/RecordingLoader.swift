import Foundation
import libzstd

/// Reads jet1090 and ship162 decoded output: one JSON object per line,
/// optionally zstd-compressed (`.jsonl`, `.jsonl.zst`).
enum RecordingLoader {
    enum LoadError: LocalizedError {
        case unreadable(String)
        case corrupt(String)
        case empty

        var errorDescription: String? {
            switch self {
            case let .unreadable(name): "Cannot read \(name)."
            case let .corrupt(name): "\(name) is not a valid zstd file."
            case .empty: "No aircraft or ship messages found."
            }
        }
    }

    private static let blockSize = 4 << 20

    static func isSupported(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst") || name.hasSuffix(".json.zst")
    }

    /// Blocking; call off the main thread. `progress` receives 0...1.
    static func load(_ urls: [URL], progress: @escaping @Sendable (Double) -> Void) throws -> [Series] {
        let sizes = urls.map { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        let total = Double(max(1, sizes.reduce(0, +)))
        var done = 0.0
        let master = Builder()
        let workers = max(2, ProcessInfo.processInfo.activeProcessorCount)

        for url in urls {
            let name = url.lastPathComponent
            guard let handle = try? FileHandle(forReadingFrom: url) else { throw LoadError.unreadable(name) }
            defer { try? handle.close() }
            let stream = name.lowercased().hasSuffix(".zst") ? ZSTD_createDCtx() : nil
            defer { if let stream { ZSTD_freeDCtx(stream) } }
            var output = [UInt8](repeating: 0, count: ZSTD_DStreamOutSize())

            // Text accumulates in `carry`, is cut into blocks at line ends,
            // and blocks are parsed in parallel then merged in order.
            var carry: [UInt8] = []
            var blocks: [[UInt8]] = []

            func parseBlocks() {
                guard !blocks.isEmpty else { return }
                let builders = blocks.map { _ in Builder() }
                let pending = blocks
                DispatchQueue.concurrentPerform(iterations: pending.count) { i in
                    pending[i].withUnsafeBytes { builders[i].ingest(block: $0) }
                }
                for builder in builders { master.merge(builder.take()) }
                blocks.removeAll()
            }

            func cut(final: Bool) {
                guard carry.count >= blockSize || (final && !carry.isEmpty) else { return }
                if final {
                    blocks.append(carry)
                    carry = []
                } else if let newline = carry.lastIndex(of: 0x0A) {
                    blocks.append(Array(carry[...newline]))
                    carry = Array(carry[(newline + 1)...])
                }
                if blocks.count >= workers || final { parseBlocks() }
            }

            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                try chunk.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                    guard let stream else {
                        carry.append(contentsOf: source)
                        return
                    }
                    var input = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)
                    while input.pos < input.size {
                        try output.withUnsafeMutableBytes { destination in
                            var out = ZSTD_outBuffer(dst: destination.baseAddress, size: destination.count, pos: 0)
                            let code = ZSTD_decompressStream(stream, &out, &input)
                            if ZSTD_isError(code) != 0 { throw LoadError.corrupt(name) }
                            carry.append(contentsOf: UnsafeRawBufferPointer(rebasing: destination[0..<out.pos]))
                        }
                    }
                }
                cut(final: false)
                done += Double(chunk.count)
                progress(min(1, done / total))
            }
            cut(final: true)
            parseBlocks()
        }

        var series = master.take()
        guard !series.isEmpty else { throw LoadError.empty }
        for i in series.indices { series[i].sortIfNeeded() }
        return series
    }
}
