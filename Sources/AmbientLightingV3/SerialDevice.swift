import AmbientLightingCore
import Foundation
import ORSSerial

struct SerialPortChoice: Identifiable, Hashable {
    let id: String
    let name: String
}

final class SerialDevice: NSObject, ObservableObject, ORSSerialPortDelegate {
    @Published private(set) var ports: [SerialPortChoice] = []
    @Published private(set) var isConnected = false
    @Published private(set) var status = "No device connected"

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
        ports = ORSSerialPortManager.shared().availablePorts.map {
            SerialPortChoice(id: $0.path, name: $0.name)
        }
    }

    func connect(path: String?, baudRate: Int) {
        guard let path,
              let selected = ORSSerialPortManager.shared().availablePorts.first(where: { $0.path == path }) else {
            status = "Select a serial port first"
            return
        }
        status = "Connecting…"
        queue.async {
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
                self.status = "No device connected"
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
                DispatchQueue.main.async { self.status = "Serial write failed" }
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
                self.status = "Device disconnected"
                self.refreshPorts()
            }
        }
    }

    func serialPortWasOpened(_ serialPort: ORSSerialPort) {
        isConnected = true
        status = "Connected to \(serialPort.name)"
    }

    func serialPortWasClosed(_ serialPort: ORSSerialPort) {
        isConnected = false
        status = "Port closed"
    }

    func serialPort(_ serialPort: ORSSerialPort, didEncounterError error: Error) {
        isConnected = false
        status = error.localizedDescription
    }
}
