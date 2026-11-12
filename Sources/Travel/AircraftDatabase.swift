import Foundation
import SQLite3
import zlib

/// Registration and type of aircraft by ICAO 24-bit address, from the
/// database jet1090 downloads or from a file chosen by the user.
@MainActor
final class AircraftDatabase {
    struct Record: Sendable {
        var registration: String?
        var typecode: String?
    }

    enum Source: Equatable {
        /// The BaseStation database cached by jet1090.
        case jet1090
        /// A `.csv` or `.csv.gz` table with `icao24`, `registration` and
        /// `typecode` columns, or a BaseStation `.sqb` database.
        case file(URL)

        var url: URL {
            switch self {
            case .jet1090:
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Caches/jet1090/basestation.sqb")
            case let .file(url): url
            }
        }

        var label: String {
            switch self {
            case .jet1090: "jet1090 database"
            case let .file(url): url.lastPathComponent
            }
        }
    }

    let source: Source
    /// Empty when the database is usable.
    private(set) var problem = ""

    private var table: [String: Record] = [:]
    private var connection: OpaquePointer?
    private var statement: OpaquePointer?

    /// Opens a SQLite database at once; a CSV table must be read first with
    /// `Self.readTable`, off the main thread, and passed in.
    init(source: Source, table: [String: Record]? = nil) {
        self.source = source
        let path = source.url.path
        guard FileManager.default.isReadableFile(atPath: path) else {
            problem = "\(source.label) not found"
            return
        }
        if let table {
            self.table = table
            if table.isEmpty { problem = "No aircraft found in \(source.label)" }
        } else if sqlite3_open_v2(path, &connection, SQLITE_OPEN_READONLY, nil) != SQLITE_OK
            || sqlite3_prepare_v2(
                connection, "SELECT Registration, ICAOTypeCode FROM Aircraft WHERE ModeS = ?1", -1, &statement, nil
            ) != SQLITE_OK {
            problem = "Cannot read \(source.label)"
            statement = nil
        }
    }

    deinit {
        sqlite3_finalize(statement)
        sqlite3_close(connection)
    }

    static func isTable(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".csv") || name.hasSuffix(".csv.gz")
    }

    func lookup(_ icao24: String) -> Record? {
        if let known = table[icao24] { return known }
        guard let statement else { return nil }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_reset(statement)
        sqlite3_bind_text(statement, 1, icao24.uppercased(), -1, transient)
        var record = Record()
        if sqlite3_step(statement) == SQLITE_ROW {
            record.registration = Self.text(statement, 0)
            record.typecode = Self.text(statement, 1)?.uppercased()
        }
        // Remembered, found or not.
        table[icao24] = record
        return record
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, column) else { return nil }
        let value = String(cString: bytes).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// Reads a CSV table, gzip-compressed or not. Blocking.
    nonisolated static func readTable(_ url: URL) -> [String: Record] {
        guard let file = gzopen(url.path, "rb") else { return [:] }
        defer { gzclose(file) }
        var buffer = [CChar](repeating: 0, count: 1 << 16)
        func nextLine() -> String? {
            guard gzgets(file, &buffer, Int32(buffer.count)) != nil else { return nil }
            return String(cString: buffer).trimmingCharacters(in: .newlines)
        }

        guard let header = nextLine()?.lowercased().split(separator: ",", omittingEmptySubsequences: false),
              let icao = header.firstIndex(of: "icao24")
        else { return [:] }
        let registration = header.firstIndex(of: "registration")
        let typecode = header.firstIndex(of: "typecode")
        // Later columns may contain quoted commas; only the leading ones are read.
        let needed = max(icao, registration ?? 0, typecode ?? 0)

        var table: [String: Record] = [:]
        while let line = nextLine() {
            let fields = line.split(separator: ",", maxSplits: needed + 1, omittingEmptySubsequences: false)
            guard fields.count > needed else { continue }
            func field(_ index: Int?) -> String? {
                guard let index else { return nil }
                let value = fields[index].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                return value.isEmpty ? nil : value
            }
            guard let id = field(icao)?.lowercased() else { continue }
            let record = Record(registration: field(registration), typecode: field(typecode)?.uppercased())
            if record.registration != nil || record.typecode != nil { table[id] = record }
        }
        return table
    }
}
