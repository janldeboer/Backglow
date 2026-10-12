import Foundation

/// LED-side calibration after HyperHDR's color engine (MIT, awawa-dev). It stays in
/// the local settings; the controller profile keeps its fixed v1 layout.
public struct LEDCalibration: Codable, Equatable, Sendable {
    public enum Temperature: String, Codable, CaseIterable, Sendable {
        case neutral, warm, cold

        /// Linear-light tint, as HyperHDR's presets.
        public var tint: LightingRGB {
            switch self {
            case .neutral: LightingRGB(red: 1, green: 1, blue: 1)
            case .warm: LightingRGB(red: 1, green: 0.93, blue: 0.85)
            case .cold: LightingRGB(red: 0.9, green: 0.95, blue: 1)
            }
        }
    }

    /// Corners of the RGB cube; the raw value's bits are red = 1, green = 2, blue = 4.
    public enum Corner: Int, Codable, CaseIterable, Sendable {
        case black, red, green, yellow, blue, magenta, cyan, white

        public var ideal: LightingRGB {
            LightingRGB(red: Double(rawValue & 1), green: Double(rawValue >> 1 & 1),
                        blue: Double(rawValue >> 2 & 1))
        }
    }

    public var temperature = Temperature.neutral
    /// sRGB color the LEDs should receive for each fully saturated input corner.
    public var targets: [LightingRGB] = Corner.allCases.map(\.ideal)
    public var minimumBacklight = 0.0
    public var coloredBacklight = false
    /// Share of the strip's full-white power that may be drawn; 1 disables the limit.
    public var powerLimit = 1.0

    public init() {}

    public func target(_ corner: Corner) -> LightingRGB { targets[corner.rawValue] }

    public mutating func setTarget(_ color: LightingRGB, for corner: Corner) {
        targets[corner.rawValue] = color.clamped()
    }

    public var usesTargets: Bool { targets != Corner.allCases.map(\.ideal) }

    public mutating func normalize() {
        if targets.count != Corner.allCases.count { targets = Corner.allCases.map(\.ideal) }
        targets = targets.map { $0.clamped() }
        minimumBacklight = min(max(minimumBacklight, 0), 0.1)
        powerLimit = min(max(powerLimit, 0.2), 1)
    }
}

extension LEDCalibration {
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        temperature = try values.decodeIfPresent(Temperature.self, forKey: .temperature) ?? temperature
        targets = try values.decodeIfPresent([LightingRGB].self, forKey: .targets) ?? targets
        minimumBacklight = try values.decodeIfPresent(Double.self, forKey: .minimumBacklight) ?? minimumBacklight
        coloredBacklight = try values.decodeIfPresent(Bool.self, forKey: .coloredBacklight) ?? coloredBacklight
        powerLimit = try values.decodeIfPresent(Double.self, forKey: .powerLimit) ?? powerLimit
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

public extension ColorProcessing {
    /// Temperature and eight-corner calibration in linear light, before sRGB encoding.
    static func calibrated(_ linear: LightingRGB, with calibration: LEDCalibration) -> LightingRGB {
        let tint = calibration.temperature.tint
        let color = LightingRGB(red: linear.red * tint.red, green: linear.green * tint.green,
                                blue: linear.blue * tint.blue).clamped()
        guard calibration.usesTargets else { return color }
        // Trilinear interpolation between the corner targets, as HyperHDR's calibration LUT.
        var result = LightingRGB.black
        for corner in LEDCalibration.Corner.allCases {
            let bits = corner.rawValue
            let weight = (bits & 1 != 0 ? color.red : 1 - color.red) *
                (bits & 2 != 0 ? color.green : 1 - color.green) *
                (bits & 4 != 0 ? color.blue : 1 - color.blue)
            guard weight > 0 else { continue }
            let target = calibration.target(corner).linearized
            result.red += target.red * weight
            result.green += target.green * weight
            result.blue += target.blue * weight
        }
        return result.clamped()
    }

    /// Keeps a minimum glow, either per channel (colored) or as neutral gray for dark colors.
    static func withMinimumBacklight(_ color: LightingRGB, calibration: LEDCalibration) -> LightingRGB {
        let level = calibration.minimumBacklight
        guard level > 0 else { return color }
        if calibration.coloredBacklight {
            return LightingRGB(red: max(color.red, level), green: max(color.green, level),
                               blue: max(color.blue, level))
        }
        let average = (color.red + color.green + color.blue) / 3
        return average < level ? LightingRGB(red: level, green: level, blue: level) : color
    }

    /// Scales the whole frame down when the sum of output values exceeds the limit.
    /// WS2812-type LEDs draw current roughly in proportion to their 8-bit values.
    static func limitingPower(_ colors: [LightingRGB], to limit: Double) -> [LightingRGB] {
        guard limit < 1, !colors.isEmpty else { return colors }
        let total = colors.reduce(0) { $0 + $1.red + $1.green + $1.blue }
        let allowed = Double(colors.count * 3) * limit
        guard total > allowed else { return colors }
        let scale = allowed / total
        return colors.map {
            LightingRGB(red: $0.red * scale, green: $0.green * scale, blue: $0.blue * scale)
        }
    }
}
