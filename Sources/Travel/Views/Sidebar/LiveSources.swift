import SwiftUI

/// One live source: status, and a button to start or stop it.
struct LiveRow: View {
    @Bindable var state: AppState
    let source: LiveSource
    let onEdit: () -> Void

    var body: some View {
        let running = state.isRunning(source)
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if source.isDevice {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(source.name)
                        .lineLimit(1)
                }
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if !source.isDevice {
                Button {
                    state.toggle(source)
                } label: {
                    Image(systemName: running ? "stop.fill" : "play.fill")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .help(running ? "Stop" : "Start")
            }
        }
        .help(help)
        .contextMenu {
            if !source.isDevice {
                Button(running ? "Stop" : "Start") { state.toggle(source) }
            }
            Button("Edit…", action: onEdit)
            Button("Remove") { state.remove(source) }
            Divider()
            Button("Clear Live Data") { state.clearLive() }
        }
    }

    private var help: String {
        guard let device = source.device else { return "Redis \(source.address) · \(source.channels)" }
        return [device.model, device.serial.map { "serial \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    private var color: Color {
        if source.isDevice {
            guard let receiver = state.receiver(for: source) else { return .gray }
            return receiver.owner == nil ? .blue : .orange
        }
        switch state.status(of: source) {
        case .off: return .gray
        case .connecting: return .yellow
        case .connected: return .green
        case .failed: return .red
        }
    }

    private var caption: String {
        if source.isDevice {
            guard let receiver = state.receiver(for: source) else { return "Unplugged" }
            if let owner = receiver.owner { return "In use by \(owner)" }
            return "Port \(receiver.portPath) · no decoder yet"
        }
        switch state.status(of: source) {
        case .off: return source.address
        case .connecting: return "Connecting…"
        case .connected: return "Connected · \(source.address)"
        case let .failed(message): return "\(message) · retrying"
        }
    }
}

struct LiveSourceEditor: View {
    enum Mode: String, CaseIterable, Identifiable {
        case receiver = "Receiver"
        case redis = "Redis"

        var id: String { rawValue }
    }

    @Bindable var state: AppState
    @State var source: LiveSource
    let isNew: Bool
    let onSave: (LiveSource) -> Void
    @State private var mode: Mode
    @State private var picked: Int?
    @Environment(\.dismiss) private var dismiss

    init(state: AppState, source: LiveSource, isNew: Bool, onSave: @escaping (LiveSource) -> Void) {
        self.state = state
        var source = source
        // A new source is named after what is picked, unless given a name.
        if isNew { source.name = "" }
        _source = State(initialValue: source)
        self.isNew = isNew
        self.onSave = onSave
        _mode = State(initialValue: source.isDevice || isNew ? .receiver : .redis)
        _picked = State(initialValue: source.device?.match(in: state.usb.receivers)?.locationID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Live Source" : "Edit Live Source")
                .font(.headline)
            if isNew {
                Picker("Kind", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            switch mode {
            case .receiver:
                DeviceTree(state: state, editing: source.id, picked: $picked)
                Form {
                    TextField("Name", text: $source.name, prompt: Text(pickedDevice?.sdr?.name ?? "Receiver"))
                }
                Text("Receivers are listed as they are plugged in. Connecting one to a decoder (jet1090, ship162) comes next.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .redis:
                Form {
                    TextField("Name", text: $source.name, prompt: Text("Redis"))
                    TextField("Address", text: $source.address, prompt: Text("127.0.0.1:6379"))
                    TextField("Channels", text: $source.channels, prompt: Text("jet1090 ship162"))
                }
                Text("Redis pub/sub channels carrying jet1090 or ship162 decoded JSON.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: mode == .receiver ? 560 : 400)
    }

    private var pickedDevice: UsbDevice? {
        state.usb.receivers.first { $0.locationID == picked }
    }

    private var canSave: Bool {
        switch mode {
        case .receiver: pickedDevice != nil
        case .redis: !source.address.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func save() {
        var saved = source
        saved.name = saved.name.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .receiver:
            guard let device = pickedDevice else { return }
            saved.device = LiveSource.Device(device)
            if saved.name.isEmpty {
                saved.name = device.sdr?.name ?? device.product
            }
        case .redis:
            saved.device = nil
            saved.address = saved.address.trimmingCharacters(in: .whitespaces)
            if saved.name.isEmpty { saved.name = "Redis" }
        }
        onSave(saved)
        dismiss()
    }
}
