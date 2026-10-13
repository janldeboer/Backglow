import BackglowCore
import AppKit
import CoreImage
import Foundation

/// Fast-changing capture and output values. They live apart from `LightingModel` so their
/// updates redraw only the views that show them, not the whole window.
@MainActor
final class LiveState: ObservableObject {
    @Published fileprivate(set) var preview: CGImage?
    @Published fileprivate(set) var zones: [LightingZone] = []
    @Published fileprivate(set) var colors: [LightingRGB] = []
    @Published fileprivate(set) var imageWidth = 0
    @Published fileprivate(set) var imageHeight = 0
    @Published fileprivate(set) var processingMilliseconds = 0.0
    @Published fileprivate(set) var actualFPS = 0.0
    @Published fileprivate(set) var usesGPU = false
}

@MainActor
final class LightingModel: ObservableObject {
    @Published private(set) var configuration = LightingConfiguration()
    @Published private(set) var displays: [DisplayChoice] = []
    /// The lights are on, from the screen or in a single color.
    @Published private(set) var isRunning = false
    @Published private(set) var isCapturing = false
    @Published private(set) var captureStatus = String(localized: "Bereit")
    /// While set, every LED shows this calibration corner instead of the screen.
    @Published private(set) var testCorner: LEDCalibration.Corner?
    /// What the last automatic connection did, for the automation page.
    @Published private(set) var autoConnectStatus: String?

    let live = LiveState()
    let serial = SerialDevice()
    private let capture = ScreenCaptureEngine()
    private var smoother = SpringColorSmoother()
    private var antiFlicker = AntiFlickerFilter()
    private var outputTask: Task<Void, Never>?
    private var lastOutputTime: TimeInterval?
    private var hasPendingOutput = false
    private var lastFrameTime: TimeInterval?
    private var smoothedFPS = 0.0
    private var lastStatsTime: TimeInterval = 0
    private var restartTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private let persistsSettings: Bool
    /// Display sleep or system sleep: the LEDs are dark until the screens wake.
    private var outputPaused = false
    private var systemObservers: [NSObjectProtocol] = []
    /// The pairing that switched the lights on; leaving it switches them off again.
    private var autoConnectedPairing: AutoConnectPairing.ID?
    /// Switched off by hand while present; ignored until it disappears once.
    private var suppressedPairing: AutoConnectPairing.ID?
    /// Chip ID the auto-connected controller must report before it gets LED data.
    private var pendingControllerCheck: String?

    private static let settingsURL = settingsURL(folder: "Backglow")
    /// Settings saved before the rename; read only when Backglow has none of its own yet.
    private static let legacySettingsURL = settingsURL(folder: "AmbientLightingV3")

