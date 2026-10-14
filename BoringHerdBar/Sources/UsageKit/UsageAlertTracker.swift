import Foundation

/// A usage window crossing a threshold, or resetting. Only Claude and Codex Session/Weekly windows raise these.
public struct UsageEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case warning, critical, reset }
    public let provider: UsageProvider
    public let label: String
    public let kind: Kind
    public let percent: Int
    public let resetsAt: Date?

    public init(provider: UsageProvider, label: String, kind: Kind, percent: Int, resetsAt: Date?) {
        self.provider = provider
        self.label = label
        self.kind = kind
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

/// Decides which ``UsageEvent``s a new snapshot raises, from the previous reading of each window.
///
/// Thresholds fire on an upward crossing only, and once per reset period: a reading that wobbles around a
/// bound does not re-fire until the window resets. The first reading of a window never fires (no toast at
/// launch for a window that is already high). A reset event only follows a window that had been warned about.
public struct UsageAlertTracker {
    private struct Key: Hashable {
        let provider: UsageProvider
        let label: String
    }

    private struct State {
        var percent: Double
        var resetsAt: Date?
        var warned: Bool
        var critical: Bool
    }

    /// A window whose percent fell by at least this many points started a new period.
    public static let resetDropPoints: Double = 50

    private var states: [Key: State] = [:]

    public init() {}

    public static func isTracked(_ provider: UsageProvider, label: String) -> Bool {
        (provider == .claude || provider == .codex) && (label == "Session" || label == "Weekly")
    }

    public mutating func forget(_ provider: UsageProvider) {
        states = states.filter { $0.key.provider != provider }
    }

    public mutating func update(_ snapshot: UsageSnapshot, warn: Double, critical: Double, now: Date) -> [UsageEvent] {
        // Carried (stale, rate-limited, error) values would only repeat the last reading.
        guard snapshot.state == .ok else { return [] }
        var events: [UsageEvent] = []
        for window in snapshot.windows where Self.isTracked(snapshot.provider, label: window.label) {
            let key = Key(provider: snapshot.provider, label: window.label)
            let percent = window.usedPercent
            func event(_ kind: UsageEvent.Kind) -> UsageEvent {
                UsageEvent(
                    provider: snapshot.provider, label: window.label, kind: kind,
                    percent: Int(percent.rounded()), resetsAt: window.resetsAt)
            }
            guard var state = states[key] else {
                states[key] = State(
                    percent: percent, resetsAt: window.resetsAt, warned: percent >= warn, critical: percent >= critical)
                continue
            }
            var rolled = false
            if let previousReset = state.resetsAt, previousReset <= now {
                rolled = window.resetsAt.map { $0 > previousReset } ?? true
            }
            if state.percent - percent >= Self.resetDropPoints || rolled {
                if state.warned { events.append(event(.reset)) }
                state.warned = false
                state.critical = false
            }
            if percent >= critical, !state.critical {
                events.append(event(.critical))
                state.critical = true
                state.warned = true
            } else if percent >= warn, !state.warned {
                events.append(event(.warning))
                state.warned = true
            }
            state.percent = percent
            state.resetsAt = window.resetsAt
            states[key] = state
        }
        return events
    }
}
