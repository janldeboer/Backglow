import Foundation

/// A monitor as macOS reports it from its EDID. Unlike a `displayID`, vendor, model and
/// serial number stay the same across reboots and ports.
public struct DisplayIdentity: Codable, Equatable, Hashable, Sendable {
    public var vendor: UInt32
    public var model: UInt32
    /// Zero when the monitor reports no serial number.
    public var serial: UInt32
    /// The `displayID` when the pairing was made; tells apart identical monitors without serial.
    public var displayID: UInt32

    public init(vendor: UInt32, model: UInt32, serial: UInt32, displayID: UInt32) {
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.displayID = displayID
    }

    public func matches(_ other: DisplayIdentity) -> Bool {
        guard vendor == other.vendor, model == other.model else { return false }
        return serial != 0 ? serial == other.serial : displayID == other.displayID
    }
}

/// A USB serial port as IOKit reports it, without opening it.
public struct USBDeviceIdentity: Codable, Equatable, Hashable, Sendable {
    public var vendorID: Int
    public var productID: Int
    public var serialNumber: String?
    public var path: String

    public init(vendorID: Int, productID: Int, serialNumber: String?, path: String) {
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.path = path
    }

    /// Without a USB serial number, VID/PID alone would match any adapter of the same
    /// kind, so the port path, which follows the physical USB socket, has to match too.
    public func matches(_ other: USBDeviceIdentity) -> Bool {
        guard vendorID == other.vendorID, productID == other.productID else { return false }
        if let serialNumber, !serialNumber.isEmpty { return serialNumber == other.serialNumber }
        return path == other.path
    }
}

/// A display and LED controller the user connected once and asked to remember.
public struct AutoConnectPairing: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var display: DisplayIdentity
    public var device: USBDeviceIdentity
    /// Chip ID reported by v3 firmware; when set, another controller is disconnected again.
    public var controllerID: String?

    public init(name: String, display: DisplayIdentity, device: USBDeviceIdentity, controllerID: String?) {
        self.name = name
        self.display = display
        self.device = device
        self.controllerID = controllerID
    }

    public struct Match: Equatable, Sendable {
        public var pairing: AutoConnectPairing
        public var displayID: UInt32
        public var portPath: String
    }

    /// The first remembered pairing whose display and controller are both present.
    public static func firstAvailable(_ pairings: [AutoConnectPairing], displays: [DisplayIdentity],
                                      devices: [USBDeviceIdentity]) -> Match? {
        for pairing in pairings {
            guard let display = displays.first(where: pairing.display.matches),
                  let device = devices.first(where: pairing.device.matches) else { continue }
            return Match(pairing: pairing, displayID: display.displayID, portPath: device.path)
        }
        return nil
    }
}
