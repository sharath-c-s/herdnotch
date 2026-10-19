import Dispatch
import Foundation
import HerdHost
import HerdKit
import NotchCore

/// Polls herdr and publishes the herd agent ledger for the notch's `.herd` route.
///
/// A thin poller, deliberately: unlike `BoringHerdBar/HerdBarModel`, this type carries no attachment
/// probe, and ``snapshot``/``counts`` themselves still carry no completion memory — `HerdUrgencyOrder`
/// ranks them by the status herdr reports *right now*, so a blocked agent still floats above idle ones,
/// with no remembered "just finished" promotion. This model reuses only ``HerdKit`` — never
/// `HerdBarModel` itself — which is what keeps `HerdNotch` free to lift into the boringNotch fork
/// without dragging the host app's model layer along.
///
/// It does now carry exactly one piece of memory: ``recency``, which backs ``topAgents``, the bento
/// agents hero card's top-5 shortlist. herdr's own `HerdAgent` has no timestamp for "when did this
/// status begin", so that shortlist's own priority order (blocked/working/idle by local recency, `done`
/// only inside a 15-minute window) has nothing to sort by unless this model watches for status changes
/// itself and remembers when it saw one. See ``updateTopAgents(from:now:)`` for the full rule.
///
/// It does now read ``HerdPreferences`` (from `HerdHost`), the same store `HerdBarModel` reads: the
/// watch on/off switch, the open-panel poll interval, the session filter and the remote-socket paths.
/// That is the one piece of `HerdBarModel`-shaped behaviour this model gains, and it is read-only —
/// nothing here writes back to preferences, so the "no `HerdBarModel` dependency" boundary this type's
/// own history documents stays intact.
///
/// Thread-safety: main-actor isolated, so every published mutation happens where SwiftUI wants it.
/// ``HerdSnapshotBuilder/build()`` is synchronous and blocking, and is therefore dispatched onto
/// ``queue``, a dedicated serial queue, mirroring the off-main discipline `HerdBarModel` uses for the
/// same reason: a wedged herdr session must not stall the main actor for the length of a poll.
@MainActor
final class NotchHerdModel: ObservableObject {
    /// The most recent snapshot, reordered by ``HerdUrgencyOrder``.
    ///
    /// Starts empty so the notch has something to render before the first poll returns, and so "herdr
    /// not running" reads as an empty ledger rather than a crash or a blank frame.
    ///
    /// ``poll()`` only assigns a freshly built snapshot here when it actually differs (by `==`, see the
    /// ``HerdSnapshot: Hashable`` conformance below) from the one already published — a perf fix an
    /// adversarial review asked for: every poll, and every `hoverExit` while a panel is expanded (which
    /// runs through `NotchWindowController.updateViewModel(for:)` and, before its own guard, republished
    /// unconditionally), was invalidating and re-rendering every `@ObservedObject` view reading this model
    /// even when herdr reported the exact same agents. `@Published`'s `willSet` fires unconditionally on
    /// every *assignment*, so the fix has to be at the call site (skip the assignment), not on the
    /// property itself.
    @Published private(set) var snapshot = HerdSnapshot(sessions: [], counts: StatusCounts())

    /// The status tally carried on ``snapshot``, exposed as a computed property rather than a second
    /// `@Published` field.
    ///
    /// A separate `@Published var counts` was redundant: `@ObservedObject` invalidates a view whenever
    /// *any* of the object's `@Published` properties changes, not per-property, so publishing `counts`
    /// alongside `snapshot` bought this model nothing but a second, always-in-lockstep write on every
    /// poll — one more redundant re-render source the perf fix above closes. Deriving it from `snapshot`
    /// means it can never drift from the tally `snapshot` itself carries, and it still change-notifies
    /// correctly: `snapshot`'s own `@Published` publisher is what `NotchContentView`'s `@ObservedObject`
    /// reacts to, and `counts` only ever changes when `snapshot` does.
    var counts: StatusCounts { snapshot.counts }

    /// Total agents across every status in the current (filtered) ``snapshot``, for the bento agents hero
    /// card's header dot-counts and its "+N more" footer.
    ///
    /// A thin, documented alias for ``counts``'s own `StatusCounts.total` — kept as its own property
    /// because the design spec calls out "the total live count" by name as something this model must
    /// expose, and a caller reading `herdModel.liveAgentCount` should not have to know that total lives one
    /// level down inside `counts` instead.
    var liveAgentCount: Int { counts.total }

