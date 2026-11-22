import Foundation

/// How the colors travel over the serial link.
public enum SerialProtocol: String, Codable, CaseIterable, Sendable {
    /// Adalight once Backglow's firmware reports it, otherwise the older `led`/`les` stream.
    case automatic
    /// "Ada", LED count, checksum, then RGB per LED. Understood by WLED, HyperHDR's
    /// HyperSerial firmware, Prismatik sketches and Backglow's firmware from 3.4.
    case adalight
    /// Backglow's original stream: "led" + index/R/G/B for each LED, then "les".
    case legacy

    /// The protocol actually sent. Only `adalight` and `legacy` are returned.
    public func resolved(controllerSupportsAdalight: Bool) -> SerialProtocol {
        switch self {
        case .automatic: controllerSupportsAdalight ? .adalight : .legacy
        case .adalight, .legacy: self
        }
    }
}

public enum SerialPacket {
    /// The largest strip the `led`/`les` stream can address with its one-byte index.
    public static let legacyLEDLimit = 256
    /// The largest strip an Adalight header can describe.
    public static let adalightLEDLimit = 65_536

    public static func frame(colors: [LightingRGB], maximumLEDs: Int = 70,
                             protocol serialProtocol: SerialProtocol = .legacy) -> Data {
        switch serialProtocol {
        case .adalight: adalightFrame(colors: colors, ledCount: maximumLEDs)
        case .legacy, .automatic: legacyFrame(colors: colors, maximumLEDs: maximumLEDs)
        }
    }

    /// Existing controller protocol: "led" + index/R/G/B for each LED, then "les".
    /// LEDs after the last one sent are switched off by the firmware.
    public static func legacyFrame(colors: [LightingRGB], maximumLEDs: Int = 70) -> Data {
        var data = Data()
        let limit = min(max(maximumLEDs, 0), legacyLEDLimit)
        data.reserveCapacity(min(colors.count, limit) * 7 + 3)
        for (index, color) in colors.prefix(limit).enumerated() {
            let (red, green, blue) = bytes(color)
            data.append(contentsOf: [108, 101, 100, UInt8(index), red, green, blue])
        }
        data.append(contentsOf: [108, 101, 115])
        return data
    }

    /// Adalight: "Ada", high and low byte of (count - 1), their XOR with 0x55, then R, G, B
    /// for every LED. The frame always covers the whole strip: colors beyond `ledCount` are
    /// dropped and missing LEDs are sent black, because receivers such as WLED keep LEDs that
    /// a frame does not mention.
    public static func adalightFrame(colors: [LightingRGB], ledCount: Int) -> Data {
        let count = min(max(ledCount, 0), adalightLEDLimit)
        guard count > 0 else { return Data() }
        let high = UInt8((count - 1) >> 8)
        let low = UInt8((count - 1) & 0xff)
        var data = Data([65, 100, 97, high, low, high ^ low ^ 0x55])
        data.reserveCapacity(6 + count * 3)
        for color in colors.prefix(count) {
            let (red, green, blue) = bytes(color)
            data.append(contentsOf: [red, green, blue])
        }
        data.append(contentsOf: repeatElement(0, count: max(count - colors.count, 0) * 3))
        return data
    }

    /// Bytes on the wire for one frame of `colorCount` colors on a strip of `maximumLEDs`.
    public static func frameByteCount(colorCount: Int, maximumLEDs: Int,
                                      protocol serialProtocol: SerialProtocol) -> Int {
        switch serialProtocol {
        case .adalight:
            let count = min(max(maximumLEDs, 0), adalightLEDLimit)
            return count > 0 ? 6 + count * 3 : 0
        case .legacy, .automatic:
            return min(max(colorCount, 0), min(max(maximumLEDs, 0), legacyLEDLimit)) * 7 + 3
        }
    }

    /// LED update rate the `led`/`les` stream can sustain on a serial link, capped at 60 Hz.
    public static func outputFrequency(ledCount: Int, baudRate: Int) -> Double {
        outputFrequency(frameBytes: min(max(ledCount, 0), legacyLEDLimit) * 7 + 3, baudRate: baudRate)
    }

    /// Update rate a frame of this size can sustain, between 15 and 60 Hz.
    /// Assumes 10 bits per byte on the wire and leaves 10 % headroom.
    public static func outputFrequency(frameBytes: Int, baudRate: Int) -> Double {
        let sustainable = Double(baudRate) / 10 * 0.9 / Double(max(frameBytes, 1))
        return min(max(sustainable, 15), 60)
    }

    private static func bytes(_ color: LightingRGB) -> (UInt8, UInt8, UInt8) {
        let rgb = color.clamped()
        return (UInt8((rgb.red * 255).rounded()), UInt8((rgb.green * 255).rounded()),
                UInt8((rgb.blue * 255).rounded()))
    }
}
