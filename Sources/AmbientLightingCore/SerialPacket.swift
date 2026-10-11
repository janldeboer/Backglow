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

    /// LED update rate the `led`/`les` stream can sustain on a serial link, capped at 60 Hz.
    /// Assumes 10 bits per byte on the wire and leaves 10 % headroom.
    public static func outputFrequency(ledCount: Int, baudRate: Int) -> Double {
        let frameBytes = Double(min(max(ledCount, 0), 256) * 7 + 3)
        let sustainable = Double(baudRate) / 10 * 0.9 / frameBytes
        return min(max(sustainable, 15), 60)
    }
}
