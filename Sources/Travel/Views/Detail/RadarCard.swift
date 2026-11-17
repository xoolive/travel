import SwiftUI

/// A radar chosen on the map: what the catalogue says about the site, and how
/// each of its codes fits the data. Stays open until closed; meanwhile the
/// aircraft it interrogates stay coloured on the map.
struct RadarCard: View {
    let radar: RadarMark
    let aircraft: Int
    let close: () -> Void

    private static let basis = [
        "located": "Reviewed installation",
        "approximate": "Approximate area",
        "historical": "Historical directory (2014, unverified)",
        "airport": "Airport area of the catalogue name",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(radar.label)
                    .font(.title3.weight(.semibold).monospaced())
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(radar.name).font(.callout)
                Text(Self.basis[radar.basis] ?? radar.basis)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            ForEach(radar.fits, id: \.code) { fit in
                HStack(alignment: .firstTextBaseline) {
                    Text(fit.code).font(.callout.monospaced().weight(.medium))
                    Text(fit.period.map { String(format: "%.2f s", $0) } ?? "–")
                        .font(.callout.monospacedDigit())
                    Spacer()
                    Text(fit.consistent ? "consistent" : "weak")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(fit.consistent ? Color.green : Color.orange)
                }
                Text("\(fit.aircraft) of \(fit.located) aircraft, median \(Int(fit.medianDistance / 1000)) km")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            Text(radar.heard ? "Interrogating \(aircraft) aircraft now, in teal" : "Not heard in the last 2 minutes")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }
}
