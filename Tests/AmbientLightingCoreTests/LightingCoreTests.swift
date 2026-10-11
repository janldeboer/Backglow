import XCTest
@testable import AmbientLightingCore

final class LightingCoreTests: XCTestCase {
    func testPerimeterMappingKeepsLEDOrderAndEdgePixels() {
        var configuration = LightingConfiguration()
        configuration.rows = 3
        configuration.columns = 4
        configuration.ledCount = 10
        configuration.startOffset = 0
        configuration.reversed = false
        let zones = PerimeterLayout.zones(width: 401, height: 301, configuration: configuration)
        XCTAssertEqual(zones.count, 10)
        XCTAssertEqual(zones.map { [$0.row, $0.column] }, [
            [0,0], [0,1], [0,2], [0,3], [1,3],
            [2,3], [2,2], [2,1], [2,0], [1,0]
        ])
        XCTAssertEqual(zones[3].rect.x + zones[3].rect.width, 401)
        XCTAssertEqual(zones[5].rect.y + zones[5].rect.height, 301)
        XCTAssertEqual(Set(zones.map(\.id)).count, zones.count)
    }

    func testOffsetReverseAndContentBounds() {
        var configuration = LightingConfiguration()
        configuration.rows = 2
        configuration.columns = 3
        configuration.ledCount = 3
        configuration.startOffset = -1
        configuration.reversed = true
        let zones = PerimeterLayout.zones(
            width: 300, height: 200, configuration: configuration,
            contentRect: PixelRect(x: 30, y: 20, width: 240, height: 160)
        )
        XCTAssertEqual(zones.map { [$0.row, $0.column] }, [[0,1], [0,0], [1,0]])
        XCTAssertEqual(zones[0].rect, PixelRect(x: 110, y: 20, width: 80, height: 80))
    }

    func testAverageUsesAllPixelsAndRespectsRowStride() {
        let bytes: [UInt8] = [
            0, 0, 255, 255, 255, 0, 0, 255, 99, 99, 99, 99,
            0, 255, 0, 255, 255, 255, 255, 255, 99, 99, 99, 99
        ]
        let result = bytes.withUnsafeBytes {
            PixelAnalysis.average(
                bytes: $0, bytesPerRow: 12, imageWidth: 2, imageHeight: 2,
                rect: PixelRect(x: 0, y: 0, width: 2, height: 2)
            )
        }
        XCTAssertEqual(result.red, 0.5, accuracy: 0.001)
        XCTAssertEqual(result.green, 0.5, accuracy: 0.001)
        XCTAssertEqual(result.blue, 0.5, accuracy: 0.001)
    }

    func testAverageMixesLightNotCodeValues() {
        let bytes: [UInt8] = [0, 0, 0, 255, 255, 255, 255, 255]
        let result = bytes.withUnsafeBytes {
            PixelAnalysis.average(
                bytes: $0, bytesPerRow: 8, imageWidth: 2, imageHeight: 1,
                rect: PixelRect(x: 0, y: 0, width: 2, height: 1)
            )
        }
        XCTAssertEqual(result.red, 0.5, accuracy: 0.001)
        XCTAssertEqual(result.srgbEncoded.red, 0.735, accuracy: 0.001)
        XCTAssertEqual(SRGB.toNonlinear(SRGB.toLinear(0.3)), 0.3, accuracy: 0.0001)
    }

    func testCalibrationAndSmoothing() {
        var calibration = ColorCalibration()
        calibration.saturation = 0
        let gray = ColorProcessing.corrected(LightingRGB(red: 1, green: 0, blue: 0), with: calibration)
        XCTAssertEqual(gray.red, gray.green, accuracy: 0.001)
        XCTAssertEqual(gray.green, gray.blue, accuracy: 0.001)
        calibration.saturation = 1
        calibration.redGain = 0.5
        let red = ColorProcessing.corrected(LightingRGB(red: 1, green: 0, blue: 0), with: calibration)
        XCTAssertEqual(red.red, 0.5, accuracy: 0.001)
    }

    func testSpringSmoothingIsTimeBasedAndLimitsLumaRate() {
        var smoother = SpringColorSmoother()
        smoother.configure(smoothing: 0.25)
        smoother.setTarget([.black])
        smoother.setTarget([LightingRGB(red: 1, green: 1, blue: 1)])
        // Same elapsed time at two tick rates must give nearly the same color.
        var fast = smoother
        var slow = smoother
        var fastColor = LightingRGB.black
        var slowColor = LightingRGB.black
        for _ in 0..<12 { fastColor = fast.advance(by: 1.0 / 60)[0] }
        for _ in 0..<6 { slowColor = slow.advance(by: 1.0 / 30)[0] }
        XCTAssertEqual(fastColor.red, slowColor.red, accuracy: 0.05)
        // 0.2 s at 1.5 luma per second allows at most 0.3.
        XCTAssertLessThanOrEqual(fastColor.green, 0.3 + 0.001)
        XCTAssertGreaterThan(fastColor.green, 0.1)
        var settled = LightingRGB.black
        for _ in 0..<240 { settled = fast.advance(by: 1.0 / 60)[0] }
        XCTAssertTrue(fast.isSettled)
        XCTAssertEqual(settled, LightingRGB(red: 1, green: 1, blue: 1))

        var off = SpringColorSmoother()
        off.configure(smoothing: 0)
        off.setTarget([.black])
        off.setTarget([LightingRGB(red: 1, green: 0, blue: 0)])
        XCTAssertEqual(off.advance(by: 0.016)[0].red, 1)
    }

