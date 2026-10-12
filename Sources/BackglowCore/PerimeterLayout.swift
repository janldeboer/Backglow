import Foundation

public struct PixelRect: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct LightingZone: Identifiable, Equatable, Sendable {
    public let id: Int
    public let row: Int
    public let column: Int
    public let rect: PixelRect
}

public enum PerimeterLayout {
    public static func zones(
        width: Int,
        height: Int,
        configuration input: LightingConfiguration,
        contentRect: PixelRect? = nil
    ) -> [LightingZone] {
        var config = input
        config.normalize()
        let bounds = contentRect ?? PixelRect(x: 0, y: 0, width: width, height: height)
        guard width > 0, height > 0, bounds.width >= config.columns,
              bounds.height >= config.rows else { return [] }

        var perimeter: [(Int, Int)] = []
        for column in 0..<config.columns { perimeter.append((0, column)) }
        for row in 1..<config.rows { perimeter.append((row, config.columns - 1)) }
        for column in stride(from: config.columns - 2, through: 0, by: -1) {
            perimeter.append((config.rows - 1, column))
        }
        if config.rows > 2 {
            for row in stride(from: config.rows - 2, through: 1, by: -1) {
                perimeter.append((row, 0))
            }
        }

        var selected: [(Int, Int)] = (0..<config.ledCount).map {
            perimeter[(config.startOffset + $0) % perimeter.count]
        }
        if config.reversed { selected.reverse() }

        return selected.enumerated().map { index, position in
            let (row, column) = position
            let x0 = bounds.x + column * bounds.width / config.columns
            let x1 = bounds.x + (column + 1) * bounds.width / config.columns
            let y0 = bounds.y + row * bounds.height / config.rows
            let y1 = bounds.y + (row + 1) * bounds.height / config.rows
            return LightingZone(
                id: index, row: row, column: column,
                rect: PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            )
        }
    }
}
