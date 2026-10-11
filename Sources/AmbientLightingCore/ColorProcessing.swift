import Foundation

public struct LightingRGB: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let black = LightingRGB(red: 0, green: 0, blue: 0)

    public func clamped() -> LightingRGB {
        LightingRGB(
            red: min(max(red, 0), 1),
            green: min(max(green, 0), 1),
            blue: min(max(blue, 0), 1)
        )
    }
}

public enum ColorProcessing {
    public static func corrected(_ input: LightingRGB, with calibration: ColorCalibration) -> LightingRGB {
        let color = input.clamped()
        let maximum = max(color.red, color.green, color.blue)
        let minimum = min(color.red, color.green, color.blue)
        let difference = maximum - minimum
        var hue = 0.0
        if difference > 0 {
            if maximum == color.red {
                hue = ((color.green - color.blue) / difference).truncatingRemainder(dividingBy: 6)
            } else if maximum == color.green {
                hue = (color.blue - color.red) / difference + 2
            } else {
                hue = (color.red - color.green) / difference + 4
            }
            hue = (hue / 6 + 1).truncatingRemainder(dividingBy: 1)
        }
        let saturation = maximum == 0 ? 0 : min(1, difference / maximum * calibration.saturation)
        let chroma = maximum * saturation
        let sector = hue * 6
        let secondary = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let match = maximum - chroma
        let channels: (Double, Double, Double)
        switch sector {
        case ..<1: channels = (chroma, secondary, 0)
        case ..<2: channels = (secondary, chroma, 0)
        case ..<3: channels = (0, chroma, secondary)
        case ..<4: channels = (0, secondary, chroma)
        case ..<5: channels = (secondary, 0, chroma)
        default: channels = (chroma, 0, secondary)
        }
        return LightingRGB(
            red: pow(channels.0 + match, calibration.gamma) * calibration.redGain * calibration.brightness,
            green: pow(channels.1 + match, calibration.gamma) * calibration.greenGain * calibration.brightness,
            blue: pow(channels.2 + match, calibration.gamma) * calibration.blueGain * calibration.brightness
        ).clamped()
    }
}
