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
    public var ledCalibration = LEDCalibration()

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
        ledCalibration.normalize()
    }
}

extension LightingConfiguration {
    /// Missing keys fall back to defaults, so settings saved by older builds still load
    /// when new options are added.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LightingConfiguration()
        displayID = try values.decodeIfPresent(UInt32.self, forKey: .displayID)
        rows = try values.decodeIfPresent(Int.self, forKey: .rows) ?? defaults.rows
        columns = try values.decodeIfPresent(Int.self, forKey: .columns) ?? defaults.columns
        ledCount = try values.decodeIfPresent(Int.self, forKey: .ledCount) ?? defaults.ledCount
        deviceLEDCount = try values.decodeIfPresent(Int.self, forKey: .deviceLEDCount) ?? defaults.deviceLEDCount
        startOffset = try values.decodeIfPresent(Int.self, forKey: .startOffset) ?? defaults.startOffset
        reversed = try values.decodeIfPresent(Bool.self, forKey: .reversed) ?? defaults.reversed
        ignoreBlackBars = try values.decodeIfPresent(Bool.self, forKey: .ignoreBlackBars) ?? defaults.ignoreBlackBars
        framesPerSecond = try values.decodeIfPresent(Int.self, forKey: .framesPerSecond) ?? defaults.framesPerSecond
        captureScale = try values.decodeIfPresent(Double.self, forKey: .captureScale) ?? defaults.captureScale
        portPath = try values.decodeIfPresent(String.self, forKey: .portPath)
        baudRate = try values.decodeIfPresent(Int.self, forKey: .baudRate) ?? defaults.baudRate
        calibration = try values.decodeIfPresent(ColorCalibration.self, forKey: .calibration) ?? defaults.calibration
        ledCalibration = try values.decodeIfPresent(LEDCalibration.self, forKey: .ledCalibration)
            ?? defaults.ledCalibration
    }
}
