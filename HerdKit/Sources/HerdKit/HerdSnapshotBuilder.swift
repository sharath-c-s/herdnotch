import Foundation

/// Assembles the full session → workspace → agent tree that the panel renders.
///
/// One pass is: discover sessions, then for each running session fetch `workspace.list` and
/// `agent.list`, group the agents under their workspace, sort everything, and tally the statuses.
/// All ordering happens here so the UI never sorts: sorting in a SwiftUI body would re-run on every
/// redraw and, worse, would let two views disagree about row order.
///
/// Failure is per session by design. A snapshot that fails wholesale because one of four sessions
/// stopped answering would blank the panel for the three that are fine, so a failing session keeps
/// its row and carries its message in ``HerdSession/error``.
///
/// Thread-safety: a `Sendable` value with no mutable state. ``build()`` is synchronous and blocking
/// (one connect plus three round trips per running session), so it belongs off the main thread. The
/// per-session work is fanned out across the libdispatch global pool inside ``build()``; see
/// ``populated(_:)`` for why.
public struct HerdSnapshotBuilder: Sendable {
    /// Session enumeration and liveness probing.
    private let discovery: HerdrDiscovery

    /// Connection factory shared with ``discovery``, so a test fake controls both probes and calls.
    private let connector: any SocketConnecting

    /// Budget for each `workspace.list` and `agent.list` round trip against a local session.
    private let callTimeout: TimeInterval

    /// Budget for the same calls against a session reached through a forwarded socket.
    private let remoteCallTimeout: TimeInterval

    /// Creates a builder.
    ///
    /// - Parameters:
    ///   - configRoot: herdr configuration directory to scan. Defaults to `~/.config/herdr`.
    ///   - extraPaths: Additional socket paths or directories holding forwarded remote sessions.
    ///   - connector: Connection factory used for both liveness probes and data calls.
    ///   - callTimeout: Per-call budget for a local session. Defaults to 2 s, which is far above the
    ///     roughly 36 ms a real `agent.list` takes and exists only to bound a wedged server.
    ///   - remoteCallTimeout: Per-call budget for a remote session. Defaults to 700 ms, deliberately
    ///     tighter than ``callTimeout``. A forwarded socket has a failure mode a local one does not: the
    ///     local end of an `ssh -L` tunnel accepts a connection immediately and only then discovers that
    ///     the far side is unreachable, so a blackholed network shows up as a read that never completes
    ///     rather than as a refused connect. Since every call ``populate(_:)`` makes for one session draws on
    ///     a single budget, this figure is the whole worst case for one dead remote, and it is small enough
    ///     to stay inside a 1 Hz poll.
    ///   - probeTimeout: Per-socket liveness probe budget. Defaults to 300 ms.
    public init(
        configRoot: URL = HerdrDiscovery.defaultConfigRoot,
        extraPaths: [String] = [],
        connector: any SocketConnecting = UnixSocketConnector(),
        callTimeout: TimeInterval = 2.0,
        remoteCallTimeout: TimeInterval = 0.7,
        probeTimeout: TimeInterval = 0.3
    ) {
        self.discovery = HerdrDiscovery(
            configRoot: configRoot,
            extraPaths: extraPaths,
            connector: connector,
            probeTimeout: probeTimeout
        )
        self.connector = connector
        self.callTimeout = callTimeout
        self.remoteCallTimeout = remoteCallTimeout
    }

    /// Produces one complete snapshot.
    ///
    /// Never throws. Every failure that can be attributed to a session becomes that session's
    /// ``HerdSession/error``, and a session that is not running is returned with `running: false` and
    /// no workspaces rather than being dropped.
    ///
    /// - Returns: A sorted, pre-aggregated snapshot. `counts` covers every agent in every session.
    public func build() -> HerdSnapshot {
        let sessions = populated(discovery.discover()).sorted(by: HerdSession.sortsBefore)
        let counts = StatusCounts(agents: sessions.lazy.flatMap(\.workspaces).flatMap(\.agents))
        return HerdSnapshot(sessions: sessions, counts: counts)
    }

