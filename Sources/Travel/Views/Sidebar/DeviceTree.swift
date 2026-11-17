import SwiftUI

/// The USB devices as a tree, the way `cyme --tree` draws it. Receivers can
/// be picked; hubs and other devices are shown to explain the wiring.
struct DeviceTree: View {
    private struct Row: Identifiable {
        let id: String
        /// Tree guides drawn before the device.
        let guides: String
        let device: UsbDevice?
        let bus: UsbBus?
    }

    @Bindable var state: AppState
    /// The source being edited, which may keep its own receiver.
    let editing: UUID
    @Binding var picked: Int?

    var body: some View {
        let rows = flatten()
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("USB DEVICES")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    state.usb.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Read the USB devices again")
            }
            .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        if let bus = row.bus {
                            busRow(bus)
                        } else if let device = row.device {
                            deviceRow(device, guides: row.guides)
                        }
                    }
                    if state.usb.receivers.isEmpty {
                        Text("No receiver plugged in")
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 220)
            .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func busRow(_ bus: UsbBus) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu")
                .foregroundStyle(.secondary)
            Text("Bus \(bus.number)")
                .fontWeight(.semibold)
            Text(bus.controller)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.top, 4)
        .frame(height: 24)
    }

    private func deviceRow(_ device: UsbDevice, guides: String) -> some View {
        let taken = takenBy(device)
        let selectable = device.sdr != nil && taken == nil
        let selected = selectable && picked == device.locationID
        return HStack(spacing: 6) {
            Text(guides)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.tertiary)
            Image(systemName: device.sdr != nil ? "antenna.radiowaves.left.and.right" : (device.isHub ? "point.3.connected.trianglepath.dotted" : "cable.connector"))
                .foregroundStyle(device.sdr != nil ? Color.accentColor : .secondary)
                .frame(width: 16)
            Text(device.sdr?.name ?? device.product)
                .fontWeight(device.sdr != nil ? .semibold : .regular)
                .foregroundStyle(device.sdr != nil ? .primary : .secondary)
            if let serial = device.serial, device.sdr != nil {
                Text(serial)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let taken {
                Text("Added as \(taken)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if device.sdr != nil, let owner = device.owner {
                Text("In use by \(owner)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(device.portPath)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(device.identifiers)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .padding(.horizontal, 4)
        .frame(height: 24)
        .background(selected ? Color.accentColor.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { if selectable { picked = device.locationID } }
        .help(device.sdr.map { "\($0.name) · desperado driver: \($0.driver)" } ?? device.product)
    }

    /// Name of another source already using this receiver.
    private func takenBy(_ device: UsbDevice) -> String? {
        state.liveSources.first { $0.id != editing && $0.device?.match(in: state.usb.receivers) == device }?.name
    }

    private func flatten() -> [Row] {
        var rows: [Row] = []
        func walk(_ devices: [UsbDevice], prefix: String) {
            for (i, device) in devices.enumerated() {
                let last = i == devices.count - 1
                rows.append(Row(id: "d\(device.locationID)", guides: prefix + (last ? "└─" : "├─"), device: device, bus: nil))
                walk(device.children, prefix: prefix + (last ? "   " : "│  "))
            }
        }
        for bus in state.usb.buses {
            rows.append(Row(id: "b\(bus.number)", guides: "", device: nil, bus: bus))
            walk(bus.devices, prefix: "")
        }
        return rows
    }
}
