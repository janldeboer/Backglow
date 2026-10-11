import Foundation

public enum PixelAnalysis {
    /// BGRA8 sRGB pixels in top-left origin. Uses every pixel for the CPU reference path
    /// and returns the average in linear light, matching the GPU's sRGB texture reads.
    public static func average(
        bytes: UnsafeRawBufferPointer,
        bytesPerRow: Int,
        imageWidth: Int,
        imageHeight: Int,
        rect: PixelRect
    ) -> LightingRGB {
        guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
              rect.width > 0, rect.height > 0, bytesPerRow >= imageWidth * 4,
              rect.x >= 0, rect.y >= 0,
              rect.x + rect.width <= imageWidth,
              rect.y + rect.height <= imageHeight,
              bytes.count >= bytesPerRow * imageHeight else { return .black }
        let linear = SRGB.linearTable
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        for y in rect.y..<(rect.y + rect.height) {
            let row = base.advanced(by: y * bytesPerRow)
            for x in rect.x..<(rect.x + rect.width) {
                let pixel = row.advanced(by: x * 4)
                blue += linear[Int(pixel[0])]
                green += linear[Int(pixel[1])]
                red += linear[Int(pixel[2])]
            }
        }
        let count = Double(rect.width * rect.height)
        return LightingRGB(red: red / count, green: green / count, blue: blue / count)
    }

    /// Conservative letterbox estimate. It keeps the full image for very dark scenes.
    public static func contentBounds(
        bytes: UnsafeRawBufferPointer,
        bytesPerRow: Int,
        width: Int,
        height: Int
    ) -> PixelRect {
        guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
              width > 20, height > 20, bytes.count >= bytesPerRow * height,
              bytesPerRow >= width * 4 else {
            return PixelRect(x: 0, y: 0, width: width, height: height)
        }
        func isBright(_ x: Int, _ y: Int) -> Bool {
            let offset = y * bytesPerRow + x * 4
            return Int(base[offset]) + Int(base[offset + 1]) + Int(base[offset + 2]) > 72
        }
        func rowHasContent(_ y: Int) -> Bool {
            (1...9).contains { isBright($0 * width / 10, y) }
        }
        func columnHasContent(_ x: Int) -> Bool {
            (1...9).contains { isBright(x, $0 * height / 10) }
        }
        guard rowHasContent(height / 2) || columnHasContent(width / 2) else {
            return PixelRect(x: 0, y: 0, width: width, height: height)
        }
        let rowStep = max(1, height / 200)
        let columnStep = max(1, width / 200)
        let maxTop = height / 5
        let maxSide = width / 5
        let top = stride(from: 0, through: maxTop, by: rowStep).first(where: rowHasContent) ?? 0
        let bottom = stride(from: height - 1, through: height - 1 - maxTop, by: -rowStep)
            .first(where: rowHasContent) ?? (height - 1)
        let left = stride(from: 0, through: maxSide, by: columnStep)
            .first(where: columnHasContent) ?? 0
        let right = stride(from: width - 1, through: width - 1 - maxSide, by: -columnStep)
            .first(where: columnHasContent) ?? (width - 1)
        guard bottom - top >= height * 3 / 5, right - left >= width * 3 / 5 else {
            return PixelRect(x: 0, y: 0, width: width, height: height)
        }
        return PixelRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }
}