    /// Populates every session, fanning the blocking round trips out across the global pool.
    ///
    /// This used to be a plain `map`, and the reason it is not any more is remote sessions. Sequentially,
    /// one session that accepts a connection and then never answers costs its full timeout *and* delays
    /// every session behind it, so a single blackholed `ssh -L` forward would drag the whole snapshot, and
    /// with it the local rows, past the poll interval. Fanning out makes the build cost the slowest
    /// session rather than the sum of all of them, which is what keeps one unreachable remote from
    /// degrading the local sessions.
    ///
    /// `DispatchQueue.concurrentPerform` rather than a `TaskGroup`, for the same reason the caller runs
    /// this on a dedicated serial queue rather than the cooperative pool: these calls block, and blocking
    /// a cooperative thread starves unrelated work. `concurrentPerform` blocks the calling thread and
    /// spends libdispatch's own pool, which is what that pool is for. Total CPU is unchanged, since the
    /// same syscalls happen either way.
    ///
    /// One session is populated inline, which is the common single-session case and avoids paying for a
    /// fan-out that has nothing to fan.
    ///
    /// - Parameter sessions: Descriptors from ``HerdrDiscovery``, in display order.
    /// - Returns: The same sessions, in the same order, with workspaces or an error attached.
    private func populated(_ sessions: [HerdSession]) -> [HerdSession] {
        guard sessions.count > 1 else { return sessions.map(populate(_:)) }
        let sink = PopulatedSessions(count: sessions.count)
        DispatchQueue.concurrentPerform(iterations: sessions.count) { index in
            sink.store(populate(sessions[index]), at: index)
        }
        return sink.ordered(fallingBackTo: sessions)
    }

    /// Fetches and attaches one session's workspaces and agents.
    ///
    /// Only `agent.list` can fail the session, and that is the whole of the blast-radius policy here. The
    /// panel exists to show agents; workspaces and tab labels are how those agents are grouped and named. A
    /// session was seen losing all sixteen of its rows to a single transient socket fault on one of the
    /// supporting calls, which is a much larger consequence than the fault deserved, so each call now fails
    /// no further than its own contribution:
    ///
    /// - `agent.list` failing means there is genuinely nothing to print, so it sets ``HerdSession/error``.
    ///   It is retried once inside the same budget first, because the faults that reach it are the kind a
    ///   fresh connection fixes: a server that closed the socket between the liveness probe and the request.
    /// - `workspace.list` failing degrades to grouping every agent under a synthesised placeholder
    ///   workspace, which prints the workspace id instead of its label. The rows survive, named and
    ///   statused, which is what the user is reading.
    /// - `tab.list` failing degrades to unlabelled rows, as it already did.
    ///
    /// All three round trips share **one** budget, and the order they are made in is the order of their
    /// importance. Two things fall out of that. One dead session costs at most `timeout` in total however
    /// many of its calls fail, which is the property `remoteCallTimeout` is sized against and which
    /// per-call budgets would have multiplied by three the moment the supporting calls stopped being fatal.
    /// And `agent.list` gets first claim on the budget, so a server slow enough to exhaust it loses the
    /// decoration rather than the rows.
    ///
    /// - Parameter session: A descriptor from ``HerdrDiscovery``.
    /// - Returns: The same session with workspaces filled in, or with ``HerdSession/error`` set if
    ///   `agent.list` failed. Stopped sessions are returned untouched without any network attempt.
    private func populate(_ session: HerdSession) -> HerdSession {
        guard session.running else { return session }
        // A remote session gets the tighter budget, because its "accepted then silent" failure mode is
        // the one a local socket does not have. See `remoteCallTimeout`.
        let deadline = Deadline(after: session.isRemote ? remoteCallTimeout : callTimeout)
        let client = HerdrClient(socketPath: session.socketPath, connector: connector)
        do {
            let agents = try Self.retrying(within: deadline) { try client.listAgents(timeout: $0) }

            // Two more round trips, roughly 36 ms each like the first, which is affordable at a 1 Hz poll.
            // Both are deliberately outside the fatal path: a workspace label and a tab label are how the
            // rows are grouped and named, not whether there are rows, so their failures degrade to the
            // workspace id and to the cwd basename rather than turning a working session into an error row.
            // `group(agents:into:)` already synthesises a workspace for any id the workspace reply did not
            // mention, so an empty list is a case it handles rather than a case it breaks on.
            //
            // Skipped outright once the budget is gone, rather than paying for a connect that cannot finish.
            let workspaces = deadline.hasExpired
                ? []
                : ((try? client.listWorkspaces(timeout: deadline.remaining)) ?? [])
            let labels = deadline.hasExpired
                ? [:]
                : ((try? client.listTabLabels(timeout: deadline.remaining)) ?? [:])

            return HerdSession(
                name: session.name,
                isDefault: session.isDefault,
                running: true,
                socketPath: session.socketPath,
                isRemote: session.isRemote,
                workspaces: Self.group(agents: Self.label(agents, using: labels), into: workspaces)
            )
        } catch {
            return HerdSession(
                name: session.name,
                isDefault: session.isDefault,
                running: true,
                socketPath: session.socketPath,
                isRemote: session.isRemote,
                error: String(describing: error)
            )
        }
    }

