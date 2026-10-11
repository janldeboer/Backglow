import Foundation

/// sRGB transfer functions. Zone averages are computed in linear light and
/// encoded back to sRGB before user calibration, as HyperHDR does.
public enum SRGB {
    public static func toLinear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    public static func toNonlinear(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
    }

    /// Linear value for every 8-bit sRGB code, for the CPU reference path.
    public static let linearTable: [Double] = (0...255).map { toLinear(Double($0) / 255) }
}

public extension LightingRGB {
    var linearized: LightingRGB {
        LightingRGB(red: SRGB.toLinear(red), green: SRGB.toLinear(green), blue: SRGB.toLinear(blue))
    }

    var srgbEncoded: LightingRGB {
        LightingRGB(red: SRGB.toNonlinear(red), green: SRGB.toNonlinear(green), blue: SRGB.toNonlinear(blue))
    }
}
