import Foundation
import HerdHost
import HerdKit

/// Polls herdr and publishes the current snapshot plus a coarse health state.
///
/// This is the standalone equivalent of the fork's `HerdManager`, but it calls ``HerdSnapshotBuilder``
/// directly instead of going through an XPC helper, because a hand-assembled ad-hoc-signed bundle is
/// not sandboxed and can read `~/.config/herdr` itself.
///
/// Why polling rather than herdr's `events.subscribe`: herdr's `pane.agent_status_changed` event is
/// pane-scoped and needs a `pane_id`, so a push design means one subscription per pane plus
/// re-subscription on every `pane.created` and `pane.closed`. A measured `agent.list` round trip is
/// about 36 ms, so polling four sessions at 1 Hz costs less than the bookkeeping would.
///
/// Thread-safety: main-actor isolated, so every published mutation happens where SwiftUI wants it.
/// ``HerdSnapshotBuilder/build()`` is synchronous and blocking, and is therefore dispatched onto
/// ``queue``, a dedicated serial queue. It must not run on the cooperative pool either: a wedged
/// session can block for the full call timeout, which would starve a pool thread.
@MainActor
final class HerdBarModel: ObservableObject {
    /// The most recent snapshot, filtered by ``HerdPreferences/sessionFilter``.
    ///
    /// Starts empty so the status item can render before the first poll returns rather than flashing
    /// in a moment later.
    @Published private(set) var snapshot = HerdSnapshot(sessions: [], counts: StatusCounts())

    /// What the app knows beyond the snapshot. Drives the panel banner and the status item's
    /// degraded marker.
    @Published private(set) var state: HerdBarState = .noSessions("Looking for herdr sessions.")

    /// Keys of agents that finished inside ``HerdCompletionMemory/window``.
    ///
    /// Published alongside the snapshot rather than folded into it, because it is not snapshot data: the
    /// same snapshot decoded a minute later would have a different set. The panel needs it for two things
    /// that must agree, the row order and the row's mark, and taking both from one published value is what
    /// stops a row floating to the top with nothing to explain why.
    @Published private(set) var recentlyCompleted: Set<String> = []

    /// Names of running sessions that have no terminal attached to them.
    ///
    /// Refreshed when the panel opens rather than on every poll, and that is the whole design of it. The
    /// probe is a *write*: it stamps each session's window title, which is how herdr answers the question at
    /// all. Doing that at 1 Hz would be a stream of writes nobody asked for, whereas a panel open is a
    /// deliberate user action that happens dozens of times a day, and being correct at the instant the user
    /// looks is exactly when it matters.
    @Published private(set) var detachedSessions: Set<String> = []

    /// Interval used while the panel is closed, in seconds.
    ///
    /// Backing off matters more than latency here: with the popover shut, nobody can see a stale
    /// count, so paying for 1 Hz would be paying for nothing. The status item roll-up does go stale
    /// for up to this long, which is the accepted cost; opening the panel refreshes immediately.
    private static let idleInterval: TimeInterval = 5.0

    /// Every discovered session name, for the settings window's filter list.
    let roster = HerdSessionRoster()

    /// Settings source. Read on every tick so a settings change takes effect without restarting the loop.
    private let preferences: HerdPreferences

    /// Serial queue that owns every blocking herdr call.
    ///
    /// Serial rather than concurrent so two overlapping polls cannot open eight sockets at once, and
    /// `.utility` because nothing here is user-initiated.
    private let queue = DispatchQueue(label: "com.boringherd.snapshot", qos: .utility)

    /// Fires notifications on agents becoming blocked.
    private let notifier: HerdBlockedNotifier

    /// Diffs consecutive snapshots once, for both the notification and the popup.
    private let tracker = HerdTransitionTracker()

    /// Asks each running session whether a terminal is attached to it.
    private let attachmentProbe = HerdAttachmentProbe()

    /// Kept across polls so the process inspector's caches survive.
    // ponytail: no pendingAsk here, so a local Claude agent never reads as blocked in the menu bar; the
    // notch shares transcript readers for it. Wire a reader map here if the menu bar needs it.
    // ponytail: the menu bar announces no local finishes (no long-task rule here), acceptable; the notch owns that.
    private let localSource = LocalAgentSource()

    /// Remembers which agents finished recently, so the ledger can float them above the idle bulk.
    ///
    /// Lives here rather than in HerdKit because it needs a clock and memory of the previous snapshot,
    /// and HerdKit is deliberately a stateless snapshot builder. The ranking rule it feeds,
    /// ``HerdUrgencyOrder``, is a pure function and does live in HerdKit, so the fork gets the same
    /// ordering without inheriting a clock.
    private let completions = HerdCompletionMemory()

    /// Receives this tick's transitions so it can show the transient popup.
    ///
    /// A callback rather than a direct reference to the popup, because the popup needs the status
    /// item's button to anchor to and the model has no business knowing that a status item exists.
    /// Set by the app delegate, which owns both.
    var onTransitions: (([HerdTransition]) -> Void)?