    /// Every discovered session name, for the settings window's filter list. Updated on every poll, the
    /// same point `HerdBarModel.roster` is updated from, and for the same reason: the settings window
    /// must be able to offer a session the filter is currently hiding, which the *filtered* snapshot
    /// cannot do.
    let roster = HerdSessionRoster()

    /// Every live agent for the bento agents hero card's scrolling browse list, in priority order (see
    /// ``updateTopAgents(from:now:)``). Empty before the first poll.
    @Published private(set) var topAgents: [NotchAgentEntry] = []

    /// Activity read on the latest poll, keyed by transcript id (see `AgentActivityTracker.transcriptID`).
    /// Lets search rows show an activity line without triggering any transcript read of their own.
    @Published private(set) var activityByTranscriptID: [String: AgentActivity] = [:]

    /// Key identifying one agent across polls for ``recency``: `(session.name, tab label or cwd basename)`,
    /// not `agent.paneId`. herdr can hand a pane a fresh id after a tab reattaches to the same running
    /// work, and the design spec's shortlist wants that continuity — "this is still the agent it was" —
    /// preserved across a pane-id change the user never sees.
    private struct RecencyKey: Hashable {
        let sessionName: String
        let displayIdentifier: String
    }

    /// One key's locally observed current status and the instant that status began.
    private struct RecencyEntry {
        let status: AgentStatus
        let since: Date
    }

    /// Locally observed status-change recency, keyed by ``RecencyKey``. There is no upstream timestamp for
    /// this — see this type's own documentation — so every entry is this model's own memory: seeded with
    /// the poll's `now` the first time a key is ever seen, and reset to `now` the instant a key's status
    /// differs from what was last recorded. Pruned to exactly the current poll's own agents on every
    /// ``updateTopAgents(from:now:)`` call, so a session or agent that stops appearing does not accumulate
    /// here forever.
    private var recency: [RecencyKey: RecencyEntry] = [:]

    /// The instant each agent was last observed to be ``AgentStatus/done``, keyed by ``RecencyKey``, backing
    /// the "sticky done" behaviour ``NotchAgentEntry/effectiveStatus`` documents. Set whenever an agent is
    /// seen `done`; cleared the moment that agent is seen `working` again (touched → back to running). Used
    /// to keep a just-finished agent's dot green for ``stickyDoneWindow`` even after herdr flips its live
    /// status to `idle`. Pruned to the current poll's agents alongside ``recency``.
    private var lastDone: [RecencyKey: Date] = [:]

    /// How long a just-finished agent keeps rendering as ``AgentStatus/done`` (green) after herdr has flipped
    /// its live status away from `done`, unless it goes `working` first. Read live from
    /// ``NotchPreferences/stickyDoneSeconds`` on every poll (rather than cached), so a settings change
    /// applies to the next poll with no relaunch needed. Defaults to a minute — long enough to notice a
    /// completed run, short enough that a genuinely-idle agent does not masquerade as freshly-done for long.
    private var stickyDoneWindow: TimeInterval { TimeInterval(NotchPreferences.shared.stickyDoneSeconds) }

    /// Whether at least one poll has ever completed. `false` at launch, `true` forever after the first
    /// call to ``updateTopAgents(from:now:)`` returns — the same "the first snapshot only establishes a
    /// baseline" rule `BoringHerdBar/HerdTransitionTracker.hasBaseline` documents, and for the identical
    /// reason: without it, launching with three agents already blocked would announce all three as toast
    /// alerts, as if they had just happened.
    private var hasAlertBaseline = false

    /// Minimum gap between two toast alerts about the same agent, keyed by ``RecencyKey``. Mirrors
    /// `BoringHerdBar/HerdBlockedNotifier.debounceInterval` exactly, and for the same reason: one minute
    /// swallows a burst of consecutive blocked/done flips from one flapping agent while still letting a
    /// genuinely new one minutes later through.
    private static let alertDebounceInterval: TimeInterval = 60

    /// When each key last produced a toast alert. See ``alertDebounceInterval``.
    private var lastAlerted: [RecencyKey: Date] = [:]

    /// The most recent coalesced toast alert, or `nil` before the first one ever fires. `NotchWindowController`
    /// observes this to drive ``NotchToast``, whose own hover/click callback opens the real notch — see
    /// ``NotchAlert``'s own documentation.
    ///
    /// Deliberately never reset to `nil` once set, and deliberately not compared for equality before
    /// assignment the way ``snapshot``/``topAgents`` are: a toast firing is a discrete *event*, not a
    /// piece of state whose redundant republication needs to be optimised away, and `NotchAlert.id` is a
    /// fresh `UUID` every time regardless of whether the underlying entries happen to look the same.
    @Published private(set) var alert: NotchAlert?

