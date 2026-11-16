import Foundation

/// One blocked hook connection waiting for a decision.
public struct PendingApproval: Sendable, Equatable {
    /// Identifies the socket connection that must receive the reply.
    public let token: UInt64
    public let request: HookRequest
    public let arrivedAt: Date
    /// When the session was first seen not blocked on a permission prompt, nil while it is blocked.
    public var notBlockedSince: Date?

    public init(token: UInt64, request: HookRequest, arrivedAt: Date) {
        self.token = token
        self.request = request
        self.arrivedAt = arrivedAt
    }
}

/// Pending approvals, at most one per session. Pure value type: callers pass `now` and act on returned tokens.
///
/// Every `[UInt64]` returned is a list of connections the caller must answer with passthrough (empty reply).
public struct ApprovalBook: Sendable, Equatable {
    /// Sessions this app does not track (headless `claude -p`, other config dirs) are released after this.
    public static let unknownSessionTimeout: TimeInterval = 3
    /// New requests are not judged against the blocked state until the terminal had time to show its dialog.
    public static let arrivalGrace: TimeInterval = 2
    /// A tracked session not blocked for this long means the user answered in the terminal.
    public static let notBlockedTimeout: TimeInterval = 2

    public private(set) var all: [PendingApproval] = []

    public init() {}

    public func pending(sessionID: String) -> PendingApproval? {
        all.first { $0.request.sessionID == sessionID }
    }

    /// Adds a request; returns tokens of older entries for the same session, which it supersedes.
    public mutating func add(_ r: HookRequest, token: UInt64, now: Date) -> [UInt64] {
        let superseded = all.filter { $0.request.sessionID == r.sessionID }.map(\.token)
        all.removeAll { $0.request.sessionID == r.sessionID }
        all.append(PendingApproval(token: token, request: r, arrivedAt: now))
        return superseded
    }

    /// Removes and returns the entry for `token`; nil when it was superseded, swept or dropped.
    public mutating func resolve(token: UInt64) -> PendingApproval? {
        guard let i = all.firstIndex(where: { $0.token == token }) else { return nil }
        return all.remove(at: i)
    }

    /// Forgets a connection that closed on its own.
    public mutating func drop(token: UInt64) {
        all.removeAll { $0.token == token }
    }

    /// Removes and returns tokens of entries that will never get a UI decision.
    ///
    /// The hook process is not killed when the terminal answers, so "no longer blocked" is the only signal.
    public mutating func sweep(now: Date, knownSessionIDs: Set<String>, blockedSessionIDs: Set<String>) -> [UInt64] {
        var released: [UInt64] = []
        var kept: [PendingApproval] = []
        for var entry in all {
            let age = now.timeIntervalSince(entry.arrivedAt)
            if !knownSessionIDs.contains(entry.request.sessionID) {
                if age >= Self.unknownSessionTimeout {
                    released.append(entry.token)
                    continue
                }
            } else if age >= Self.arrivalGrace {
                if blockedSessionIDs.contains(entry.request.sessionID) {
                    entry.notBlockedSince = nil
                } else if let since = entry.notBlockedSince {
                    if now.timeIntervalSince(since) >= Self.notBlockedTimeout {
                        released.append(entry.token)
                        continue
                    }
                } else {
                    entry.notBlockedSince = now
                }
            }
            kept.append(entry)
        }
        all = kept
        return released
    }
}
