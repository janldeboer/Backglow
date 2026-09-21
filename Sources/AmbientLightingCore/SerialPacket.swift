import Foundation

public enum SerialPacket {
    /// Existing controller protocol: "led" + index/R/G/B for each LED, then "les".
    public static func frame(colors: [LightingRGB], maximumLEDs: Int = 70) -> Data {
        var data = Data()
        let limit = min(max(maximumLEDs, 0), 256)
        data.reserveCapacity(min(colors.count, limit) * 7 + 3)
        for (index, color) in colors.prefix(limit).enumerated() {
            let rgb = color.clamped()
            data.append(contentsOf: [108, 101, 100, UInt8(index)])
            data.append(UInt8((rgb.red * 255).rounded()))
            data.append(UInt8((rgb.green * 255).rounded()))
            data.append(UInt8((rgb.blue * 255).rounded()))
        }
        data.append(contentsOf: [108, 101, 115])
        return data
    }
}
