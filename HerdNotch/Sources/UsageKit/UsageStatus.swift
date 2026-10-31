import Foundation

/// The note and dimming a usage card shows for a snapshot: pure, so the thresholds are testable.
public enum UsageStatus {
    /// Two missed 5-minute polls: a healthy reading never ages this far.
    public static let outdatedAfter: TimeInterval = 10 * 60

    public static func isOutdated(_ snapshot: UsageSnapshot, now: Date) -> Bool {
        now.timeIntervalSince(snapshot.updatedAt) >= outdatedAfter
    }

    /// Nil when there is nothing to say (a fresh ok reading). `loading` is for a provider with no snapshot yet.
    public static func note(for snapshot: UsageSnapshot?, now: Date) -> String? {
        guard let snapshot else { return "loading" }
        switch snapshot.state {
        case .ok: return isOutdated(snapshot, now: now) ? updatedAgo(snapshot.updatedAt, now: now) : nil
        case .notSetUp: return "not set up"
        case .stale(let since, _): return updatedAgo(since, now: now)
        case .rateLimited(let until):
            let seconds = until.timeIntervalSince(now)
            return seconds > 0 ? "rate limited, retry ~\(Int((seconds / 60).rounded(.up)))m" : "rate limited"
        case .error(let message): return String(message.prefix(40))
        }
    }

    public static func isDimmed(_ snapshot: UsageSnapshot?, now: Date) -> Bool {
        guard let snapshot else { return false }
        switch snapshot.state {
        case .stale, .rateLimited: return true
        case .ok: return isOutdated(snapshot, now: now)
        default: return false
        }
    }

    // ponytail: a small copy of NotchCore's ShortDuration (UsageKit does not depend on NotchCore); unify if it grows.
    private static func updatedAgo(_ date: Date, now: Date) -> String {
        let minutes = Int(max(now.timeIntervalSince(date), 60)) / 60
        let text: String
        if minutes < 60 {
            text = "\(minutes)m"
        } else if minutes >= 24 * 60 {
            text = "\(minutes / (24 * 60))d"
        } else {
            text = "\(minutes / 60)h \(minutes % 60)m"
        }
        return "updated \(text) ago"
    }
}