    /// Settings source, read on every poll so a change (watch on/off, poll interval, session filter,
    /// remote paths) takes effect without restarting the loop — the same contract `HerdBarModel` gives
    /// its own preferences.
    private let preferences: HerdPreferences

    /// Poll interval while no panel showing this model is expanded.
    ///
    /// Five seconds, the same idle back-off `HerdBarModel` uses, and for the same reason: with nothing
    /// on screen to go stale, paying for the configured interval buys nothing and only risks the
    /// sub-0.5%-idle-CPU budget this whole app is held to. Deliberately not itself preference-driven:
    /// `HerdBarModel`'s own idle back-off is not either, for the same reason.
    private static let idleInterval: TimeInterval = 5.0

    /// Serial queue that owns every blocking herdr call, kept separate from any queue `BoringHerdBar`
    /// might also be running in the same process (the two apps are never co-resident, but a shared
    /// label would still be a false economy).
    private let queue = DispatchQueue(label: "com.herdnotch.snapshot", qos: .utility)

    /// Transcript readers for the shortlist and alert agents; does its own IO off the main actor.
    private let activityTracker: AgentActivityTracker

    /// The local agent source, kept across polls so its process inspector's caches survive. Its
    /// `pendingAsk` reads through ``activityTracker`` so a Claude transcript is tailed once.
    private let localSource: LocalAgentSource

    /// The poll loop. Cancelled on ``stop()``.
    private var pollTask: Task<Void, Never>?

    /// Whether any panel currently showing this model is expanded, which selects the poll interval.
    private var isActive = false

    /// Creates the model.
    ///
    /// - Parameter preferences: Settings source, re-read on every tick.
    init(preferences: HerdPreferences) {
        self.preferences = preferences
        let tracker = AgentActivityTracker()
        activityTracker = tracker
        localSource = LocalAgentSource(pendingAsk: { tracker.pendingAsk(for: $0) })
    }

    /// Guards against a second poll starting while one is in flight.
    private var isPolling = false

    /// Set when ``poll()`` is asked to run again while it is already mid-flight (`isPolling == true`).
    ///
    /// Without this, ``setActive(_:)``'s activation poll and the in-flight ``poll()`` from the loop's own
    /// iteration could land in the same instant: the guard at the top of ``poll()`` would see
    /// `isPolling == true` and return immediately, silently dropping the activation's request for a fresh
    /// read — which is exactly the "opened panel can show data up to ~5s stale" bug this flag closes. The
    /// in-flight call checks this flag itself, right before it would otherwise return, and loops for one
    /// more build-and-publish pass instead of exiting, so a request that arrives mid-poll is deferred by
    /// at most one extra poll rather than lost outright.
    private var pollAgainRequested = false

    /// Starts the poll loop. Safe to call once; a second call is ignored.
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                let interval = self.isActive ? self.preferences.pollInterval : Self.idleInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Stops the poll loop. Called on app termination so the process does not linger mid-socket-read.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Re-polls now, for a settings change that alters what is discovered (the watch switch, the session
    /// filter or the remote paths) or that a rebound hotkey wants confirmed immediately. Mirrors
    /// `HerdBarModel.refreshNow()`: the loop may be most of the way through an idle sleep, and waiting it
    /// out would show a stale answer to a change the user just made.
    func refreshNow() {
        Task { await poll() }
    }

    /// Raises or lowers the poll rate, and restarts the poll loop to re-poll immediately when raising it.
    ///
    /// Called by `NotchWindowController` as a panel's presentation crosses into or out of
    /// `.expanded`/`.expanding`. On activation this used to fire one extra, one-off `poll()` alongside the
    /// loop's own in-flight sleep — which fixed the *first* refresh but never actually raised the cadence
    /// until the loop's already-in-progress five-second idle sleep happened to finish on its own, and could
    /// be silently dropped outright if that extra poll landed while a `build()` was already running (see
    /// ``pollAgainRequested``). Restarting the loop instead (``stop()`` then ``start()``) fixes both: the
    /// new `Task`'s very first action is `poll()`, run before any sleep at all, and every sleep after that
    /// reads `isActive` (already flipped above) fresh, so it immediately picks up
    /// ``HerdPreferences/pollInterval`` rather than waiting out whatever ``idleInterval`` sleep was
    /// already in flight.
    ///
    /// `stop()` marks the outgoing task cancelled but does not wait for it: if that task's own `poll()` call
    /// is still running, it keeps running to completion (a wedged herdr session must not be interrupted
    /// mid-read) and simply exits its loop afterwards without sleeping, since `Task.isCancelled` is already
    /// true by then. No double timer results — `pollTask` is reassigned to exactly one new task, and the
    /// outgoing one never re-enters its loop.
    ///
    /// - Parameter active: `true` while a panel showing this model is expanded or expanding.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        guard active else { return }
        stop()
        start()
    }

