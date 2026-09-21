import Foundation

public struct LightingConfiguration: Codable, Equatable, Sendable {
    public var displayID: UInt32?
    public var rows: Int = 12
    public var columns: Int = 21
    public var ledCount: Int = 59
    public var deviceLEDCount: Int = 70
    public var startOffset: Int = 43
    public var reversed: Bool = true
    public var ignoreBlackBars: Bool = false
    public var framesPerSecond: Int = 30
    public var captureScale: Double = 0.5
    public var portPath: String?
    public var baudRate: Int = 230_400
    public var calibration = ColorCalibration()

    public init() {}

    public var maximumZoneCount: Int {
        guard rows >= 2, columns >= 2 else { return 0 }
        return 2 * (rows + columns) - 4
    }

    public mutating func normalize() {
        rows = min(max(rows, 2), 50)
        columns = min(max(columns, 2), 50)
        deviceLEDCount = min(max(deviceLEDCount, 1), 255)
        ledCount = min(max(ledCount, 1), min(maximumZoneCount, deviceLEDCount))
        startOffset = ((startOffset % maximumZoneCount) + maximumZoneCount) % maximumZoneCount
        framesPerSecond = min(max(framesPerSecond, 5), 60)
        captureScale = min(max(captureScale, 0.25), 1)
        baudRate = max(baudRate, 1_200)
        calibration.normalize()
    }
}

public struct ColorCalibration: Codable, Equatable, Sendable {
    public var saturation: Double = 1
    public var gamma: Double = 1
    public var redGain: Double = 1
    public var greenGain: Double = 1
    public var blueGain: Double = 1
    public var brightness: Double = 1
    public var smoothing: Double = 0.25

    public init() {}

    public mutating func normalize() {
        saturation = min(max(saturation, 0), 2)
        gamma = min(max(gamma, 0.25), 3)
        redGain = min(max(redGain, 0), 2)
        greenGain = min(max(greenGain, 0), 2)
        blueGain = min(max(blueGain, 0), 2)
        brightness = min(max(brightness, 0), 1)
        smoothing = min(max(smoothing, 0), 0.95)
    }
}
