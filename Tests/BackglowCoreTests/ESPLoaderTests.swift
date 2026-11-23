import CryptoKit
import XCTest
@testable import BackglowCore

/// Plays the ROM serial loader of an ESP8266 or ESP32 closely enough to run a whole flash.
private final class SimulatedROM: ESPSerialLink {
    let chip: ESPChip
    var flash = [UInt32: UInt8]()
    var commands: [UInt8] = []
    var flashBegins: [[UInt32]] = []
    /// Resets that do not reach the loader, like a board whose auto-reset is slow.
    var ignoredResets = 0
    var respondsAtAll = true
    var corruptAfterWrite = false
    var failingCommand: UInt8?
    private(set) var hardResets = 0

    private var lines = (dtr: false, rts: false)
    private var inLoader = false
    private var output = Data()
    private var decoder = SLIP.Decoder()
    private var region: (offset: UInt32, blocks: UInt32, nextSequence: UInt32)?

    init(chip: ESPChip) { self.chip = chip }

    func setLines(dtr: Bool, rts: Bool) throws {
        // EN rising (RTS released) with GPIO0 low (DTR asserted) enters the loader;
        // EN rising with GPIO0 high runs the application.
        if lines.rts, !rts {
            if dtr {
                if ignoredResets > 0 { ignoredResets -= 1 } else { inLoader = respondsAtAll }
            } else {
                inLoader = false
                hardResets += 1
            }
        }
        lines = (dtr, rts)
    }

    func pause(_ seconds: TimeInterval) {}
    func discardInput() { output.removeAll() }

    func read(timeout: TimeInterval) throws -> Data {
        defer { output.removeAll() }
        return output
    }

    func write(_ data: Data) throws {
        guard inLoader else { return }
        for packet in decoder.append(data) { handle([UInt8](packet)) }
    }

    private func respond(_ command: UInt8, value: UInt32 = 0, data: [UInt8] = [], status: UInt8 = 0) {
        let body = data + [status, status == 0 ? 0 : 0x05] + Array(repeating: 0, count: chip.statusLength - 2)
        var bytes: [UInt8] = [0x01, command]
        bytes.appendLE(UInt16(body.count))
        bytes.appendLE(value)
        // Boot noise and a stray delimiter in front, as the real ROM prints at reset.
        output += Data("ets Jun  8 2016\r\n".utf8) + SLIP.encode(Data(bytes + body))
    }

    private func handle(_ packet: [UInt8]) {
        let command = packet[1]
        let payload = Array(packet[8...])
        let word = { (index: Int) in payload.readLE32(at: index * 4) }
        commands.append(command)
        if command == failingCommand { respond(command, status: 1); return }
        switch ESPCommand(rawValue: command) {
        case .sync:
            for _ in 0..<(chip == .esp32 ? 8 : 1) { respond(command) }
        case .readRegister:
            respond(command, value: word(0) == 0x4000_1000 ? chip.magicValue : 0)
        case .spiAttach:
            XCTAssertEqual(chip, .esp32)
            respond(command)
        case .flashBegin:
            flashBegins.append((0..<4).map(word))
            region = (word(3), word(1), 0)
            respond(command)
        case .flashData:
            guard var current = region else { return respond(command, status: 1) }
            let length = Int(word(0))
            let block = Array(payload[16..<(16 + length)])
            XCTAssertEqual(word(1), current.nextSequence)
            XCTAssertEqual(packet.readLE32(at: 4), ESPCommand.checksum(Data(block)))
            for (index, byte) in block.enumerated() {
                flash[current.offset + current.nextSequence * UInt32(ESPCommand.blockSize) + UInt32(index)] = byte
            }
            if corruptAfterWrite { flash[current.offset] = ~(flash[current.offset] ?? 0) }
            current.nextSequence += 1
            region = current
            respond(command)
        case .flashMD5:
            guard chip == .esp32 else { return respond(command, status: 1) }
            let bytes = (0..<word(1)).map { flash[word(0) + $0] ?? 0xff }
            let hex = Insecure.MD5.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
            respond(command, data: Array(hex.utf8))
        default:
            respond(command, status: 1)
        }
    }

