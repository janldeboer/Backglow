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

        var smoother = ColorSmoother()
        _ = smoother.apply([.black], amount: 0.5)
        let middle = smoother.apply([LightingRGB(red: 1, green: 1, blue: 1)], amount: 0.5)
        XCTAssertEqual(middle[0].red, 0.5, accuracy: 0.001)
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
}
