import Foundation

public struct ControllerProfile: Equatable, Sendable {
    public static let schemaVersion: UInt8 = 1
    public static let byteCount = 24

    public var physicalLEDs: Int
    public var activeLEDs: Int
    public var rows: Int
    public var columns: Int
    public var startOffset: Int
    public var reversed: Bool
    public var ignoreBlackBars: Bool
    public var calibration: ColorCalibration

    public init(configuration: LightingConfiguration) {
        physicalLEDs = configuration.deviceLEDCount
        activeLEDs = configuration.ledCount
        rows = configuration.rows
        columns = configuration.columns
        startOffset = configuration.startOffset
        reversed = configuration.reversed
        ignoreBlackBars = configuration.ignoreBlackBars
        calibration = configuration.calibration
    }

    public func applying(to configuration: LightingConfiguration) -> LightingConfiguration {
        var result = configuration
        result.deviceLEDCount = physicalLEDs
        result.ledCount = activeLEDs
        result.rows = rows
        result.columns = columns
        result.startOffset = startOffset
        result.reversed = reversed
        result.ignoreBlackBars = ignoreBlackBars
        result.calibration = calibration
        result.normalize()
        return result
    }

    public var isValid: Bool {
        let zones = 2 * (rows + columns) - 4
        return (1...255).contains(physicalLEDs) &&
            (1...min(physicalLEDs, zones)).contains(activeLEDs) &&
            (2...50).contains(rows) && (2...50).contains(columns) &&
            (0..<zones).contains(startOffset) &&
            (0...2).contains(calibration.saturation) &&
            (0.25...3).contains(calibration.gamma) &&
            (0...2).contains(calibration.redGain) &&
            (0...2).contains(calibration.greenGain) &&
            (0...2).contains(calibration.blueGain) &&
            (0...1).contains(calibration.brightness) &&
            (0...0.95).contains(calibration.smoothing)
    }

    public func encoded() -> [UInt8]? {
        guard isValid else { return nil }
        var bytes: [UInt8] = [Self.schemaVersion]
        bytes.appendLE(UInt16(physicalLEDs))
        bytes.appendLE(UInt16(activeLEDs))
        bytes += [UInt8(rows), UInt8(columns)]
        bytes.appendLE(UInt16(startOffset))
        bytes.append((reversed ? 1 : 0) | (ignoreBlackBars ? 2 : 0))
        for value in [calibration.saturation, calibration.gamma, calibration.redGain,
                      calibration.greenGain, calibration.blueGain, calibration.brightness,
                      calibration.smoothing] {
            bytes.appendLE(UInt16((value * 10_000).rounded()))
        }
        return bytes
    }

    public static func decode(_ bytes: [UInt8]) -> ControllerProfile? {
        guard bytes.count == byteCount, bytes[0] == schemaVersion,
              bytes[9] & ~UInt8(3) == 0 else { return nil }
        var config = LightingConfiguration()
        config.deviceLEDCount = Int(bytes.readLE16(at: 1))
        config.ledCount = Int(bytes.readLE16(at: 3))
        config.rows = Int(bytes[5])
        config.columns = Int(bytes[6])
        config.startOffset = Int(bytes.readLE16(at: 7))
        config.reversed = bytes[9] & 1 != 0
        config.ignoreBlackBars = bytes[9] & 2 != 0
        let values = stride(from: 10, to: 24, by: 2).map { Double(bytes.readLE16(at: $0)) / 10_000 }
        config.calibration.saturation = values[0]
        config.calibration.gamma = values[1]
        config.calibration.redGain = values[2]
        config.calibration.greenGain = values[3]
        config.calibration.blueGain = values[4]
        config.calibration.brightness = values[5]
        config.calibration.smoothing = values[6]
        let profile = ControllerProfile(configuration: config)
        return profile.isValid ? profile : nil
    }
}

public enum ControllerMessage: UInt8, Sendable {
    case hello = 1
    case getProfile = 2
    case profile = 3
    case setProfile = 4
    case saved = 5
    case error = 6
    case noProfile = 7
    case initializeStorage = 8
}

public struct ControllerFrame: Equatable, Sendable {
    public static let probe = Data("AL3?".utf8)
    private static let magic: [UInt8] = Array("AL3!".utf8)
    public let message: ControllerMessage
    public let payload: [UInt8]

    public init(_ message: ControllerMessage, payload: [UInt8] = []) {
        self.message = message
        self.payload = payload
    }

    public func encoded() -> Data? {
        guard payload.count <= 64 else { return nil }
        let body = [message.rawValue, UInt8(payload.count)] + payload
        let crc = Self.crc16(body)
        return Data(Self.magic + body + [UInt8(crc & 0xff), UInt8(crc >> 8)])
    }

    public static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xffff
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    public static func profilePayload(revision: UInt32, profile: ControllerProfile) -> [UInt8]? {
        guard let body = profile.encoded() else { return nil }
        var bytes: [UInt8] = []
        bytes.appendLE(revision)
        return bytes + body
    }

    public static func parseProfilePayload(_ bytes: [UInt8]) -> (UInt32, ControllerProfile)? {
        guard bytes.count == ControllerProfile.byteCount + 4,
              let profile = ControllerProfile.decode(Array(bytes[4...])) else { return nil }
        return (bytes.readLE32(at: 0), profile)
    }
}

public struct ControllerFrameParser {
    private var buffer: [UInt8] = []
    private static let magic: [UInt8] = Array("AL3!".utf8)

    public init() {}

    public mutating func append(_ data: Data) -> [ControllerFrame] {
        buffer += data
        var frames: [ControllerFrame] = []
        var cursor = 0
        while cursor < buffer.count {
            let available = buffer.count - cursor
            let prefixCount = min(available, Self.magic.count)
            if !(0..<prefixCount).allSatisfy({ buffer[cursor + $0] == Self.magic[$0] }) {
                cursor += 1
                continue
            }
            guard available >= 8 else { break }
            let length = Int(buffer[cursor + 5])
            guard length <= 64 else {
                cursor += 1
                continue
            }
            let end = cursor + 6 + length
            guard buffer.count >= end + 2 else { break }
            let expected = buffer.readLE16(at: end)
            let actual = ControllerFrame.crc16(Array(buffer[(cursor + 4)..<end]))
            guard expected == actual, let kind = ControllerMessage(rawValue: buffer[cursor + 4]) else {
                cursor += 1
                continue
            }
            frames.append(ControllerFrame(kind, payload: Array(buffer[(cursor + 6)..<end])))
            cursor = end + 2
        }
        if cursor > 0 { buffer.removeFirst(cursor) }
        return frames
    }
}

extension Array where Element == UInt8 {
    public mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8(value >> 8))
    }

    public mutating func appendLE(_ value: UInt32) {
        appendLE(UInt16(value & 0xffff))
        appendLE(UInt16(value >> 16))
    }

    public func readLE16(at index: Int) -> UInt16 {
        UInt16(self[index]) | UInt16(self[index + 1]) << 8
    }

    public func readLE32(at index: Int) -> UInt32 {
        UInt32(readLE16(at: index)) | UInt32(readLE16(at: index + 2)) << 16
    }
}
