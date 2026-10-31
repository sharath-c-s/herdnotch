import Foundation

/// The glitch-free notch state machine, and the whole reason `NotchCore` exists as a Foundation-only
/// library: everything in this type is a pure function of the state it already holds plus one incoming
/// ``NotchEvent``, with no clock, timer, pointer monitor or animation of its own. Every side effect it
/// wants performed comes back out as a ``NotchCommand`` for the caller to carry out; every fact time has
/// passed comes back *in* as an event (`hoverDebounceFired`, `exitGraceFired`, `animationSettled`) once the
/// AppKit layer has actually made it true. That split is what makes the transition table below testable
/// with no window server: a test drives it with the exact event sequence a real timer or monitor would have
/// produced, and reads the resulting state and commands with no timing dependency at all.
///
/// ## `reduce(_:)` returns a complete command list
///
/// `reduce(_:)` returns `[NotchCommand]`: every command names both the effect to perform and the
/// ``NotchDisplayID`` to perform it on. This is a deliberate departure from an earlier design that returned
/// bare `[NotchEffect]` implicitly scoped to the triggering event's own display — that design could not
/// express the one cross-panel transition this reducer enforces, **at most one panel may be `expanding` or
/// `expanded` at a time**, without silently mutating some *other* display's state with no command telling
/// the caller to animate it.
///
/// Every call to `reduce(_:)` now returns the **complete** set of commands needed, across every display
/// touched by that call. When display A begins expanding and the invariant forces a currently
/// `expanding`/`expanded` display B into `collapsing`, the returned array contains both A's
/// `startExpand(generation:)` (tagged `display: A`) and B's `startCollapse(generation:)` (tagged
/// `display: B`), plus whichever of `cancelHoverDebounce` / `cancelExitGrace` B's own pending timers require
/// (see ``forceOtherPanelsToCollapsing(excluding:)``). The AppKit controller therefore needs no
/// reconciliation pass over ``panels``: it is a dumb executor that, for every command in the array, performs
/// `command.effect` against whichever panel `command.display` names. (It never needs to remove B's pointer
/// monitors from this same call: those monitors are still legitimately in use while B's own collapse
/// animation is in flight, and the normal `collapsing` → `collapsed` settle path already emits
/// `removePointerMonitors` for B the moment B's own `animationSettled` arrives — removing them twice would
/// be redundant, not incorrect, so this reducer chooses not to.)
///
/// ## Commands cover lifecycle, animation, timers, pointer monitors and window visibility — never content
///
/// `NotchCommand`/`NotchEffect` describe everything a dumb executor needs to run the panel's open/close
/// machinery: `startExpand`/`startCollapse`, `scheduleHoverDebounce`/`scheduleExitGrace` and their cancels,
/// `installPointerMonitors`/`removePointerMonitors`, and `hidePanel`/`showCollapsed`. They never describe
/// **which** ``NotchRoute`` is on screen. Panel content is state, not an effect: the SwiftUI view is expected
/// to read the route to render directly from ``NotchPanelState/presentation`` (`.expanded(route)`) or, while
/// still expanding, from ``NotchPanelState/pendingRoute``. This is a deliberate design decision, not an
/// oversight — a design review flagged `handleRoute(_:panel:)` returning `[]` for every `route(_:)` event as
/// suspicious-looking, and the resolution is this: there is no "render this route" effect for a dumb executor
/// to run, because the executor never renders anything itself, so a `route(_:)` event legitimately mutates
/// state and returns no command. (Earlier drafts of this type's documentation, and of
/// ``NotchPanelState``'s, described `panels` as a fallback a caller had to re-read because some cross-panel
/// effect might be missing; that was true only during a design iteration that has since been fixed — see the
/// section above — and both places have been corrected to state the real, narrower reason `panels` is read
/// directly: content, never lifecycle.)
///
/// ## Generations close the stale-completion race
///
/// Every expand or collapse bumps ``NotchPanelState/animationGeneration`` and stamps the new value onto the
/// ``NotchEffect`` it emits. `animationSettled(display, generation:)` only advances state when `generation`
/// equals the panel's *current* ``NotchPanelState/animationGeneration``; anything else, including an
/// old animation's completion arriving after a retarget, is a complete no-op — no state change, no
/// commands. This is what closes the "aborted collapse completion marks state collapsed under an expanded
/// panel" desync named in the design review: interrupting an animation is always a bump, never a rewrite.
///
/// The two dismissal/expand timers get the identical treatment, belt-and-braces alongside the
/// `hoverDebouncePending`/`exitGracePending` flags: ``NotchPanelState/hoverDebounceGeneration`` and
/// ``NotchPanelState/exitGraceGeneration`` are bumped on every schedule *and* every cancel, stamped onto
/// `scheduleHoverDebounce(generation:)`/`scheduleExitGrace(generation:)`, and checked against the fired
/// event's echoed-back `generation` before either fire is honoured. The flags alone already reject a fire
/// that arrives after a clean cancel; the generation additionally rejects a fire from a timer object the
/// AppKit layer *thought* it cancelled in time to reschedule but actually raced — a case the flag alone
/// cannot distinguish from a fresh fire, because a cancel-then-immediate-reschedule leaves the flag `true`
/// throughout.
///
/// ## Locks are display-local; releasing one across displays is a controller responsibility
///
/// ``InteractionLock`` is inserted only while a panel is ``NotchPresentation/expanding(_:)`` or
/// ``NotchPresentation/expanded(_:)`` (a lock-begin arriving in any other state is ignored outright — see
/// `dragBegan`/`scrollMomentumBegan` handling below), and every lock this reducer holds is cleared
/// defensively whenever a panel is force-collapsed (the at-most-one-expanded invariant) or suspended, so a
/// lock can never outlive the panel it was guarding. Every member of ``InteractionLock`` now has its own
/// begin/end event pair driving it — `.drag` (`dragBegan`/`dragEnded`), `.scrollMomentum`
/// (`scrollMomentumBegan`/`scrollMomentumEnded`), `.mouseDown` (`pressBegan`/`pressEnded`), and
/// `.playlistPicker` (`playlistPickerOpened`/`playlistPickerClosed`) — all routed through the same
/// ``insertLockIfActive(_:panel:)`` acquire path and ``handlePointerLeftMaybe(display:pointerInside:panel:)``
/// release-and-recheck path. What this reducer cannot see on its own is a lock whose *begin* and *end*
/// events land on different displays — for example, a scroll gesture that began over display A's panel but,
/// because the pointer physically moved, reports its momentum-end over display B. `NotchEvent` carries no
/// cross-display correlation for this, so the AppKit controller is responsible for always pairing a lock's
/// begin/end events to the *same* display identity it captured at begin time, not whichever display the end
/// event's monitor happens to fire on.
///
/// A held lock also changes what an *already-fired* exit grace means: `exitGraceFired` arriving while a lock
/// is held cannot collapse the panel (the lock says so), but the timer itself has still run to completion and
/// is now consumed — see ``handleExitGraceFired(display:generation:panel:)``. `exitGracePending` is cleared
/// so the *next* lock-release event is free to schedule a brand-new grace (with a bumped generation) rather
/// than being blocked forever by a stale `true` flag from a grace that already fired once.
///
/// ## Thread safety
///
/// `NotchInteractionReducer` is a plain value type. It has no synchronisation of its own because it needs
/// none: the AppKit layer owns exactly one instance, mutates it only from `reduce(_:)`, and only ever calls
/// that from the main actor, where every timer completion, pointer monitor callback and menu action this
/// reducer reacts to already runs.
public struct NotchInteractionReducer: Sendable {
    /// Every display's panel state, keyed by ``NotchDisplayID``.
    ///
    /// A display appears here the first time any event names it; there is no separate registration step.
    /// Per the contract documented on this type, every command needed to react to a cross-panel *lifecycle*
    /// state change is already present in the array `reduce(_:)` returns, so reading `panels` is never
    /// needed to discover a missed lifecycle command. It IS how the AppKit layer's SwiftUI content learns
    /// panel *content* (the current ``NotchRoute``), since content is never delivered as a command — see the
    /// "commands cover lifecycle... never content" section on this type.
    public private(set) var panels: [NotchDisplayID: NotchPanelState] = [:]

