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

    func testBlackBarDetectorFindsLetterboxAndReportsDarkFramesAsUnknown() {
        var bytes = [UInt8](repeating: 0, count: 100 * 80 * 4)
        for y in 10..<70 {
            for x in 0..<100 { bytes[(y * 100 + x) * 4] = 200 }
        }
        let detected = bytes.withUnsafeBytes {
            PixelAnalysis.detectContent(bytes: $0, bytesPerRow: 400, width: 100, height: 80)
        }
        XCTAssertEqual(detected, PixelRect(x: 0, y: 10, width: 100, height: 60))
        let dark = [UInt8](repeating: 0, count: 100 * 80 * 4)
        XCTAssertNil(dark.withUnsafeBytes {
            PixelAnalysis.detectContent(bytes: $0, bytesPerRow: 400, width: 100, height: 80)
        })
    }

    func testBlackBorderStabilizerIgnoresGlitchesAndHoldsThroughDarkScenes() {
        let letterbox = PixelRect(x: 0, y: 100, width: 1000, height: 400)
        let subtitle = PixelRect(x: 0, y: 100, width: 1000, height: 460)
        var stabilizer = BlackBorderStabilizer()
        XCTAssertEqual(stabilizer.update(letterbox, at: 0), letterbox)
        // A brief subtitle in the bar is ignored.
        XCTAssertEqual(stabilizer.update(subtitle, at: 0.1), letterbox)
        XCTAssertEqual(stabilizer.update(letterbox, at: 0.2), letterbox)
        // A steady new border needs the confirmation time after the glitch window.
        var time = 0.3
        while time < 1.4 {
            XCTAssertEqual(stabilizer.update(subtitle, at: time), letterbox)
            time += 0.1
        }
        XCTAssertEqual(stabilizer.update(subtitle, at: 1.6), subtitle)
        // Dark frames keep the border until they last for the unknown duration.
        time = 2
        while time < 12 {
            XCTAssertEqual(stabilizer.update(nil, at: time), subtitle)
            time += 0.1
        }
        XCTAssertNil(stabilizer.update(nil, at: 12.4))
        // From the full image, a detected border applies once it outlasts a glitch.
        XCTAssertNil(stabilizer.update(letterbox, at: 12.5))
        XCTAssertEqual(stabilizer.update(letterbox, at: 12.8), letterbox)
    }

    func testLEDCalibrationInterpolatesCornerTargets() {
        var calibration = LEDCalibration()
        let neutralGray = LightingRGB(red: 0.2, green: 0.3, blue: 0.4)
        XCTAssertEqual(ColorProcessing.calibrated(neutralGray, with: calibration), neutralGray)
        calibration.setTarget(LightingRGB(red: 1, green: 0.8, blue: 0.7), for: .white)
        let white = ColorProcessing.calibrated(LightingRGB(red: 1, green: 1, blue: 1), with: calibration)
        XCTAssertEqual(white.srgbEncoded.green, 0.8, accuracy: 0.0001)
        XCTAssertEqual(white.srgbEncoded.blue, 0.7, accuracy: 0.0001)
        // Pure red is untouched by the white target.
        XCTAssertEqual(ColorProcessing.calibrated(LightingRGB(red: 1, green: 0, blue: 0), with: calibration),
                       LightingRGB(red: 1, green: 0, blue: 0))
        // Mid-gray weighs all eight corners equally, so the white target counts one eighth.
        let half = ColorProcessing.calibrated(LightingRGB(red: 0.5, green: 0.5, blue: 0.5), with: calibration)
        XCTAssertEqual(half.green, (3 + SRGB.toLinear(0.8)) / 8, accuracy: 0.0001)

        calibration = LEDCalibration()
        calibration.temperature = .warm
        let warm = ColorProcessing.calibrated(LightingRGB(red: 1, green: 1, blue: 1), with: calibration)
        XCTAssertEqual(warm, LightingRGB(red: 1, green: 0.93, blue: 0.85))
    }

    func testMinimumBacklightAndPowerLimit() {
        var calibration = LEDCalibration()
        calibration.minimumBacklight = 0.05
        let dim = LightingRGB(red: 0.08, green: 0.01, blue: 0)
        XCTAssertEqual(ColorProcessing.withMinimumBacklight(dim, calibration: calibration),
                       LightingRGB(red: 0.05, green: 0.05, blue: 0.05))
        calibration.coloredBacklight = true
        XCTAssertEqual(ColorProcessing.withMinimumBacklight(dim, calibration: calibration),
                       LightingRGB(red: 0.08, green: 0.05, blue: 0.05))

        let white = LightingRGB(red: 1, green: 1, blue: 1)
        let limited = ColorProcessing.limitingPower([white, .black], to: 0.25)
        XCTAssertEqual(limited[0].red, 0.5, accuracy: 0.0001)
        XCTAssertEqual(ColorProcessing.limitingPower([white, .black], to: 0.5), [white, .black])
        XCTAssertEqual(ColorProcessing.limitingPower([white], to: 1), [white])
    }

    func testSettingsFromOlderBuildsStillLoad() throws {
        let legacy = #"{"rows":10,"columns":18,"ledCount":50,"deviceLEDCount":70,"startOffset":3,"reversed":false,"ignoreBlackBars":true,"framesPerSecond":40,"captureScale":0.5,"baudRate":230400,"calibration":{"saturation":1.2,"gamma":1,"redGain":1,"greenGain":1,"blueGain":1,"brightness":0.8,"smoothing":0.3}}"#
        let decoded = try JSONDecoder().decode(LightingConfiguration.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.rows, 10)
        XCTAssertEqual(decoded.calibration.saturation, 1.2)
        XCTAssertEqual(decoded.ledCalibration, LEDCalibration())
        var current = LightingConfiguration()
        current.ledCalibration.powerLimit = 0.6
        let roundTrip = try JSONDecoder().decode(LightingConfiguration.self,
                                                 from: JSONEncoder().encode(current))
        XCTAssertEqual(roundTrip, current)
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
