import Foundation

/// Watches how evenly the LED clock ticks and how long frame analysis takes. When the Mac
/// cannot keep up, it lowers capture and output rates; after a hang, or while most ticks
/// come late, it freezes the colors until the clock has been steady again for a while.
public struct PerformanceGovernor: Sendable {
    public enum State: Equatable, Sendable {
        case normal, throttled, frozen
    }

    /// Lowest fraction of the configured rates the governor throttles to.
    public static let minimumRateFactor = 0.25
    /// A single gap this long between ticks freezes the colors.
    public static let freezeGap: TimeInterval = 0.25
    /// Steady ticking this long ends a freeze.
    public static let steadyToUnfreeze: TimeInterval = 1.0
    /// Time at a rate before throttling further, and before raising it again.
    public static let throttleHold: TimeInterval = 2
    public static let recoveryHold: TimeInterval = 10

    public private(set) var state = State.normal
    /// Fraction of the configured capture and output rates to run at: 1, 0.5 or 0.25.
    public private(set) var rateFactor = 1.0
    /// Share of recent ticks that came late, 0…1.
    public private(set) var lateness = 0.0
    /// Analysis time relative to the frame interval, smoothed; above 1 the analysis cannot keep up.
    public private(set) var load = 0.0

    private var lastTick: TimeInterval?
    private var lastRateChange: TimeInterval?
    private var steadySince: TimeInterval?

    public init() {}

    public mutating func reset() {
        self = PerformanceGovernor()
    }

    /// Forgets the last tick, for example after the clock was stopped on purpose.
    public mutating func clockRestarted() {
        lastTick = nil
        steadySince = nil
    }

    /// Records one tick of the output clock. `expectedInterval` is the interval it was asked
    /// to keep at the current rate factor.
    public mutating func recordTick(at now: TimeInterval, expectedInterval: TimeInterval) {
        defer { lastTick = now }
        guard let lastTick else { return }
        let interval = now - lastTick
        let late = interval > expectedInterval * 1.8 + 0.004
        lateness = lateness * 0.95 + (late ? 0.05 : 0)
        if late {
            steadySince = nil
        } else if steadySince == nil {
            steadySince = now
        }
        if interval > Self.freezeGap || lateness > 0.5 {
            if state != .frozen { throttle(at: now, force: true) }
            state = .frozen
            return
        }
        if state == .frozen {
            guard let steadySince, now - steadySince >= Self.steadyToUnfreeze else { return }
            state = .normal
        }
        if lateness > 0.2 || load > 0.8 {
            throttle(at: now, force: false)
        } else if lateness < 0.02, load < 0.4, rateFactor < 1,
                  now - (lastRateChange ?? -.infinity) >= Self.recoveryHold {
            rateFactor = min(1, rateFactor * 2)
            lastRateChange = now
        }
        state = rateFactor < 1 ? .throttled : .normal
    }

    /// Records how long one captured frame took to analyze, against the time between frames.
    public mutating func recordAnalysis(seconds: TimeInterval, frameInterval: TimeInterval) {
        guard frameInterval > 0 else { return }
        load = load * 0.9 + 0.1 * max(seconds, 0) / frameInterval
    }

    private mutating func throttle(at now: TimeInterval, force: Bool) {
        guard rateFactor > Self.minimumRateFactor else { return }
        guard force || now - (lastRateChange ?? -.infinity) >= Self.throttleHold else { return }
        rateFactor = max(Self.minimumRateFactor, rateFactor / 2)
        lastRateChange = now
        // Judge the new rate on its own ticks.
        lateness /= 2
        load /= 2
    }
}