    private static func settingsURL(folder: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    /// With `persistsSettings` false, the model starts from defaults and never writes settings.
    init(persistsSettings: Bool = true) {
        self.persistsSettings = persistsSettings
        if persistsSettings,
           let saved = (try? Data(contentsOf: Self.settingsURL)) ?? (try? Data(contentsOf: Self.legacySettingsURL)),
           var decoded = try? JSONDecoder().decode(LightingConfiguration.self, from: saved) {
            decoded.normalize()
            configuration = decoded
        }
        capture.onFrame = { [weak self] frame in
            Task { @MainActor [weak self] in self?.receive(frame) }
        }
        capture.onError = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.isCapturing = false
                self?.captureStatus = message
            }
        }
        serial.onProfileLoaded = { [weak self] profile in
            self?.change { $0 = profile.applying(to: $0) }
        }
        serial.onControllerIdentified = { [weak self] id in self?.verifyController(id) }
        Task { await refreshDisplays() }
        // The screenshot mode never touches real devices.
        if persistsSettings {
            serial.onPortsChanged = { [weak self] in self?.evaluateAutoConnect() }
            observeSystem()
            Task { evaluateAutoConnect() }
        }
    }

    var profileHasLocalChanges: Bool {
        guard let stored = serial.storedProfile else { return true }
        return stored.encoded() != ControllerProfile(configuration: configuration).encoded()
    }

    func saveControllerProfile() {
        serial.saveProfile(ControllerProfile(configuration: configuration))
    }

    func refreshDisplays() async {
        do {
            displays = try await ScreenCaptureEngine.availableDisplays()
            if configuration.displayID == nil || !displays.contains(where: { $0.id == configuration.displayID }) {
                if let first = displays.first { change { $0.displayID = first.id } }
            }
        } catch {
            captureStatus = String(localized: "Bildschirmliste nicht verfügbar: \(error.localizedDescription)")
        }
    }

    func change(_ edit: (inout LightingConfiguration) -> Void) {
        let previous = configuration
        var updated = previous
        edit(&updated)
        updated.normalize()
        guard updated != previous else { return }
        configuration = updated
        save()
        capture.update(updated)
        if updated.displayID != previous.displayID ||
            updated.framesPerSecond != previous.framesPerSecond ||
            updated.captureScale != previous.captureScale {
            scheduleRestart()
        }
        if updated.ledCount != previous.ledCount ||
            updated.startOffset != previous.startOffset ||
            updated.reversed != previous.reversed ||
            updated.rows != previous.rows ||
            updated.columns != previous.columns {
            resetOutput()
        }
        if updated.outputMode != previous.outputMode {
            applyMode()
        } else {
            updateSolidTarget()
        }
        if updated.autoConnect != previous.autoConnect || updated.pairings != previous.pairings {
            evaluateAutoConnect()
        }
    }

    func start() {
        isRunning = true
        applyMode()
    }

    /// Starts or ends the screen capture to match the output mode while the lights are on.
    private func applyMode() {
        guard isRunning else { return }
        captureTask?.cancel()
        switch configuration.outputMode {
        case .screen:
            captureTask = Task { await startCapture() }
        case .solidColor:
            restartTask?.cancel()
            captureTask = Task {
                try? await capture.stop()
                isCapturing = false
                captureStatus = String(localized: "Einzelfarbe")
            }
            updateSolidTarget()
        }
    }

    /// The spring fades to a new single color the same way it follows the screen.
    private func updateSolidTarget() {
        guard isRunning, configuration.outputMode == .solidColor else { return }
        let color = processed(configuration.solidColor.linearized)
        smoother.configure(smoothing: configuration.calibration.smoothing)
        smoother.setTarget(Array(repeating: color, count: configuration.ledCount))
        hasPendingOutput = true
        startOutputClock()
    }

    func showTestCorner(_ corner: LEDCalibration.Corner?) {
        testCorner = corner
        if corner != nil {
            startOutputClock()
            return
        }
        resetOutput()
        if isRunning {
            hasPendingOutput = true
            updateSolidTarget()
        } else {
            stopOutputClock()
            live.colors = []
            sendBlack()
        }
    }

    /// Switching off by hand also keeps a present pairing from switching on again right away.
    func stop() {
        suppressCurrentPairing()
        switchOff()
    }

    func disconnectController() {
        suppressCurrentPairing()
        serial.disconnect()
        pendingControllerCheck = nil
    }

    /// Dark LEDs before the app quits, so they do not keep the last color.
    func prepareForTermination() {
        guard serial.isConnected else { return }
        sendBlack()
        serial.flush()
    }

    private func switchOff() {
        isRunning = false
        testCorner = nil
        restartTask?.cancel()
        captureTask?.cancel()
        stopOutputClock()
        sendBlack()
        captureTask = Task {
            do { try await capture.stop() } catch { captureStatus = error.localizedDescription }
            isCapturing = false
            captureStatus = String(localized: "Gestoppt")
            resetOutput()
            sendBlack()
        }
    }

    /// Shows a still image as if it had been captured, through the same GPU reduction and
    /// color pipeline but without smoothing or LED output. Used by the screenshot mode.
    func showStill(_ pixelBuffer: CVPixelBuffer) async {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let start = CFAbsoluteTimeGetCurrent()
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        let bytes = UnsafeRawBufferPointer(start: CVPixelBufferGetBaseAddress(pixelBuffer),
                                           count: CVPixelBufferGetBytesPerRow(pixelBuffer) * height)
        let content = configuration.ignoreBlackBars ? PixelAnalysis.detectContent(
            bytes: bytes, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), width: width, height: height
        ) : nil
        let zones = PerimeterLayout.zones(width: width, height: height, configuration: configuration,
                                          contentRect: content)
        let cpuColors = zones.map {
            PixelAnalysis.average(bytes: bytes, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                  imageWidth: width, imageHeight: height, rect: $0.rect)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        let gpuColors: [LightingRGB]? = await withCheckedContinuation { continuation in
            guard let reducer = GPUZoneReducer(),
                  reducer.reduce(pixelBuffer: pixelBuffer, zones: zones, completion: { continuation.resume(returning: $0) })
            else {
                continuation.resume(returning: nil)
                return
            }
        }
        live.preview = CIContext().createCGImage(CIImage(cvPixelBuffer: pixelBuffer),
                                                 from: CGRect(x: 0, y: 0, width: width, height: height))
        live.zones = zones
        live.imageWidth = width
        live.imageHeight = height
        live.colors = (gpuColors ?? cpuColors).map(processed)
        live.usesGPU = gpuColors != nil
        live.processingMilliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000
        captureStatus = String(localized: "Demo-Bild")
    }

    private func startCapture() async {
        captureStatus = String(localized: "Bildschirmaufnahme startet…")
        do {
            let displayID = try await capture.start(configuration)
            guard isRunning, configuration.outputMode == .screen else {
                try? await capture.stop()
                return
            }
            if configuration.displayID != displayID { change { $0.displayID = displayID } }
            isCapturing = true
            captureStatus = String(localized: "Live")
            lastFrameTime = nil
        } catch {
            isCapturing = false
            captureStatus = error.localizedDescription
        }
    }

    private func scheduleRestart() {
        guard isRunning, configuration.outputMode == .screen else { return }
        restartTask?.cancel()
        restartTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, isRunning, configuration.outputMode == .screen else { return }
            await startCapture()
        }
    }

    private func receive(_ frame: ProcessedFrame) {
        guard isRunning, configuration.outputMode == .screen else { return }
        let corrected = frame.colors.map(processed)
        smoother.configure(smoothing: configuration.calibration.smoothing)
        smoother.setTarget(corrected)
        hasPendingOutput = true
        startOutputClock()
        // @Published fires on every assignment, so only assign values that changed.
        if live.zones != frame.zones { live.zones = frame.zones }
        if live.imageWidth != frame.imageWidth { live.imageWidth = frame.imageWidth }
        if live.imageHeight != frame.imageHeight { live.imageHeight = frame.imageHeight }
        if let image = frame.image { live.preview = image }
        if live.usesGPU != frame.usedGPU { live.usesGPU = frame.usedGPU }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastFrameTime, now > lastFrameTime {
            let instantaneous = 1 / (now - lastFrameTime)
            smoothedFPS = smoothedFPS == 0 ? instantaneous : smoothedFPS * 0.8 + instantaneous * 0.2
        }
        lastFrameTime = now
        // Readable numbers, and no redraw for every frame.
        if now - lastStatsTime >= 0.5 {
            lastStatsTime = now
            live.actualFPS = smoothedFPS
            live.processingMilliseconds = frame.processingMilliseconds
        }
    }

    /// LED output runs on its own clock so smoothing stays fluid between capture frames
    /// and its speed does not depend on the capture rate.
    private func startOutputClock() {
        guard outputTask == nil else { return }
        outputTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = 1 / SerialPacket.outputFrequency(
                    ledCount: self.configuration.ledCount, baudRate: self.configuration.baudRate
                )
                self.outputTick()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func stopOutputClock() {
        outputTask?.cancel()
        outputTask = nil
        lastOutputTime = nil
    }

    /// HyperHDR's order: linear calibration, sRGB encoding, user correction, minimum backlight.
    private func processed(_ linear: LightingRGB) -> LightingRGB {
        let calibrated = ColorProcessing.calibrated(linear, with: configuration.ledCalibration)
        let corrected = ColorProcessing.corrected(calibrated.srgbEncoded, with: configuration.calibration)
        return ColorProcessing.withMinimumBacklight(corrected, calibration: configuration.ledCalibration)
    }

    private func outputTick() {
        guard !outputPaused else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = lastOutputTime.map { now - $0 } ?? 0
        lastOutputTime = now
        let frame: [LightingRGB]
        if let testCorner {
            frame = Array(repeating: processed(testCorner.ideal), count: configuration.ledCount)
        } else {
            guard hasPendingOutput || !smoother.isSettled else { return }
            frame = smoother.advance(by: elapsed)
            if smoother.isSettled { hasPendingOutput = false }
        }
        let output = antiFlicker.apply(
            ColorProcessing.limitingPower(frame, to: configuration.ledCalibration.powerLimit)
        )
        if output != live.colors { live.colors = output }
        if serial.isConnected, pendingControllerCheck == nil {
            serial.send(output, maximumLEDs: configuration.deviceLEDCount)
        }
    }

    private func sendBlack() {
        // An unconfirmed controller gets no data at all, not even black.
        guard pendingControllerCheck == nil else { return }
        serial.send(Array(repeating: .black, count: configuration.ledCount),
                    maximumLEDs: configuration.deviceLEDCount)
    }

    private func resetOutput() {
        smoother.reset()
        antiFlicker.reset()
    }

    // MARK: Sleep and wake

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        systemObservers = [
            observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.evaluateAutoConnect() },
            observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.setOutputPaused(true) },
            observe(workspace, NSWorkspace.willSleepNotification) { $0.setOutputPaused(true) },
            observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.resumeIfScreensAwake() },
            observe(workspace, NSWorkspace.didWakeNotification) { $0.resumeIfScreensAwake() },
        ]
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ action: @escaping @MainActor (LightingModel) -> Void) -> NSObjectProtocol {
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in if let self { action(self) } }
        }
    }

    private func resumeIfScreensAwake() {
        // A dark wake or a wake with the lid closed leaves the screens asleep.
        guard CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { return }
        setOutputPaused(false)
        evaluateAutoConnect()
    }

    private func setOutputPaused(_ paused: Bool) {
        guard outputPaused != paused else { return }
        outputPaused = paused
        if paused {
            sendBlack()
            serial.flush()
        } else {
            hasPendingOutput = true
        }
    }

    // MARK: Automatic connection

    var canRememberPairing: Bool {
        serial.connectedPort != nil && configuration.displayID != nil
    }

    /// Remembers the selected display and the connected controller as a pair.
    func rememberCurrentPairing() {
        guard let port = serial.connectedPort, let displayID = configuration.displayID else { return }
        let display = DisplayDiscovery.identity(displayID)
        let displayName = DisplayDiscovery.name(displayID) ?? String(localized: "Bildschirm")
        let pairing = AutoConnectPairing(name: "\(displayName) · \(port.name)", display: display,
                                         device: port.identity, controllerID: serial.controllerID)
        // Already connected, so it counts as switched on by this pairing.
        autoConnectedPairing = pairing.id
        suppressedPairing = nil
        change {
            $0.pairings.removeAll { $0.display.matches(display) && $0.device.matches(port.identity) }
            $0.pairings.append(pairing)
            $0.autoConnect = true
        }
        autoConnectStatus = String(localized: "Kombination gemerkt: \(pairing.name)")
    }

    func forgetPairing(_ id: AutoConnectPairing.ID) {
        change { $0.pairings.removeAll { $0.id == id } }
    }

    func isPairingAvailable(_ pairing: AutoConnectPairing) -> Bool {
        AutoConnectPairing.firstAvailable([pairing], displays: DisplayDiscovery.active(),
                                          devices: serial.ports.map(\.identity)) != nil
    }

    /// The active pairing while it is still present, otherwise the first one that is.
    private func currentMatch() -> AutoConnectPairing.Match? {
        let displays = DisplayDiscovery.active()
        let devices = serial.ports.map(\.identity)
        let active = configuration.pairings.filter { $0.id == autoConnectedPairing }
        return AutoConnectPairing.firstAvailable(active, displays: displays, devices: devices)
            ?? AutoConnectPairing.firstAvailable(configuration.pairings, displays: displays, devices: devices)
    }

    private func suppressCurrentPairing() {
        if let id = autoConnectedPairing ?? (configuration.autoConnect ? currentMatch()?.pairing.id : nil) {
            suppressedPairing = id
        }
        autoConnectedPairing = nil
    }

    /// Runs when displays, USB serial ports or the pairings change. A port is only opened
    /// when it matches a controller the user connected and remembered before.
    func evaluateAutoConnect() {
        guard persistsSettings else { return }
        guard configuration.autoConnect else {
            autoConnectedPairing = nil
            suppressedPairing = nil
            return
        }
        if let active = autoConnectedPairing, !configuration.pairings.contains(where: { $0.id == active }) {
            autoConnectedPairing = nil // Forgotten; the lights stay as they are.
        }
        let match = currentMatch()
        if let suppressed = suppressedPairing, suppressed != match?.pairing.id { suppressedPairing = nil }
        if let active = autoConnectedPairing, active != match?.pairing.id {
            autoConnectedPairing = nil
            switchOff()
            serial.disconnect()
            pendingControllerCheck = nil
            autoConnectStatus = String(localized: "Bildschirm oder Controller getrennt – Licht aus")
        }
        guard let match, suppressedPairing != match.pairing.id,
              autoConnectedPairing != match.pairing.id else { return }
        autoConnectedPairing = match.pairing.id
        change {
            $0.displayID = match.displayID
            $0.portPath = match.portPath
        }
        if serial.connectedPort?.id != match.portPath {
            connectAutomatically(match)
        }
        if !isRunning { start() }
        autoConnectStatus = String(localized: "Automatisch eingeschaltet: \(match.pairing.name)")
    }

    private func connectAutomatically(_ match: AutoConnectPairing.Match) {
        serial.connect(path: match.portPath, baudRate: configuration.baudRate)
        guard let expected = match.pairing.controllerID else { return }
        // LED data goes out only after the controller has reported the remembered chip ID.
        pendingControllerCheck = expected
        let pairingID = match.pairing.id
        Task {
            try? await Task.sleep(for: .seconds(6))
            guard pendingControllerCheck != nil, autoConnectedPairing == pairingID else { return }
            rejectController(String(localized: "Controller hat sich nicht gemeldet – automatische Verbindung getrennt"))
        }
    }

    private func verifyController(_ id: String) {
        guard let active = autoConnectedPairing,
              let index = configuration.pairings.firstIndex(where: { $0.id == active }) else { return }
        guard let expected = configuration.pairings[index].controllerID else {
            change { $0.pairings[index].controllerID = id }
            return
        }
        guard expected == id else {
            rejectController(String(localized: "Anderer Controller an diesem Anschluss – automatische Verbindung getrennt"))
            return
        }
        if pendingControllerCheck != nil {
            pendingControllerCheck = nil
            hasPendingOutput = true
        }
    }

    private func rejectController(_ message: String) {
        suppressedPairing = autoConnectedPairing
        autoConnectedPairing = nil
        switchOff()
        serial.disconnect()
        pendingControllerCheck = nil
        autoConnectStatus = message
    }

    private func save() {
        guard persistsSettings else { return }
        do {
            try FileManager.default.createDirectory(at: Self.settingsURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(configuration).write(to: Self.settingsURL, options: .atomic)
        } catch {
            captureStatus = String(localized: "Einstellungen konnten nicht gespeichert werden: \(error.localizedDescription)")
        }
    }
}