    /// Performs one poll: build a snapshot off the main thread, filter it, reorder it, and publish it if
    /// it changed.
    ///
    /// Never throws and never crashes on "herdr not running": ``HerdSnapshotBuilder/build()`` never
    /// throws either, and an empty discovery simply yields a snapshot with no sessions, which
    /// `HerdLedgerView` already renders as "Run herdr in a terminal to start one."
    ///
    /// Watching can be turned off entirely (``HerdPreferences/isEnabled``), which publishes an empty
    /// snapshot and roster rather than attempting a build — the same "polling is off" behaviour
    /// `HerdBarModel` gives its own `state`, just with no banner surface here to say so on.
    ///
    /// If another call to `poll()` arrives while this one is already running, it does not run a second,
    /// overlapping build; it instead sets ``pollAgainRequested`` and returns immediately. This call notices
    /// that flag in its own `repeat`/`while` and loops for one more build-and-publish pass before finally
    /// releasing ``isPolling`` — see ``pollAgainRequested``'s documentation for why silently dropping that
    /// request instead would reintroduce ``setActive(_:)``'s "opened panel can show stale data" bug.
    private func poll() async {
        guard !isPolling else {
            pollAgainRequested = true
            return
        }
        isPolling = true
        defer { isPolling = false }

        repeat {
            pollAgainRequested = false
            guard preferences.isEnabled else {
                roster.update([])
                let empty = HerdSnapshot(sessions: [], counts: StatusCounts())
                if empty != snapshot { snapshot = empty }
                recency.removeAll()
                if !topAgents.isEmpty { topAgents = [] }
                continue
            }
            let raw = await build()
            // Published before filtering, for the same reason `HerdBarModel.roster` is: the settings
            // window's session list has to offer sessions the filter is currently hiding.
            roster.update(AgentSourceMerge.rosterNames(raw.sessions, mode: preferences.agentSourceMode))
            let filtered = Self.applying(filter: preferences.sessionFilter, to: raw)
            // Computed from `filtered`, before `HerdUrgencyOrder` reorders anything below: see
            // ``updateTopAgents(from:now:)`` for why this shortlist cannot reuse that ordering.
            await updateTopAgents(from: filtered, now: Date())
            // `snapshot`/``counts`` themselves stay memoryless (see this type's documentation), so every
            // agent is ranked purely by its current status: a `working -> idle` transition is simply idle,
            // with no "just finished" promotion.
            let ordered = HerdUrgencyOrder.applying(recentlyCompleted: [], to: filtered)
            if ordered != snapshot {
                snapshot = ordered
            }
        } while pollAgainRequested
    }

