import BackglowCore
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

struct DisplayChoice: Identifiable, Hashable {
    let id: UInt32
    let title: String
    let width: Int
    let height: Int
}

struct ProcessedFrame {
    let image: CGImage?
    let zones: [LightingZone]
    /// Zone averages in linear light.
    let colors: [LightingRGB]
    let imageWidth: Int
    let imageHeight: Int
    let processingMilliseconds: Double
    let usedGPU: Bool
}

final class ScreenCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((ProcessedFrame) -> Void)?
    var onError: ((String) -> Void)?

    private let sampleQueue = DispatchQueue(label: "lighting.capture.frames", qos: .userInitiated)
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let gpu = GPUZoneReducer()
    private var stream: SCStream?
    private var configuration = LightingConfiguration()
    private var inFlight = false
    private var isActive = false
    private var frameNumber = 0
    private var lastPreviewTime = 0.0
    private var contentBounds: PixelRect?
    private var borderStabilizer = BlackBorderStabilizer()

    static func availableDisplays() async throws -> [DisplayChoice] {
        let content = try await SCShareableContent.current
        return content.displays.enumerated().map { index, display in
            DisplayChoice(
                id: display.displayID,
                title: "Display \(index + 1) · \(display.width) × \(display.height)",
                width: display.width,
                height: display.height
            )
        }
    }

    func update(_ settings: LightingConfiguration) {
        sampleQueue.async {
            self.configuration = settings
            self.contentBounds = nil
            self.borderStabilizer.reset()
        }
    }

    func start(_ settings: LightingConfiguration) async throws -> UInt32 {
        try await stop()
        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == settings.displayID })
                ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        let ownApplications = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApplications,
            exceptingWindows: []
        )
        let streamSettings = SCStreamConfiguration()
        streamSettings.width = max(64, Int(Double(display.width) * settings.captureScale))
        streamSettings.height = max(64, Int(Double(display.height) * settings.captureScale))
        streamSettings.pixelFormat = kCVPixelFormatType_32BGRA
        streamSettings.colorSpaceName = CGColorSpace.sRGB
        streamSettings.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.framesPerSecond))
        streamSettings.queueDepth = 3
        streamSettings.showsCursor = false
        streamSettings.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: streamSettings, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        sampleQueue.sync {
            configuration = settings
            contentBounds = nil
            borderStabilizer.reset()
            frameNumber = 0
            inFlight = false
            isActive = true
        }
        do {
            try await stream.startCapture()
            self.stream = stream
            return display.displayID
        } catch {
            sampleQueue.sync { isActive = false }
            throw error
        }
    }

    func stop() async throws {
        sampleQueue.sync { isActive = false }
        if let stream {
            self.stream = nil
            try await stream.stopCapture()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer,
              isActive, !inFlight else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
           let statusValue = attachments.first?[.status] as? Int,
           SCFrameStatus(rawValue: statusValue) != .complete {
            return
        }
        inFlight = true
        frameNumber += 1
        let start = CFAbsoluteTimeGetCurrent()
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let settings = configuration
        // Detect about ten times per second; the stabilizer decides when a border applies.
        let detectionInterval = max(1, settings.framesPerSecond / 10)
        if settings.ignoreBlackBars && (frameNumber == 1 || frameNumber % detectionInterval == 0) {
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
                let detected = PixelAnalysis.detectContent(
                    bytes: UnsafeRawBufferPointer(start: base, count: stride * height),
                    bytesPerRow: stride, width: width, height: height
                )
                contentBounds = borderStabilizer.update(
                    detected, at: ProcessInfo.processInfo.systemUptime
                )
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        let zones = PerimeterLayout.zones(
            width: width, height: height, configuration: settings,
            contentRect: settings.ignoreBlackBars ? contentBounds : nil
        )
        guard !zones.isEmpty else { inFlight = false; return }

        let now = CFAbsoluteTimeGetCurrent()
        let shouldPreview = now - lastPreviewTime > 0.12
        let preview: CGImage?
        if shouldPreview {
            lastPreviewTime = now
            let scale = min(1, 960 / Double(width))
            let image = CIImage(cvPixelBuffer: pixelBuffer)
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            preview = imageContext.createCGImage(image, from: image.extent)
        } else {
            preview = nil
        }

        let finish: ([LightingRGB], Bool) -> Void = { [weak self] colors, usedGPU in
            guard let self else { return }
            let result = ProcessedFrame(
                image: preview, zones: zones, colors: colors,
                imageWidth: width, imageHeight: height,
                processingMilliseconds: (CFAbsoluteTimeGetCurrent() - start) * 1000,
                usedGPU: usedGPU
            )
            self.sampleQueue.async { self.inFlight = false }
            DispatchQueue.main.async {
                self.onFrame?(result)
            }
        }
        if let gpu, gpu.reduce(pixelBuffer: pixelBuffer, zones: zones, completion: { colors in
            if let colors { finish(colors, true) }
            else { finish(Self.cpuColors(pixelBuffer, zones: zones), false) }
        }) {
            return
        }
        finish(Self.cpuColors(pixelBuffer, zones: zones), false)
    }

    private static func cpuColors(_ pixelBuffer: CVPixelBuffer, zones: [LightingZone]) -> [LightingRGB] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return Array(repeating: .black, count: zones.count)
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = UnsafeRawBufferPointer(start: base, count: stride * height)
        return zones.map {
            PixelAnalysis.average(
                bytes: bytes, bytesPerRow: stride,
                imageWidth: width, imageHeight: height, rect: $0.rect
            )
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onError?(error.localizedDescription) }
    }

    enum CaptureError: LocalizedError {
        case noDisplay

        var errorDescription: String? {
            "No display is available for screen capture."
        }
    }
}
