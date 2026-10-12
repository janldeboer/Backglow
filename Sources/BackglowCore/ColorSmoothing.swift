import Foundation

/// Time-based spring smoothing in BT.709 YUV, after HyperHDR's hybrid interpolator
/// (MIT, awawa-dev). Speed does not depend on the capture frame rate, and the
/// luminance rate limit keeps bright cuts from flashing the room.
public struct SpringColorSmoother {
    public var stiffness = 150.0
    public var damping = 26.0
    /// Maximum change of luma per second; 0 disables the limit.
    public var maximumLumaRate = 1.5

    private var current: [SIMD3<Double>] = []
    private var velocity: [SIMD3<Double>] = []
    private var target: [SIMD3<Double>] = []
    private var targetRGB: [LightingRGB] = []
    public private(set) var isSettled = true

    public init() {}

    /// Maps the 0…0.95 smoothing setting to a settling time of up to about 1.2 s.
    /// Zero disables smoothing.
    public mutating func configure(smoothing: Double) {
        let amount = min(max(smoothing, 0), 0.95)
        guard amount > 0 else {
            stiffness = 0
            return
        }
        let angularFrequency = 4 / (amount * 1.3)
        stiffness = angularFrequency * angularFrequency
        damping = 2.12 * angularFrequency
    }

    public mutating func reset() {
        current = []
        velocity = []
        target = []
        targetRGB = []
        isSettled = true
    }

    public mutating func setTarget(_ colors: [LightingRGB]) {
        targetRGB = colors
        target = colors.map(Self.yuv)
        if current.count != target.count || stiffness == 0 {
            current = target
            velocity = Array(repeating: .zero, count: target.count)
            isSettled = true
        } else {
            isSettled = false
        }
    }

    /// Advances the spring and returns the colors to display now.
    public mutating func advance(by seconds: TimeInterval) -> [LightingRGB] {
        guard !isSettled else { return targetRGB }
        let dt = min(max(seconds, 0.001), 0.1)
        let finishThreshold = 0.00014
        let velocityThreshold = 0.0005
        let lower = SIMD3<Double>(0, -0.5, -0.5)
        let upper = SIMD3<Double>(1, 0.5, 0.5)
        var settled = true
        for index in current.indices {
            let difference = target[index] - current[index]
            if Self.maximum(difference) < finishThreshold, Self.maximum(velocity[index]) < velocityThreshold {
                current[index] = target[index]
                velocity[index] = .zero
                continue
            }
            settled = false
            velocity[index] += (stiffness * difference - damping * velocity[index]) * dt
            var step = velocity[index] * dt
            let lumaLimit = maximumLumaRate * dt
            if maximumLumaRate > 0, abs(step.x) > lumaLimit {
                let scale = lumaLimit / abs(step.x)
                step *= scale
                velocity[index] *= scale
            }
            var next = current[index] + step
            for channel in 0..<3 where next[channel] < lower[channel] || next[channel] > upper[channel] {
                velocity[index][channel] = 0
                next[channel] = min(max(next[channel], lower[channel]), upper[channel])
            }
            current[index] = next
        }
        isSettled = settled
        return settled ? targetRGB : current.map { Self.rgb($0).clamped() }
    }

    private static func maximum(_ value: SIMD3<Double>) -> Double {
        max(abs(value.x), abs(value.y), abs(value.z))
    }

    private static func yuv(_ color: LightingRGB) -> SIMD3<Double> {
        let y = 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
        return SIMD3(y, (color.blue - y) / 1.8556, (color.red - y) / 1.5748)
    }

    private static func rgb(_ value: SIMD3<Double>) -> LightingRGB {
        let red = value.x + 1.5748 * value.z
        let blue = value.x + 1.8556 * value.y
        let green = (value.x - 0.2126 * red - 0.0722 * blue) / 0.7152
        return LightingRGB(red: red, green: green, blue: blue)
    }
}

/// Keeps the previous 8-bit value until a channel moves by about half a step,
/// so rounding noise in static scenes does not make the LEDs flicker.
public struct AntiFlickerFilter {
    private var held: [LightingRGB] = []

    public init() {}

    public mutating func reset() { held = [] }

    public mutating func apply(_ colors: [LightingRGB]) -> [LightingRGB] {
        guard held.count == colors.count else {
            held = colors
            return colors
        }
        for index in colors.indices {
            let old = held[index]
            let new = colors[index]
            let change = max(abs(new.red - old.red), abs(new.green - old.green), abs(new.blue - old.blue))
            if change * 255 > 0.49 { held[index] = new }
        }
        return held
    }
}