    func bytes(at offset: UInt32, count: Int) -> [UInt8] {
        (0..<UInt32(count)).map { flash[offset + $0] ?? 0xff }
    }
}

final class ESPLoaderTests: XCTestCase {
    private func sample(_ count: Int, seed: UInt8) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) ^ seed })
    }

    func testSLIPEscapesAndSkipsNoiseAcrossChunks() {
        let packet = Data([0x01, 0xc0, 0x02, 0xdb, 0x03])
        let encoded = SLIP.encode(packet)
        XCTAssertEqual(Array(encoded), [0xc0, 0x01, 0xdb, 0xdc, 0x02, 0xdb, 0xdd, 0x03, 0xc0])
        var decoder = SLIP.Decoder()
        let stream = Data("boot noise".utf8) + encoded + encoded
        var packets: [Data] = []
        for byte in stream { packets += decoder.append(Data([byte])) }
        XCTAssertEqual(packets, [packet, packet])
    }

    func testESP8266EraseSizeMatchesEsptool() {
        XCTAssertEqual(ESPCommand.esp8266EraseSize(offset: 0, size: 0), 0)
        XCTAssertEqual(ESPCommand.esp8266EraseSize(offset: 0, size: 0x1000), 0x1000)
        XCTAssertEqual(ESPCommand.esp8266EraseSize(offset: 0, size: 300_000), (74 - 16) * 4096)
        XCTAssertEqual(ESPCommand.esp8266EraseSize(offset: 0x3000, size: 0x5000), 3 * 4096)
    }

    func testFlashesESP32RegionsAndVerifiesThem() throws {
        let rom = SimulatedROM(chip: .esp32)
        rom.ignoredResets = 1 // The second reset reaches the loader.
        let loader = ESPLoader(link: rom)
        XCTAssertEqual(try loader.connect(), .esp32)
        let bootloader = sample(1027, seed: 0x11) // Not a multiple of 4: padded with 0xFF.
        let firmware = sample(3000, seed: 0x5a)
        var steps: [ESPLoader.Step] = []
        try loader.flash([FlashRegion(offset: 0x1000, data: bootloader),
                          FlashRegion(offset: 0x10000, data: firmware)],
                         expected: .esp32) { steps.append($0) }
        try loader.hardReset()

        XCTAssertEqual(rom.bytes(at: 0x1000, count: 1027), Array(bootloader))
        XCTAssertEqual(rom.bytes(at: 0x1000 + 1027, count: 1), [0xff])
        XCTAssertEqual(rom.bytes(at: 0x10000, count: 3000), Array(firmware))
        XCTAssertEqual(rom.flashBegins, [[1028, 2, 0x400, 0x1000], [3000, 3, 0x400, 0x10000]])
        XCTAssertTrue(rom.commands.contains(ESPCommand.spiAttach.rawValue))
        XCTAssertEqual(rom.commands.filter { $0 == ESPCommand.flashMD5.rawValue }.count, 2)
        XCTAssertFalse(rom.commands.contains(ESPCommand.flashEnd.rawValue))
        XCTAssertEqual(rom.hardResets, 1)
        XCTAssertTrue(steps.contains(.verifying(region: 1)))
        XCTAssertEqual(steps.last, .verifying(region: 1))
    }

    func testFlashesESP8266WithEraseWorkaroundAndWithoutMD5() throws {
        let rom = SimulatedROM(chip: .esp8266)
        let loader = ESPLoader(link: rom)
        XCTAssertEqual(try loader.connect(), .esp8266)
        let firmware = sample(5000, seed: 0x33)
        try loader.flash([FlashRegion(offset: 0, data: firmware)], expected: .esp8266)
        XCTAssertEqual(rom.bytes(at: 0, count: 5000), Array(firmware))
        // An empty flash begin attaches the flash, then the real one with the smaller erase.
        XCTAssertEqual(rom.flashBegins, [[0, 0, 0x400, 0], [4096, 5, 0x400, 0]])
        XCTAssertFalse(rom.commands.contains(ESPCommand.flashMD5.rawValue))
        XCTAssertFalse(rom.commands.contains(ESPCommand.spiAttach.rawValue))
    }

    func testWrongChipStopsBeforeAnyWrite() throws {
        let rom = SimulatedROM(chip: .esp8266)
        let loader = ESPLoader(link: rom)
        try loader.connect()
        XCTAssertThrowsError(try loader.flash([FlashRegion(offset: 0, data: sample(64, seed: 1))], expected: .esp32)) {
            XCTAssertEqual($0 as? ESPLoaderError, .wrongChip(expected: .esp32, found: .esp8266))
        }
        XCTAssertTrue(rom.flashBegins.isEmpty)
    }

    func testReportsCorruptedFlash() throws {
        let rom = SimulatedROM(chip: .esp32)
        rom.corruptAfterWrite = true
        let loader = ESPLoader(link: rom)
        try loader.connect()
        XCTAssertThrowsError(try loader.flash([FlashRegion(offset: 0x10000, data: sample(100, seed: 2))], expected: .esp32)) {
            XCTAssertEqual($0 as? ESPLoaderError, .verificationFailed(offset: 0x10000))
        }
    }

    func testReportsSilentBoardAndRejectedCommand() throws {
        let silent = SimulatedROM(chip: .esp32)
        silent.respondsAtAll = false
        XCTAssertThrowsError(try ESPLoader(link: silent).connect(attempts: 2)) {
            XCTAssertEqual($0 as? ESPLoaderError, .noResponse)
        }
        let rejecting = SimulatedROM(chip: .esp32)
        rejecting.failingCommand = ESPCommand.flashBegin.rawValue
        let loader = ESPLoader(link: rejecting)
        try loader.connect()
        XCTAssertThrowsError(try loader.flash([FlashRegion(offset: 0x10000, data: sample(10, seed: 3))], expected: .esp32)) {
            XCTAssertEqual($0 as? ESPLoaderError,
                           .commandFailed(command: ESPCommand.flashBegin.rawValue, status: 1, error: 5))
        }
    }

    func testManifestChecksFileHashes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("esp32dev"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let firmware = sample(256, seed: 9)
        try firmware.write(to: folder.appendingPathComponent("esp32dev/firmware.bin"))
        let hash = SHA256.hash(data: firmware).map { String(format: "%02x", $0) }.joined()
        let json = """
        {"version": "3.4.0", "images": [{"id": "esp32dev", "chip": "esp32", "board": "ESP32 Dev Module",
         "dataPin": 18, "parts": [{"offset": 65536, "file": "esp32dev/firmware.bin", "sha256": "\(hash)"}]}]}
        """
        var manifest = try JSONDecoder().decode(FirmwareManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.version, FirmwareVersion(major: 3, minor: 4, patch: 0))
        XCTAssertEqual(try FirmwareManifest.regions(for: manifest.images[0], in: folder),
                       [FlashRegion(offset: 0x10000, data: firmware)])
        manifest.images[0].parts[0].sha256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try FirmwareManifest.regions(for: manifest.images[0], in: folder)) {
            XCTAssertEqual($0 as? FirmwareManifestError, .hashMismatch("esp32dev/firmware.bin"))
        }
    }

    func testFirmwareVersionsCompare() {
        XCTAssertNil(FirmwareVersion("3.4"))
        XCTAssertNil(FirmwareVersion("3.4.x"))
        XCTAssertLessThan(FirmwareVersion("3.3.9")!, FirmwareVersion("3.4.0")!)
        XCTAssertLessThan(FirmwareVersion("3.4.0")!, FirmwareVersion("10.0.0")!)
        XCTAssertEqual(FirmwareVersion("3.4.0")!.description, "3.4.0")
    }
}
