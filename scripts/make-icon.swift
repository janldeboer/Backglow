import AppKit

let size = 1024
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
    bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let canvas = CGRect(x: 0, y: 0, width: size, height: size)
NSColor.clear.setFill()
canvas.fill()

let shell = NSBezierPath(roundedRect: CGRect(x: 38, y: 38, width: 948, height: 948),
                         xRadius: 220, yRadius: 220)
NSGradient(starting: NSColor(calibratedRed: 0.08, green: 0.15, blue: 0.29, alpha: 1),
           ending: NSColor(calibratedRed: 0.02, green: 0.04, blue: 0.11, alpha: 1))!
    .draw(in: shell, angle: -45)

let screen = NSBezierPath(roundedRect: CGRect(x: 232, y: 232, width: 560, height: 560),
                          xRadius: 82, yRadius: 82)
NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.38, blue: 0.52, alpha: 1),
           ending: NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.2, alpha: 1))!
    .draw(in: screen, angle: 140)
NSColor(calibratedWhite: 1, alpha: 0.24).setStroke()
screen.lineWidth = 7
screen.stroke()

let tones: [NSColor] = [
    NSColor(calibratedRed: 0.18, green: 0.77, blue: 1, alpha: 1),
    NSColor(calibratedRed: 0.48, green: 0.42, blue: 1, alpha: 1),
    NSColor(calibratedRed: 1, green: 0.36, blue: 0.67, alpha: 1),
    NSColor(calibratedRed: 1, green: 0.65, blue: 0.31, alpha: 1)
]
func led(_ rect: CGRect, _ color: NSColor) {
    let glow = NSBezierPath(roundedRect: rect.insetBy(dx: -11, dy: -11), xRadius: 24, yRadius: 24)
    color.withAlphaComponent(0.13).setFill()
    glow.fill()
    let tile = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
    color.setFill()
    tile.fill()
}
for index in 0..<7 {
    let p = CGFloat(index) / 6
    let color = tones[min(Int(p * 3), 3)]
    let x = 234 + CGFloat(index) * 84
    led(CGRect(x: x, y: 834, width: 52, height: 52), color)
    led(CGRect(x: x, y: 138, width: 52, height: 52), tones[3 - min(Int(p * 3), 3)])
}
for index in 0..<6 {
    let p = CGFloat(index) / 5
    let y = 274 + CGFloat(index) * 87
    led(CGRect(x: 136, y: y, width: 52, height: 52), tones[min(Int(p * 3), 3)])
    led(CGRect(x: 836, y: y, width: 52, height: 52), tones[3 - min(Int(p * 3), 3)])
}

let beam = NSBezierPath()
beam.move(to: CGPoint(x: 309, y: 430))
beam.curve(to: CGPoint(x: 715, y: 584),
           controlPoint1: CGPoint(x: 445, y: 730), controlPoint2: CGPoint(x: 574, y: 295))
beam.lineWidth = 34
beam.lineCapStyle = .round
NSColor(calibratedRed: 0.28, green: 0.83, blue: 1, alpha: 0.9).setStroke()
beam.stroke()

NSGraphicsContext.restoreGraphicsState()
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