    /// Creates a reducer with no panels yet. Every display is materialised lazily on first use.
    public init() {}

    /// Advances the state machine by exactly one event, returning the commands the caller must perform.
    ///
    /// Pure: calling this twice with the same starting ``panels`` and the same event produces the same new
    /// ``panels`` and the same commands, every time. Every command in the returned array names the display
    /// it targets (see ``NotchCommand``); this array is complete, including any command needed for a
    /// display other than `event.display` because the at-most-one-expanded invariant forced it to change
    /// state in this same call. See the type-level documentation for the full contract.
    ///
    /// - Parameter event: The event to apply, already carrying the display it targets.
    /// - Returns: The commands the caller must perform, each tagged with its own display. Empty when the
    ///   event was a no-op in the current state (a stale `animationSettled`, a blocked dismissal, a
    ///   redundant `hoverIntent`, and so on) and no other display was touched either.
    @discardableResult
    public mutating func reduce(_ event: NotchEvent) -> [NotchCommand] {
        let display = event.display
        var panel = panels[display] ?? .initial
        defer { panels[display] = panel }

        switch event {
        case .hoverIntent:
            return handleHoverIntent(display: display, panel: &panel)

        case .hoverDebounceFired(_, let generation):
            return handleHoverDebounceFired(display: display, generation: generation, panel: &panel)

        case .hoverExit(_, let pointerInside):
            return handlePointerLeftMaybe(display: display, pointerInside: pointerInside, panel: &panel)

        case .exitGraceFired(_, let generation):
            return handleExitGraceFired(display: display, generation: generation, panel: &panel)

        case .click:
            return handleClick(display: display, panel: &panel)

        case .hotkeyToggle:
            return handleHotkeyToggle(display: display, panel: &panel)

        case .fileDragEntered:
            return handleFileDragEntered(display: display, panel: &panel)

        case .dragBegan:
            insertLockIfActive(.drag, panel: &panel)
            return []

        case .dragEnded(_, let pointerInside):
            panel.locks.remove(.drag)
            return handlePointerLeftMaybe(display: display, pointerInside: pointerInside, panel: &panel)

        case .scrollMomentumBegan:
            insertLockIfActive(.scrollMomentum, panel: &panel)
            return []

        case .scrollMomentumEnded(_, let pointerInside):
            panel.locks.remove(.scrollMomentum)
            return handlePointerLeftMaybe(display: display, pointerInside: pointerInside, panel: &panel)

        case .pressBegan:
            insertLockIfActive(.mouseDown, panel: &panel)
            return []

        case .pressEnded(_, let pointerInside):
            panel.locks.remove(.mouseDown)
            return handlePointerLeftMaybe(display: display, pointerInside: pointerInside, panel: &panel)

        case .playlistPickerOpened:
            insertLockIfActive(.playlistPicker, panel: &panel)
            return []

        case .playlistPickerClosed(_, let pointerInside):
            panel.locks.remove(.playlistPicker)
            return handlePointerLeftMaybe(display: display, pointerInside: pointerInside, panel: &panel)

        case .lockReleased(_, let pointerInside):
            // No specific lock is named on this event (see NotchEvent's documentation): every lock now has
            // its own begin/end pair, so this is a defensive full clear for a lock released through some
            // other path, understood to be sent only once nothing more is holding this panel open.
            panel.locks = []
            return handlePointerLeftMaybe(display: display, pointerInside: pointerInside, panel: &panel)

        case .escape:
            return handleImmediateCollapseRequest(display: display, panel: &panel)

        case .route(_, let route):
            return handleRoute(route, panel: &panel)

        case .suspend:
            return handleSuspend(display: display, panel: &panel)

        case .resume:
            return handleResume(display: display, panel: &panel)

        case .animationSettled(_, let generation):
            return handleAnimationSettled(display: display, generation: generation, panel: &panel)
        }
    }

