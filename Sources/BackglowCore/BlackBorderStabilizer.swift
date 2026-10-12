import Foundation

/// Smooths letterbox detection over time, after HyperHDR's black-border processor
/// (MIT, awawa-dev). Short glitches are ignored, a new border must hold steadily
/// before it is used, and dark scenes keep the current border for a long time.
public struct BlackBorderStabilizer {
    public var confirmDuration: TimeInterval = 1
    public var unknownDuration: TimeInterval = 10
    public var glitchTolerance: TimeInterval = 0.25

    private enum Border: Equatable {
        case unknown
        case content(PixelRect)
    }

    private var current = Border.unknown
    private var candidate: Border?
    private var candidateSince: TimeInterval = 0
    private var inconsistentSince: TimeInterval?

    public init() {}

    public mutating func reset() { self = BlackBorderStabilizer() }

    /// `detected` is nil when a frame gives no reliable answer, such as a dark scene.
    /// Returns the content rectangle to use, or nil for the full image.
    public mutating func update(_ detected: PixelRect?, at time: TimeInterval) -> PixelRect? {
        let border = detected.map(Border.content) ?? .unknown
        if let candidate, Self.matches(border, candidate) {
            inconsistentSince = nil
        } else if candidate == nil {
            candidate = border
            candidateSince = time
        } else {
            let since = inconsistentSince ?? time
            inconsistentSince = since
            guard time - since >= glitchTolerance else { return output }
            candidate = border
            candidateSince = time
            inconsistentSince = nil
        }

        guard let candidate, !Self.matches(candidate, current) else { return output }
        let held = time - candidateSince
        switch candidate {
        case .unknown:
            if held >= unknownDuration { current = .unknown }
        case .content:
            if current == .unknown || held >= confirmDuration { current = candidate }
        }
        return output
    }

    private var output: PixelRect? {
        if case .content(let rect) = current { return rect }
        return nil
    }

    /// Detection samples in steps, so allow a small difference before calling it a change.
    private static func matches(_ lhs: Border, _ rhs: Border) -> Bool {
        switch (lhs, rhs) {
        case (.unknown, .unknown):
            return true
        case let (.content(a), .content(b)):
            let tolerance = max(2, max(a.width, a.height) / 100)
            return abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance &&
                abs(a.x + a.width - b.x - b.width) <= tolerance &&
                abs(a.y + a.height - b.y - b.height) <= tolerance
        default:
            return false
        }
    }
}
