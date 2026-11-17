import Foundation
import IOKit
import Observation

/// What an SDR receiver is, from its USB vendor and product identifiers.
struct SdrModel: Sendable, Equatable {
    let name: String
    /// The desperado feature that drives it.
    let driver: String

    private static let catalog: [UInt32: SdrModel] = [
        key(0x0BDA, 0x2838): SdrModel(name: "RTL-SDR", driver: "rtlsdr"),
        key(0x0BDA, 0x2832): SdrModel(name: "RTL-SDR", driver: "rtlsdr"),
        // The R2 and the Mini share their identifiers.
        key(0x1D50, 0x60A1): SdrModel(name: "Airspy R2 / Mini", driver: "airspy"),
        key(0x03EB, 0x800C): SdrModel(name: "Airspy HF+", driver: "airspy"),
        key(0x1D50, 0x6089): SdrModel(name: "HackRF One", driver: "hackrf"),
        key(0x1D50, 0xCC15): SdrModel(name: "rad1o", driver: "hackrf"),
        key(0x0456, 0xB673): SdrModel(name: "ADALM-Pluto", driver: "pluto"),
        key(0x2500, 0x0020): SdrModel(name: "USRP B200/B210", driver: "soapy"),
        key(0x2500, 0x0021): SdrModel(name: "USRP B200 mini", driver: "soapy"),
        key(0x2500, 0x0022): SdrModel(name: "USRP B205 mini", driver: "soapy"),
    ]

    private static func key(_ vendor: Int, _ product: Int) -> UInt32 {
        UInt32(vendor) << 16 | UInt32(product)
    }

    static func identify(vendor: Int, product: Int) -> SdrModel? {
        if let known = catalog[key(vendor, product)] { return known }
        // Every SDRplay RSP uses the same vendor identifier.
        if vendor == 0x1DF7 { return SdrModel(name: "SDRplay RSP", driver: "soapy") }
        return nil
    }
}

/// One USB device, with what is plugged into it when it is a hub.
struct UsbDevice: Identifiable, Sendable, Equatable {
    /// Bus number in the top byte, then one port number per nibble.
    let locationID: Int
    let vendorID: Int
    let productID: Int
    let product: String
    let manufacturer: String?
    let serial: String?
    /// The driver holding the device, when one does.
    let owner: String?
    let sdr: SdrModel?
    var children: [UsbDevice] = []

    var id: Int { locationID }
    var bus: Int { locationID >> 24 }

    /// Ports from the bus to the device, as `cyme` prints them.
    var ports: [Int] {
        var result: [Int] = []
        for shift in stride(from: 20, through: 0, by: -4) {
            let port = (locationID >> shift) & 0xF
            if port == 0 { break }
            result.append(port)
        }
        return result
    }

    var portPath: String { "\(bus)-" + ports.map(String.init).joined(separator: ".") }
    var identifiers: String { String(format: "%04x:%04x", vendorID, productID) }
    var isHub: Bool { !children.isEmpty || product.localizedCaseInsensitiveContains("hub") }
}

/// A USB host controller and the devices on its bus.
struct UsbBus: Identifiable, Sendable, Equatable {
    let number: Int
    let controller: String
    var devices: [UsbDevice]

    var id: Int { number }
}

/// The USB device tree, kept up to date as devices are plugged and unplugged.
@MainActor
@Observable
final class UsbMonitor {
    private(set) var buses: [UsbBus] = []

    @ObservationIgnored private var port: IONotificationPortRef?
    @ObservationIgnored private var iterators: [io_iterator_t] = []
    @ObservationIgnored private var pending: DispatchWorkItem?

    init() {
        refresh()
        watch()
    }

    /// Every SDR receiver, depth first.
    var receivers: [UsbDevice] {
        func collect(_ devices: [UsbDevice]) -> [UsbDevice] {
            devices.flatMap { ($0.sdr == nil ? [] : [$0]) + collect($0.children) }
        }
        return buses.flatMap { collect($0.devices) }
    }

    func refresh() {
        let devices = Self.enumerate()
        var controllers: [Int: String] = [:]
        for (device, controller) in devices { controllers[device.bus] = controller }

        // A device's parent is the one whose port path is its own minus the last port.
        var byLocation = Dictionary(uniqueKeysWithValues: devices.map { ($0.0.locationID, $0.0) })
        func parent(of device: UsbDevice) -> Int? {
            let depth = device.ports.count
            guard depth > 1 else { return nil }
            let shift = 24 - 4 * (depth - 1)
            return device.locationID & ~((1 << shift) - 1)
        }
        // Attach children from the deepest devices up.
        for device in devices.map(\.0).sorted(by: { $0.ports.count > $1.ports.count }) {
            guard let parentID = parent(of: device), byLocation[parentID] != nil,
                  let current = byLocation[device.locationID]
            else { continue }
            byLocation[parentID]!.children.append(current)
            byLocation[parentID]!.children.sort { $0.locationID < $1.locationID }
            byLocation[device.locationID] = nil
        }
        // What is left has no parent among the devices: it sits on the bus.
        let grouped = Dictionary(grouping: byLocation.values, by: \.bus)
        let result = grouped.keys.sorted().map { bus in
            UsbBus(
                number: bus,
                controller: controllers[bus] ?? "USB bus",
                devices: grouped[bus]!.sorted { $0.locationID < $1.locationID }
            )
        }
        if result != buses { buses = result }
    }

    // MARK: IOKit

    private static func enumerate() -> [(UsbDevice, String)] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [(UsbDevice, String)] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let location: Int = property(entry, "locationID"),
                  let vendor: Int = property(entry, "idVendor"),
                  let product: Int = property(entry, "idProduct")
            else { continue }
            let name: String = property(entry, "USB Product Name") ?? property(entry, "kUSBProductString") ?? "USB device"
            let device = UsbDevice(
                locationID: location,
                vendorID: vendor,
                productID: product,
                product: name,
                manufacturer: property(entry, "USB Vendor Name"),
                serial: property(entry, "USB Serial Number"),
                owner: property(entry, "UsbExclusiveOwner"),
                sdr: SdrModel.identify(vendor: vendor, product: product)
            )
            result.append((device, controller(of: entry)))
        }
        return result
    }

    private static func property<T>(_ entry: io_registry_entry_t, _ key: String) -> T? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? T
    }

    /// Class name of the host controller above a device, such as AppleT8122USBXHCI.
    private static func controller(of entry: io_registry_entry_t) -> String {
        var current = entry
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        while true {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, "IOUSB", &parent) == KERN_SUCCESS else { return "USB bus" }
            IOObjectRelease(current)
            current = parent
            var name = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(current, &name)
            let className = String(cString: name)
            if className != "IOUSBHostDevice" { return className }
        }
    }

    /// Re-reads the tree shortly after any device appears or goes away; the
    /// delay lets a new device publish its strings first.
    private func watch() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { context, iterator in
            // Draining the iterator re-arms the notification.
            while case let entry = IOIteratorNext(iterator), entry != 0 { IOObjectRelease(entry) }
            guard let context else { return }
            let monitor = Unmanaged<UsbMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.scheduleRefresh() }
        }
        for kind in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            if IOServiceAddMatchingNotification(port, kind, IOServiceMatching("IOUSBHostDevice"), callback, context, &iterator) == KERN_SUCCESS {
                while case let entry = IOIteratorNext(iterator), entry != 0 { IOObjectRelease(entry) }
                iterators.append(iterator)
            }
        }
    }

    private func scheduleRefresh() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