    /// Recomputes ``recency`` and ``topAgents`` from `snapshot`, once per poll.
    ///
    /// Deliberately never touches ``HerdUrgencyOrder``: that type ranks `done` above `working` (see its
    /// own documentation), which is the wrong priority for a shortlist whose whole point is surfacing what
    /// still needs attention. This method applies its own four-bucket priority instead — every `blocked`
    /// agent, newest local status-change first; then `working`, by local recency; then a `done` agent only
    /// if it was locally observed to have gone `done` less than 15 minutes ago; then `idle`, by local
    /// recency. `done` deliberately outranks `idle`: a just-finished run is a notable event, an idle agent
    /// is not. `unknown` agents are never shortlisted: the design spec's own priority list has no
    /// bucket for them, and "not yet classified" is not one of the four states this shortlist exists to
    /// surface.
    ///
    /// Ties — most commonly every agent on the very first poll ever, when every ``RecencyKey`` is freshly
    /// seeded at the same `now` — fall back to `snapshot`'s own tree order (session, then workspace, then
    /// agent), because `flattened` below is built in that order before being sorted and `Array.sorted(by:)`
    /// is a stable sort in Swift. That is the design spec's "empty-map first snapshot → deterministic tree
    /// order" rule, satisfied for free rather than as a special case.
    ///
    /// Also drives ``alert``: the same per-agent old-status/new-status comparison this method already makes
    /// to maintain ``recency`` is exactly what a toast needs to detect "this agent just became blocked or
    /// done", so that detection is folded into this method's own loop rather than duplicated by a second
    /// diff pass — see ``NotchAlert``'s own documentation for the qualifying rule and the debounce.
    ///
    /// - Parameters:
    ///   - snapshot: The filtered, not-yet-urgency-reordered snapshot for this poll.
    ///   - now: The instant this poll ran. Used both to seed/refresh ``recency`` and to render each
    ///     surfaced entry's ``NotchAgentEntry/relativeAge`` — the one and only place that string is
    ///     computed, since there is no perpetual timer here to recompute it on a tick (see the design
    ///     spec's "ages... update on discrete model callbacks only" rule).
    private func updateTopAgents(from snapshot: HerdSnapshot, now: Date) async {
        var seenKeys: Set<RecencyKey> = []
        var aliveTranscripts: Set<String> = []
        var flattened: [(session: HerdSession, workspace: HerdWorkspace, agent: HerdAgent)] = []
        var newlyAlerted: [NotchAlertEntry] = []
        for session in snapshot.sessions {
            for workspace in session.workspaces {
                for agent in workspace.agents {
                    let key = Self.recencyKey(session: session, agent: agent)
                    seenKeys.insert(key)
                    // Captured before the overwrite below: the long-task rule needs how long it was working.
                    let previous = recency[key]
                    let previousStatus = previous?.status
                    if previousStatus != agent.agentStatus {
                        recency[key] = RecencyEntry(status: agent.agentStatus, since: now)
                    }
                    // Sticky-done bookkeeping: remember when an agent last went done, and forget it the
                    // instant it goes working (it was touched — back to running). Everything else (idle,
                    // unknown) leaves the memory intact so a just-finished agent stays green through the
                    // brief idle herdr flips it to, until ``stickyDoneWindow`` elapses.
                    if agent.agentStatus == .done {
                        lastDone[key] = recency[key]?.since ?? now
                    } else if agent.agentStatus == .working {
                        lastDone[key] = nil
                    }
                    // Qualifying rule mirrors `HerdTransition.isNewlyBlocked`/`isCompleted`: a genuine
                    // transition (not the first-ever observation of this agent), landing on blocked or
                    // done, from anything other than `unknown` (which usually means herdr had simply not
                    // classified the pane yet, not that it "just finished" or "just got stuck" — see that
                    // type's own documentation for the identical reasoning). `hasAlertBaseline` additionally
                    // suppresses every candidate on the very first poll ever, so launching with agents
                    // already blocked never announces them as if they had just happened.
                    // A working agent that lands on done or idle is a "finished" candidate for the long-task
                    // rule; any other done (idle to done) and every blocked keeps the rule above.
                    var announce = false
                    var detail: String?
                    if hasAlertBaseline, let previous, previous.status != agent.agentStatus,
                        previous.status != .unknown
                    {
                        switch agent.agentStatus {
                        case .blocked:
                            announce = true
                        case .done where previous.status != .working:
                            announce = true
                        case .done, .idle:
                            if previous.status == .working {
                                let decision = LongTaskRule.evaluate(
                                    workedFor: now.timeIntervalSince(previous.since),
                                    thresholdMinutes: preferences.longTaskMinutes,
                                    landedOnDone: agent.agentStatus == .done, isLocal: agent.source == .local)
                                announce = decision.announce
                                detail = decision.detail
                            }
                        default:
                            break
                        }
                    }
                    if announce {
                        // The toast says finished, so the row must too: `lastDone` is otherwise only set on a real done.
                        if agent.agentStatus == .idle { lastDone[key] = now }
                        let debounced = lastAlerted[key].map { now.timeIntervalSince($0) < Self.alertDebounceInterval }
                            ?? false
                        if !debounced {
                            lastAlerted[key] = now
                            // An idle landing is announced as finished, so the toast says `done`.
                            var entry = NotchAlertEntry(
                                session: session, agent: agent,
                                status: agent.agentStatus == .blocked ? .blocked : .done)
                            entry.detail = detail
                            newlyAlerted.append(entry)
                        }
                    }
                    if let id = AgentActivityTracker.transcriptID(session: session, agent: agent) {
                        aliveTranscripts.insert(id)
                    }
                    flattened.append((session, workspace, agent))
                }
            }
        }
        recency = recency.filter { seenKeys.contains($0.key) }
        lastDone = lastDone.filter { seenKeys.contains($0.key) }
        lastAlerted = lastAlerted.filter { seenKeys.contains($0.key) }
        hasAlertBaseline = true
        let doneWindow: TimeInterval = 15 * 60
        let ranked: [(bucket: Int, entry: NotchAgentEntry)] = flattened.compactMap { session, workspace, agent in
            let key = Self.recencyKey(session: session, agent: agent)
            guard let since = recency[key]?.since else { return nil }
            // Resolve the sticky-done override: a genuinely-done agent renders done from `since`; an agent
            // whose live status has drifted off done (to idle/unknown, never working) but that finished
            // within ``stickyDoneWindow`` keeps rendering done, dated from when it finished, so the dot
            // stays green and it stays ranked in the done bucket. `working` clears the memory (handled in
            // the loop above), so a touched agent immediately drops the green.
            let effectiveStatus: AgentStatus
            let effectiveSince: Date
            if agent.agentStatus == .done {
                effectiveStatus = .done
                effectiveSince = since
            } else if agent.agentStatus != .working, let done = lastDone[key],
                now.timeIntervalSince(done) < stickyDoneWindow
            {
                effectiveStatus = .done
                effectiveSince = done
            } else {
                effectiveStatus = agent.agentStatus
                effectiveSince = since
            }
            // Agents with no bucket (unknown, long-done) still list, after every bucketed agent.
            let bucket = Self.shortlistBucket(
                for: effectiveStatus, since: effectiveSince, now: now, doneWindow: doneWindow
            ) ?? 4
            let entry = NotchAgentEntry(
                session: session, workspace: workspace, agent: agent,
                effectiveStatus: effectiveStatus,
                statusSince: effectiveSince, relativeAge: Self.relativeAge(from: effectiveSince, to: now)
            )
            return (bucket, entry)
        }
        let sorted = ranked.sorted { lhs, rhs in
            lhs.bucket == rhs.bucket ? lhs.entry.statusSince > rhs.entry.statusSince : lhs.bucket < rhs.bucket
        }
        var shortlist = sorted.map(\.entry)

        // Transcript IO only for the first `activityCap` rows and the alert batch, bounding it to a few files.
        let shortlistIDs = shortlist.map { AgentActivityTracker.transcriptID(session: $0.session, agent: $0.agent) }
        let wantedShortlistIDs = shortlistIDs.prefix(Self.activityCap)
        let alertIDs = newlyAlerted.map { AgentActivityTracker.transcriptID(session: $0.session, agent: $0.agent) }
        let activities = await activityTracker.activities(
            wanted: Set((wantedShortlistIDs + alertIDs).compactMap { $0 }), alive: aliveTranscripts)
        for (index, id) in wantedShortlistIDs.enumerated() {
            shortlist[index].activity = id.flatMap { activities[$0] }
        }
        for (index, id) in alertIDs.enumerated() {
            newlyAlerted[index].pendingAsk = id.flatMap { activities[$0] }?.pendingAsk
        }

        // One coalesced alert per poll, never several queued up: a second qualifying batch replaces
        // whatever ``NotchToast`` is already showing rather than stacking behind it, the same
        // "a new event always wins" rule `BoringHerdBar/HerdTransientPopup.show(_:anchor:duration:)`
        // documents for its own dismiss-timer rearm.
        if !newlyAlerted.isEmpty {
            alert = NotchAlert(id: UUID(), entries: newlyAlerted)
        }
        if shortlist != topAgents {
            topAgents = shortlist
        }
        if activities != activityByTranscriptID {
            activityByTranscriptID = activities
        }
    }

