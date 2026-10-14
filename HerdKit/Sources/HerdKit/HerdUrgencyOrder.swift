import Foundation

/// How much a row wants the user's attention, lowest first.
///
/// Distinct from ``AgentStatus/sortRank`` because it has one case that no single snapshot can compute:
/// ``recentlyCompleted`` is an agent that is `idle` right now but was `working` a moment ago, which is
/// only knowable by remembering the previous snapshot. That memory needs a clock, and a clock does not
/// belong in HerdKit, so the recency decision is made by the caller and handed in as a set of keys.
/// This type only ranks and sorts.
///
/// `unknown` sits between `working` and `idle` deliberately. It is not urgent, because nobody can act
/// on it, but it is more often a bug than a state, so burying it under fourteen idle rows would hide
/// the one row that indicates something is wrong with the panel itself.
///
/// ``done`` and ``recentlyCompleted`` are both "this has finished" and both are kept, which is not a
/// duplication. ``done`` is what herdr reports directly and is therefore exact but has no age: it stays
/// true for as long as the agent sits there finished. ``recentlyCompleted`` is inferred from
/// `working -> idle` plus a clock, so it is the only signal available for an agent or a herdr build that
/// never reports `done`, and it expires. The exact statement outranks the inferred one.
public enum HerdUrgency: Int, Sendable, Comparable {
    /// Waiting on the human. The only state that is genuinely urgent.
    case blocked = 0
    /// herdr reports the agent as finished.
    case done = 1
    /// Finished within the caller's recency window. Idle now, but worth a look.
    case recentlyCompleted = 2
    /// Actively producing output.
    case working = 3
    /// herdr did not report a state this build recognises.
    case unknown = 4
    /// Alive with nothing in flight. The bulk of rows and the least informative.
    case idle = 5

    /// Orders two urgencies by their raw rank.
    ///
    /// - Parameters:
    ///   - lhs: Left operand.
    ///   - rhs: Right operand.
    /// - Returns: `true` when `lhs` is more urgent than `rhs`.
    public static func < (lhs: HerdUrgency, rhs: HerdUrgency) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Reorders a snapshot so the rows that want attention float to the top.
///
/// Stateless and clockless by design: everything time-dependent arrives as ``recentlyCompleted``, so
/// this type stays a pure function of its inputs and can be unit tested without waiting for a timer.
/// The caller that owns the clock (the app's model layer) decides what "recently" means.
///
/// **The sort is hierarchical, not flat, and that is the load-bearing decision.** A ledger's
/// readability comes from printing the session and workspace only when they change, which turns
/// grouping into whitespace. Sorting sixteen agents into one flat urgency order would interleave
/// sessions, so every single row would have to reprint its session and workspace and the elision would
/// collapse into noise. So urgency propagates upwards instead: a session is ranked by its most urgent
/// member, a workspace likewise, and agents are ranked within their own workspace. The groups stay
/// intact and still reorder as a whole.
///
/// **The sort is stable.** `Array.sort(by:)` is not guaranteed stable in Swift, and an unstable sort at
/// a 1 Hz poll would let rows of equal rank swap places under the cursor. Every comparison therefore
/// falls back to the element's original index, which both fixes the order and preserves whatever order
/// ``HerdSnapshotBuilder`` produced for ties.
public enum HerdUrgencyOrder {

    /// One element decorated with its rank and its position in the input.
    ///
    /// A named generic rather than a tuple, and not for style: the tuple version of this sort exceeded the
    /// Swift type checker's budget and failed to compile with "unable to type-check this expression in
    /// reasonable time". Naming the shape fixes it and makes the comparator readable.
    private struct Ranked<Element> {
        /// Urgency rank, lower is more urgent.
        let rank: Int
        /// Index in the unsorted input, used as the tie-break that makes the sort stable.
        let index: Int
        /// The element itself.
        let element: Element
    }

    /// Orders decorated elements by rank, then by original index.
    ///
    /// The index tie-break is what makes this stable. `Array.sort(by:)` gives no stability guarantee in
    /// Swift, and an unstable sort re-run at 1 Hz would let rows of equal rank swap places under the
    /// cursor.
    ///
    /// - Parameter items: Decorated elements in input order.
    /// - Returns: The elements alone, in urgency order.
    private static func flatten<Element>(_ items: [Ranked<Element>]) -> [Element] {
        items
            .sorted { lhs, rhs in
                lhs.rank == rhs.rank ? lhs.index < rhs.index : lhs.rank < rhs.rank
            }
            .map(\.element)
    }

