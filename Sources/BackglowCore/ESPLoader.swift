import CryptoKit
import Foundation

/// The serial line to an ESP chip. Implemented over a POSIX port in the app and by a
/// simulated ROM loader in the tests. All calls come from one thread.
public protocol ESPSerialLink: AnyObject {
    func write(_ data: Data) throws
    /// Returns the bytes that arrive within `timeout`, or an empty value.
    func read(timeout: TimeInterval) throws -> Data
    /// Sets both modem lines at once. `true` asserts the line (low voltage).
    func setLines(dtr: Bool, rts: Bool) throws
    func discardInput()
    func pause(_ seconds: TimeInterval)
}

public enum ESPChip: String, Codable, CaseIterable, Sendable {
    case esp8266, esp32

    /// Value of the ROM's chip-detect register at 0x40001000.
    var magicValue: UInt32 {
        switch self {
        case .esp8266: 0xfff0_c101
        case .esp32: 0x00f0_1d83
        }
    }

    /// The ROM loader appends this many status bytes to every response.
    var statusLength: Int { self == .esp8266 ? 2 : 4 }

    public var displayName: String {
        switch self {
        case .esp8266: "ESP8266"
        case .esp32: "ESP32"
        }
    }
}

public enum ESPLoaderError: Error, Equatable, Sendable {
    case noResponse
    case unsupportedChip(UInt32)
    case wrongChip(expected: ESPChip, found: ESPChip)
    case commandFailed(command: UInt8, status: UInt8, error: UInt8)
    case invalidResponse
    case verificationFailed(offset: UInt32)
    case imageTooLarge
}

/// Byte framing used by the ESP ROM loader: packets between 0xC0, with 0xC0 and 0xDB escaped.
public enum SLIP {
    public static func encode(_ packet: Data) -> Data {
        var out = Data([0xc0])
        out.reserveCapacity(packet.count + 8)
        for byte in packet {
            switch byte {
            case 0xc0: out.append(contentsOf: [0xdb, 0xdc])
            case 0xdb: out.append(contentsOf: [0xdb, 0xdd])
            default: out.append(byte)
            }
        }
        out.append(0xc0)
        return out
    }

    /// Collects bytes and returns complete packets. Bytes outside a packet, such as boot
    /// messages from the chip, are skipped.
    public struct Decoder: Sendable {
        private var packet = Data()
        private var inPacket = false
        private var escaping = false

        public init() {}

        public mutating func append(_ data: Data) -> [Data] {
            var packets: [Data] = []
            for byte in data {
                if !inPacket {
                    if byte == 0xc0 { inPacket = true; packet.removeAll(keepingCapacity: true) }
                    continue
                }
                if escaping {
                    escaping = false
                    switch byte {
                    case 0xdc: packet.append(0xc0)
                    case 0xdd: packet.append(0xdb)
                    default: inPacket = false // Broken escape: drop the packet.
                    }
                    continue
                }
                switch byte {
                case 0xc0:
                    // Two delimiters in a row start a packet rather than end an empty one.
                    if packet.isEmpty { continue }
                    packets.append(packet)
                    packet.removeAll(keepingCapacity: true)
                    inPacket = false
                case 0xdb: escaping = true
                default: packet.append(byte)
                }
            }
            return packets
        }
    }
}

/// Commands and packet layout of the ESP8266/ESP32 ROM serial loader, as used by esptool.
public enum ESPCommand: UInt8, Sendable {
    case flashBegin = 0x02
    case flashData = 0x03
    case flashEnd = 0x04
    case sync = 0x08
    case readRegister = 0x0a
    case spiAttach = 0x0d
    case flashMD5 = 0x13

    public static let blockSize = 0x400
    static let chipDetectRegister: UInt32 = 0x4000_1000

    public static func checksum(_ data: Data) -> UInt32 {
        UInt32(data.reduce(UInt8(0xef)) { $0 ^ $1 })
    }

    /// Direction 0, command, payload length, checksum (only used by flash data), payload.
    public static func packet(_ command: ESPCommand, payload: Data = Data(), checksum: UInt32 = 0) -> Data {
        var bytes: [UInt8] = [0x00, command.rawValue]
        bytes.appendLE(UInt16(payload.count))
        bytes.appendLE(checksum)
        return Data(bytes) + payload
    }

    static func words(_ values: UInt32...) -> Data {
        var bytes: [UInt8] = []
        for value in values { bytes.appendLE(value) }
        return Data(bytes)
    }