    // MARK: - Expansion

    /// `hoverIntent`: starts the debounce from collapsed, cancels a pending exit grace on re-entry, clears a
    /// pending "pointer left during expand" flag on genuine re-entry mid-expand, and retargets an
    /// in-flight ``NotchPresentation/collapsing`` animation straight back to expanding (BUG fix: a flick back
    /// onto the pill while it is mid-collapse must not finish collapsing out from under the returning
    /// pointer).
    private mutating func handleHoverIntent(
        display: NotchDisplayID, panel: inout NotchPanelState
    ) -> [NotchCommand] {
        switch panel.presentation {
        case .collapsed:
            guard !panel.hoverDebouncePending else { return [] }
            panel.hoverDebouncePending = true
            panel.hoverDebounceGeneration += 1
            return [
                NotchCommand(
                    display: display,
                    effect: .scheduleHoverDebounce(generation: panel.hoverDebounceGeneration)
                )
            ]

        case .expanded:
            guard panel.exitGracePending else { return [] }
            panel.exitGracePending = false
            panel.exitGraceGeneration += 1
            return [NotchCommand(display: display, effect: .cancelExitGrace)]

        case .expanding:
            panel.pointerOutsideDuringExpand = false
            return []

        case .collapsing:
            return retargetToExpanding(.hover, display: display, panel: &panel)

        case .suspended:
            return []
        }
    }