    func testAntiFlickerHoldsSubStepNoise() {
        var filter = AntiFlickerFilter()
        let base = LightingRGB(red: 0.1, green: 0.1, blue: 0.1)
        _ = filter.apply([base])
        let noisy = LightingRGB(red: 0.1 + 0.4 / 255, green: 0.1, blue: 0.1)
        XCTAssertEqual(filter.apply([noisy]), [base])
        let moved = LightingRGB(red: 0.1 + 0.6 / 255, green: 0.1, blue: 0.1)
        XCTAssertEqual(filter.apply([moved]), [moved])
    }

    func testOutputFrequencyFollowsSerialBandwidth() {
        XCTAssertEqual(SerialPacket.outputFrequency(ledCount: 70, baudRate: 230_400), 42.06, accuracy: 0.01)
        XCTAssertEqual(SerialPacket.outputFrequency(ledCount: 20, baudRate: 2_000_000), 60)
        XCTAssertEqual(SerialPacket.outputFrequency(ledCount: 255, baudRate: 9_600), 15)
    }

    func testPacketMatchesExistingFirmware() {
        let bytes = Array(SerialPacket.frame(colors: [LightingRGB(red: 1, green: 0, blue: 0)]))
        XCTAssertEqual(bytes, [108, 101, 100, 0, 255, 0, 0, 108, 101, 115])
    }

    func testBlackBarDetectorRetainsDarkFullFrame() {
        let bytes = [UInt8](repeating: 0, count: 100 * 80 * 4)
        let rect = bytes.withUnsafeBytes {
            PixelAnalysis.contentBounds(bytes: $0, bytesPerRow: 400, width: 100, height: 80)
        }
        XCTAssertEqual(rect, PixelRect(x: 0, y: 0, width: 100, height: 80))
    }

    func testControllerProfileRoundTripKeepsComputerSettingsLocal() {
        var local = LightingConfiguration()
        local.displayID = 1234
        local.portPath = "/dev/cu.usbserial-test"
        local.framesPerSecond = 45
        local.captureScale = 0.75
        local.calibration.redGain = 1.42
        let profile = ControllerProfile(configuration: local)
        let bytes = try! XCTUnwrap(profile.encoded())
        XCTAssertEqual(bytes.count, 24)
        XCTAssertEqual(Array(bytes.prefix(10)), [1, 70, 0, 59, 0, 12, 21, 43, 0, 1])
        let decoded = try! XCTUnwrap(ControllerProfile.decode(bytes))
        var otherComputer = LightingConfiguration()
        otherComputer.displayID = 5678
        otherComputer.portPath = "/dev/cu.usbmodem-other"
        otherComputer.framesPerSecond = 20
        let applied = decoded.applying(to: otherComputer)
        XCTAssertEqual(applied.displayID, 5678)
        XCTAssertEqual(applied.portPath, "/dev/cu.usbmodem-other")
        XCTAssertEqual(applied.framesPerSecond, 20)
        XCTAssertEqual(applied.calibration.redGain, 1.42)
        XCTAssertEqual(applied.rows, 12)
    }

    func testControllerFrameFragmentationAndCorruptionRecovery() {
        XCTAssertEqual(Array(ControllerFrame(.hello).encoded() ?? Data()),
                       [65, 76, 51, 33, 1, 0, 62, 46])
        let profile = ControllerProfile(configuration: LightingConfiguration())
        let payload = try! XCTUnwrap(ControllerFrame.profilePayload(revision: 42, profile: profile))
        let frame = try! XCTUnwrap(ControllerFrame(.profile, payload: payload).encoded())
        var parser = ControllerFrameParser()
        XCTAssertTrue(parser.append(Data([0x99, 0x41, 0x4c])).isEmpty)
        XCTAssertTrue(parser.append(frame.prefix(3)).isEmpty)
        XCTAssertTrue(parser.append(frame.dropFirst(3).prefix(7)).isEmpty)
        let received = parser.append(frame.dropFirst(10))
        XCTAssertEqual(received.count, 1)
        let parsed = try! XCTUnwrap(ControllerFrame.parseProfilePayload(received[0].payload))
        XCTAssertEqual(parsed.0, 42)
        XCTAssertEqual(parsed.1, profile)

        var damaged = Array(frame)
        damaged[10] ^= 0x80
        XCTAssertEqual(parser.append(Data(damaged) + frame), [ControllerFrame(.profile, payload: payload)])
    }

    func testControllerRejectsInvalidProfiles() {
        var bytes = try! XCTUnwrap(ControllerProfile(configuration: LightingConfiguration()).encoded())
        bytes[0] = 2
        XCTAssertNil(ControllerProfile.decode(bytes))
        bytes[0] = 1
        bytes[1] = 0
        bytes[2] = 0
        XCTAssertNil(ControllerProfile.decode(bytes))
        bytes[1] = 70
        bytes[9] = 4
        XCTAssertNil(ControllerProfile.decode(bytes))
    }
}
