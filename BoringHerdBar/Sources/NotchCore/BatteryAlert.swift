import Foundation

/// The three charge-percentage bounds that separate ``BatteryTier``s, configurable so a user who wants
/// an earlier or later warning can move them without touching the tier/crossing logic itself.
public struct BatteryThresholds: Sendable, Equatable {
    public let low: Int
    public let warning: Int
    public let critical: Int

    public init(low: Int, warning: Int, critical: Int) {
        self.low = low
        self.warning = warning
        self.critical = critical
    }

    /// Matches the shipped `NotchPreferences` defaults (20/10/5), so a caller with no stored preference
    /// yet (a test, or a fresh install) sees the same bounds the settings form ships with.
    public static let `default` = BatteryThresholds(low: 20, warning: 10, critical: 5)
}

/// How urgent the current charge level is, most severe last so a `switch` reads worst-to-best top-down
/// only if the caller orders it that way; ``BatteryAlert/tier(percent:thresholds:)`` itself always checks
/// most-severe first.
public enum BatteryTier: Sendable, Equatable {
    case healthy
    case low
    case warning
    case critical
}

/// Pure classification of a battery reading against configured thresholds. No AppKit/SwiftUI, no clock,
/// no state — every function is a plain value-in, value-out mapping so `NotchWindowController` can drive
/// toast presentation from it with no simulated time needed in tests.
public enum BatteryAlert {
    /// Classifies `percent` against `thresholds`, most-severe bound first so a percent at or below more
    /// than one bound (the common case, since the bounds are nested) always reports the worst one.
    ///
    /// - Parameters:
    ///   - percent: Current charge, 0...100.
    ///   - thresholds: The configured bounds.
    /// - Returns: The tier `percent` falls into.
    public static func tier(percent: Int, thresholds: BatteryThresholds) -> BatteryTier {
        if percent <= thresholds.critical { return .critical }
        if percent <= thresholds.warning { return .warning }
        if percent <= thresholds.low { return .low }
        return .healthy
    }

    /// The most-severe threshold bound `current` newly crossed downward since `previous`, or `nil` if
    /// none was crossed this step.
    ///
    /// A single poll tick can skip over more than one bound (a sleep/wake reading jumping straight from
    /// 40% to 3%), so this checks `[critical, warning, low]` in that order and returns the first (most
    /// severe) bound with `previous > bound && current <= bound`, rather than every bound crossed.
    ///
    /// - Parameters:
    ///   - previous: The last reading, or `nil` if this is the first reading this process has seen.
    ///   - current: The new reading.
    ///   - charging: Whether the battery is charging; a charging battery is climbing, not draining, so a
    ///     "crossing" while charging is not a real drain event.
    ///   - thresholds: The configured bounds.
    /// - Returns: The tier of the most-severe bound crossed, or `nil` when charging, when `previous` is
    ///   `nil`, or when `current` did not newly cross any bound.
    public static func crossedTier(
        previous: Int?, current: Int, charging: Bool, thresholds: BatteryThresholds
    ) -> BatteryTier? {
        guard !charging, let previous else { return nil }
        let bounds: [(Int, BatteryTier)] = [
            (thresholds.critical, .critical), (thresholds.warning, .warning), (thresholds.low, .low)
        ]
        for (bound, tier) in bounds where previous > bound && current <= bound {
            return tier
        }
        return nil
    }

    /// Whether `current` is the charge reading that just reached 100% while charging, having started
    /// below it — the one-shot "fully charged" moment, not every poll while already sitting at 100%.
    ///
    /// - Parameters:
    ///   - previous: The last reading, or `nil` if this is the first reading this process has seen.
    ///   - current: The new reading.
    ///   - charging: Whether the battery is charging.
    /// - Returns: `true` only on the reading that transitions from below 100% to exactly 100% while
    ///   charging.
    public static func justReachedFull(previous: Int?, current: Int, charging: Bool) -> Bool {
        guard let previous else { return false }
        return previous < 100 && current == 100 && charging
    }

    /// Reorders `low`/`warning`/`critical` into a strict `critical < warning < low`, nudging with a
    /// minimum gap of 1 wherever the raw inputs are inverted or equal.
    ///
    /// Deterministic left-to-right rule: `critical` is kept as given, `warning` is raised to at least
    /// `critical + 1`, then `low` is raised to at least `warning + 1` — so a caller feeding already-ordered
    /// input back gets it unchanged, and `critical` (the most severe, least likely to be the one a user
    /// meant to move) never moves to satisfy the others.
    ///
    /// - Parameters:
    ///   - low: Raw "low" bound.
    ///   - warning: Raw "warning" bound.
    ///   - critical: Raw "critical" bound.
    /// - Returns: Thresholds guaranteed to satisfy `critical < warning < low`.
    public static func ordered(low: Int, warning: Int, critical: Int) -> BatteryThresholds {
        let orderedWarning = max(warning, critical + 1)
        let orderedLow = max(low, orderedWarning + 1)
        return BatteryThresholds(low: orderedLow, warning: orderedWarning, critical: critical)
    }
}
