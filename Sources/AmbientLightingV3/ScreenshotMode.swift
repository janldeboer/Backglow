import AmbientLightingCore
import AppKit
import CoreVideo
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// `--screenshots <folder>` starts with default settings and a generated demo image instead
/// of the live screen, saves light and dark PNGs of every page, then quits. The README
/// images come from this mode, so no private screen content or device names end up in them.
enum ScreenshotMode {
    static let folder: URL? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--screenshots"), index + 1 < arguments.count else {
            return nil
        }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }()

    static var isActive: Bool { folder != nil }

    static func save(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Captures one of this app's windows, including Liquid Glass, without the shadow.
    @MainActor
    static func capture(_ window: NSWindow) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let shareable = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let filter = SCContentFilter(desktopIndependentWindow: shareable)
        let settings = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        settings.width = Int(filter.contentRect.width * scale)
        settings.height = Int(filter.contentRect.height * scale)
        settings.showsCursor = false
        settings.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: settings)
    }
}

/// A letterboxed sunset drawn in code, so the preview and LED colors have something to show.
enum DemoImage {
    static func pixelBuffer(width: Int = 1920, height: Int = 1080) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        draw(in: context, width: CGFloat(width), height: CGFloat(height))
        return buffer
    }

    private static func draw(in context: CGContext, width: CGFloat, height: CGFloat) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
            CGColor(colorSpace: space, components: [red, green, blue, alpha])!
        }
        context.setFillColor(color(0, 0, 0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // 2.39:1 content inside a 16:9 frame, so black-bar detection has bars to find.
        let contentHeight = (width / 2.39).rounded()
        let content = CGRect(x: 0, y: ((height - contentHeight) / 2).rounded(), width: width, height: contentHeight)
        context.saveGState()
        context.clip(to: content)
        let sky = CGGradient(colorsSpace: space, colors: [
            color(0.98, 0.55, 0.25), color(0.93, 0.33, 0.42), color(0.45, 0.20, 0.55), color(0.08, 0.12, 0.38)
        ] as CFArray, locations: [0, 0.3, 0.62, 1])!
        context.drawLinearGradient(sky, start: CGPoint(x: 0, y: content.minY + content.height * 0.35),
                                   end: CGPoint(x: 0, y: content.maxY), options: [.drawsBeforeStartLocation])
        let sun = CGPoint(x: content.width * 0.68, y: content.minY + content.height * 0.42)
        let glow = CGGradient(colorsSpace: space, colors: [
            color(1, 0.93, 0.62), color(1, 0.75, 0.35, 0.6), color(1, 0.6, 0.3, 0)
        ] as CFArray, locations: [0, 0.18, 1])!
        context.drawRadialGradient(glow, startCenter: sun, startRadius: 0, endCenter: sun,
                                   endRadius: content.height * 0.55, options: [])
        func hills(base: CGFloat, amplitude: CGFloat, phase: CGFloat, fill: CGColor) {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: content.minY))
            for step in 0...96 {
                let x = width * CGFloat(step) / 96
                let y = content.minY + content.height * base +
                    amplitude * content.height * sin(x / width * .pi * 3 + phase)
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: width, y: content.minY))
            context.addPath(path)
            context.setFillColor(fill)
            context.fillPath()
        }
        hills(base: 0.34, amplitude: 0.06, phase: 0.4, fill: color(0.42, 0.18, 0.40))
        hills(base: 0.24, amplitude: 0.05, phase: 2.1, fill: color(0.10, 0.28, 0.32))
        hills(base: 0.12, amplitude: 0.04, phase: 4.0, fill: color(0.04, 0.12, 0.16))
        context.restoreGState()
    }
}
