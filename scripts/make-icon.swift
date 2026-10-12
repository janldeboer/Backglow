import AppKit
import CoreImage

// Draws the layers of AppBundle/Backglow.icon: a glass monitor showing a sunset and the
// light it casts on the wall behind it. Icon Composer adds the glass, shadow and appearance
// variants, so the layers stay flat. Usage: swift scripts/make-icon.swift <Assets folder>

let size = 1024
let assets = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let screen = CGRect(x: 208, y: 318, width: 608, height: 388)
let screenRadius: CGFloat = 44
/// The monitor around the picture; its glass edge is what makes the picture read as a display.
let bezel = screen.insetBy(dx: -26, dy: -26)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func canvas(_ draw: (CGContext) -> Void) -> CGImage {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(context)
    return context.makeImage()!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
               colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

func save(_ image: CGImage, _ name: String) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    try rep.representation(using: .png, properties: [:])!.write(to: assets.appendingPathComponent(name))
}

// Coordinates are bottom-up, so the top edge of the screen is screen.maxY.
let sky = gradient([
    (0, rgb(0x2A1C68)), (0.38, rgb(0x6A3A9E)), (0.68, rgb(0xE0607E)), (1, rgb(0xFFB25C))
])

// The glow: the screen's edge colors, spread outward. A tight bright rim plus a wide halo.
func glowLayer(spread: CGFloat, sigma: Double) -> CIImage {
    let shape = canvas { context in
        let rect = bezel.insetBy(dx: -spread, dy: -spread)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 90 + spread, cornerHeight: 90 + spread,
                               transform: nil))
        context.clip()
        context.drawLinearGradient(gradient([
            (0, rgb(0x2EC4FF)), (0.32, rgb(0x7A6BFF)), (0.64, rgb(0xFF5CAB)), (1, rgb(0xFFA64F))
        ]), start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    }
    return CIImage(cgImage: shape).clampedToExtent().applyingGaussianBlur(sigma: sigma)
}
let full = CGRect(x: 0, y: 0, width: size, height: size)
let combined = glowLayer(spread: 8, sigma: 18)
    .composited(over: glowLayer(spread: 60, sigma: 64))
    .cropped(to: full)
let glow = CIContext().createCGImage(combined, from: full,
                                     format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
try save(glow, "glow.png")

// The screen: a sunset with a sun and two hills, so the glow reads as its reflection.
let picture = canvas { context in
    context.addPath(CGPath(roundedRect: screen, cornerWidth: screenRadius, cornerHeight: screenRadius,
                           transform: nil))
    context.clip()
    context.drawLinearGradient(sky, start: CGPoint(x: 0, y: screen.maxY),
                               end: CGPoint(x: 0, y: screen.minY + 120), options: [.drawsAfterEndLocation])

    let sun = CGPoint(x: screen.midX + 120, y: screen.minY + 150)
    context.drawRadialGradient(gradient([(0, rgb(0xFFF4C8)), (0.22, rgb(0xFFD27A)), (1, rgb(0xFFB25C, 0))]),
                               startCenter: sun, startRadius: 0, endCenter: sun, endRadius: 170, options: [])

    func hill(_ color: CGColor, base: CGFloat, peaks: [(CGFloat, CGFloat)]) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: screen.minX, y: screen.minY))
        path.addLine(to: CGPoint(x: screen.minX, y: base))
        var last = CGPoint(x: screen.minX, y: base)
        for (x, y) in peaks {
            let next = CGPoint(x: screen.minX + x * screen.width, y: y)
            path.addCurve(to: next, control1: CGPoint(x: (last.x + next.x) / 2, y: last.y),
                          control2: CGPoint(x: (last.x + next.x) / 2, y: next.y))
            last = next
        }
        path.addLine(to: CGPoint(x: screen.maxX, y: screen.minY))
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(color)
        context.fillPath()
    }
    hill(rgb(0x5B2D6E), base: screen.minY + 120,
         peaks: [(0.25, screen.minY + 150), (0.6, screen.minY + 95), (0.85, screen.minY + 150), (1, screen.minY + 120)])
    hill(rgb(0x173A48), base: screen.minY + 70,
         peaks: [(0.4, screen.minY + 105), (0.75, screen.minY + 60), (1, screen.minY + 85)])
}
try save(picture, "screen.png")

let frame = canvas { context in
    context.addPath(CGPath(roundedRect: bezel, cornerWidth: screenRadius + 26, cornerHeight: screenRadius + 26,
                           transform: nil))
    context.setFillColor(rgb(0x0A0F20))
    context.fillPath()
}
try save(frame, "bezel.png")
print("Wrote glow.png, bezel.png and screen.png to \(assets.path)")
