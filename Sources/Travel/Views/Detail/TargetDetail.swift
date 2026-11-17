import SwiftUI

/// The filed flight plan of an aircraft: route, times and ICAO field 15.
struct FlightPlanView: View {
    let plan: FlightPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("FLIGHT PLAN")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text([plan.callsign, plan.aircraftType].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text("\(plan.departure) → \(plan.destination) · EOBT \(plan.eobt.split(separator: " ").last.map(String.init) ?? plan.eobt)")
                .font(.callout)
            Text(plan.route)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The selected aircraft or ship: current state and plots over time.
struct TargetDetail: View {
    @Bindable var state: AppState
    let id: String

    var body: some View {
        let entity = state.selected
        let kind = entity?.kind ?? state.dataset?.kind(of: id) ?? .aircraft
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                // The only way to deselect: clicking the map does not.
                CloseButton { state.selectedID = nil }
            }
            .padding(.horizontal, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entity?.label ?? state.dataset?.name(of: id) ?? id.uppercased())
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(subtitle(entity))
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let entity {
                        fields(entity)
                    } else {
                        Text("Not received at this time")
                            .foregroundStyle(.secondary)
                    }

                    if let plan = state.flightPlan(for: id, callsign: entity?.name ?? state.dataset?.name(of: id)) {
                        Divider()
                        FlightPlanView(plan: plan)
                    }

                    Divider()
                    PlotStack(state: state, id: id, kind: kind)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }

    private func subtitle(_ entity: Entity?) -> String {
        var parts = [id.uppercased()]
        if let entity, entity.kind == .aircraft {
            parts.append(contentsOf: [entity.info.registration, entity.info.typecode].compactMap { $0 })
        }
        if let entity, entity.kind == .ship, let country = entity.info.country {
            parts.append(country)
        }
        let text = parts.joined(separator: " · ")
        return entity?.info.flag.map { "\($0) \(text)" } ?? text
    }

    @ViewBuilder
    private func fields(_ entity: Entity) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 10) {
            if entity.kind == .aircraft {
                GridRow {
                    field("Altitude", entity[.altitude].map { "\(Int($0).formatted()) ft" })
                    field("Ground speed", entity[.groundspeed].map { "\(Int($0)) kt" })
                }
                GridRow {
                    field("Vertical rate", entity[.verticalRate].map { "\(Int($0).formatted()) ft/min" })
                    field("Track", entity[.track].map(degrees))
                }
                GridRow {
                    field("Squawk", entity.info.squawk)
                    field("Mach", entity[.mach].map { String(format: "%.2f", $0) })
                }
            } else {
                GridRow {
                    field("Speed", entity[.groundspeed].map { String(format: "%.1f kn", $0) })
                    field("Course", entity[.track].map(degrees))
                }
                GridRow {
                    field("Type", entity.info.shipType)
                    field("Destination", entity.info.destination)
                }
                GridRow {
                    field("Status", entity.info.status)
                        .gridCellColumns(2)
                }
            }
        }
    }

    private func degrees(_ value: Double) -> String {
        String(format: "%03d°", Int(value.rounded()) % 360)
    }

    private func field(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value ?? "—")
                .font(.title3.monospacedDigit().weight(.medium))
                .lineLimit(1)
        }
    }
}
