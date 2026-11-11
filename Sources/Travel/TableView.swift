import SwiftUI

private typealias Column = TableColumn<Entity, KeyPathComparator<Entity>, Text, Text>

private let clockFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "HH:mm:ss"
    return formatter
}()

/// Sortable state table, with the columns of the jet1090 terminal interface.
struct EntityTable: View {
    @Bindable var state: AppState
    @State private var kind: Kind = .aircraft
    @State private var order = [KeyPathComparator(\Entity.nameKey)]
    @State private var search = ""

    private var rows: [Entity] {
        state.entities
            .filter { $0.kind == kind }
            .filter {
                search.isEmpty
                    || $0.nameKey.localizedCaseInsensitiveContains(search)
                    || $0.id.localizedCaseInsensitiveContains(search)
            }
            .sorted(using: order)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Kind", selection: $kind) {
                    Text("Aircraft").tag(Kind.aircraft)
                    Text("Ships").tag(Kind.ship)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text("\(rows.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                TextField("Filter", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
            .padding(8)

            if kind == .aircraft {
                Table(rows, selection: $state.selectedID, sortOrder: $order) {
                    aircraftIdentity
                    aircraftMotion
                    activity
                }
            } else {
                Table(rows, selection: $state.selectedID, sortOrder: $order) {
                    shipColumns
                    activity
                }
            }
        }
        .font(.callout.monospacedDigit())
        .onChange(of: state.dataset?.id, initial: true) {
            guard let dataset = state.dataset, !dataset.isLive else { return }
            kind = dataset.count(of: .aircraft) == 0 ? .ship : .aircraft
        }
    }

    private func number(_ title: String, _ channel: Channel, _ format: String = "%.0f") -> Column {
        TableColumn(title, value: \Entity[sort: channel]) { entity in
            Text(entity[channel].map { String(format: format, $0) } ?? "")
        }
        .width(min: 40, ideal: 58)
    }

    @TableColumnBuilder<Entity, KeyPathComparator<Entity>>
    private var aircraftIdentity: some TableColumnContent<Entity, KeyPathComparator<Entity>> {
        TableColumn("icao24", value: \Entity.id) { Text($0.id) }
            .width(min: 40, ideal: 64)
        TableColumn("callsign", value: \Entity.nameKey) { Text($0.nameKey) }
        TableColumn("sqwk", value: \Entity.squawkKey) { Text($0.squawkKey) }
            .width(min: 40, ideal: 48)
        TableColumn("lat", value: \Entity.latitudeKey) { Text($0.latitude.map { String(format: "%.3f", $0) } ?? "") }
            .width(min: 40, ideal: 70)
        TableColumn("lon", value: \Entity.longitudeKey) { Text($0.longitude.map { String(format: "%.3f", $0) } ?? "") }
            .width(min: 40, ideal: 70)
        number("alt", .altitude)
        number("sel", .selectedAltitude)
    }

    @TableColumnBuilder<Entity, KeyPathComparator<Entity>>
    private var aircraftMotion: some TableColumnContent<Entity, KeyPathComparator<Entity>> {
        number("gs", .groundspeed)
        number("tas", .tas)
        number("ias", .ias)
        number("mach", .mach, "%.2f")
        number("vrate", .verticalRate)
        number("trk", .track)
        number("hdg", .heading)
        number("roll", .roll, "%.1f")
        number("nac", .nacp)
    }

    @TableColumnBuilder<Entity, KeyPathComparator<Entity>>
    private var shipColumns: some TableColumnContent<Entity, KeyPathComparator<Entity>> {
        TableColumn("mmsi", value: \Entity.id) { Text($0.id) }
            .width(min: 40, ideal: 84)
        TableColumn("name", value: \Entity.nameKey) { Text($0.nameKey) }
        TableColumn("flag", value: \Entity.flagKey) { Text([$0.info.flag, $0.info.country].compactMap { $0 }.joined(separator: " ")) }
        TableColumn("type", value: \Entity.shipTypeKey) { Text($0.shipTypeKey) }
        TableColumn("status", value: \Entity.statusKey) { Text($0.statusKey) }
        TableColumn("lat", value: \Entity.latitudeKey) { Text($0.latitude.map { String(format: "%.4f", $0) } ?? "") }
            .width(min: 40, ideal: 70)
        TableColumn("lon", value: \Entity.longitudeKey) { Text($0.longitude.map { String(format: "%.4f", $0) } ?? "") }
            .width(min: 40, ideal: 70)
        number("speed", .groundspeed, "%.1f")
        number("course", .track)
        number("hdg", .heading)
    }

    @TableColumnBuilder<Entity, KeyPathComparator<Entity>>
    private var activity: some TableColumnContent<Entity, KeyPathComparator<Entity>> {
        TableColumn("dest", value: \Entity.destinationKey) { Text($0.destinationKey) }
        TableColumn("count", value: \Entity.count) { Text("\($0.count)") }
            .width(min: 40, ideal: 56)
        TableColumn("last", value: \Entity.lastSeen) { entity in
            Text("\(Int(max(0, state.currentTime - entity.lastSeen)))s")
        }
        TableColumn("first", value: \Entity.firstSeen) { entity in
            Text(clockFormatter.string(from: Date(timeIntervalSince1970: entity.firstSeen)))
        }
    }
}
