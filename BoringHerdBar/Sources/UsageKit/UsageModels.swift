import Foundation

public enum UsageProvider: String, CaseIterable, Sendable {
    case claude, codex, openCode, antigravity
}

/// One rate-limit window. `usedPercent` is 0...100; `resetsAt` is nil when the window has not started
/// or the provider did not report a reset.
public struct UsageWindow: Equatable, Sendable {
    public var label: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public var periodSeconds: TimeInterval?

    public init(label: String, usedPercent: Double, resetsAt: Date? = nil, periodSeconds: TimeInterval? = nil) {
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.periodSeconds = periodSeconds
    }
}

public enum UsageExtra: Equatable, Sendable {
    /// Claude extra usage in dollars; `limitUSD` is nil when no monthly cap is set.
    case claudeExtraUsage(usedUSD: Double, limitUSD: Double?)
    /// Codex flex credits: the floored credit count and its dollar value.
    case codexCredits(credits: Int, usd: Double)
}

public enum UsageState: Equatable, Sendable {
    case ok
    /// Windows are last-good values from `since`; the live fetch is not possible (for example an expired token).
    case stale(since: Date, reason: String)
    case notSetUp(reason: String)
    /// Windows are last-good values (possibly empty) and no request is made before `until`.
    case rateLimited(until: Date)
    /// A transient failure; windows are last-good values (possibly empty).
    case error(String)
}

public struct UsageSnapshot: Equatable, Sendable {
    public var provider: UsageProvider
    public var windows: [UsageWindow]
    public var plan: String?
    public var extra: UsageExtra?
    public var state: UsageState
    public var updatedAt: Date

    public init(
        provider: UsageProvider,
        windows: [UsageWindow] = [],
        plan: String? = nil,
        extra: UsageExtra? = nil,
        state: UsageState,
        updatedAt: Date
    ) {
        self.provider = provider
        self.windows = windows
        self.plan = plan
        self.extra = extra
        self.state = state
        self.updatedAt = updatedAt
    }
}

/// What a provider source returns on success.
struct UsageReading: Equatable, Sendable {
    var windows: [UsageWindow]
    var plan: String?
    var extra: UsageExtra?
}

/// Why a source could not produce a reading. Messages never carry tokens, ids or response bodies.
enum UsageFailure: Error, Equatable {
    case notSetUp(String)
    case stale(String)
    case rateLimited(retryAfter: TimeInterval?)
    case failed(String)
}

protocol UsageSource: Sendable {
    func load(now: Date) async throws -> UsageReading
}

enum UsagePeriod {
    static let session: TimeInterval = 5 * 3600
    static let week: TimeInterval = 7 * 86400
    static let month: TimeInterval = 30 * 86400
}