    /// Local agents key on their synthetic pane id: two unnamed agents in one project share a display
    /// identifier, and merging their recency would make one agent's finish look like the other's.
    private static func recencyKey(session: HerdSession, agent: HerdAgent) -> RecencyKey {
        RecencyKey(
            sessionName: session.name,
            displayIdentifier: agent.source == .local
                ? agent.paneId : (agent.tabLabel.flatMap { $0.isEmpty ? nil : $0 } ?? agent.cwdBasename))
    }

    /// How many of the first listed agents get a transcript read each poll.
    private static let activityCap = 24

    /// The design spec's four shortlist buckets, ascending priority (`0` sorts first). `nil` means no
    /// bucket (`unknown`, or a `done` agent past `doneWindow`); such agents list last, after bucket 3.
    ///
    /// - Parameters:
    ///   - status: The agent's current status.
    ///   - since: This agent's ``RecencyEntry/since``, i.e. when it locally entered `status`.
    ///   - now: The instant to measure `since` against.
    ///   - doneWindow: How long a `done` agent stays shortlisted after going done.
    /// - Returns: The bucket, or `nil` for the trailing no-bucket group.
    private static func shortlistBucket(
        for status: AgentStatus, since: Date, now: Date, doneWindow: TimeInterval
    ) -> Int? {
        // Priority order (0 sorts first): the agents that need a human or just changed come before the ones
        // quietly sitting idle. The user wants "running, just finished and blocked ones first", so a
        // recently-`done` agent ranks ABOVE `idle`, not below it — a finished run is a notable event worth
        // surfacing on the shortlist, where a long-idle agent is not.
        switch status {
        case .blocked: return 0
        case .working: return 1
        case .done: return now.timeIntervalSince(since) < doneWindow ? 2 : nil
        case .idle: return 3
        case .unknown: return nil
        }
    }

