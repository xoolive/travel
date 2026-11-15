import Foundation
import SQLite3

/// One of the user's own flights, as the Flighty app knows it.
struct OwnFlight: Sendable, Equatable {
    /// Airline IATA code and number, such as AF7403.
    var number: String
    var origin: String
    var destination: String
    var destinationPosition: LatLon
    var tail: String?
    var aircraftType: String?
    /// Best known departure and arrival times (actual, else estimated, else scheduled).
    var departure: Double
    var arrival: Double

    /// Whether `t` falls during the flight, with half an hour either side.
    func covers(_ t: Double) -> Bool {
        t >= departure - 1800 && t <= arrival + 1800
    }
}

/// Reads the user's own flights from the Flighty app's local database,
/// read-only. The database is private to Flighty and may change with its
/// updates; only the main account's own flights are read, nothing else.
enum Flighty {
    static let database = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.flightyapp.flighty/Data/Documents/MainFlightyDatabase.db")

    private static let query = """
        SELECT coalesce(l.iata, l.icao, '') || f.number,
               coalesce(a.icao, a.iata, ''), coalesce(b.icao, b.iata, ''), b.latitude, b.longitude,
               f.equipmentTailNumber, f.equipmentIcao,
               coalesce(f.departureScheduleRunwayActual, f.departureScheduleGateActual,
                        f.departureScheduleRunwayEstimated, f.departureScheduleGateEstimated,
                        f.departureScheduleGateOriginal, f.lastKnownDepartureDate),
               coalesce(f.arrivalScheduleRunwayActual, f.arrivalScheduleGateActual,
                        f.arrivalScheduleRunwayEstimated, f.arrivalScheduleGateEstimated,
                        f.arrivalScheduleGateOriginal, f.lastKnownArrivalDate)
        FROM Flight f
        JOIN UserFlight u ON u.flightId = f.id AND u.isMyFlight = 1 AND u.deleted IS NULL
        JOIN User me ON me.remoteId = u.userId
        JOIN Account account ON account.id = me.accountId AND account.rawKind = 'main'
        JOIN Airport a ON a.id = f.departureAirportId
        JOIN Airport b ON b.id = f.scheduledArrivalAirportId
        LEFT JOIN Airline l ON l.id = f.airlineId
        GROUP BY f.id
        """

    /// The user's own flights; empty when Flighty is absent or unreadable.
    static func ownFlights() -> [OwnFlight] {
        // immutable=1: never take a lock or write, even while Flighty runs.
        var url = URLComponents(url: database, resolvingAgainstBaseURL: false)!
        url.scheme = "file"
        url.queryItems = [URLQueryItem(name: "mode", value: "ro"), URLQueryItem(name: "immutable", value: "1")]
        var connection: OpaquePointer?
        guard FileManager.default.isReadableFile(atPath: database.path),
              sqlite3_open_v2(url.string, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
        else {
            sqlite3_close(connection)
            return []
        }
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        func text(_ column: Int32) -> String? {
            guard let bytes = sqlite3_column_text(statement, column) else { return nil }
            let value = String(cString: bytes).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        var flights: [OwnFlight] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let departure = sqlite3_column_double(statement, 7)
            let arrival = sqlite3_column_double(statement, 8)
            guard departure > 0, arrival > departure else { continue }
            flights.append(OwnFlight(
                number: text(0) ?? "",
                origin: text(1) ?? "",
                destination: text(2) ?? "",
                destinationPosition: LatLon(latitude: sqlite3_column_double(statement, 3),
                                            longitude: sqlite3_column_double(statement, 4)),
                tail: text(5),
                aircraftType: text(6),
                departure: departure,
                arrival: arrival
            ))
        }
        return flights.sorted { $0.departure < $1.departure }
    }
}
