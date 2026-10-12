import Foundation
import IOKit
import ORSSerial

/// Read-only enumeration. This never opens a serial port or toggles modem lines.
enum USBSerialPortDiscovery {
    static func available() -> [SerialPortChoice] {
        ORSSerialPortManager.shared().availablePorts.compactMap { port in
            guard port.path.hasPrefix("/dev/cu."),
                  let vendorID = property("idVendor", for: port) as? NSNumber,
                  let productID = property("idProduct", for: port) as? NSNumber else {
                return nil
            }
            let serialNumber = (property("kUSBSerialNumberString", for: port)
                ?? property("USB Serial Number", for: port)) as? String
            let productName = (property("kUSBProductString", for: port)
                ?? property("USB Product Name", for: port)) as? String
            let name = productName?.isEmpty == false ? productName! : port.name
            return SerialPortChoice(
                id: port.path,
                name: name,
                vendorID: vendorID.intValue,
                productID: productID.intValue,
                serialNumber: serialNumber
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func property(_ key: String, for port: ORSSerialPort) -> Any? {
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        return IORegistryEntrySearchCFProperty(
            port.ioKitDevice, kIOServicePlane, key as CFString,
            kCFAllocatorDefault, options
        )
    }
}