    /// A short relative-age string (`"now"`, `"2m"`, `"1h"`) for `since`, measured against `now`.
    ///
    /// - Parameters:
    ///   - since: The instant to measure from.
    ///   - now: The instant to measure to.
    private static func relativeAge(from since: Date, to now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(since) / 60))
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }

    /// Runs the blocking build on ``queue`` and hands the result back to the main actor.
    ///
    /// A fresh ``HerdSnapshotBuilder`` per poll, same as `HerdBarModel`: it is a value holding a couple
    /// of numbers and a path, so building one costs nothing, and the remote paths it scans come from
    /// preferences and must be re-read each tick. The source mode is re-read each tick too: `.herdr` is the
    /// untouched herdr path, `.local` never calls herdr, and `.both` merges the two (see
    /// ``AgentSourceMerge``).
    ///
    /// - Returns: The unfiltered, unordered snapshot.
    private func build() async -> HerdSnapshot {
        let builder = HerdSnapshotBuilder(extraPaths: preferences.effectiveRemotePaths)
        let mode = preferences.agentSourceMode
        let local = localSource
        // The local session is invisible when the filter excludes it, so skip its transcript reads too.
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
    /// The same rule `HerdBarModel.applying(filter:to:)` applies, duplicated rather than shared: it is
    /// ten lines over `HerdKit` value types, and hoisting it into `HerdKit` or `HerdHost` for one caller
    /// on each side would be a new shared abstraction this reuse did not ask for.
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
}

/// One agent surfaced in ``NotchHerdModel/topAgents``: everything the bento agents hero card's breadcrumb
/// row needs, already carrying the ``session`` and ``workspace`` it came from — `HerdFocusService`'s
/// `focus(agent:in:)` needs the whole `HerdSession` for its socket path, not just a name — plus this
/// model's own locally observed recency for it.
///
/// `Equatable` (synthesised, every stored property already conforms) is what lets
/// ``NotchHerdModel/updateTopAgents(from:now:)`` skip republishing a shortlist that has not actually
/// changed, the same perf discipline ``NotchHerdModel/snapshot`` already applies to itself.
struct NotchAgentEntry: Identifiable, Equatable {
    /// `agent.paneId`, the same stable per-session identity `HerdAgent.id` already uses. Unique within
    /// ``topAgents`` because a session's own agents each hold a distinct pane.
    var id: String { agent.paneId }

    /// The session this agent's pane lives in.
    let session: HerdSession

    /// The workspace containing ``agent``.
    let workspace: HerdWorkspace

    /// The agent itself.
    let agent: HerdAgent

    /// The status to actually render for this row, which is usually ``agent``'s live `agentStatus` but is
    /// held at ``AgentStatus/done`` for a short "sticky" window after an agent finishes: herdr often flips a
    /// just-finished pane straight to `idle`, which would drop its dot from green to blue instantly and let
    /// a completed run blend into the idle crowd before the user notices it. This keeps a just-finished
    /// agent green for ~1 minute (see ``NotchHerdModel``'s sticky-done window) or until it is touched and
    /// goes back to `working`, whichever comes first. Use THIS, not `agent.agentStatus`, for the dot colour
    /// and bucket.
    let effectiveStatus: AgentStatus

    /// Locally observed instant ``agent``'s *current* status began. See ``NotchHerdModel``'s own
    /// documentation for why there is no upstream timestamp to read this from instead.
    let statusSince: Date

    /// ``statusSince``'s age relative to the poll that produced this entry, already formatted (`"now"`,
    /// `"2m"`, `"1h"`). Computed once, at publish time — see
    /// ``NotchHerdModel/updateTopAgents(from:now:)``'s own documentation for why this is never re-derived
    /// by a view-layer timer.
    let relativeAge: String

