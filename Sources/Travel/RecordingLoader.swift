import Foundation
import libzstd

/// Reads jet1090 and ship162 decoded output: one JSON object per line,
/// plain or compressed (`.jsonl`, `.jsonl.zst`, `.jsonl.7z`).
enum RecordingLoader {
    enum LoadError: LocalizedError {
        case unreadable(String)
        case corrupt(String)
        case empty

        var errorDescription: String? {
            switch self {
            case let .unreadable(name): "Cannot read \(name): the file is missing or not readable."
            case let .corrupt(name): "\(name) is not a valid archive."
            case .empty: "No aircraft or ship messages found."
            }
        }
    }

    private static let blockSize = 4 << 20
    private static let suffixes = [".jsonl", ".jsonl.zst", ".json.zst", ".jsonl.7z", ".json.7z"]
    /// The system tar (libarchive) reads 7z archives.
    private static let tar = "/usr/bin/tar"

    static func isSupported(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return suffixes.contains { name.hasSuffix($0) }
    }

    /// Blocking; call off the main thread. `progress` receives 0...1.
    static func load(_ urls: [URL], progress: @escaping @Sendable (Double) -> Void) throws -> [Series] {
        let master = Builder()
        let workers = max(2, ProcessInfo.processInfo.activeProcessorCount)

        for (fileIndex, url) in urls.enumerated() {
            let name = url.lastPathComponent
            guard FileManager.default.isReadableFile(atPath: url.path) else { throw LoadError.unreadable(name) }
            let report: (Double) -> Void = { fraction in
                progress((Double(fileIndex) + min(1, fraction)) / Double(urls.count))
            }

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

            func consume(_ bytes: UnsafeRawBufferPointer) {
                carry.append(contentsOf: bytes)
                guard carry.count >= blockSize, let newline = carry.lastIndex(of: 0x0A) else { return }
                blocks.append(Array(carry[...newline]))
                carry = Array(carry[(newline + 1)...])
                if blocks.count >= workers { parseBlocks() }
            }

            if name.lowercased().hasSuffix(".7z") {
                try readArchive(url, consume: consume, report: report)
            } else {
                try readFile(url, consume: consume, report: report)
            }
            if !carry.isEmpty { blocks.append(carry) }
            parseBlocks()
        }

        var series = master.take()
        guard !series.isEmpty else { throw LoadError.empty }
        for i in series.indices { series[i].sortIfNeeded() }
        return series
    }

    /// Plain or zstd-compressed text.
    private static func readFile(
        _ url: URL,
        consume: (UnsafeRawBufferPointer) -> Void,
        report: (Double) -> Void
    ) throws {
        let name = url.lastPathComponent
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw LoadError.unreadable(name) }
        defer { try? handle.close() }
        let total = Double(max(1, (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1))
        let stream = name.lowercased().hasSuffix(".zst") ? ZSTD_createDCtx() : nil
        defer { if let stream { ZSTD_freeDCtx(stream) } }
        var output = [UInt8](repeating: 0, count: ZSTD_DStreamOutSize())
        var done = 0.0

        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            try chunk.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                guard let stream else {
                    consume(source)
                    return
                }
                var input = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)
                while input.pos < input.size {
                    try output.withUnsafeMutableBytes { destination in
                        var out = ZSTD_outBuffer(dst: destination.baseAddress, size: destination.count, pos: 0)
                        let code = ZSTD_decompressStream(stream, &out, &input)
                        if ZSTD_isError(code) != 0 { throw LoadError.corrupt(name) }
                        consume(UnsafeRawBufferPointer(rebasing: destination[0..<out.pos]))
                    }
                }
            }
            done += Double(chunk.count)
            report(done / total)
        }
    }

    /// A 7z archive, extracted to a pipe by the system tar.
    private static func readArchive(
        _ url: URL,
        consume: (UnsafeRawBufferPointer) -> Void,
        report: (Double) -> Void
    ) throws {
        let name = url.lastPathComponent
        let total = Double(max(1, archiveSize(url)))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tar)
        process.arguments = ["-xOf", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw LoadError.unreadable(name) }
        defer { if process.isRunning { process.terminate() } }

        var done = 0.0
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            chunk.withUnsafeBytes { consume($0) }
            done += Double(chunk.count)
            report(done / total)
        }
        process.waitUntilExit()
        if process.terminationStatus != 0, done == 0 { throw LoadError.corrupt(name) }
    }

    /// Total uncompressed size listed in the archive, for the progress bar.
    private static func archiveSize(_ url: URL) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tar)
        process.arguments = ["-tvf", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return 0 }
        let listing = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        // Lines look like: -rw-r--r--  0 0  0  250697504 May  7  2026 name
        return listing.split(separator: "\n").reduce(0) { sum, line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            return sum + (fields.count > 4 ? Int(fields[4]) ?? 0 : 0)
        }
    }
}