    static let syncPayload = Data([0x07, 0x07, 0x12, 0x20] + [UInt8](repeating: 0x55, count: 32))

    /// The ESP8266 ROM erases too much for some sizes; esptool asks for less to compensate.
    public static func esp8266EraseSize(offset: Int, size: Int) -> Int {
        let sectorSize = 4096
        let sectorsPerBlock = 16
        let sectors = (size + sectorSize - 1) / sectorSize
        var head = sectorsPerBlock - (offset / sectorSize) % sectorsPerBlock
        if sectors < head { head = sectors }
        return sectors < 2 * head ? (sectors + 1) / 2 * sectorSize : (sectors - head) * sectorSize
    }
}

public struct ESPResponse: Equatable, Sendable {
    public let command: UInt8
    public let value: UInt32
    public let data: Data

    public init?(_ packet: Data) {
        let bytes = [UInt8](packet)
        guard bytes.count >= 8, bytes[0] == 0x01 else { return nil }
        let size = Int(bytes.readLE16(at: 2))
        guard bytes.count >= 8 + size else { return nil }
        command = bytes[1]
        value = bytes.readLE32(at: 4)
        data = Data(bytes[8..<(8 + size)])
    }
}

/// One file written to one flash address.
public struct FlashRegion: Equatable, Sendable {
    public let offset: UInt32
    public let data: Data

    public init(offset: UInt32, data: Data) {
        self.offset = offset
        self.data = data
    }
}

/// Talks to the ROM loader of an ESP8266 or ESP32: reset into download mode, identify the
/// chip, write regions block by block and, where the ROM can, verify them with MD5.
/// The ROM's own loader is used throughout; no stub is uploaded.
public final class ESPLoader {
    public enum Step: Equatable, Sendable {
        case connecting
        case connected(ESPChip)
        case erasing(region: Int)
        case writing(region: Int, fraction: Double)
        case verifying(region: Int)
        case restarting
    }

    private let link: ESPSerialLink
    private var decoder = SLIP.Decoder()
    private var pending: [Data] = []
    public private(set) var chip: ESPChip?

    public init(link: ESPSerialLink) {
        self.link = link
    }

    /// Resets the chip into the ROM loader and returns its type. Tries the reset several
    /// times with a short and a long delay, as esptool does.
    @discardableResult
    public func connect(attempts: Int = 4) throws -> ESPChip {
        for attempt in 0..<attempts {
            try enterDownloadMode(delay: attempt % 2 == 0 ? 0.05 : 0.55)
            if trySync() {
                let magic = try command(.readRegister, payload: ESPCommand.words(ESPCommand.chipDetectRegister)).value
                guard let found = ESPChip.allCases.first(where: { $0.magicValue == magic }) else {
                    throw ESPLoaderError.unsupportedChip(magic)
                }
                chip = found
                return found
            }
        }
        throw ESPLoaderError.noResponse
    }