    /// Transcript-derived activity, `nil` for remote/non-claude agents or an unreadable transcript.
    var activity: AgentActivity?
}

/// One agent's genuine transition into ``AgentStatus/blocked`` or ``AgentStatus/done``, as coalesced into
/// ``NotchAlert``.
///
/// Deliberately not `NotchAgentEntry`: this is a point-in-time event (a transition just happened), not a
/// live shortlist row, and carries the specific status that was transitioned *into* rather than whatever
/// ``NotchHerdModel/topAgents`` might currently say about the same agent a moment later.
struct NotchAlertEntry: Equatable {
    /// The session this agent's pane lives in.
    let session: HerdSession
    /// The agent that transitioned.
    let agent: HerdAgent
    /// The status it transitioned into: always ``AgentStatus/blocked`` or ``AgentStatus/done``.
    let status: AgentStatus
    /// What the blocked agent is asking for, from its transcript, for the toast's "why blocked" line.
    var pendingAsk: String?
    /// Overrides the toast's default "kind · session" detail line (e.g. "finished after 12m"). A blocked
    /// entry's ``pendingAsk`` still wins over this.
    var detail: String?
}

/// A coalesced batch of ``NotchAlertEntry`` values from one poll, backing `NotchToast` — the notch's
/// transient "an agent needs you" surface, the equivalent of `BoringHerdBar/HerdTransientPopup` for a menu
/// bar app.
///
/// Coalesced rather than queued: every qualifying transition detected in a single
/// ``NotchHerdModel/updateTopAgents(from:now:)`` call becomes one `NotchAlert`, so four agents blocking at
/// once produce one "4 agents need you"-shaped toast rather than four toasts stacked behind each other —
/// see that method's own documentation for the qualifying rule (a genuine transition, not a first
/// observation, landing on blocked/done from anything but `unknown`) and its 60-second per-agent debounce.
///
/// `Identifiable` via a fresh `UUID` per instance rather than any content-derived key, specifically so two
/// alerts with coincidentally identical entries are still two distinct firings — see
/// ``NotchHerdModel/alert``'s own documentation for why this type is never deduplicated by content.
struct NotchAlert: Identifiable, Equatable {
    let id: UUID
    /// Every transition this batch coalesces. Never empty — ``NotchHerdModel`` only ever assigns
    /// ``NotchHerdModel/alert`` when this is non-empty.
    let entries: [NotchAlertEntry]
}

/// A same-value equality/hash conformance for ``HerdSnapshot``, added here rather than in `HerdKit` itself:
/// this fix's scope is `HerdNotch` only, and `HerdSnapshot` does not need to change to gain one — every
/// stored property it has (`sessions: [HerdSession]`, `counts: StatusCounts`) already conforms to
/// `Hashable` in `HerdKit`, so this is a manual, entirely mechanical implementation of what the compiler
/// would have synthesised automatically had `HerdSnapshot`'s own declaration listed the conformance (Swift
/// only synthesises `Hashable` for a type declared in the same file as the conformance, never through an
/// extension in another module). ``NotchHerdModel/poll()`` is the sole reason this exists: it is what lets
/// that method skip publishing a rebuilt snapshot that is identical, agent-for-agent, to the one already
/// on screen.
extension HerdSnapshot: @retroactive Hashable {
    public static func == (lhs: HerdSnapshot, rhs: HerdSnapshot) -> Bool {
        lhs.sessions == rhs.sessions && lhs.counts == rhs.counts
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(sessions)
        hasher.combine(counts)
    }
}

/// Lets ``HerdSearchWindow`` (from `HerdHost`) search this model's snapshot, restoring the fn-fn pane
/// search the notch app's hotkey used to skip in favour of routing straight to the herd ledger.
///
/// ``panelDidOpen()`` and ``panelDidClose()`` are no-ops here, unlike `HerdBarModel`'s versions: this
/// model never fully idles the way a closed popover does (see this type's own documentation), so there
/// is no back-off to lift the search window out of, only the existing 1 Hz/5 Hz cadence `setActive(_:)`
/// already governs from the notch panel's own expansion state. A search opened while the notch panel is
/// collapsed can therefore show data up to ``idleInterval`` stale, the same bounded, self-correcting
/// staleness ``HerdSearchWindow`` already accepts for `HerdBarModel`.
extension NotchHerdModel: HerdSearchSnapshotSource {
    /// No recency memory here (see this type's own documentation), so every result ranks by its current
    /// status alone.
    var recentlyCompleted: Set<String> { [] }

    func panelDidOpen() {}

    func panelDidClose() {}
}
