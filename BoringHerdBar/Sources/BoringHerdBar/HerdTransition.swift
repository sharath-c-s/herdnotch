import Foundation
import HerdKit

/// One agent changing status between two consecutive snapshots.
///
/// Exists so the status diff is computed exactly once per poll and then consumed by everything that
/// cares (the notification and the transient popup). Two independent diffs would drift the moment one
/// of them changed its idea of what counts as a transition.
struct HerdTransition: Sendable {
    /// Name of the session the agent belongs to. Part of the identity, never dropped.
    let sessionName: String
    /// The agent as it appears in the new snapshot.
    let agent: HerdAgent
    /// Status in the previous snapshot.
    let from: AgentStatus
    /// Status in the new snapshot. Always different from ``from``.
    let to: AgentStatus

    /// Stable identity for one agent across snapshots.
    ///
    /// The session name is part of the key because a `paneId` such as `w1:p7` is unique only inside
    /// its session: two sessions each having a workspace `w1` is completely normal. Keying on
    /// `paneId` alone lets one session's agent overwrite another's entry, which shows up as missed
    /// transitions and as notifications replacing each other in Notification Center.
    var key: String { Self.key(sessionName: sessionName, paneId: agent.paneId) }

    /// Builds the identity key for a session and pane pair.
    ///
    /// - Parameters:
    ///   - sessionName: Owning session's name.
    ///   - paneId: Pane identifier, unique only within that session.
    /// - Returns: A key unique across every session. The separator is a control character so it
    ///   cannot occur in either component.
    static func key(sessionName: String, paneId: String) -> String {
        "\(sessionName)\u{1}\(paneId)"
    }

    /// Whether this is an agent starting to wait on the human.
    ///
    /// Transitions out of ``AgentStatus/unknown`` are excluded: `unknown` usually means herdr has not
    /// classified the pane yet, so `unknown -> blocked` is far more often detection settling down
    /// than a real change the user should be told about.
    ///
    /// `done -> blocked` is included, and has to be: an agent that finished and then asked something is
    /// asking a genuinely new question, and it is one of the likelier ways a prompt appears on a pane the
    /// user had stopped watching.
    var isNewlyBlocked: Bool { to == .blocked && (from == .idle || from == .working || from == .done) }

    /// Whether this is an agent finishing its work.
    ///
    /// Two shapes count, because herdr reports completion two ways. `working -> idle` is the inferred
    /// signal, and was the only one available while `done` was folded into `unknown`. Any transition
    /// *into* `done` is herdr saying so directly, which is the better evidence of the two.
    ///
    /// `unknown -> done` is excluded, for the same reason `isNewlyBlocked` excludes transitions out of
    /// `unknown`: it is far more often herdr's detection settling on a pane it had not classified than an
    /// agent that finished while the app was not looking. `blocked -> idle` is excluded too, because it
    /// means the user answered the prompt themselves and already knows.
    var isCompleted: Bool {
        (from == .working && to == .idle) || (to == .done && from != .unknown)
    }
}

/// Diffs consecutive snapshots into ``HerdTransition`` values.
///
/// The first snapshot after launch only establishes the baseline and yields nothing. Without that,
/// relaunching the app with three blocked agents present would announce all three as if they had just
/// happened, which trains the user to ignore the alerts.
///
/// An agent whose previous status is not known (a new pane, or a session that just came back online)
/// also yields nothing. That is the same rule applied per session rather than per launch, and it is
/// what stops a restarted herdr server from replaying its whole agent list as fresh events.
///
/// Thread-safety: main-actor isolated. Only the poll loop touches it.
@MainActor
final class HerdTransitionTracker {
    /// Status of every agent as of the previous snapshot, keyed by ``HerdTransition/key``.
    private var previous: [String: AgentStatus] = [:]

    /// Whether a baseline snapshot has been recorded yet.
    private var hasBaseline = false

    /// Diffs one snapshot against the previous one.
    ///
    /// The baseline is always advanced, including on the very first call, so callers cannot get a
    /// stale diff by ignoring the result.
    ///
    /// - Parameter snapshot: The snapshot just published, already filtered.
    /// - Returns: Every status change since the previous snapshot, empty on the first call.
    func transitions(in snapshot: HerdSnapshot) -> [HerdTransition] {
        var current: [String: AgentStatus] = [:]
        var result: [HerdTransition] = []

        for session in snapshot.sessions {
            for workspace in session.workspaces {
                for agent in workspace.agents {
                    let key = HerdTransition.key(sessionName: session.name, paneId: agent.paneId)
                    current[key] = agent.agentStatus
                    guard hasBaseline,
                          let from = previous[key],
                          from != agent.agentStatus else { continue }
                    result.append(
                        HerdTransition(
                            sessionName: session.name,
                            agent: agent,
                            from: from,
                            to: agent.agentStatus
                        )
                    )
                }
            }
        }

        previous = current
        hasBaseline = true
        return result
    }
}