    /// The poll loop. Cancelled on `applicationWillTerminate`.
    private var pollTask: Task<Void, Never>?

    /// Whether the popover is open, which selects the poll interval.
    ///
    /// Readable from outside because the status item has to know: it must not resize itself while the
    /// popover is anchored to it. See ``HerdStatusItem/refresh()``.
    private(set) var isPanelOpen = false

    /// Guards against a second poll starting while one is in flight, which a wedged session plus a
    /// manual refresh could otherwise cause.
    private var isPolling = false

    /// Creates the model.
    ///
    /// - Parameters:
    ///   - preferences: Settings source, re-read on every tick.
    ///   - notifier: Receives each snapshot so it can spot transitions into `blocked`.
    init(preferences: HerdPreferences, notifier: HerdBlockedNotifier) {
        self.preferences = preferences
        self.notifier = notifier
    }

    /// Starts the poll loop. Safe to call once; a second call is ignored.
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                let interval = self.currentInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Stops the poll loop. Called on app termination so the process does not linger mid-socket-read.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Records that the popover opened and refreshes immediately.
    ///
    /// The immediate refresh is what makes the 5 s idle back-off invisible: the loop may be most of
    /// the way through a long sleep when the user clicks, and waiting it out would show stale rows.
    func panelDidOpen() {
        isPanelOpen = true
        Task {
            await poll()
            await refreshAttachment()
        }
    }

    /// Re-polls and re-probes now, for a settings change that alters what is discovered.
    ///
    /// Adding a forwarded socket path or clearing the session filter should be visible immediately rather
    /// than up to five seconds later, and the poll loop may be most of the way through its idle sleep. The
    /// `isPolling` guard inside ``poll()`` makes a call landing on top of an in-flight poll a no-op rather
    /// than a second concurrent build.
    func refreshNow() {
        Task {
            await poll()
            await refreshAttachment()
        }
    }

