import Foundation
import Testing

@testable import NotchCore

/// Tests for the glitch-free notch reducer.
///
/// Every test drives ``NotchInteractionReducer`` with the exact event sequence a real timer or pointer
/// monitor would have produced (never a shortcut that skips a debounce or a settle), because the whole
/// point of `NotchCore` being pure is that this sequence is reproducible with no window server and no
/// actual elapsed time. Displays are arbitrary `NotchDisplayID` (`UInt32`) constants; nothing here needs a
/// real screen. `reduce(_:)` returns `[NotchCommand]`, each command already tagged with the display it
/// targets (see ``NotchCommand``), so assertions compare against commands built with the local `command`
/// helper rather than bare `NotchEffect` values.
@Suite struct NotchCoreTests {

    private let displayA: NotchDisplayID = 1
    private let displayB: NotchDisplayID = 2

    /// Builds a ``NotchCommand`` pairing `effect` with `display`, for concise expectations below.
    private func command(_ effect: NotchEffect, on display: NotchDisplayID) -> NotchCommand {
        NotchCommand(display: display, effect: effect)
    }

    /// Fires the hover-debounce timer currently pending on `display`, reading the generation `reducer`
    /// itself scheduled so tests do not have to re-derive it at every call site now that
    /// `hoverDebounceFired` must echo the generation back. Bundles the read-then-fire together purely for
    /// call-site brevity; tests that need to exercise a stale (mismatched) generation on purpose still
    /// construct the event directly.
    @discardableResult
    private func fireHoverDebounce(_ display: NotchDisplayID, in reducer: inout NotchInteractionReducer) -> [NotchCommand] {
        let generation = reducer.panels[display]?.hoverDebounceGeneration ?? 0
        return reducer.reduce(.hoverDebounceFired(display, generation: generation))
    }

    /// Fires the exit-grace timer currently pending on `display`, same rationale as ``fireHoverDebounce``.
    @discardableResult
    private func fireExitGrace(_ display: NotchDisplayID, in reducer: inout NotchInteractionReducer) -> [NotchCommand] {
        let generation = reducer.panels[display]?.exitGraceGeneration ?? 0
        return reducer.reduce(.exitGraceFired(display, generation: generation))
    }

    // MARK: - Basic expand-and-settle

    /// The hover path end to end: intent schedules the debounce, the debounce firing actually starts the
    /// expand animation and installs the pointer monitors, and the matching settle lands on `expanded(.home)`.
    @Test func hoverIntentThenDebounceThenSettleExpandsToHome() {
        var reducer = NotchInteractionReducer()

        let intentCommands = reducer.reduce(.hoverIntent(displayA))
        let hoverGeneration = reducer.panels[displayA]?.hoverDebounceGeneration ?? 0
        #expect(intentCommands == [command(.scheduleHoverDebounce(generation: hoverGeneration), on: displayA)])
        #expect(reducer.panels[displayA]?.presentation == .collapsed)

        let debounceCommands = fireHoverDebounce(displayA, in: &reducer)
        guard case .expanding(let trigger) = reducer.panels[displayA]?.presentation else {
            Issue.record("expected expanding after debounce fired")
            return
        }
        #expect(trigger == .hover)
        let generation = reducer.panels[displayA]?.animationGeneration
        #expect(debounceCommands.contains(command(.startExpand(generation: generation ?? 0), on: displayA)))
        #expect(debounceCommands.contains(command(.installPointerMonitors, on: displayA)))

        let settleCommands = reducer.reduce(.animationSettled(displayA, generation: generation ?? 0))
        #expect(reducer.panels[displayA]?.presentation == .expanded(.home))
        #expect(settleCommands == [])
    }

    // MARK: - Stale generation

    /// A settle for the wrong generation must not touch state at all, which is the entire point of stamping
    /// a generation on every animation: an aborted, retargeted animation's late completion cannot rewrite
    /// state out from under whatever the reducer has since moved on to.
    @Test func staleAnimationSettledIsANoOp() {
        var reducer = NotchInteractionReducer()
        reducer.reduce(.hoverIntent(displayA))
        fireHoverDebounce(displayA, in: &reducer)
        let stateBefore = reducer.panels[displayA]

        let commands = reducer.reduce(.animationSettled(displayA, generation: 999))

        #expect(commands == [])
        #expect(reducer.panels[displayA] == stateBefore)
    }

    // MARK: - Stale timer generation fire is a no-op

    /// A hover-debounce fire carrying a stale generation — the timer object outliving a cancel-then-reschedule
    /// race — must be a complete no-op even though `hoverDebouncePending` reads `true` throughout (the flag
    /// alone cannot tell the two firings apart; the generation is what does). The fresh generation, once
    /// fired, actually expands.
    @Test func staleHoverDebounceGenerationFireIsANoOpFreshGenerationExpands() {
        var reducer = NotchInteractionReducer()

        reducer.reduce(.hoverIntent(displayA))
        let staleGeneration = reducer.panels[displayA]?.hoverDebounceGeneration ?? 0

        // Cancel then immediately reschedule, simulating a fast flick-out-then-back before the original
        // timer object is actually torn down.
        reducer.reduce(.hoverExit(displayA, pointerInside: false))
        reducer.reduce(.hoverIntent(displayA))
        let freshGeneration = reducer.panels[displayA]?.hoverDebounceGeneration ?? 0
        #expect(freshGeneration > staleGeneration)

        let staleFireCommands = reducer.reduce(.hoverDebounceFired(displayA, generation: staleGeneration))
        #expect(staleFireCommands == [], "a fire carrying the pre-reschedule generation must not expand the panel")
        #expect(reducer.panels[displayA]?.presentation == .collapsed)

        let freshFireCommands = reducer.reduce(.hoverDebounceFired(displayA, generation: freshGeneration))
        guard case .expanding = reducer.panels[displayA]?.presentation else {
            Issue.record("expected expanding once the fresh generation fires")
            return
        }
        #expect(!freshFireCommands.isEmpty)
    }

    /// Same stale-generation protection for the exit-grace timer.
    @Test func staleExitGraceGenerationFireIsANoOpFreshGenerationCollapses() {
        var reducer = NotchInteractionReducer()
        reducer.reduce(.hoverIntent(displayA))
        fireHoverDebounce(displayA, in: &reducer)
        let expandGeneration = reducer.panels[displayA]?.animationGeneration ?? 0
        reducer.reduce(.animationSettled(displayA, generation: expandGeneration))

        reducer.reduce(.hoverExit(displayA, pointerInside: false))
        let staleGraceGeneration = reducer.panels[displayA]?.exitGraceGeneration ?? 0

        // Cancel (re-entry) then immediately reschedule (exit again).
        reducer.reduce(.hoverExit(displayA, pointerInside: true))
        reducer.reduce(.hoverExit(displayA, pointerInside: false))
        let freshGraceGeneration = reducer.panels[displayA]?.exitGraceGeneration ?? 0
        #expect(freshGraceGeneration > staleGraceGeneration)

        let staleFireCommands = reducer.reduce(.exitGraceFired(displayA, generation: staleGraceGeneration))
        #expect(staleFireCommands == [], "a fire carrying the pre-reschedule generation must not collapse the panel")
        #expect(reducer.panels[displayA]?.presentation == .expanded(.home))

        let freshFireCommands = reducer.reduce(.exitGraceFired(displayA, generation: freshGraceGeneration))
        #expect(reducer.panels[displayA]?.presentation == .collapsing)
        #expect(!freshFireCommands.isEmpty)
    }

