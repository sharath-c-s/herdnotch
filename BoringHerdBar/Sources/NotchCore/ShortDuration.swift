import Foundation

/// Compact duration text ("45s", "12m", "1h 5m", "3d") shared by the long-task toast and the usage card.
///
/// The two callers differ only at the edges, so those are options rather than two formatters. Negative input
/// reads as zero. Whole units truncate.
public enum ShortDuration {
    /// - Parameters:
    ///   - showsSeconds: Under a minute reads as seconds; otherwise as "<1m".
    ///   - showsDays: From 24 hours up reads as whole days instead of "26h 0m".
    ///   - dropsZeroMinutes: "1h" instead of "1h 0m".
    public static func format(
        seconds: TimeInterval, showsSeconds: Bool = true, showsDays: Bool = false, dropsZeroMinutes: Bool = false
    ) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return showsSeconds ? "\(total)s" : "<1m" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        if showsDays, minutes >= 24 * 60 { return "\(minutes / (24 * 60))d" }
        let rest = minutes % 60
        return dropsZeroMinutes && rest == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(rest)m"
    }
}
