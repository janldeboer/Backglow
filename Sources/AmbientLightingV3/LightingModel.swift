import AmbientLightingCore
import AppKit
import Foundation

@MainActor
final class LightingModel: ObservableObject {
    @Published private(set) var configuration = LightingConfiguration()
    @Published private(set) var displays: [DisplayChoice] = []
    @Published private(set) var preview: CGImage?
    @Published private(set) var zones: [LightingZone] = []
    @Published private(set) var colors: [LightingRGB] = []
    @Published private(set) var previewWidth = 0
    @Published private(set) var previewHeight = 0
    @Published private(set) var isCapturing = false
    @Published private(set) var captureStatus = "Ready"
    @Published private(set) var processingMilliseconds = 0.0
    @Published private(set) var actualFPS = 0.0
    @Published private(set) var usesGPU = false

    let serial = SerialDevice()
    private let capture = ScreenCaptureEngine()
    private var smoother = ColorSmoother()
    private var lastFrameTime: TimeInterval?
    private var restartTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var desiredCapture = false

    private static let settingsURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AmbientLightingV3", isDirectory: true)
            .appendingPathComponent("settings.json")
    }()

    init() {
        if let saved = try? Data(contentsOf: Self.settingsURL),
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
        Task { await refreshDisplays() }
    }

    func refreshDisplays() async {
        do {
            displays = try await ScreenCaptureEngine.availableDisplays()
            if configuration.displayID == nil || !displays.contains(where: { $0.id == configuration.displayID }) {
                if let first = displays.first { change { $0.displayID = first.id } }
            }
        } catch {
            captureStatus = "Display list: \(error.localizedDescription)"
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
            smoother.reset()
        }
    }

    func start() {
        desiredCapture = true
        captureTask?.cancel()
        captureTask = Task { await startCapture() }
    }

    func stop() {
        desiredCapture = false
        restartTask?.cancel()
        captureTask?.cancel()
        captureTask = Task {
            do { try await capture.stop() } catch { captureStatus = error.localizedDescription }
            isCapturing = false
            captureStatus = "Stopped"
            smoother.reset()
            serial.send(Array(repeating: .black, count: configuration.ledCount),
                        maximumLEDs: configuration.deviceLEDCount)
        }
    }

    private func startCapture() async {
        captureStatus = "Starting screen capture…"
        do {
            let displayID = try await capture.start(configuration)
            guard desiredCapture else {
                try? await capture.stop()
                return
            }
            if configuration.displayID != displayID { change { $0.displayID = displayID } }
            isCapturing = true
            captureStatus = "Live"
            lastFrameTime = nil
        } catch {
            isCapturing = false
            captureStatus = error.localizedDescription
        }
    }

    private func scheduleRestart() {
        guard desiredCapture else { return }
        restartTask?.cancel()
        restartTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, desiredCapture else { return }
            await startCapture()
        }
    }

    private func receive(_ frame: ProcessedFrame) {
        guard desiredCapture else { return }
        let corrected = frame.colors.map {
            ColorProcessing.corrected($0, with: configuration.calibration)
        }
        colors = smoother.apply(corrected, amount: configuration.calibration.smoothing)
        zones = frame.zones
        previewWidth = frame.imageWidth
        previewHeight = frame.imageHeight
        if let image = frame.image { preview = image }
        processingMilliseconds = frame.processingMilliseconds
        usesGPU = frame.usedGPU
        let now = ProcessInfo.processInfo.systemUptime
        if let lastFrameTime, now > lastFrameTime {
            let instantaneous = 1 / (now - lastFrameTime)
            actualFPS = actualFPS == 0 ? instantaneous : actualFPS * 0.8 + instantaneous * 0.2
        }
        lastFrameTime = now
        if serial.isConnected {
            serial.send(colors, maximumLEDs: configuration.deviceLEDCount)
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Self.settingsURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(configuration).write(to: Self.settingsURL, options: .atomic)
        } catch {
            captureStatus = "Settings could not be saved: \(error.localizedDescription)"
        }
    }
}