    /// Builds the identity key this type expects in ``applying(recentlyCompleted:to:)``.
    ///
    /// A `paneId` such as `w1:p1` is unique only inside its own session, so two sessions each having a
    /// workspace `w1` would collide. The separator is a control character so it cannot occur in either
    /// component.
    ///
    /// - Parameters:
    ///   - sessionName: Owning session's name.
    ///   - paneId: Pane identifier, unique only within that session.
    /// - Returns: A key unique across every session.
    public static func key(sessionName: String, paneId: String) -> String {
        "\(sessionName)\u{1}\(paneId)"
    }

    /// Ranks one agent.
    ///
    /// - Parameters:
    ///   - agent: The agent to rank.
    ///   - sessionName: Its owning session, needed to build the recency key.
    ///   - recentlyCompleted: Keys of agents that finished inside the caller's recency window.
    /// - Returns: The agent's urgency. An agent in `recentlyCompleted` outranks `working` even though it
    ///   is `idle`, because "this just finished" is news and "this is still going" is not. The recency set
    ///   is consulted only for an agent whose current status is `idle`: a `done` agent already outranks it
    ///   on herdr's own word, and a `blocked` one has become urgent since it finished.
    public static func urgency(
        of agent: HerdAgent,
        sessionName: String,
        recentlyCompleted: Set<String>
    ) -> HerdUrgency {
        switch agent.agentStatus {
        case .blocked: return .blocked
        case .done: return .done
        case .working: return .working
        case .unknown: return .unknown
        case .idle:
            let key = key(sessionName: sessionName, paneId: agent.paneId)
            return recentlyCompleted.contains(key) ? .recentlyCompleted : .idle
        }
    }

    /// Returns the snapshot with sessions, workspaces and agents reordered by urgency.
    ///
    /// Counts are carried through untouched: reordering cannot change a tally, and recomputing it here
    /// would give two places in the app that decide what the counts are.
    ///
    /// Stopped sessions always sort last regardless of anything they contain, which in practice is
    /// nothing, because ``HerdSnapshotBuilder`` leaves a stopped session's `workspaces` empty. They stay
    /// in the snapshot rather than being dropped: a session that vanishes when its server stops is worse
    /// than one shown as stopped, because the user cannot tell that apart from a broken panel.
    ///
    /// - Parameters:
    ///   - recentlyCompleted: Keys, from ``key(sessionName:paneId:)``, of agents that finished inside
    ///     the caller's recency window. Pass an empty set to order by status alone.
    ///   - snapshot: The snapshot to reorder.
    /// - Returns: A snapshot with the same contents in urgency order.
    public static func applying(
        recentlyCompleted: Set<String>,
        to snapshot: HerdSnapshot
    ) -> HerdSnapshot {
        // Rank is computed once per element and carried alongside it. Computing it inside the comparator
        // instead would re-walk every workspace's agents on every comparison, which is O(n log n) walks of
        // the tree per poll for no benefit.
        var rankedSessions: [Ranked<HerdSession>] = []

        for (sessionIndex, session) in snapshot.sessions.enumerated() {
            var rankedWorkspaces: [Ranked<HerdWorkspace>] = []

            for (workspaceIndex, workspace) in session.workspaces.enumerated() {
                var rankedAgents: [Ranked<HerdAgent>] = []
                for (agentIndex, agent) in workspace.agents.enumerated() {
                    let rank = urgency(
                        of: agent,
                        sessionName: session.name,
                        recentlyCompleted: recentlyCompleted
                    ).rawValue
                    rankedAgents.append(Ranked(rank: rank, index: agentIndex, element: agent))
                }

                var reorderedWorkspace = workspace
                reorderedWorkspace.agents = flatten(rankedAgents)
                // A workspace is as urgent as its most urgent agent. An empty workspace has nothing to
                // say, so it ranks with `idle` rather than ahead of it.
                let workspaceRank = rankedAgents.map(\.rank).min() ?? HerdUrgency.idle.rawValue
                rankedWorkspaces.append(
                    Ranked(rank: workspaceRank, index: workspaceIndex, element: reorderedWorkspace)
                )
            }

            var reorderedSession = session
            reorderedSession.workspaces = flatten(rankedWorkspaces)
            // A stopped session is context rather than content, so it is parked behind every running one
            // no matter what rank its (empty) contents would imply.
            let sessionRank = session.running
                ? (rankedWorkspaces.map(\.rank).min() ?? HerdUrgency.idle.rawValue)
                : Int.max
            rankedSessions.append(
                Ranked(rank: sessionRank, index: sessionIndex, element: reorderedSession)
            )
        }

        return HerdSnapshot(sessions: flatten(rankedSessions), counts: snapshot.counts)
    }
}