    /// Runs one round trip, retrying it once inside the caller's budget when the first attempt failed in a
    /// way a fresh connection can fix.
    ///
    /// The retry is scoped by cause, not applied to everything. A refused connect or a peer that closed
    /// mid-message is a one-shot socket fault: ``HerdrClient`` opens a new connection per call, so trying
    /// again is genuinely a different attempt rather than the same one repeated. A timeout is the opposite,
    /// since it means the budget was spent waiting on a server that is not answering, and retrying it would
    /// only spend the budget twice. A server error or a decode failure will reproduce exactly, so retrying
    /// those buys a round trip and no new information.
    ///
    /// Both attempts draw on the session's one budget, which is what keeps the retry from doubling the worst
    /// case. That matters at 1 Hz with several sessions: the reason ``HerdrClient/call(_:params:timeout:)``
    /// carries a single end-to-end deadline in the first place is that a call overrunning its nominal
    /// timeout stalls the whole poll.
    ///
    /// - Parameters:
    ///   - deadline: The session's budget, shared with every other call it makes.
    ///   - attempt: The round trip, given whatever is left of the budget.
    /// - Returns: The first successful attempt's value.
    /// - Throws: The second attempt's error, or the first attempt's when nothing is left to retry with or
    ///   the cause is not one a retry can address.
    private static func retrying<T>(
        within deadline: Deadline,
        _ attempt: (TimeInterval) throws -> T
    ) throws -> T {
        do {
            return try attempt(deadline.remaining)
        } catch let error as HerdrError where Self.isWorthRetrying(error) {
            guard !deadline.hasExpired else { throw error }
            return try attempt(deadline.remaining)
        }
    }

    /// Whether a failure is a one-shot socket fault that a second connection might not hit.
    ///
    /// - Parameter error: The first attempt's failure.
    /// - Returns: `true` for ``HerdrError/socketUnavailable(_:)`` and ``HerdrError/protocolError(_:)``.
    private static func isWorthRetrying(_ error: HerdrError) -> Bool {
        switch error {
        case .socketUnavailable, .protocolError: true
        case .timeout, .server, .decode: false
        }
    }

