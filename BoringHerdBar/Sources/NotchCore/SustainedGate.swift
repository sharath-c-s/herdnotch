import Foundation

/// Fires once when a value stays above `threshold` for at least `duration`, then stays quiet until the value
/// drops below `threshold - hysteresis`. The caller supplies `now`, so tests need no real clock.
public struct SustainedGate: Sendable, Equatable {
    public let threshold: Double
    public let duration: TimeInterval
    public let hysteresis: Double
    private var aboveSince: Date?
    private var armed = true

    public init(threshold: Double, duration: TimeInterval, hysteresis: Double = 0) {
        self.threshold = threshold
        self.duration = duration
        self.hysteresis = hysteresis
    }

    /// - Returns: `true` only on the sample that completes the sustained period.
    public mutating func update(value: Double, now: Date) -> Bool {
        if value > threshold {
            if aboveSince == nil { aboveSince = now }
            if armed, let since = aboveSince, now.timeIntervalSince(since) >= duration {
                armed = false
                return true
            }
            return false
        }
        aboveSince = nil
        if value < threshold - hysteresis { armed = true }
        return false
    }
}
