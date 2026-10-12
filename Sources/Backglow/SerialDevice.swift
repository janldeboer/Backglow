import BackglowCore
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
    @Published private(set) var status = String(localized: "Kein Gerät verbunden")
    @Published private(set) var profileStatus = String(localized: "Kein Controller-Profil erkannt")
    @Published private(set) var supportsProfiles = false
    @Published private(set) var profileReady = false
    @Published private(set) var canInitializeStorage = false
    @Published private(set) var storedProfile: ControllerProfile?
    @Published private(set) var controllerID: String?
    @Published private(set) var isSavingProfile = false
    var onProfileLoaded: ((ControllerProfile) -> Void)?

    private let queue = DispatchQueue(label: "lighting.serial.output", qos: .userInitiated)
    private let pendingLock = NSLock()
    private var pendingFrame: Data?
    private var drainScheduled = false
    private var port: ORSSerialPort? // Access only from queue, except delegate identity checks.
    private var parser = ControllerFrameParser() // Delegate callbacks run on the main queue.
    private var generation = 0
    private var currentRevision: UInt32 = 0
    private var recognizedProtocol = false
    private var controllerCapacity = 0
    private var expectedSave: [UInt8]?
    private var expectedRevision: UInt32?
    private var initializingStorage = false

    override init() {
        super.init()
        refreshPorts()
    }

    func refreshPorts() {
        ports = USBSerialPortDiscovery.available()
    }

    func connect(path: String?, baudRate: Int) {
        guard let path, let listed = ports.first(where: { $0.id == path }) else {
            status = String(localized: "USB-Controller auswählen oder Anschlüsse aktualisieren")
            return
        }
        status = String(localized: "Verbinde…")
        resetProfileState()
        queue.async {
            guard USBSerialPortDiscovery.available().contains(where: {
                $0.id == listed.id && $0.vendorID == listed.vendorID &&
                $0.productID == listed.productID && $0.serialNumber == listed.serialNumber
            }), let selected = ORSSerialPortManager.shared().availablePorts.first(where: {
                $0.path == path
            }) else {
                DispatchQueue.main.async {
                    self.status = String(localized: "Anschluss verändert – bitte erneut auswählen")
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
        resetProfileState()
        queue.async {
            self.port?.close()
            self.port?.delegate = nil
            self.port = nil
            DispatchQueue.main.async {
                self.isConnected = false
                self.status = String(localized: "Kein Gerät verbunden")
            }
        }
    }

    func saveProfile(_ profile: ControllerProfile) {
        guard isConnected, supportsProfiles, profileReady, !isSavingProfile,
              profile.physicalLEDs <= controllerCapacity,
              let bytes = profile.encoded(),
              let payload = ControllerFrame.profilePayload(revision: currentRevision, profile: profile),
              let frame = ControllerFrame(.setProfile, payload: payload).encoded() else {
            profileStatus = String(localized: "Profil kann gerade nicht gespeichert werden")
            return
        }
        expectedSave = bytes
        isSavingProfile = true
        profileStatus = String(localized: "Schreibe Profil auf den Controller…")
        sendControl(frame)
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.generation == token, self.isSavingProfile else { return }
            self.expectedSave = nil
            self.expectedRevision = nil
            self.isSavingProfile = false
            self.profileReady = false
            self.profileStatus = String(localized: "Keine Bestätigung erhalten – Profil erneut laden")
        }
    }

    func reloadProfile() {
        guard isConnected, supportsProfiles,
              let frame = ControllerFrame(.getProfile).encoded() else { return }
        profileReady = false
        profileStatus = String(localized: "Lese Controller-Profil…")
        sendControl(frame)
    }

    func initializeStorage() {
        guard isConnected, canInitializeStorage,
              let frame = ControllerFrame(.initializeStorage).encoded() else { return }
        canInitializeStorage = false
        initializingStorage = true
        profileStatus = String(localized: "Richte Controller-Speicher ein…")
        sendControl(frame)
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.generation == token, self.initializingStorage else { return }
            self.initializingStorage = false
            self.canInitializeStorage = true
            self.profileStatus = String(localized: "Keine Antwort vom Controller-Speicher")
        }
    }

    private func resetProfileState() {
        generation += 1
        parser = ControllerFrameParser()
        supportsProfiles = false
        profileReady = false
        canInitializeStorage = false
        initializingStorage = false
        recognizedProtocol = false
        controllerCapacity = 0
        storedProfile = nil
        controllerID = nil
        currentRevision = 0
        expectedSave = nil
        expectedRevision = nil
        isSavingProfile = false
        profileStatus = String(localized: "Prüfe Controller-Protokoll…")
    }

    private func sendControl(_ data: Data) {
        queue.async {
            guard let port = self.port, port.isOpen else { return }
            if !port.send(data) {
                DispatchQueue.main.async { self.profileStatus = String(localized: "Steuerbefehl konnte nicht gesendet werden") }
            }
        }
    }

    private func probe(_ token: Int) {
        guard generation == token, isConnected, !recognizedProtocol else { return }
        sendControl(ControllerFrame.probe)
    }

    private func handle(_ frame: ControllerFrame) {
        switch frame.message {
        case .hello:
            guard frame.payload.count == 8, frame.payload[0] == 1,
                  frame.payload.readLE16(at: 1) >= 1 else {
                profileStatus = String(localized: "Controller-Protokoll nicht kompatibel")
                return
            }
            guard !recognizedProtocol || (!supportsProfiles && frame.payload[3] == 1) else { return }
            initializingStorage = false
            recognizedProtocol = true
            controllerCapacity = Int(frame.payload.readLE16(at: 1))
            controllerID = String(format: "%08X", frame.payload.readLE32(at: 4))
            canInitializeStorage = frame.payload[3] == 0
            guard frame.payload[3] == 1 else {
                switch frame.payload[3] {
                case 0: profileStatus = String(localized: "Controller-Speicher nicht eingerichtet")
                case 2: profileStatus = String(localized: "Profil-Version unbekannt – kein Überschreiben möglich")
                default: profileStatus = String(localized: "Controller-Speicher nicht verfügbar")
                }
                return
            }
            supportsProfiles = true
            reloadProfile()
        case .profile:
            guard supportsProfiles,
                  let (revision, profile) = ControllerFrame.parseProfilePayload(frame.payload) else {
                profileStatus = String(localized: "Ungültiges Controller-Profil")
                return
            }
            let wasSave = expectedSave != nil
            if let expectedSave {
                guard expectedRevision == revision, profile.encoded() == expectedSave else {
                    isSavingProfile = false
                    self.expectedSave = nil
                    expectedRevision = nil
                    profileReady = false
                    profileStatus = String(localized: "Rückleseprüfung fehlgeschlagen – Profil unverändert lassen")
                    return
                }
                self.expectedSave = nil
                expectedRevision = nil
                isSavingProfile = false
                profileStatus = String(localized: "Auf Controller gespeichert und geprüft · Revision \(Int(revision))")
            } else {
                profileStatus = String(localized: "Controller-Profil geladen · Revision \(Int(revision))")
            }
            currentRevision = revision
            storedProfile = profile
            profileReady = true
            if !wasSave { onProfileLoaded?(profile) }
        case .noProfile:
            guard supportsProfiles else { return }
            if expectedSave != nil {
                expectedSave = nil
                expectedRevision = nil
                isSavingProfile = false
                profileStatus = String(localized: "Rückleseprüfung fehlgeschlagen – kein Profil vorhanden")
                return
            }
            storedProfile = nil
            currentRevision = 0
            profileReady = true
            profileStatus = String(localized: "Noch kein Profil gespeichert – aktuelle Einstellungen übernehmen")
        case .saved:
            guard isSavingProfile, frame.payload.count == 4 else { return }
            expectedRevision = frame.payload.readLE32(at: 0)
            reloadProfile()
        case .error:
            let code = frame.payload.first ?? 0
            if initializingStorage {
                initializingStorage = false
                canInitializeStorage = true
            }
            expectedSave = nil
            expectedRevision = nil
            isSavingProfile = false
            profileReady = false
            profileStatus = String(localized: "Controller hat den Befehl abgelehnt (Code \(Int(code)))")
        case .getProfile, .setProfile, .initializeStorage:
            break
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
        pendingLock.lock()
        let frame = pendingFrame
        pendingFrame = nil
        pendingLock.unlock()
        if let frame, let port, port.isOpen, !port.send(frame) {
            DispatchQueue.main.async { self.status = String(localized: "Serielles Schreiben fehlgeschlagen") }
        }
        // Yield the queue after each frame so profile reads/writes and disconnects
        // are not starved when the LED stream exceeds the serial bandwidth.
        pendingLock.lock()
        let more = pendingFrame != nil
        if !more { drainScheduled = false }
        pendingLock.unlock()
        if more { queue.async { self.drain() } }
    }

    func serialPortWasRemovedFromSystem(_ serialPort: ORSSerialPort) {
        queue.async {
            if self.port === serialPort {
                self.port = nil
            }
            DispatchQueue.main.async {
                self.resetProfileState()
                self.isConnected = false
                self.status = String(localized: "Gerät getrennt")
                self.refreshPorts()
            }
        }
    }

    func serialPortWasOpened(_ serialPort: ORSSerialPort) {
        isConnected = true
        status = String(localized: "Verbunden mit \(serialPort.name)")
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.probe(token) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.probe(token) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in self?.probe(token) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self, self.generation == token, self.isConnected, !self.recognizedProtocol else { return }
            self.profileStatus = String(localized: "Ältere Firmware: Farbsteuerung verfügbar, kein Geräteprofil")
        }
    }

    func serialPort(_ serialPort: ORSSerialPort, didReceive data: Data) {
        guard isConnected else { return }
        for frame in parser.append(data) { handle(frame) }
    }

    func serialPortWasClosed(_ serialPort: ORSSerialPort) {
        isConnected = false
        status = String(localized: "Anschluss geschlossen")
        resetProfileState()
    }

    func serialPort(_ serialPort: ORSSerialPort, didEncounterError error: Error) {
        isConnected = false
        status = error.localizedDescription
        resetProfileState()
    }
}