    // MARK: - Per-display independence and the at-most-one-expanded invariant

    /// Expanding display A must not touch a collapsed display B: the cross-panel invariant only ever forces
    /// a panel that is itself expanding/expanded, never an already-collapsed one (with no pending debounce
    /// of its own to worry about).
    @Test func expandingOneDisplayLeavesACollapsedOtherDisplayAlone() {
        var reducer = NotchInteractionReducer()
        reducer.reduce(.hoverIntent(displayA))
        fireHoverDebounce(displayA, in: &reducer)

        #expect(reducer.panels[displayB] == nil || reducer.panels[displayB]?.presentation == .collapsed)
    }

    /// The at-most-one-expanded invariant: if B is already expanded and A starts expanding, B is driven to
    /// `collapsing` as a state mutation, with its own generation bumped, and — per the command contract
    /// documented on ``NotchInteractionReducer`` — the `startCollapse` command for B is present in the SAME
    /// call's returned array, tagged with B's own display. The AppKit controller never has to diff `panels`
    /// to discover this.
    @Test func atMostOneExpandedAcrossTwoDisplays() {
        var reducer = NotchInteractionReducer()

        // Get B to expanded.
        reducer.reduce(.hoverIntent(displayB))
        fireHoverDebounce(displayB, in: &reducer)
        let bGenerationBeforeA = reducer.panels[displayB]?.animationGeneration ?? 0
        reducer.reduce(.animationSettled(displayB, generation: bGenerationBeforeA))
        #expect(reducer.panels[displayB]?.presentation == .expanded(.home))

        // A starts expanding.
        let aIntentCommands = reducer.reduce(.hoverIntent(displayA))
        let aHoverGeneration = reducer.panels[displayA]?.hoverDebounceGeneration ?? 0
        #expect(aIntentCommands == [command(.scheduleHoverDebounce(generation: aHoverGeneration), on: displayA)])
        let aFiredCommands = fireHoverDebounce(displayA, in: &reducer)

        guard case .expanding = reducer.panels[displayA]?.presentation else {
            Issue.record("expected A to be expanding")
            return
        }
        #expect(reducer.panels[displayB]?.presentation == .collapsing)
        let bGenerationAfterA = reducer.panels[displayB]?.animationGeneration ?? 0
        #expect(bGenerationAfterA > bGenerationBeforeA)
        #expect(aFiredCommands.contains(command(.startCollapse(generation: bGenerationAfterA), on: displayB)))
        let aGeneration = reducer.panels[displayA]?.animationGeneration ?? 0
        #expect(aFiredCommands.contains(command(.startExpand(generation: aGeneration), on: displayA)))

        // At no point may both be expanded/expanding simultaneously.
        let expandingOrExpanded: (NotchPresentation?) -> Bool = {
            switch $0 {
            case .expanding, .expanded: return true
            default: return false
            }
        }
        #expect(!(expandingOrExpanded(reducer.panels[displayA]?.presentation)
            && expandingOrExpanded(reducer.panels[displayB]?.presentation)))
    }

    /// Two-display hover race (pins BUG: "two-display flash-expand"): A and B both hover-in at nearly the
    /// same time; A's debounce wins the race to actually start expanding. The at-most-one-expanded
    /// invariant holds at every step (B never leaves `.collapsed`), and B's own still-pending hover debounce
    /// is cancelled by A's expand-start call (a `cancelHoverDebounce` command tagged with B's display),
    /// rather than being left to fire ~90ms later and flash B open only to be immediately force-collapsed.
    /// B's own timer firing late (with the generation it was actually scheduled with) is then a no-op.
    @Test func twoDisplayHoverRaceCancelsLosersPendingDebounceRatherThanFlashingItOpen() {
        var reducer = NotchInteractionReducer()

        reducer.reduce(.hoverIntent(displayA))
        reducer.reduce(.hoverIntent(displayB))
        #expect(reducer.panels[displayA]?.hoverDebouncePending == true)
        #expect(reducer.panels[displayB]?.hoverDebouncePending == true)
        let bScheduledGeneration = reducer.panels[displayB]?.hoverDebounceGeneration ?? 0

        let aFiredCommands = fireHoverDebounce(displayA, in: &reducer)
        guard case .expanding = reducer.panels[displayA]?.presentation else {
            Issue.record("expected A to be expanding")
            return
        }
        #expect(reducer.panels[displayB]?.presentation == .collapsed)
        #expect(reducer.panels[displayB]?.hoverDebouncePending == false)
        #expect(aFiredCommands.contains(command(.cancelHoverDebounce, on: displayB)))

        let bFiredCommands = reducer.reduce(.hoverDebounceFired(displayB, generation: bScheduledGeneration))
        #expect(bFiredCommands == [], "B's debounce was already cancelled; its late timer firing must be a no-op")
        #expect(reducer.panels[displayB]?.presentation == .collapsed)
    }

    // MARK: - Exit grace

    /// The full dismissal path while unlocked: leaving schedules the grace timer, the grace firing actually
    /// starts the collapse, and the matching settle both lands on `collapsed` and tears down the monitors
    /// installed on expand.
    @Test func exitGraceCollapsesAndRemovesMonitorsOnSettle() {
        var reducer = NotchInteractionReducer()
        reducer.reduce(.hoverIntent(displayA))
        fireHoverDebounce(displayA, in: &reducer)
        let expandGeneration = reducer.panels[displayA]?.animationGeneration ?? 0
        reducer.reduce(.animationSettled(displayA, generation: expandGeneration))

        let exitCommands = reducer.reduce(.hoverExit(displayA, pointerInside: false))
        let graceGeneration = reducer.panels[displayA]?.exitGraceGeneration ?? 0
        #expect(exitCommands == [command(.scheduleExitGrace(generation: graceGeneration), on: displayA)])

        let graceCommands = fireExitGrace(displayA, in: &reducer)
        #expect(reducer.panels[displayA]?.presentation == .collapsing)
        let collapseGeneration = reducer.panels[displayA]?.animationGeneration ?? 0
        #expect(collapseGeneration > expandGeneration)
        #expect(graceCommands.contains(command(.startCollapse(generation: collapseGeneration), on: displayA)))

        let settleCommands = reducer.reduce(.animationSettled(displayA, generation: collapseGeneration))
        #expect(reducer.panels[displayA]?.presentation == .collapsed)
        #expect(settleCommands == [command(.removePointerMonitors, on: displayA)])
    }

    // MARK: - hoverExit bug fixes (phantom expand / stuck open)

    /// BUG fix: `hoverExit(pointerInside: false)` while a hover debounce is pending (still collapsed) now
    /// cancels the debounce instead of being a no-op. Before this fix, a brush-past the pill still expanded
    /// ~90ms later with the pointer already gone — a phantom expand.
    @Test func hoverExitWhileDebouncePendingCancelsDebounceInsteadOfExpanding() {
        var reducer = NotchInteractionReducer()
        let intentCommands = reducer.reduce(.hoverIntent(displayA))
        let scheduledGeneration = reducer.panels[displayA]?.hoverDebounceGeneration ?? 0
        #expect(intentCommands == [command(.scheduleHoverDebounce(generation: scheduledGeneration), on: displayA)])

        let exitCommands = reducer.reduce(.hoverExit(displayA, pointerInside: false))
        #expect(exitCommands == [command(.cancelHoverDebounce, on: displayA)])
        #expect(reducer.panels[displayA]?.hoverDebouncePending == false)
        #expect(reducer.panels[displayA]?.presentation == .collapsed)

        let staleFireCommands = reducer.reduce(.hoverDebounceFired(displayA, generation: scheduledGeneration))
        #expect(staleFireCommands == [], "the cancelled debounce firing anyway must not expand the panel")
        #expect(reducer.panels[displayA]?.presentation == .collapsed)
    }

    /// BUG fix: `hoverExit(pointerInside: true)` while expanded with an exit grace pending now cancels the
    /// grace, consistent with `NotchEvent.hoverExit`'s documented licence for the caller to deliver
    /// containment-positive motion through this same event. Before this fix, the grace timer would still
    /// fire and collapse the panel even though the pointer had already come back.
    @Test func hoverExitWithPointerInsideCancelsPendingExitGrace() {
        var reducer = NotchInteractionReducer()
        reducer.reduce(.hoverIntent(displayA))
        fireHoverDebounce(displayA, in: &reducer)
        let generation = reducer.panels[displayA]?.animationGeneration ?? 0
        reducer.reduce(.animationSettled(displayA, generation: generation))

        let exitCommands = reducer.reduce(.hoverExit(displayA, pointerInside: false))
        let graceGeneration = reducer.panels[displayA]?.exitGraceGeneration ?? 0
        #expect(exitCommands == [command(.scheduleExitGrace(generation: graceGeneration), on: displayA)])
        #expect(reducer.panels[displayA]?.exitGracePending == true)

        let returnCommands = reducer.reduce(.hoverExit(displayA, pointerInside: true))
        #expect(returnCommands == [command(.cancelExitGrace, on: displayA)])
        #expect(reducer.panels[displayA]?.exitGracePending == false)

        let staleGraceCommands = reducer.reduce(.exitGraceFired(displayA, generation: graceGeneration))
        #expect(staleGraceCommands == [], "the cancelled grace firing anyway must not collapse the panel")
        #expect(reducer.panels[displayA]?.presentation == .expanded(.home))
    }

    /// BUG fix: `hoverExit(pointerInside: false)` arriving during `.expanding` (a fast flick out before the
    /// expand animation even finishes) is no longer dropped. It sets `pointerOutsideDuringExpand`, and once
    /// the matching `animationSettled` lands, the panel is scheduled for an immediate exit grace instead of
    /// resting open forever with nothing outside it left to signal a dismissal.
    @Test func pointerExitDuringExpandSchedulesExitGraceOnSettleInsteadOfRestingOpen() {
        var reducer = NotchInteractionReducer()
        reducer.reduce(.hoverIntent(displayA))
        fireHoverDebounce(displayA, in: &reducer)
        guard case .expanding = reducer.panels[displayA]?.presentation else {
            Issue.record("expected expanding")
            return
        }

        let exitCommands = reducer.reduce(.hoverExit(displayA, pointerInside: false))
        #expect(exitCommands == [], "nothing to emit yet; the flag is recorded for settle to act on")
        #expect(reducer.panels[displayA]?.pointerOutsideDuringExpand == true)

        let generation = reducer.panels[displayA]?.animationGeneration ?? 0
        let settleCommands = reducer.reduce(.animationSettled(displayA, generation: generation))
        #expect(reducer.panels[displayA]?.presentation == .expanded(.home))
        let graceGeneration = reducer.panels[displayA]?.exitGraceGeneration ?? 0
        #expect(settleCommands == [command(.scheduleExitGrace(generation: graceGeneration), on: displayA)])
        #expect(reducer.panels[displayA]?.exitGracePending == true)
        #expect(reducer.panels[displayA]?.pointerOutsideDuringExpand == false)

        let graceFiredCommands = fireExitGrace(displayA, in: &reducer)
        #expect(reducer.panels[displayA]?.presentation == .collapsing)
        let collapseGeneration = reducer.panels[displayA]?.animationGeneration ?? 0
        #expect(graceFiredCommands.contains(command(.startCollapse(generation: collapseGeneration), on: displayA)))
    }

    // MARK: - Dead-hover leak fix

    /// BUG fix (CRITICAL): a `click` arriving while a `hoverIntent`'s debounce is still pending must cancel
    /// that debounce, not leave `hoverDebouncePending` stuck `true` forever. Before this fix, the panel
    /// would still expand and later collapse normally, but every subsequent `hoverIntent` on this display
    /// would then hit the `guard !panel.hoverDebouncePending` in `handleHoverIntent` and silently do
    /// nothing — hover-expand permanently dead on that display.
    @Test func clickWhileHoverDebouncePendingCancelsItSoHoverWorksAgainAfterCollapse() {
        var reducer = NotchInteractionReducer()

        reducer.reduce(.hoverIntent(displayA))
        #expect(reducer.panels[displayA]?.hoverDebouncePending == true)

        let clickCommands = reducer.reduce(.click(displayA))
        #expect(clickCommands.contains(command(.cancelHoverDebounce, on: displayA)))
        #expect(reducer.panels[displayA]?.hoverDebouncePending == false)

        let generation = reducer.panels[displayA]?.animationGeneration ?? 0
        reducer.reduce(.animationSettled(displayA, generation: generation))
        #expect(reducer.panels[displayA]?.presentation == .expanded(.home))

        reducer.reduce(.escape(displayA))
        let collapseGeneration = reducer.panels[displayA]?.animationGeneration ?? 0
        reducer.reduce(.animationSettled(displayA, generation: collapseGeneration))
        #expect(reducer.panels[displayA]?.presentation == .collapsed)

        // Hover-expand must still work: the stale `hoverDebouncePending` flag from before the click must
        // not have leaked through the click, the expansion, and the collapse.
        let secondHoverCommands = reducer.reduce(.hoverIntent(displayA))
        let hoverGeneration = reducer.panels[displayA]?.hoverDebounceGeneration ?? 0
        #expect(secondHoverCommands == [command(.scheduleHoverDebounce(generation: hoverGeneration), on: displayA)])
    }

    /// Same dead-hover leak fix, driven by `hotkeyToggle` instead of `click`.
    @Test func hotkeyToggleWhileHoverDebouncePendingCancelsItSoHoverWorksAgainAfterCollapse() {
        var reducer = NotchInteractionReducer()

        reducer.reduce(.hoverIntent(displayA))
        #expect(reducer.panels[displayA]?.hoverDebouncePending == true)

        let toggleCommands = reducer.reduce(.hotkeyToggle(displayA))
        #expect(toggleCommands.contains(command(.cancelHoverDebounce, on: displayA)))
        #expect(reducer.panels[displayA]?.hoverDebouncePending == false)

        let generation = reducer.panels[displayA]?.animationGeneration ?? 0
        reducer.reduce(.animationSettled(displayA, generation: generation))
        reducer.reduce(.escape(displayA))
        let collapseGeneration = reducer.panels[displayA]?.animationGeneration ?? 0
        reducer.reduce(.animationSettled(displayA, generation: collapseGeneration))
        #expect(reducer.panels[displayA]?.presentation == .collapsed)

        let secondHoverCommands = reducer.reduce(.hoverIntent(displayA))
        let hoverGeneration = reducer.panels[displayA]?.hoverDebounceGeneration ?? 0
        #expect(secondHoverCommands == [command(.scheduleHoverDebounce(generation: hoverGeneration), on: displayA)])
    }

    // MARK: - Locks block dismissal

    /// A held lock blocks the exit grace from ever being scheduled; releasing the lock (via its paired end
    /// event) both clears it and re-evaluates containment, scheduling the grace immediately since the
    /// pointer was already outside.
    @Test func scrollMomentumLockBlocksDismissalUntilReleased() {
        var reducer = NotchInteractionReducer()
        reducer.reduce(.hoverIntent(displayA))
        fireHoverDebounce(displayA, in: &reducer)
        let generation = reducer.panels[displayA]?.animationGeneration ?? 0
        reducer.reduce(.animationSettled(displayA, generation: generation))

        let beganCommands = reducer.reduce(.scrollMomentumBegan(displayA))
        #expect(beganCommands == [])
        #expect(reducer.panels[displayA]?.locks == .scrollMomentum)

        let exitWhileLocked = reducer.reduce(.hoverExit(displayA, pointerInside: false))
        #expect(exitWhileLocked == [], "a held lock must block scheduling the exit grace")
        #expect(reducer.panels[displayA]?.presentation == .expanded(.home))

        let momentumEndedCommands = reducer.reduce(.scrollMomentumEnded(displayA, pointerInside: false))
        #expect(reducer.panels[displayA]?.locks.isEmpty == true)
        let graceGeneration = reducer.panels[displayA]?.exitGraceGeneration ?? 0
        #expect(momentumEndedCommands == [command(.scheduleExitGrace(generation: graceGeneration), on: displayA)])
    }

    /// BUG fix: a lock-begin (`scrollMomentumBegan`) arriving while the panel is `.collapsed` must not
    /// insert a lock at all. Before this fix, the lock was inserted unconditionally regardless of
    /// presentation, leaking a lock nothing would ever clear and permanently disabling dismissal on a panel
    /// that goes on to expand normally.
    @Test func scrollMomentumBeganWhileCollapsedInsertsNoLockAndDoesNotBlockLaterDismissal() {
        var reducer = NotchInteractionReducer()
        let beganCommands = reducer.reduce(.scrollMomentumBegan(displayA))
        #expect(beganCommands == [])
        #expect(reducer.panels[displayA]?.locks.isEmpty == true)

        reducer.reduce(.hoverIntent(displayA))
        fireHoverDebounce(displayA, in: &reducer)
        let generation = reducer.panels[displayA]?.animationGeneration ?? 0
        reducer.reduce(.animationSettled(displayA, generation: generation))

        let escapeCommands = reducer.reduce(.escape(displayA))
        #expect(reducer.panels[displayA]?.presentation == .collapsing)
        #expect(!escapeCommands.isEmpty, "no leaked lock from the earlier out-of-window scrollMomentumBegan may block dismissal")
    }

    // MARK: - Newly wired locks: mouseDown and playlistPicker

    /// `pressBegan` acquires `.mouseDown`, blocking a hover-exit's grace exactly like the other locks;
    /// `pressEnded(pointerInside: false)` releases it and schedules a fresh grace, closing the "declared but
    /// unreachable" gap on ``InteractionLock/mouseDown``.
    @Test func pressBeganAcquiresMouseDownLockAndPressEndedReleasesAndSchedulesGrace() {
        var reducer = NotchInteractionReducer()
        reducer.reduce(.hoverIntent(displayA))
        fireHoverDebounce(displayA, in: &reducer)
        let generation = reducer.panels[displayA]?.animationGeneration ?? 0
        reducer.reduce(.animationSettled(displayA, generation: generation))

        let pressBeganCommands = reducer.reduce(.pressBegan(displayA))
        #expect(pressBeganCommands == [])
        #expect(reducer.panels[displayA]?.locks == .mouseDown)

        let exitWhileLocked = reducer.reduce(.hoverExit(displayA, pointerInside: false))
        #expect(exitWhileLocked == [], "a held mouseDown lock must block scheduling the exit grace")

        let pressEndedCommands = reducer.reduce(.pressEnded(displayA, pointerInside: false))
        #expect(reducer.panels[displayA]?.locks.isEmpty == true)
        let graceGeneration = reducer.panels[displayA]?.exitGraceGeneration ?? 0
        #expect(pressEndedCommands == [command(.scheduleExitGrace(generation: graceGeneration), on: displayA)])
    }

    /// Same acquire/release/re-evaluate pairing for `playlistPickerOpened`/`playlistPickerClosed`, closing
    /// the same gap on ``InteractionLock/playlistPicker``.
    @Test func playlistPickerOpenedAcquiresLockAndClosedReleasesAndSchedulesGrace() {
        var reducer = NotchInteractionReducer()
        reducer.reduce(.hoverIntent(displayA))
        fireHoverDebounce(displayA, in: &reducer)
        let generation = reducer.panels[displayA]?.animationGeneration ?? 0
        reducer.reduce(.animationSettled(displayA, generation: generation))

        let openedCommands = reducer.reduce(.playlistPickerOpened(displayA))
        #expect(openedCommands == [])
        #expect(reducer.panels[displayA]?.locks == .playlistPicker)

        let exitWhileLocked = reducer.reduce(.hoverExit(displayA, pointerInside: false))
        #expect(exitWhileLocked == [], "a held playlistPicker lock must block scheduling the exit grace")

        let closedCommands = reducer.reduce(.playlistPickerClosed(displayA, pointerInside: false))
        #expect(reducer.panels[displayA]?.locks.isEmpty == true)
        let graceGeneration = reducer.panels[displayA]?.exitGraceGeneration ?? 0
        #expect(closedCommands == [command(.scheduleExitGrace(generation: graceGeneration), on: displayA)])
    }

    // MARK: - Exit grace firing while locked

    /// BUG fix (grace-fires-while-locked stuck-open): an exit grace that fires while a lock is held must not
    /// leave the panel stuck open forever. The fire is consumed (`exitGracePending` cleared) without
    /// collapsing anything; the subsequent lock release then schedules a brand-new grace (a bumped
    /// generation), which does go on to collapse when it fires.
    @Test func exitGraceFiredWhileLockedClearsPendingWithoutCollapsingThenReleaseSchedulesFreshGrace() {
        var reducer = NotchInteractionReducer()
        reducer.reduce(.hoverIntent(displayA))
        fireHoverDebounce(displayA, in: &reducer)
        let expandGeneration = reducer.panels[displayA]?.animationGeneration ?? 0
        reducer.reduce(.animationSettled(displayA, generation: expandGeneration))

        reducer.reduce(.hoverExit(displayA, pointerInside: false))
        let firstGraceGeneration = reducer.panels[displayA]?.exitGraceGeneration ?? 0
        #expect(reducer.panels[displayA]?.exitGracePending == true)

        // A lock is acquired after the grace was scheduled but before it fires.
        reducer.reduce(.scrollMomentumBegan(displayA))
        #expect(reducer.panels[displayA]?.locks == .scrollMomentum)

        let firedWhileLockedCommands = reducer.reduce(.exitGraceFired(displayA, generation: firstGraceGeneration))
        #expect(reducer.panels[displayA]?.presentation == .expanded(.home), "still locked, must not collapse")
        #expect(reducer.panels[displayA]?.exitGracePending == false, "the fired grace is consumed regardless")
        #expect(firedWhileLockedCommands.contains(command(.cancelExitGrace, on: displayA)))

        // Releasing the lock re-evaluates containment and schedules a NEW grace.
        let releaseCommands = reducer.reduce(.lockReleased(displayA, pointerInside: false))
        #expect(reducer.panels[displayA]?.locks.isEmpty == true)
        let secondGraceGeneration = reducer.panels[displayA]?.exitGraceGeneration ?? 0
        #expect(secondGraceGeneration > firstGraceGeneration)
        #expect(releaseCommands == [command(.scheduleExitGrace(generation: secondGraceGeneration), on: displayA)])

        // The fresh grace, once it fires, actually collapses.
        let secondFireCommands = reducer.reduce(.exitGraceFired(displayA, generation: secondGraceGeneration))
        #expect(reducer.panels[displayA]?.presentation == .collapsing)
        let collapseGeneration = reducer.panels[displayA]?.animationGeneration ?? 0
        #expect(secondFireCommands.contains(command(.startCollapse(generation: collapseGeneration), on: displayA)))
    }

    // MARK: - lockReleased re-checks containment

    /// `lockReleased(pointerInside:false)` starts the exit grace exactly like any other "stopped covering
    /// the panel" event; `lockReleased(pointerInside:true)` must not.
    @Test func lockReleasedReChecksContainment() {
        var reducer = NotchInteractionReducer()
        reducer.reduce(.hoverIntent(displayA))
        fireHoverDebounce(displayA, in: &reducer)
        let generation = reducer.panels[displayA]?.animationGeneration ?? 0
        reducer.reduce(.animationSettled(displayA, generation: generation))

        let outsideCommands = reducer.reduce(.lockReleased(displayA, pointerInside: false))
        let graceGeneration = reducer.panels[displayA]?.exitGraceGeneration ?? 0
        #expect(outsideCommands == [command(.scheduleExitGrace(generation: graceGeneration), on: displayA)])

        // Reset for the pointer-inside case on a second display.
        reducer.reduce(.hoverIntent(displayB))
        fireHoverDebounce(displayB, in: &reducer)
        let bGeneration = reducer.panels[displayB]?.animationGeneration ?? 0
        reducer.reduce(.animationSettled(displayB, generation: bGeneration))

        let insideCommands = reducer.reduce(.lockReleased(displayB, pointerInside: true))
        #expect(insideCommands == [])
        #expect(reducer.panels[displayB]?.presentation == .expanded(.home))
    }

    // MARK: - Re-entry cancels a pending collapse

    /// A `hoverIntent` that arrives while an exit grace is pending cancels it and leaves the panel expanded,
    /// rather than letting the already-scheduled grace timer collapse the panel the user just came back to.
    @Test func reEntryCancelsPendingExitGrace() {
        var reducer = NotchInteractionReducer()
        reducer.reduce(.hoverIntent(displayA))
        fireHoverDebounce(displayA, in: &reducer)
        let generation = reducer.panels[displayA]?.animationGeneration ?? 0
        reducer.reduce(.animationSettled(displayA, generation: generation))
        reducer.reduce(.hoverExit(displayA, pointerInside: false))
        #expect(reducer.panels[displayA]?.exitGracePending == true)
        let graceGeneration = reducer.panels[displayA]?.exitGraceGeneration ?? 0

        let reEntryCommands = reducer.reduce(.hoverIntent(displayA))

        #expect(reEntryCommands == [command(.cancelExitGrace, on: displayA)])
        #expect(reducer.panels[displayA]?.presentation == .expanded(.home))
        #expect(reducer.panels[displayA]?.exitGracePending == false)

        // The grace timer firing after cancellation must not collapse the panel.
        let staleGraceCommands = reducer.reduce(.exitGraceFired(displayA, generation: graceGeneration))
        #expect(staleGraceCommands == [])
        #expect(reducer.panels[displayA]?.presentation == .expanded(.home))
    }

    // MARK: - Re-entry during collapsing retargets to expanding

    /// BUG fix: `hoverIntent` arriving while the panel is mid-`collapsing` now retargets straight back to
    /// expanding (bumped generation, `startExpand`) instead of being dropped, which used to let the panel
    /// finish closing under a pointer that had already come back. `installPointerMonitors` is deliberately
    /// NOT re-emitted: the monitor pair from the original expand was never torn down (that only happens on
    /// a genuine collapse-settle), so it is still installed. The stale collapse's own `animationSettled` is
    /// then a no-op thanks to the generation bump.
    @Test func hoverIntentDuringCollapsingRetargetsToExpandingWithoutReinstallingMonitors() {
        var reducer = NotchInteractionReducer()
        reducer.reduce(.hoverIntent(displayA))
        fireHoverDebounce(displayA, in: &reducer)
        let expandGeneration = reducer.panels[displayA]?.animationGeneration ?? 0
        reducer.reduce(.animationSettled(displayA, generation: expandGeneration))
        reducer.reduce(.escape(displayA))
        #expect(reducer.panels[displayA]?.presentation == .collapsing)
        let collapseGeneration = reducer.panels[displayA]?.animationGeneration ?? 0

        let retargetCommands = reducer.reduce(.hoverIntent(displayA))
        guard case .expanding(let trigger) = reducer.panels[displayA]?.presentation else {
            Issue.record("expected expanding after re-entry during collapsing")
            return
        }
        #expect(trigger == .hover)
        let newGeneration = reducer.panels[displayA]?.animationGeneration ?? 0
        #expect(newGeneration > collapseGeneration)
        #expect(retargetCommands == [command(.startExpand(generation: newGeneration), on: displayA)])
        #expect(!retargetCommands.contains(command(.installPointerMonitors, on: displayA)))

        let staleCollapseSettleCommands = reducer.reduce(.animationSettled(displayA, generation: collapseGeneration))
        #expect(staleCollapseSettleCommands == [])
        #expect(reducer.panels[displayA]?.presentation == .expanding(.hover))
    }

    /// Same retarget-during-collapsing fix as above, driven by `click` instead of `hoverIntent`.
    @Test func clickDuringCollapsingRetargetsToExpanding() {
        var reducer = NotchInteractionReducer()
        reducer.reduce(.hoverIntent(displayA))
        fireHoverDebounce(displayA, in: &reducer)
        let expandGeneration = reducer.panels[displayA]?.animationGeneration ?? 0
        reducer.reduce(.animationSettled(displayA, generation: expandGeneration))
        reducer.reduce(.escape(displayA))
        let collapseGeneration = reducer.panels[displayA]?.animationGeneration ?? 0

        let clickCommands = reducer.reduce(.click(displayA))
        guard case .expanding(let trigger) = reducer.panels[displayA]?.presentation else {
            Issue.record("expected expanding after click during collapsing")
            return
        }
        #expect(trigger == .click)
        let newGeneration = reducer.panels[displayA]?.animationGeneration ?? 0
        #expect(newGeneration > collapseGeneration)
        #expect(clickCommands == [command(.startExpand(generation: newGeneration), on: displayA)])
    }

    /// Same retarget-during-collapsing fix as above, driven by `hotkeyToggle` instead of `hoverIntent`.
    @Test func hotkeyToggleDuringCollapsingRetargetsToExpanding() {
        var reducer = NotchInteractionReducer()
        reducer.reduce(.hoverIntent(displayA))
        fireHoverDebounce(displayA, in: &reducer)
        let expandGeneration = reducer.panels[displayA]?.animationGeneration ?? 0
        reducer.reduce(.animationSettled(displayA, generation: expandGeneration))
        reducer.reduce(.escape(displayA))
        let collapseGeneration = reducer.panels[displayA]?.animationGeneration ?? 0

        let toggleCommands = reducer.reduce(.hotkeyToggle(displayA))
        guard case .expanding(let trigger) = reducer.panels[displayA]?.presentation else {
            Issue.record("expected expanding after hotkeyToggle during collapsing")
            return
        }
        #expect(trigger == .hotkey)
        let newGeneration = reducer.panels[displayA]?.animationGeneration ?? 0
        #expect(newGeneration > collapseGeneration)
        #expect(toggleCommands == [command(.startExpand(generation: newGeneration), on: displayA)])
    }

    // MARK: - Routing carried through expansion

    /// A `route(_:)` event during `.expanding` retargets the route the panel will land on; `route(_:)` while
    /// already `.expanded` swaps immediately as before; and a fresh expansion after a full collapse defaults
    /// back to `.home`.
    @Test func routeDuringExpandLandsOnRequestedRouteAndResetsToHomeOnNextExpand() {
        var reducer = NotchInteractionReducer()
        reducer.reduce(.hoverIntent(displayA))
        fireHoverDebounce(displayA, in: &reducer)
        let expandGeneration = reducer.panels[displayA]?.animationGeneration ?? 0

        let routeCommands = reducer.reduce(.route(displayA, .herd))
        #expect(routeCommands == [])
        reducer.reduce(.animationSettled(displayA, generation: expandGeneration))
        #expect(reducer.panels[displayA]?.presentation == .expanded(.herd))

        let swapCommands = reducer.reduce(.route(displayA, .spotify))
        #expect(swapCommands == [])
        #expect(reducer.panels[displayA]?.presentation == .expanded(.spotify))

        reducer.reduce(.escape(displayA))
        let collapseGeneration = reducer.panels[displayA]?.animationGeneration ?? 0
        reducer.reduce(.animationSettled(displayA, generation: collapseGeneration))
        #expect(reducer.panels[displayA]?.presentation == .collapsed)

        reducer.reduce(.hoverIntent(displayA))
        fireHoverDebounce(displayA, in: &reducer)
        let reExpandGeneration = reducer.panels[displayA]?.animationGeneration ?? 0
        reducer.reduce(.animationSettled(displayA, generation: reExpandGeneration))
        #expect(reducer.panels[displayA]?.presentation == .expanded(.home))
    }

    // MARK: - Route contract: state-observed, not delivered as a command

    /// `route(_:)` while `.expanded` returns `[]` and mutates `presentation` directly to `.expanded(route)` —
    /// pinning the design decision that panel content is state the view reads, never a command a dumb
    /// executor is told to run (see ``NotchInteractionReducer``'s "commands cover lifecycle... never
    /// content" section).
    @Test func routeWhileExpandedReturnsNoCommandsAndMutatesPresentation() {
        var reducer = NotchInteractionReducer()
        reducer.reduce(.hoverIntent(displayA))
        fireHoverDebounce(displayA, in: &reducer)
        let generation = reducer.panels[displayA]?.animationGeneration ?? 0
        reducer.reduce(.animationSettled(displayA, generation: generation))
        #expect(reducer.panels[displayA]?.presentation == .expanded(.home))

        let routeCommands = reducer.reduce(.route(displayA, .herd))
        #expect(routeCommands == [])
        #expect(reducer.panels[displayA]?.presentation == .expanded(.herd))
    }

    /// `route(_:)` while `.expanded` also mirrors the new route onto `pendingRoute`, not only
    /// `presentation` (the fn-fn route-flash fix): a `.collapsing` panel's content is read from
    /// `pendingRoute` (see `NotchContentView.currentRoute`), so if a swap left `pendingRoute` stale, an
    /// immediate collapse right after the swap would flash the *previous* route for one frame before the
    /// mask finished covering the surface. Asserting `pendingRoute` directly (rather than only observing
    /// through a subsequent collapse-and-resettle) pins the fix at its actual source.
    @Test func routeWhileExpandedAlsoUpdatesPendingRoute() {
        var reducer = NotchInteractionReducer()
        reducer.reduce(.hoverIntent(displayA))
        fireHoverDebounce(displayA, in: &reducer)
        let generation = reducer.panels[displayA]?.animationGeneration ?? 0
        reducer.reduce(.animationSettled(displayA, generation: generation))
        #expect(reducer.panels[displayA]?.presentation == .expanded(.home))
        #expect(reducer.panels[displayA]?.pendingRoute == .home)

        reducer.reduce(.route(displayA, .herd))
        #expect(reducer.panels[displayA]?.presentation == .expanded(.herd))
        #expect(reducer.panels[displayA]?.pendingRoute == .herd)
    }

    /// `route(_:)` while `.expanding` retargets `pendingRoute`; the panel lands on that route once
    /// `animationSettled` arrives, with no command ever naming the route either at the `route(_:)` event or
    /// at settle.
    @Test func routeWhileExpandingLandsOnRequestedRouteAtSettle() {
        var reducer = NotchInteractionReducer()
        reducer.reduce(.hoverIntent(displayA))
        fireHoverDebounce(displayA, in: &reducer)
        guard case .expanding = reducer.panels[displayA]?.presentation else {
            Issue.record("expected expanding")
            return
        }

        let routeCommands = reducer.reduce(.route(displayA, .spotify))
        #expect(routeCommands == [])

        let generation = reducer.panels[displayA]?.animationGeneration ?? 0
        let settleCommands = reducer.reduce(.animationSettled(displayA, generation: generation))
        #expect(reducer.panels[displayA]?.presentation == .expanded(.spotify))
        #expect(settleCommands == [])
    }

    // MARK: - Suspend and resume

    /// Suspending an expanded panel with a pending exit grace tears down both the grace timer and the
    /// pointer monitors in one call, hides the panel's window (it was visible), and forces the panel to
    /// `suspended` rather than running the normal collapse animation. Resuming returns it to `collapsed`,
    /// not back to `expanded`, and shows the window again.
    @Test func suspendTearsDownTimersAndMonitorsThenResumeCollapses() {
        var reducer = NotchInteractionReducer()
        reducer.reduce(.hoverIntent(displayA))
        fireHoverDebounce(displayA, in: &reducer)
        let generation = reducer.panels[displayA]?.animationGeneration ?? 0
        reducer.reduce(.animationSettled(displayA, generation: generation))
        reducer.reduce(.hoverExit(displayA, pointerInside: false))
        #expect(reducer.panels[displayA]?.exitGracePending == true)

        let suspendCommands = reducer.reduce(.suspend(displayA))
        #expect(reducer.panels[displayA]?.presentation == .suspended)
        #expect(suspendCommands.contains(command(.cancelExitGrace, on: displayA)))
        #expect(suspendCommands.contains(command(.removePointerMonitors, on: displayA)))
        #expect(suspendCommands.contains(command(.hidePanel, on: displayA)))
        #expect(reducer.panels[displayA]?.exitGracePending == false)
        #expect(reducer.panels[displayA]?.locks.isEmpty == true)

        let resumeCommands = reducer.reduce(.resume(displayA))
        #expect(reducer.panels[displayA]?.presentation == .collapsed)
        #expect(resumeCommands == [command(.showCollapsed, on: displayA)])
    }

    /// BUG-adjacent regression guard: suspending mid-`expanding` bumps the generation, so the in-flight
    /// expand's own `animationSettled` is a stale no-op once it eventually arrives, and resuming afterward
    /// still yields a clean re-expand rather than any leftover `expanding`/`pointerOutsideDuringExpand`
    /// state bleeding into the next hover.
    @Test func suspendDuringExpandingMakesTheInFlightExpandSettleAStaleNoOp() {
        var reducer = NotchInteractionReducer()
        reducer.reduce(.hoverIntent(displayA))
        fireHoverDebounce(displayA, in: &reducer)
        let expandGeneration = reducer.panels[displayA]?.animationGeneration ?? 0
        guard case .expanding = reducer.panels[displayA]?.presentation else {
            Issue.record("expected expanding")
            return
        }

        let suspendCommands = reducer.reduce(.suspend(displayA))
        #expect(reducer.panels[displayA]?.presentation == .suspended)
        #expect(suspendCommands.contains(command(.removePointerMonitors, on: displayA)))
        #expect(suspendCommands.contains(command(.hidePanel, on: displayA)))

        let staleExpandSettleCommands = reducer.reduce(.animationSettled(displayA, generation: expandGeneration))
        #expect(staleExpandSettleCommands == [])
        #expect(reducer.panels[displayA]?.presentation == .suspended)

        let resumeCommands = reducer.reduce(.resume(displayA))
        #expect(resumeCommands == [command(.showCollapsed, on: displayA)])
        #expect(reducer.panels[displayA]?.presentation == .collapsed)

        let reEntryCommands = reducer.reduce(.hoverIntent(displayA))
        let hoverGeneration = reducer.panels[displayA]?.hoverDebounceGeneration ?? 0
        #expect(reEntryCommands == [command(.scheduleHoverDebounce(generation: hoverGeneration), on: displayA)])
    }

    // MARK: - Suspend/resume window visibility

    /// `suspend` of a fully `.expanded` panel emits `hidePanel`; `resume` back from `.suspended` emits
    /// `showCollapsed`. A dumb executor cannot infer window ordering from the presentation change alone, so
    /// these are named effects, not something inferred from state.
    @Test func suspendOfExpandedPanelHidesAndResumeShowsCollapsed() {
        var reducer = NotchInteractionReducer()
        reducer.reduce(.hoverIntent(displayA))
        fireHoverDebounce(displayA, in: &reducer)
        let generation = reducer.panels[displayA]?.animationGeneration ?? 0
        reducer.reduce(.animationSettled(displayA, generation: generation))
        #expect(reducer.panels[displayA]?.presentation == .expanded(.home))

        let suspendCommands = reducer.reduce(.suspend(displayA))
        #expect(suspendCommands.contains(command(.hidePanel, on: displayA)))

        let resumeCommands = reducer.reduce(.resume(displayA))
        #expect(resumeCommands == [command(.showCollapsed, on: displayA)])
        #expect(reducer.panels[displayA]?.presentation == .collapsed)
    }

    /// `suspend` of a still-`.collapsed` panel must NOT emit `hidePanel`: the collapsed pill's own
    /// visibility at launch, or on a vanished display, is a controller responsibility outside this
    /// reducer's suspend/resume lifecycle (see `NotchEffect.hidePanel`'s documentation).
    @Test func suspendOfCollapsedPanelDoesNotHidePanel() {
        var reducer = NotchInteractionReducer()
        let suspendCommands = reducer.reduce(.suspend(displayA))
        #expect(!suspendCommands.contains(command(.hidePanel, on: displayA)))
        #expect(reducer.panels[displayA]?.presentation == .suspended)
    }

    // MARK: - Escape and hotkey

    /// Escape and an unlocked hotkey toggle both collapse an expanded panel immediately, with no exit
    /// grace: these are decisive dismissals, not an ambiguous pointer signal to debounce.
    @Test func escapeCollapsesExpandedPanelImmediately() {
        var reducer = NotchInteractionReducer()
        reducer.reduce(.hoverIntent(displayA))
        fireHoverDebounce(displayA, in: &reducer)
        let generation = reducer.panels[displayA]?.animationGeneration ?? 0
        reducer.reduce(.animationSettled(displayA, generation: generation))

        let escapeCommands = reducer.reduce(.escape(displayA))
        #expect(reducer.panels[displayA]?.presentation == .collapsing)
        let collapseGeneration = reducer.panels[displayA]?.animationGeneration ?? 0
        #expect(escapeCommands == [command(.startCollapse(generation: collapseGeneration), on: displayA)])
    }

    /// `hotkeyToggle` expands a collapsed panel and collapses an expanded one.
    @Test func hotkeyTogglesBothDirections() {
        var reducer = NotchInteractionReducer()

        let expandCommands = reducer.reduce(.hotkeyToggle(displayA))
        guard case .expanding(let trigger) = reducer.panels[displayA]?.presentation else {
            Issue.record("expected expanding after hotkey toggle from collapsed")
            return
        }
        #expect(trigger == .hotkey)
        #expect(expandCommands.contains(command(.installPointerMonitors, on: displayA)))

        let generation = reducer.panels[displayA]?.animationGeneration ?? 0
        reducer.reduce(.animationSettled(displayA, generation: generation))
        #expect(reducer.panels[displayA]?.presentation == .expanded(.home))

        let collapseCommands = reducer.reduce(.hotkeyToggle(displayA))
        #expect(reducer.panels[displayA]?.presentation == .collapsing)
        #expect(!collapseCommands.isEmpty)
    }

    /// A locked, expanded panel ignores both escape and hotkeyToggle: a lock blocks every dismissal path,
    /// not only the pointer-driven ones.
    @Test func locksBlockEscapeAndHotkeyToo() {
        var reducer = NotchInteractionReducer()
        reducer.reduce(.hoverIntent(displayA))
        fireHoverDebounce(displayA, in: &reducer)
        let generation = reducer.panels[displayA]?.animationGeneration ?? 0
        reducer.reduce(.animationSettled(displayA, generation: generation))
        reducer.reduce(.dragBegan(displayA))

        let escapeCommands = reducer.reduce(.escape(displayA))
        #expect(escapeCommands == [])
        #expect(reducer.panels[displayA]?.presentation == .expanded(.home))
    }

    // MARK: - Double hover intent

    /// A second `hoverIntent` while a debounce is already pending must not schedule a redundant timer.
    @Test func doubleHoverIntentSchedulesExactlyOneDebounce() {
        var reducer = NotchInteractionReducer()
        let first = reducer.reduce(.hoverIntent(displayA))
        let generation = reducer.panels[displayA]?.hoverDebounceGeneration ?? 0
        #expect(first == [command(.scheduleHoverDebounce(generation: generation), on: displayA)])

        let second = reducer.reduce(.hoverIntent(displayA))
        #expect(second == [])
        #expect(reducer.panels[displayA]?.hoverDebouncePending == true)
    }

    // MARK: - Lazy panel creation

    /// An event for a display nobody has seen before materialises it as `collapsed`, with no separate
    /// registration step required.
    @Test func unknownDisplayIsLazilyCreatedAsCollapsed() {
        var reducer = NotchInteractionReducer()
        #expect(reducer.panels[displayA] == nil)

        _ = reducer.reduce(.resume(displayA))

        #expect(reducer.panels[displayA]?.presentation == .collapsed)
    }

    // MARK: - File drag

    private func expandedReducer(_ display: NotchDisplayID) -> NotchInteractionReducer {
        var reducer = NotchInteractionReducer()
        reducer.reduce(.hoverIntent(display))
        fireHoverDebounce(display, in: &reducer)
        reducer.reduce(.animationSettled(display, generation: reducer.panels[display]?.animationGeneration ?? 0))
        return reducer
    }

    @Test func fileDragEnteredExpandsCollapsedPanelAndTakesDragLock() {
        var reducer = NotchInteractionReducer()
        let commands = reducer.reduce(.fileDragEntered(displayA))
        #expect(reducer.panels[displayA]?.presentation == .expanding(.fileDrag))
        #expect(reducer.panels[displayA]?.locks == .drag)
        let generation = reducer.panels[displayA]?.animationGeneration ?? 0
        #expect(commands.contains(command(.startExpand(generation: generation), on: displayA)))
        #expect(commands.contains(command(.installPointerMonitors, on: displayA)))
    }

    @Test func fileDragEnteredDuringCollapsingRetargetsToExpandingWithLock() {
        var reducer = expandedReducer(displayA)
        reducer.reduce(.escape(displayA))
        let collapseGeneration = reducer.panels[displayA]?.animationGeneration ?? 0

        let commands = reducer.reduce(.fileDragEntered(displayA))
        #expect(reducer.panels[displayA]?.presentation == .expanding(.fileDrag))
        #expect(reducer.panels[displayA]?.locks == .drag)
        let newGeneration = reducer.panels[displayA]?.animationGeneration ?? 0
        #expect(newGeneration > collapseGeneration)
        #expect(commands == [command(.startExpand(generation: newGeneration), on: displayA)])
    }

    @Test func fileDragLockBlocksExitGraceAndEscapeUntilDragEnded() {
        var reducer = NotchInteractionReducer()
        reducer.reduce(.fileDragEntered(displayA))
        reducer.reduce(.animationSettled(displayA, generation: reducer.panels[displayA]?.animationGeneration ?? 0))
        #expect(reducer.panels[displayA]?.presentation == .expanded(.home))

        #expect(reducer.reduce(.hoverExit(displayA, pointerInside: false)) == [])
        #expect(reducer.reduce(.escape(displayA)) == [])
        #expect(reducer.panels[displayA]?.presentation == .expanded(.home))

        let ended = reducer.reduce(.dragEnded(displayA, pointerInside: false))
        let graceGeneration = reducer.panels[displayA]?.exitGraceGeneration ?? 0
        #expect(reducer.panels[displayA]?.locks.isEmpty == true)
        #expect(ended == [command(.scheduleExitGrace(generation: graceGeneration), on: displayA)])
    }

    @Test func fileDragEndedOutsideDuringExpandingSchedulesGraceOnSettle() {
        var reducer = NotchInteractionReducer()
        reducer.reduce(.fileDragEntered(displayA))
        reducer.reduce(.dragEnded(displayA, pointerInside: false))
        let generation = reducer.panels[displayA]?.animationGeneration ?? 0
        let settled = reducer.reduce(.animationSettled(displayA, generation: generation))
        let graceGeneration = reducer.panels[displayA]?.exitGraceGeneration ?? 0
        #expect(settled == [command(.scheduleExitGrace(generation: graceGeneration), on: displayA)])
    }

    @Test func fileDragEnteredWhileExpandedOnlyTakesLock() {
        var reducer = expandedReducer(displayA)
        let generation = reducer.panels[displayA]?.animationGeneration ?? 0
        let commands = reducer.reduce(.fileDragEntered(displayA))
        #expect(commands == [])
        #expect(reducer.panels[displayA]?.presentation == .expanded(.home))
        #expect(reducer.panels[displayA]?.animationGeneration == generation)
        #expect(reducer.panels[displayA]?.locks == .drag)
    }

    @Test func fileDragEnteredWhileExpandingKeepsTriggerAndTakesLock() {
        var reducer = NotchInteractionReducer()
        reducer.reduce(.hoverIntent(displayA))
        fireHoverDebounce(displayA, in: &reducer)
        let commands = reducer.reduce(.fileDragEntered(displayA))
        #expect(commands == [])
        #expect(reducer.panels[displayA]?.presentation == .expanding(.hover))
        #expect(reducer.panels[displayA]?.locks == .drag)
    }

    @Test func fileDragEnteredWhileSuspendedIsNoOp() {
        var reducer = NotchInteractionReducer()
        reducer.reduce(.suspend(displayA))
        let commands = reducer.reduce(.fileDragEntered(displayA))
        #expect(commands == [])
        #expect(reducer.panels[displayA]?.presentation == .suspended)
        #expect(reducer.panels[displayA]?.locks.isEmpty == true)
    }

    @Test func fileDragOnSecondDisplayCollapsesFirst() {
        var reducer = expandedReducer(displayA)
        reducer.reduce(.fileDragEntered(displayB))
        #expect(reducer.panels[displayA]?.presentation == .collapsing)
        #expect(reducer.panels[displayB]?.presentation == .expanding(.fileDrag))
    }
}