    /// Re-probes which running sessions have a terminal attached, and publishes the answer.
    ///
    /// Runs after the poll rather than beside it, so it probes the sessions the panel is about to show. The
    /// blocking round trips go to ``queue`` for the same reason every other herdr call does: one wedged
    /// session can block for the full call timeout, and that must never be a main-thread stall.
    ///
    /// Skipped entirely when window-title stamping is off, because the probe *is* the stamp: attachment is
    /// only observable as a side effect of `client.window_title.set`. With stamping off there is nothing to
    /// ask, so the honest answer is no marker rather than a guess. See
    /// ``HerdPreferences/stampsWindowTitles``.
    private func refreshAttachment() async {
        let sessions = snapshot.sessions
        guard preferences.stampsWindowTitles, !sessions.isEmpty else {
            detachedSessions = []
            return
        }
        let probe = attachmentProbe
        detachedSessions = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: probe.detachedSessionNames(in: sessions))
            }
        }
    }

    /// Records that the popover closed, which lets the loop fall back to the idle interval.
    func panelDidClose() {
        isPanelOpen = false
    }

    /// Poll interval for the next sleep: the configured value while the panel is open, the idle
    /// back-off while it is closed.
    private var currentInterval: TimeInterval {
        isPanelOpen ? preferences.pollInterval : Self.idleInterval
    }

    /// Performs one poll: build a snapshot off the main thread, filter it, publish it, and let the
    /// notifier look for transitions.
    ///
    /// Never throws and never propagates a failure, because ``HerdSnapshotBuilder/build()`` does not
    /// throw: per-session failures arrive inside the snapshot as `HerdSession.error`, so one wedged
    /// session degrades one row rather than blanking the panel. This is also what makes recovery
    /// automatic when a herdr server restarts: the next poll simply succeeds again, with no
    /// connection state to invalidate because every call opens a fresh socket.
    private func poll() async {
        guard preferences.isEnabled else {
            state = .noSessions("Herd polling is off. Enable it from the menu bar item.")
            return
        }
        guard !isPolling else { return }
        isPolling = true
        defer { isPolling = false }

        let raw = await build()
        // Published before filtering, because the settings window's session list has to offer sessions the
        // filter is currently hiding. Sourcing it from the filtered snapshot is what made a deselected
        // session unreachable in the menu this replaced.
        roster.update(AgentSourceMerge.rosterNames(raw.sessions, mode: preferences.agentSourceMode))
        let filtered = Self.applying(filter: preferences.sessionFilter, to: raw)

        // One diff, three consumers now. The tracker suppresses the first snapshot after launch, so
        // nothing replays agents that were already blocked before the app started.
        //
        // The diff has to happen *before* the snapshot is published, because the recency memory it feeds
        // is what decides the row order: recording after publishing would show every completion one poll
        // late, which at 1 Hz is visible.
        let transitions = tracker.transitions(in: filtered)
        let completed = completions.record(transitions)
        recentlyCompleted = completed

        // Ordering happens here rather than in `HerdSnapshotBuilder`, and the choice is deliberate.
        // The builder already sorts blocked-first inside a workspace, which is correct and stays; what
        // it cannot know is "recently completed", because that needs a clock and the memory of the
        // previous snapshot. Re-sorting in the model also keeps the builder's output neutral for the
        // search window, which ranks by fuzzy score and wants no urgency bias applied first.
        snapshot = HerdUrgencyOrder.applying(recentlyCompleted: completed, to: filtered)
        state = Self.evaluate(filtered, filter: preferences.sessionFilter, mode: preferences.agentSourceMode)

        guard !transitions.isEmpty else { return }
        notifier.notify(transitions, isEnabled: preferences.notifiesOnBlocked)
        onTransitions?(transitions)
    }

    /// Runs the blocking build on ``queue`` and hands the result back to the main actor.
    ///
    /// The builder is constructed per poll rather than held, because the remote paths it scans come from
    /// preferences and must be re-read each tick: adding a forwarded socket in the settings window has to
    /// take effect on the next poll, not on the next launch. A `HerdSnapshotBuilder` is a value holding
    /// three numbers and two paths, so making one costs nothing. The source mode is re-read each tick for
    /// the same reason: `.herdr` is the untouched herdr path, `.local` never calls herdr, `.both` merges.
    ///
    /// - Returns: The unfiltered snapshot.
    private func build() async -> HerdSnapshot {
        let builder = HerdSnapshotBuilder(extraPaths: preferences.effectiveRemotePaths)
        let mode = preferences.agentSourceMode
        let local = localSource
        // Skip the local scan when the filter hides the session it would produce.
        let filter = preferences.sessionFilter
        let wantsLocal = mode != .herdr && (filter.isEmpty || filter.contains(LocalAgentSource.sessionName))
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: AgentSourceMerge.snapshot(
                    mode: mode, wantsLocal: wantsLocal, builder: builder, local: local))
            }
        }
    }

    /// Drops sessions the user has filtered out and re-tallies the counts.
    ///
    /// Re-tallying is necessary because ``HerdSnapshot/counts`` covers every session the builder saw;
    /// leaving it alone would make the menu bar advertise agents the panel does not list. This is the
    /// only place the app recomputes counts, and it is model code, not view code.
    ///
    /// - Parameters:
    ///   - filter: Session names to keep. Empty keeps everything.
    ///   - snapshot: The builder's output.
    /// - Returns: A snapshot containing only the requested sessions, with matching counts.
    private static func applying(filter: [String], to snapshot: HerdSnapshot) -> HerdSnapshot {
        guard !filter.isEmpty else { return snapshot }
        let wanted = Set(filter)
        let sessions = snapshot.sessions.filter { wanted.contains($0.name) }
        return HerdSnapshot(
            sessions: sessions,
            counts: StatusCounts(agents: sessions.lazy.flatMap(\.workspaces).flatMap(\.agents))
        )
    }

    /// Classifies a snapshot into a ``HerdBarState``.
    ///
    /// The distinctions are drawn where the user's next action changes:
    ///
    /// - Nothing discovered at all means herdr is not installed, or its config root is somewhere else.
    /// - Sessions discovered but none running means herdr is installed and simply not started. The
    ///   stopped sessions still render as rows, so this is a banner rather than an empty state.
    /// - Every running session erroring means herdr is up but not answering, which is the only case
    ///   that is genuinely a fault rather than a state.
    /// - A filter that matches nothing is called out separately, because otherwise it looks
    ///   identical to herdr not being installed.
    ///
    /// - Parameters:
    ///   - snapshot: The filtered snapshot about to be published.
    ///   - filter: The active session filter, needed to explain an empty result.
    ///   - mode: The source mode, so the empty text names what is actually being watched.
    /// - Returns: The state to publish.
    private static func evaluate(_ snapshot: HerdSnapshot, filter: [String], mode: AgentSourceMode) -> HerdBarState {
        if snapshot.sessions.isEmpty {
            if !filter.isEmpty {
                return .noSessions(
                    "No session matches the filter: \(filter.joined(separator: ", ")). Clear it from the menu bar item."
                )
            }
            switch mode {
            case .herdr: return .noSessions("No herdr sessions yet.")
            case .local: return .noSessions("No local agents.")
            case .both: return .noSessions("No agents.")
            }
        }

        let running = snapshot.sessions.filter(\.running)
        if running.isEmpty {
            let count = snapshot.sessions.count
            return .noSessions(
                "\(count) herdr session\(count == 1 ? "" : "s"), none running."
            )
        }

        let failing = running.compactMap(\.error)
        if failing.count == running.count {
            return .error("herdr is running but not answering. \(failing[0])")
        }
        return .ok
    }
}

/// Lets ``HerdSearchWindow`` (from `HerdHost`) search this model's snapshot without that library naming
/// this type: `snapshot`, `recentlyCompleted`, `panelDidOpen()` and `panelDidClose()` all already exist
/// above for the panel's own use, so this conformance adds no new members, only the label.
extension HerdBarModel: HerdSearchSnapshotSource {}