    /// Writes the regions in order. Throws before anything is written if the chip does not
    /// match `expected`. Leaves the chip in the loader; call `hardReset()` afterwards.
    public func flash(_ regions: [FlashRegion], expected: ESPChip,
                      progress: (Step) -> Void = { _ in }) throws {
        guard let chip else { throw ESPLoaderError.noResponse }
        guard chip == expected else { throw ESPLoaderError.wrongChip(expected: expected, found: chip) }
        progress(.connected(chip))
        // The ROM only enables the SPI flash when asked to. The ESP8266 ROM has no attach
        // command; an empty flash begin does the same there.
        switch chip {
        case .esp32: try command(.spiAttach, payload: ESPCommand.words(0, 0))
        case .esp8266: try command(.flashBegin, payload: ESPCommand.words(0, 0, UInt32(ESPCommand.blockSize), 0))
        }
        for (index, region) in regions.enumerated() {
            let image = Self.padded(region.data, to: 4)
            guard image.count <= 16 * 1024 * 1024 else { throw ESPLoaderError.imageTooLarge }
            let blocks = (image.count + ESPCommand.blockSize - 1) / ESPCommand.blockSize
            let eraseSize = chip == .esp8266
                ? ESPCommand.esp8266EraseSize(offset: Int(region.offset), size: image.count) : image.count
            progress(.erasing(region: index))
            try command(.flashBegin,
                        payload: ESPCommand.words(UInt32(eraseSize), UInt32(blocks),
                                                  UInt32(ESPCommand.blockSize), region.offset),
                        timeout: Self.timeout(perMegabyte: 30, bytes: eraseSize))
            for block in 0..<blocks {
                let start = block * ESPCommand.blockSize
                var chunk = image.subdata(in: start..<min(start + ESPCommand.blockSize, image.count))
                chunk.append(Data(repeating: 0xff, count: ESPCommand.blockSize - chunk.count))
                try command(.flashData,
                            payload: ESPCommand.words(UInt32(chunk.count), UInt32(block), 0, 0) + chunk,
                            checksum: ESPCommand.checksum(chunk),
                            timeout: Self.timeout(perMegabyte: 40, bytes: chunk.count))
                progress(.writing(region: index, fraction: Double(block + 1) / Double(blocks)))
            }
            // The ESP8266 ROM cannot compute an MD5; its per-block checksums are all there is.
            if chip == .esp32 {
                progress(.verifying(region: index))
                let response = try command(.flashMD5, payload: ESPCommand.words(region.offset, UInt32(image.count), 0, 0),
                                           timeout: Self.timeout(perMegabyte: 8, bytes: image.count))
                let digest = Insecure.MD5.hash(data: image).map { String(format: "%02x", $0) }.joined()
                guard response.data.count >= 32 + chip.statusLength,
                      String(decoding: response.data.prefix(32), as: UTF8.self).lowercased() == digest else {
                    throw ESPLoaderError.verificationFailed(offset: region.offset)
                }
            }
        }
        // No flash end: on the ROM loader it would start the old code right away.
    }

    /// Pulses EN through RTS so the chip starts the code in flash.
    public func hardReset() throws {
        try link.setLines(dtr: false, rts: true)
        link.pause(0.1)
        try link.setLines(dtr: false, rts: false)
    }

    // MARK: - Protocol

    /// GPIO0 low while EN rises selects the ROM loader. Both lines are set together, which
    /// the two-transistor auto-reset circuit of common dev boards needs.
    private func enterDownloadMode(delay: TimeInterval) throws {
        try link.setLines(dtr: false, rts: false)
        try link.setLines(dtr: true, rts: true)
        try link.setLines(dtr: false, rts: true) // GPIO0 high, EN low: chip held in reset.
        link.pause(0.1)
        try link.setLines(dtr: true, rts: false) // GPIO0 low, EN high: chip starts the loader.
        link.pause(delay)
        try link.setLines(dtr: false, rts: false)
        link.pause(0.05)
        link.discardInput()
        decoder = SLIP.Decoder()
        pending.removeAll()
    }

    private func trySync() -> Bool {
        for _ in 0..<5 {
            if (try? command(.sync, payload: ESPCommand.syncPayload, timeout: 0.1)) != nil {
                // The ROM answers a sync several times; drop the extra answers.
                link.pause(0.05)
                link.discardInput()
                decoder = SLIP.Decoder()
                pending.removeAll()
                return true
            }
        }
        return false
    }

    @discardableResult
    private func command(_ command: ESPCommand, payload: Data = Data(), checksum: UInt32 = 0,
                         timeout: TimeInterval = 3) throws -> ESPResponse {
        try link.write(SLIP.encode(ESPCommand.packet(command, payload: payload, checksum: checksum)))
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if pending.isEmpty {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw ESPLoaderError.noResponse }
                pending += decoder.append(try link.read(timeout: min(remaining, 0.05)))
                continue
            }
            let packet = pending.removeFirst()
            guard let response = ESPResponse(packet), response.command == command.rawValue else { continue }
            let statusLength = chip?.statusLength ?? (response.data.count == 2 ? 2 : 4)
            guard response.data.count >= statusLength else { throw ESPLoaderError.invalidResponse }
            let status = response.data[response.data.count - statusLength]
            let error = response.data[response.data.count - statusLength + 1]
            guard status == 0 else {
                throw ESPLoaderError.commandFailed(command: command.rawValue, status: status, error: error)
            }
            return response
        }
    }

    static func padded(_ data: Data, to alignment: Int) -> Data {
        let remainder = data.count % alignment
        return remainder == 0 ? data : data + Data(repeating: 0xff, count: alignment - remainder)
    }

    static func timeout(perMegabyte seconds: Double, bytes: Int) -> TimeInterval {
        max(3, seconds * Double(bytes) / 1_000_000)
    }
}