    /// `hoverDebounceFired`: the debounce completed without the pointer having left, so the panel actually
    /// starts expanding. Guarded on "still collapsed", "still pending" AND "still the current generation" —
    /// the generation check is the belt-and-braces layer over the flag: a fired timer racing a cancellation
    /// (the pointer left, then the already-in-flight timer fires anyway) is caught by `hoverDebouncePending`
    /// alone, but a fire from a timer object that survived a cancel-then-immediate-reschedule (the flag would
    /// still read `true`) is only caught by comparing `generation`.
    private mutating func handleHoverDebounceFired(
        display: NotchDisplayID, generation: UInt64, panel: inout NotchPanelState
    ) -> [NotchCommand] {
        guard case .collapsed = panel.presentation,
            panel.hoverDebouncePending,
            generation == panel.hoverDebounceGeneration
        else { return [] }
        panel.hoverDebouncePending = false
        return beginExpanding(.hover, display: display, panel: &panel)
    }

    /// `click`: an explicit, decisive gesture on the collapsed pill, so it skips the hover debounce
    /// entirely and expands immediately. Also retargets an in-flight ``NotchPresentation/collapsing``
    /// animation straight back to expanding, same as `hoverIntent`. A click while the panel is
    /// `expanding`/`expanded`/`suspended` is a no-op here: ``NotchTrigger/click`` exists to describe *why*
    /// an expansion started, not to describe every click that can land inside an already-open panel, and
    /// this phase's routes have no click-driven behaviour of their own yet.
    private mutating func handleClick(
        display: NotchDisplayID, panel: inout NotchPanelState
    ) -> [NotchCommand] {
        switch panel.presentation {
        case .collapsed:
            return beginExpanding(.click, display: display, panel: &panel)
        case .collapsing:
            return retargetToExpanding(.click, display: display, panel: &panel)
        case .expanding, .expanded, .suspended:
            return []
        }
    }

    /// `fileDragEntered`: like `click`, expands a collapsed panel or retargets a collapsing one, but also
    /// takes the `.drag` lock immediately. `insertLockIfActive` skips `collapsed`/`collapsing`, so the lock
    /// is inserted after the state change (the panel is `expanding` by then). While `expanding`/`expanded`
    /// it only takes the lock (idempotent); `suspended` is a no-op and takes nothing.
    private mutating func handleFileDragEntered(
        display: NotchDisplayID, panel: inout NotchPanelState
    ) -> [NotchCommand] {
        let commands: [NotchCommand]
        switch panel.presentation {
        case .collapsed:
            commands = beginExpanding(.fileDrag, display: display, panel: &panel)
        case .collapsing:
            commands = retargetToExpanding(.fileDrag, display: display, panel: &panel)
        case .expanding, .expanded:
            commands = []
        case .suspended:
            return []
        }
        insertLockIfActive(.drag, panel: &panel)
        return commands
    }

    /// `hotkeyToggle`: expands a collapsed panel, retargets a collapsing one straight back to expanding, or
    /// collapses an expanded, unlocked one. A locked expanded panel ignores the toggle rather than yanking
    /// the panel out from under an in-progress drag or playlist pick, consistent with ``InteractionLock``
    /// blocking dismissal everywhere else.
    private mutating func handleHotkeyToggle(
        display: NotchDisplayID, panel: inout NotchPanelState
    ) -> [NotchCommand] {
        switch panel.presentation {
        case .collapsed:
            return beginExpanding(.hotkey, display: display, panel: &panel)
        case .expanded:
            return handleImmediateCollapseRequest(display: display, panel: &panel)
        case .collapsing:
            return retargetToExpanding(.hotkey, display: display, panel: &panel)
        case .expanding, .suspended:
            return []
        }
    }

    /// Common expand-start logic for every trigger from a fully ``NotchPresentation/collapsed`` panel: clear
    /// a pending hover debounce first (BUG fix, see below), bump the generation, move to `expanding(trigger)`,
    /// reset the pending route to ``NotchRoute/home`` (a subsequent `route(_:)` event before settle can
    /// retarget it — see ``handleRoute(_:panel:)``), install the pointer monitors that replace tracking-area
    /// exit once the panel is no longer just the static pill, and enforce the at-most-one-expanded invariant
    /// against every other display.
    ///
    /// **BUG fix (dead-hover leak):** a `click` or `hotkeyToggle` arriving directly from `collapsed` while a
    /// `hoverIntent`'s debounce is still pending used to leave ``NotchPanelState/hoverDebouncePending`` `true`
    /// forever — nothing ever cleared it, because this path bypasses ``handleHoverDebounceFired(display:generation:panel:)``,
    /// the only other place that flag was reset. The panel would go on to expand and eventually collapse
    /// normally, but every subsequent `hoverIntent` on this display would then hit
    /// `handleHoverIntent(display:panel:)`'s `guard !panel.hoverDebouncePending` and silently return `[]`
    /// forever: hover-expand permanently dead on that display until relaunch. Fixed by cancelling the pending
    /// debounce here, exactly as if the pointer had left before it fired.
    private mutating func beginExpanding(
        _ trigger: NotchTrigger, display: NotchDisplayID, panel: inout NotchPanelState
    ) -> [NotchCommand] {
        var commands: [NotchCommand] = []
        if panel.hoverDebouncePending {
            panel.hoverDebouncePending = false
            panel.hoverDebounceGeneration += 1
            commands.append(NotchCommand(display: display, effect: .cancelHoverDebounce))
        }
        panel.animationGeneration += 1
        panel.presentation = .expanding(trigger)
        panel.pendingRoute = .home
        panel.pointerOutsideDuringExpand = false
        commands.append(NotchCommand(display: display, effect: .startExpand(generation: panel.animationGeneration)))
        commands.append(NotchCommand(display: display, effect: .installPointerMonitors))
        commands.append(contentsOf: forceOtherPanelsToCollapsing(excluding: display))
        return commands
    }

