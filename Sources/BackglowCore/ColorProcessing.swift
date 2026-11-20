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

// MARK: - Picking a single color

extension LightingRGB {
    /// A fully bright sRGB color; `hue` and `saturation` run from 0 to 1.
    public init(hue: Double, saturation: Double) {
        let hue = min(max(hue, 0), 1) * 6
        let saturation = min(max(saturation, 0), 1)
        func channel(_ offset: Double) -> Double {
            let k = (offset + hue).truncatingRemainder(dividingBy: 6)
            return 1 - saturation * max(0, min(k, 4 - k, 1))
        }
        self.init(red: channel(5), green: channel(3), blue: channel(1))
    }

    /// Hue and saturation of this color, ignoring its brightness. Gray has hue 0.
    public var hueSaturation: (hue: Double, saturation: Double) {
        let color = clamped()
        let maximum = max(color.red, color.green, color.blue)
        let difference = maximum - min(color.red, color.green, color.blue)
        guard maximum > 0, difference > 0 else { return (0, 0) }
        var hue: Double
        if maximum == color.red {
            hue = (color.green - color.blue) / difference
        } else if maximum == color.green {
            hue = (color.blue - color.red) / difference + 2
        } else {
            hue = (color.red - color.green) / difference + 4
        }
        hue = (hue / 6 + 1).truncatingRemainder(dividingBy: 1)
        return (hue, difference / maximum)
    }

    /// The whites the single-color mode offers, from cold to warm.
    public static let whiteKelvinRange = 2000.0...9000.0

    /// The sRGB color of a white with this color temperature (Tanner Helland's fit of the
    /// black-body curve, good from 1000 K to 40000 K).
    public static func white(kelvin: Double) -> LightingRGB {
        let t = min(max(kelvin, 1000), 40000) / 100
        let red = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
        let green = t <= 66
            ? 99.4708025861 * log(t) - 161.1195681661
            : 288.1221695283 * pow(t - 60, -0.0755148492)
        let blue = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)
        return LightingRGB(red: red / 255, green: green / 255, blue: blue / 255).clamped()
    }

    /// Color temperature for a slider position: 0 is the coldest white, 1 the warmest.
    /// Even steps in between look even, because they are even in mired (1 000 000 / K).
    public static func whiteKelvin(warmth: Double) -> Double {
        let cold = 1_000_000 / whiteKelvinRange.upperBound
        let warm = 1_000_000 / whiteKelvinRange.lowerBound
        return 1_000_000 / (cold + (warm - cold) * min(max(warmth, 0), 1))
    }

    public static func white(warmth: Double) -> LightingRGB {
        white(kelvin: whiteKelvin(warmth: warmth))
    }

    /// The slider position whose white is closest to this color, judged by the balance
    /// of red and blue. Exact for colors made by `white(warmth:)`.
    public var whiteWarmth: Double {
        func balance(_ color: LightingRGB) -> Double {
            let maximum = max(color.red, color.green, color.blue)
            return maximum > 0 ? (color.blue - color.red) / maximum : 0
        }
        let target = balance(clamped())
        var cold = 0.0
        var warm = 1.0
        for _ in 0..<32 {
            let middle = (cold + warm) / 2
            if balance(.white(warmth: middle)) > target {
                cold = middle
            } else {
                warm = middle
            }
        }
        return (cold + warm) / 2
    }
}
