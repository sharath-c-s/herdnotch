import Foundation
import HerdKit

/// Remembers which agents finished recently, so the panel can float them above the idle bulk.
///
/// This is the piece that cannot live in HerdKit. "Recently completed" is not a property of a snapshot;
/// it is a property of the *difference* between two snapshots plus a clock, and HerdKit is deliberately a
/// stateless snapshot builder. Putting a clock in it would mean the same snapshot decoded twice could
/// order differently, and would make every HerdKit test time-dependent. So the ranking rule lives in
/// ``HerdUrgencyOrder`` as a pure function and the memory lives here.
///
/// The window is **90 seconds**. The reasoning: the transient popup that announces a completion is on
/// screen for a couple of seconds, so anything shorter would mean the row had already sunk by the time
/// the user finished reading the popup and reached for the menu bar. Much longer and the top of the panel
/// becomes a graveyard of things that finished several minutes ago, which is the opposite of the panel's
/// job. Ninety seconds covers "I saw the notification, let me go look" without accumulating history.
///
/// Thread-safety: main-actor isolated. Only the poll loop touches it, on the same actor as
/// ``HerdTransitionTracker``, which is where its input comes from.
@MainActor
final class HerdCompletionMemory {
    /// How long a completion stays interesting, in seconds.
    static let window: TimeInterval = 90

    /// When each remembered agent completed, keyed by ``HerdUrgencyOrder/key(sessionName:paneId:)``.
    private var completions: [String: Date] = [:]

    /// Source of the current time. Injected so tests can drive the window without sleeping.
    private let now: () -> Date

    /// Creates the memory.
    ///
    /// - Parameter now: Clock. Defaults to the system clock; tests pass a controllable one.
    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Records this poll's completions and returns everything still inside the window.
    ///
    /// Recording and pruning happen in one call on purpose. Two separate entry points would let a caller
    /// read a stale set, and there is exactly one caller.
    ///
    /// A completion is re-stamped rather than ignored if the same agent completes twice, which is the
    /// correct behaviour: the second completion is the news, and the first is spent.
    ///
    /// An agent that goes `idle -> working -> idle` inside the window therefore surfaces twice, and an
    /// agent that goes `idle -> blocked` while remembered is ranked `blocked` anyway, because
    /// ``HerdUrgencyOrder`` only consults the recency set for agents whose current status is `idle`.
    ///
    /// - Parameter transitions: This poll's transitions, from ``HerdTransitionTracker``.
    /// - Returns: Keys of every agent that completed inside ``window``.
    func record(_ transitions: [HerdTransition]) -> Set<String> {
        let timestamp = now()
        for transition in transitions where transition.isCompleted {
            completions[
                HerdUrgencyOrder.key(
                    sessionName: transition.sessionName,
                    paneId: transition.agent.paneId
                )
            ] = timestamp
        }

        // Pruned on every poll rather than on a timer. The poll is already running at 1 Hz or 0.2 Hz, so
        // a timer would be a second schedule doing the same work, and an unpruned dictionary would grow
        // for the lifetime of the process.
        let cutoff = timestamp.addingTimeInterval(-Self.window)
        completions = completions.filter { $0.value > cutoff }
        return Set(completions.keys)
    }

    /// Keys currently inside the window, without recording anything.
    ///
    /// Used on polls that produce no transitions, so the ordering does not lose its memory on a quiet
    /// tick. Does not prune, because ``record(_:)`` is called on every poll and is the only place the
    /// dictionary needs to shrink.
    var current: Set<String> {
        let cutoff = now().addingTimeInterval(-Self.window)
        return Set(completions.filter { $0.value > cutoff }.keys)
    }
}