    /// Retargets an in-flight ``NotchPresentation/collapsing`` animation straight back to expanding, for a
    /// `hoverIntent`/`click`/`hotkeyToggle` that arrives before the collapse has settled (BUG fix: without
    /// this, re-entry during `collapsing` was silently dropped and the panel finished closing under a
    /// pointer that had already come back). Bumps the generation exactly like ``beginExpanding``, but does
    /// **not** re-emit `installPointerMonitors`: the monitor pair from the original expand is still
    /// installed (this reducer only removes it once a collapse actually *settles*, in
    /// ``handleAnimationSettled(display:generation:panel:)``), so re-installing here would be redundant.
    /// Monitor install is therefore idempotent-by-omission on this path, not because `installPointerMonitors`
    /// itself is idempotent.
    private mutating func retargetToExpanding(
        _ trigger: NotchTrigger, display: NotchDisplayID, panel: inout NotchPanelState
    ) -> [NotchCommand] {
        panel.animationGeneration += 1
        panel.presentation = .expanding(trigger)
        panel.pendingRoute = .home
        panel.pointerOutsideDuringExpand = false
        var commands: [NotchCommand] = [
            NotchCommand(display: display, effect: .startExpand(generation: panel.animationGeneration))
        ]
        commands.append(contentsOf: forceOtherPanelsToCollapsing(excluding: display))
        return commands
    }

    /// The at-most-one-expanded invariant. Every other panel currently `expanding`/`expanded` is forced
    /// into `collapsing`, its own generation bumped, with a command emitted (tagged with *that* panel's own
    /// display) for the `startCollapse` this induces, plus `cancelHoverDebounce`/`cancelExitGrace` if either
    /// of that panel's timers happened to be pending. This bypasses the exit-grace machinery and any locks
    /// that panel holds, deliberately: a lock exists to protect an interaction in progress from being
    /// dismissed by an ambiguous pointer signal on the *same* panel, not to keep a second display's panel
    /// open once the user has demonstrably moved their attention to a different display.
    ///
    /// Also guards against the "two-display flash-expand" glitch: any other panel that is merely
    /// ``NotchPresentation/collapsed`` with a hover debounce already pending has that debounce cancelled
    /// (`cancelHoverDebounce`, tagged with its own display) too. Without this, a near-simultaneous hover on
    /// the losing display would still expand ~90ms later — after this call already committed to the winning
    /// display — only to be immediately force-collapsed again, a visible flash.
    private mutating func forceOtherPanelsToCollapsing(excluding display: NotchDisplayID) -> [NotchCommand] {
        var commands: [NotchCommand] = []
        for (otherDisplay, var other) in panels where otherDisplay != display {
            switch other.presentation {
            case .expanding, .expanded:
                other.animationGeneration += 1
                other.presentation = .collapsing
                other.locks = []
                other.pointerOutsideDuringExpand = false
                if other.hoverDebouncePending {
                    other.hoverDebouncePending = false
                    other.hoverDebounceGeneration += 1
                    commands.append(NotchCommand(display: otherDisplay, effect: .cancelHoverDebounce))
                }
                if other.exitGracePending {
                    other.exitGracePending = false
                    other.exitGraceGeneration += 1
                    commands.append(NotchCommand(display: otherDisplay, effect: .cancelExitGrace))
                }
                commands.append(
                    NotchCommand(display: otherDisplay, effect: .startCollapse(generation: other.animationGeneration))
                )
                panels[otherDisplay] = other

            case .collapsed:
                guard other.hoverDebouncePending else { continue }
                other.hoverDebouncePending = false
                other.hoverDebounceGeneration += 1
                commands.append(NotchCommand(display: otherDisplay, effect: .cancelHoverDebounce))
                panels[otherDisplay] = other

            case .collapsing, .suspended:
                continue
            }
        }
        return commands
    }