    /// Joins tab labels onto agents by ``HerdAgent/tabId``.
    ///
    /// A miss leaves ``HerdAgent/tabLabel`` `nil` and keeps the agent, which matters because
    /// `agent.list` and `tab.list` are separate round trips: a tab created between them is absent from
    /// the lookup, and dropping its agent would hide exactly the kind of just-started work the panel
    /// exists to surface.
    ///
    /// - Parameters:
    ///   - agents: Agents from `agent.list`.
    ///   - labels: `tab_id` to label, from `tab.list`. Empty when that call failed.
    /// - Returns: The same agents in the same order, with labels attached where one was found.
    private static func label(_ agents: [HerdAgent], using labels: [String: String]) -> [HerdAgent] {
        guard !labels.isEmpty else { return agents }
        return agents.map { agent in
            var copy = agent
            copy.tabLabel = labels[agent.tabId]
            return copy
        }
    }

    /// Groups agents under their owning workspace and sorts both levels.
    ///
    /// `workspace.list` and `agent.list` are two separate round trips, so an agent can name a
    /// workspace that was not in the workspace reply (a workspace created between the two calls). Such
    /// agents get a synthesised placeholder workspace instead of being dropped: silently losing a
    /// blocked agent is the one failure this panel exists to prevent. Placeholders have no `number`
    /// and therefore sort last.
    ///
    /// - Parameters:
    ///   - agents: Agents from `agent.list`, in herdr's order.
    ///   - workspaces: Workspaces from `workspace.list`, in herdr's order.
    /// - Returns: Workspaces in display order, each with its agents in display order.
    private static func group(agents: [HerdAgent], into workspaces: [HerdWorkspace]) -> [HerdWorkspace] {
        let byWorkspace = Dictionary(grouping: agents, by: \.workspaceId)
        var result = workspaces.map { workspace in
            var copy = workspace
            copy.agents = (byWorkspace[workspace.workspaceId] ?? []).sorted(by: HerdAgent.sortsBefore)
            return copy
        }

        let known = Set(workspaces.map(\.workspaceId))
        for (workspaceId, orphans) in byWorkspace where !known.contains(workspaceId) {
            result.append(
                HerdWorkspace(
                    workspaceId: workspaceId,
                    agentStatus: orphans.map(\.agentStatus).reduce(AgentStatus.unknown) { $0.rollUp($1) },
                    agents: orphans.sorted(by: HerdAgent.sortsBefore)
                )
            )
        }

        return result.sorted(by: HerdWorkspace.sortsBefore)
    }
}

// MARK: - Fan-out collector

/// Index-addressed collection point for the concurrent population pass.
///
/// A lock-guarded array of optionals rather than an unsafe buffer, because the cost of the lock is
/// nothing next to a socket round trip and the alternative is unchecked memory arithmetic in a code path
/// whose entire job is to be more robust, not less. Writing by index rather than appending is what keeps
/// the caller's display order without a re-sort.
///
/// Thread-safety: every access is serialised by an internal lock, so any number of pool threads may store
/// concurrently.
private final class PopulatedSessions: @unchecked Sendable {
    /// Serialises access to ``storage``.
    private let lock = NSLock()

    /// One slot per session, `nil` until that session's slot is filled.
    private var storage: [HerdSession?]

    /// Creates a collector with `count` empty slots.
    ///
    /// - Parameter count: Number of sessions to be populated.
    init(count: Int) {
        storage = Array(repeating: nil, count: count)
    }

    /// Records one populated session.
    ///
    /// - Parameters:
    ///   - session: The populated session.
    ///   - index: Its position in the caller's array.
    func store(_ session: HerdSession, at index: Int) {
        lock.withLock { storage[index] = session }
    }

    /// The populated sessions in slot order.
    ///
    /// - Parameter originals: The descriptors the pass started from, used for any slot that was never
    ///   filled. That cannot happen while `concurrentPerform` runs every iteration, and the fallback is
    ///   here so an unfilled slot degrades to an unpopulated row rather than dropping a session, which is
    ///   the one failure mode this whole layer exists to prevent.
    /// - Returns: One session per slot, in order.
    func ordered(fallingBackTo originals: [HerdSession]) -> [HerdSession] {
        lock.withLock {
            storage.enumerated().map { index, populated in populated ?? originals[index] }
        }
    }
}
