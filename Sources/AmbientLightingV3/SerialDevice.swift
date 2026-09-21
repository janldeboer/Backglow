import AmbientLightingCore
import Foundation
import ORSSerial

struct SerialPortChoice: Identifiable, Hashable {
    let id: String
    let name: String
    let vendorID: Int
    let productID: Int
    let serialNumber: String?

    var detail: String {
        String(format: "%04X:%04X", vendorID, productID)
    }
}

final class SerialDevice: NSObject, ObservableObject, ORSSerialPortDelegate {
    @Published private(set) var ports: [SerialPortChoice] = []
    @Published private(set) var isConnected = false
    @Published private(set) var status = "Kein Gerät verbunden"

    private let queue = DispatchQueue(label: "lighting.serial.output", qos: .userInitiated)
    private let pendingLock = NSLock()
    private var pendingFrame: Data?
    private var drainScheduled = false
    private var port: ORSSerialPort? // Access only from queue, except delegate identity checks.

    override init() {
        super.init()
        refreshPorts()
    }

    func refreshPorts() {
        ports = USBSerialPortDiscovery.available()
    }

    func connect(path: String?, baudRate: Int) {
        guard let path, let listed = ports.first(where: { $0.id == path }) else {
            status = "USB-Controller auswählen oder Anschlüsse aktualisieren"
            return
        }
        status = "Verbinde…"
        queue.async {
            guard USBSerialPortDiscovery.available().contains(where: {
                $0.id == listed.id && $0.vendorID == listed.vendorID &&
                $0.productID == listed.productID && $0.serialNumber == listed.serialNumber
            }), let selected = ORSSerialPortManager.shared().availablePorts.first(where: {
                $0.path == path
            }) else {
                DispatchQueue.main.async {
                    self.status = "Anschluss verändert – bitte erneut auswählen"
                }
                return
            }
            self.port?.close()
            self.port?.delegate = nil
            self.port = selected
            selected.delegate = self
            selected.baudRate = NSNumber(value: baudRate)
            selected.open()
        }
    }

    func disconnect() {
        queue.async {
            self.port?.close()
            self.port?.delegate = nil
            self.port = nil
            DispatchQueue.main.async {
                self.isConnected = false
                self.status = "Kein Gerät verbunden"
            }
        }
    }

    func send(_ colors: [LightingRGB], maximumLEDs: Int) {
        let frame = SerialPacket.frame(colors: colors, maximumLEDs: maximumLEDs)
        pendingLock.lock()
        pendingFrame = frame // The newest frame replaces any unsent frame.
        let shouldSchedule = !drainScheduled
        if shouldSchedule { drainScheduled = true }
        pendingLock.unlock()
        if shouldSchedule { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            pendingLock.lock()
            let frame = pendingFrame
            pendingFrame = nil
            if frame == nil { drainScheduled = false }
            pendingLock.unlock()
            guard let frame else { return }
            guard let port, port.isOpen else { continue }
            if !port.send(frame) {
                DispatchQueue.main.async { self.status = "Serielles Schreiben fehlgeschlagen" }
            }
        }
    }

    func serialPortWasRemovedFromSystem(_ serialPort: ORSSerialPort) {
        queue.async {
            if self.port === serialPort {
                self.port = nil
            }
            DispatchQueue.main.async {
                self.isConnected = false
                self.status = "Gerät getrennt"
                self.refreshPorts()
            }
        }
    }

    func serialPortWasOpened(_ serialPort: ORSSerialPort) {
        isConnected = true
        status = "Verbunden mit \(serialPort.name)"
    }

    func serialPortWasClosed(_ serialPort: ORSSerialPort) {
        isConnected = false
        status = "Anschluss geschlossen"
    }

    func serialPort(_ serialPort: ORSSerialPort, didEncounterError error: Error) {
        isConnected = false
        status = error.localizedDescription
    }
}