    // MARK: - Locks

    /// Inserts `lock` only while the panel is `expanding` or `expanded`; ignored in every other state (BUG
    /// fix: a lock-begin arriving while the panel is `collapsed`, `collapsing`, or `suspended` used to be
    /// inserted unconditionally, leaking a lock that nothing would ever clear because the paired end event,
    /// if it ever contains a pointer-containment recheck, only re-checks when the panel is `expanded` — a
    /// leaked lock on a panel that never reaches `expanded` again silently disables every future dismissal
    /// path for that display).
    ///
    /// Shared by every lock's begin event: `dragBegan` (`.drag`), `scrollMomentumBegan` (`.scrollMomentum`),
    /// `pressBegan` (`.mouseDown`), and `playlistPickerOpened` (`.playlistPicker`).
    private func insertLockIfActive(_ lock: InteractionLock, panel: inout NotchPanelState) {
        switch panel.presentation {
        case .expanding, .expanded:
            panel.locks.insert(lock)
        case .collapsed, .collapsing, .suspended:
            break
        }
    }

    // MARK: - Dismissal

    /// Shared logic for every "the pointer/drag/scroll/press/picker/lock stopped or started covering this
    /// panel" event (`hoverExit`, `dragEnded`, `scrollMomentumEnded`, `pressEnded`, `playlistPickerClosed`,
    /// `lockReleased`), branching on the panel's current presentation:
    ///
    /// - `expanded`: the normal case. `pointerInside == false` schedules the exit grace exactly as before,
    ///   gated on no lock held and no grace already pending. **BUG fix:** `pointerInside == true` now
    ///   *cancels* a pending exit grace instead of being ignored, consistent with `NotchEvent.hoverExit`'s
    ///   documented licence for the caller to deliver containment-positive motion through this same event —
    ///   without this, a pointer that dips back inside the panel before the ~250ms grace elapses would still
    ///   collapse out from under it.
    /// - `collapsed`: **BUG fix.** `pointerInside == false` while a hover debounce is pending now cancels it
    ///   (`cancelHoverDebounce`) instead of being a no-op. Previously a brush-past the pill still expanded
    ///   ~90ms later with the pointer already gone — a phantom expand.
    /// - `expanding`: **BUG fix.** `pointerInside == false` sets ``NotchPanelState/pointerOutsideDuringExpand``
    ///   rather than being dropped; `pointerInside == true` clears it. The expand animation genuinely cannot
    ///   be aborted mid-flight (see that flag's documentation), so this defers the eventual exit grace to
    ///   ``handleAnimationSettled(display:generation:panel:)`` instead of losing the signal outright — this
    ///   is the "stuck open on fast flick" fix.
    /// - `collapsing`, `suspended`: no-op; there is nothing meaningful for a pointer signal to do to a panel
    ///   that is already on its way to closed or is suspended outright.
    private func handlePointerLeftMaybe(
        display: NotchDisplayID, pointerInside: Bool, panel: inout NotchPanelState
    ) -> [NotchCommand] {
        switch panel.presentation {
        case .collapsed:
            guard !pointerInside, panel.hoverDebouncePending else { return [] }
            panel.hoverDebouncePending = false
            panel.hoverDebounceGeneration += 1
            return [NotchCommand(display: display, effect: .cancelHoverDebounce)]

        case .expanded:
            if pointerInside {
                guard panel.exitGracePending else { return [] }
                panel.exitGracePending = false
                panel.exitGraceGeneration += 1
                return [NotchCommand(display: display, effect: .cancelExitGrace)]
            }
            guard panel.locks.isEmpty, !panel.exitGracePending else { return [] }
            panel.exitGracePending = true
            panel.exitGraceGeneration += 1
            return [
                NotchCommand(display: display, effect: .scheduleExitGrace(generation: panel.exitGraceGeneration))
            ]

        case .expanding:
            panel.pointerOutsideDuringExpand = !pointerInside
            return []

        case .collapsing, .suspended:
            return []
        }
    }

    /// `exitGraceFired`: the grace period elapsed with nothing having cancelled it. Guarded on "still
    /// expanded, still pending, still the current generation" for the same reason as
    /// ``handleHoverDebounceFired(display:generation:panel:)`` — a fired timer can race its own cancellation
    /// or a cancel-then-reschedule the flag alone cannot distinguish from a fresh fire.
    ///
    /// **BUG fix (grace-fires-while-locked stuck-open):** a lock acquired *after* the grace was scheduled but
    /// *before* it fired used to make this guard fail outright (the old code additionally required
    /// `panel.locks.isEmpty`), leaving `exitGracePending` stuck `true` forever — the timer had already fired
    /// and would never fire again, so no later event could ever satisfy `!panel.exitGracePending` and
    /// schedule a fresh one; the panel rested open until an unrelated `escape`/`hotkeyToggle` dismissal
    /// bailed it out. Now a matching-generation fire while a lock is held is honoured as "the timer is
    /// consumed" without collapsing: `exitGracePending` is cleared (still gated on `locks.isEmpty` for
    /// whether to actually collapse, not for whether to accept the fire at all), so the lock's own release
    /// path (`handlePointerLeftMaybe`, reached via `dragEnded`/`scrollMomentumEnded`/`pressEnded`/
    /// `playlistPickerClosed`/`lockReleased`) is free to schedule a brand-new grace, with a freshly bumped
    /// generation, the moment the lock actually clears.
    ///
    /// `cancelExitGrace` is emitted whenever the fire is honoured, whether or not it also collapses, not to
    /// stop the timer firing again, but as a resource-teardown instruction: the AppKit layer's
    /// `DispatchSourceTimer` or `Timer` object still needs to be released, and this reducer has no other
    /// event that tells the caller it may do that.
    private func handleExitGraceFired(
        display: NotchDisplayID, generation: UInt64, panel: inout NotchPanelState
    ) -> [NotchCommand] {
        guard case .expanded = panel.presentation,
            panel.exitGracePending,
            generation == panel.exitGraceGeneration
        else {
            return []
        }
        guard panel.locks.isEmpty else {
            panel.exitGracePending = false
            return [NotchCommand(display: display, effect: .cancelExitGrace)]
        }
        panel.exitGracePending = false
        panel.animationGeneration += 1
        panel.presentation = .collapsing
        return [
            NotchCommand(display: display, effect: .startCollapse(generation: panel.animationGeneration)),
            NotchCommand(display: display, effect: .cancelExitGrace),
        ]
    }

    /// `escape` and an unlocked `hotkeyToggle` while expanded: an explicit, decisive dismissal that skips
    /// the exit-grace timer entirely (there is no ambiguous pointer signal to debounce; the user has just
    /// said "close this"). Still gated on locks, since a lock's whole purpose is to survive exactly this
    /// kind of dismissal attempt while its interaction is in progress.
    private func handleImmediateCollapseRequest(
        display: NotchDisplayID, panel: inout NotchPanelState
    ) -> [NotchCommand] {
        guard case .expanded = panel.presentation, panel.locks.isEmpty else { return [] }
        var commands: [NotchCommand] = []
        if panel.exitGracePending {
            panel.exitGracePending = false
            panel.exitGraceGeneration += 1
            commands.append(NotchCommand(display: display, effect: .cancelExitGrace))
        }
        panel.animationGeneration += 1
        panel.presentation = .collapsing
        commands.append(NotchCommand(display: display, effect: .startCollapse(generation: panel.animationGeneration)))
        return commands
    }

    // MARK: - Routing

    /// `route(_:)`: while `expanded`, swaps the visible route immediately, same as before, and also mirrors
    /// it onto ``NotchPanelState/pendingRoute`` (BUG fix: an adversarial review found that swapping only
    /// `presentation` left `pendingRoute` pointing at whatever route was current *before* this swap, so a
    /// `handleImmediateCollapseRequest(display:panel:)` fired right after a route swap would drop the panel
    /// into `.collapsing` while `NotchContentView.currentRoute`'s `.collapsing` fallback to `pendingRoute`
    /// rendered the *previous* route for the one frame before the mask finished covering the surface — a
    /// route flash at exactly the moment the panel is closing). While `expanding`, updates `pendingRoute` so
    /// the target route is carried through to whichever route
    /// ``handleAnimationSettled(display:generation:panel:)`` lands on, instead of the settle unconditionally
    /// hard-coding `.home` (an earlier bug fix: "open straight to herd/Spotify" was previously
    /// unrepresentable — a `route` event that arrived mid-expand was silently dropped). A no-op in every
    /// other state: there is no route to retarget on a panel that is collapsed, collapsing, or suspended.
    private func handleRoute(_ route: NotchRoute, panel: inout NotchPanelState) -> [NotchCommand] {
        switch panel.presentation {
        case .expanded:
            panel.presentation = .expanded(route)
            panel.pendingRoute = route
        case .expanding:
            panel.pendingRoute = route
        case .collapsed, .collapsing, .suspended:
            break
        }
        return []
    }

    // MARK: - Settlement

    /// `animationSettled(generation:)`: the one place a stale generation is checked, per this type's
    /// documentation. A mismatched generation, or a generation that matches but arrives while the panel is
    /// not actually `expanding`/`collapsing` (for example, a second, redundant completion for an animation
    /// this reducer already settled), is a complete no-op.
    ///
    /// Landing an expand additionally checks ``NotchPanelState/pointerOutsideDuringExpand``: if the pointer
    /// was reported outside at some point during the animation and no lock is now held, the panel is landed
    /// as `expanded` for exactly one instant before immediately scheduling the exit grace, rather than
    /// resting open with nothing left to ever signal its dismissal (the "stuck open on fast flick" fix —
    /// see that flag's documentation on ``NotchPanelState``). Otherwise it lands normally, on
    /// ``NotchPanelState/pendingRoute`` rather than a hard-coded `.home`.
    private func handleAnimationSettled(
        display: NotchDisplayID, generation: UInt64, panel: inout NotchPanelState
    ) -> [NotchCommand] {
        guard generation == panel.animationGeneration else { return [] }
        switch panel.presentation {
        case .expanding:
            panel.presentation = .expanded(panel.pendingRoute)
            guard panel.pointerOutsideDuringExpand, panel.locks.isEmpty else {
                panel.pointerOutsideDuringExpand = false
                return []
            }
            panel.pointerOutsideDuringExpand = false
            panel.exitGracePending = true
            panel.exitGraceGeneration += 1
            return [
                NotchCommand(display: display, effect: .scheduleExitGrace(generation: panel.exitGraceGeneration))
            ]

        case .collapsing:
            panel.presentation = .collapsed
            return [NotchCommand(display: display, effect: .removePointerMonitors)]

        case .collapsed, .expanded, .suspended:
            return []
        }
    }

    // MARK: - Suspension

    /// `suspend`: forces the panel closed without running the normal collapse animation or leaving any
    /// timer live, for reasons that are not a user dismissal (sleep, a vanished display). Every pending
    /// timer this panel owns is explicitly cancelled, monitors are removed if they were ever installed, and
    /// the animation generation is bumped so a completion from whatever was in flight before suspension is
    /// recognised as stale by ``handleAnimationSettled(display:generation:panel:)`` even though the
    /// presentation guard there would already have rejected it on its own.
    ///
    /// Also emits ``NotchEffect/hidePanel`` when the panel was actually visible (`expanding`, `expanded`, or
    /// `collapsing`), since a dumb executor cannot infer window ordering from the presentation change alone.
    /// A panel that was merely ``NotchPresentation/collapsed`` is not hidden here: the collapsed pill's own
    /// visibility is a controller responsibility outside this reducer's suspend/resume lifecycle (see
    /// ``NotchEffect/hidePanel``).
    private func handleSuspend(display: NotchDisplayID, panel: inout NotchPanelState) -> [NotchCommand] {
        guard case .suspended = panel.presentation else {
            var commands: [NotchCommand] = []
            if panel.hoverDebouncePending {
                commands.append(NotchCommand(display: display, effect: .cancelHoverDebounce))
                panel.hoverDebouncePending = false
                panel.hoverDebounceGeneration += 1
            }
            if panel.exitGracePending {
                commands.append(NotchCommand(display: display, effect: .cancelExitGrace))
                panel.exitGracePending = false
                panel.exitGraceGeneration += 1
            }
            switch panel.presentation {
            case .expanding, .expanded, .collapsing:
                commands.append(NotchCommand(display: display, effect: .removePointerMonitors))
                commands.append(NotchCommand(display: display, effect: .hidePanel))
            case .collapsed, .suspended:
                break
            }
            panel.animationGeneration += 1
            panel.presentation = .suspended
            panel.locks = []
            panel.pointerOutsideDuringExpand = false
            return commands
        }
        return []
    }

    /// `resume`: a suspended panel returns to ``NotchPresentation/collapsed`` (never back into whatever route
    /// was showing before suspension), and, since suspension may have ordered the window off screen entirely
    /// (see ``handleSuspend(display:panel:)``), emits ``NotchEffect/showCollapsed`` to bring it back. A
    /// `resume` for a panel that was never suspended is a no-op: there is nothing to undo.
    private func handleResume(display: NotchDisplayID, panel: inout NotchPanelState) -> [NotchCommand] {
        guard case .suspended = panel.presentation else { return [] }
        panel.presentation = .collapsed
        return [NotchCommand(display: display, effect: .showCollapsed)]
    }
}
