import Foundation

/// A side effect the AppKit layer must perform in response to a ``NotchInteractionReducer/reduce(_:)``
/// call.
///
/// `NotchCore` never performs these itself: it has no clock, no `Timer`, no `CALayer` and no pointer
/// monitor, because a reducer that could reach out and do things is a reducer that cannot be replayed in a
/// test without also faking a run loop. `NotchEffect` itself carries no display field, because a single
/// effect in isolation has no notion of which panel it belongs to; that association is made once, at the
/// point `reduce(_:)` builds its return value, by wrapping each effect in a ``NotchCommand`` alongside the
/// ``NotchDisplayID`` it targets. See ``NotchCommand`` and ``NotchInteractionReducer`` for the full
/// contract, including how a command can target a display other than the one the triggering
/// ``NotchEvent`` named.
public enum NotchEffect: Sendable, Equatable {
    /// Animate the panel open. The AppKit layer must report completion with
    /// `animationSettled(generation:)` carrying the same generation, once the animation has actually run
    /// (not merely been requested), whether it finished normally or was interrupted and retargeted.
    ///
    /// - Parameter generation: The generation stamped on this animation, to be echoed back unchanged.
    case startExpand(generation: UInt64)

    /// Animate the panel closed. Same completion contract as ``startExpand(generation:)``.
    ///
    /// - Parameter generation: The generation stamped on this animation, to be echoed back unchanged.
    case startCollapse(generation: UInt64)

    /// Start the hover-in debounce timer (about 90ms per the design), to be scheduled in
    /// `RunLoop.Mode.common` or as a `DispatchSourceTimer` so it still fires during scroll/drag/menu
    /// tracking. On completion, feed back `hoverDebounceFired(display, generation:)` with `generation`
    /// echoed back unchanged.
    ///
    /// - Parameter generation: The generation stamped on this timer. A cancel-then-reschedule bumps this
    ///   value (see ``NotchPanelState/hoverDebounceGeneration``), so a stale timer object that was not
    ///   actually torn down in time — a race the reducer cannot prevent from the AppKit side, only detect —
    ///   reports a generation the reducer no longer recognises and its fire is a complete no-op instead of a
    ///   phantom expand.
    case scheduleHoverDebounce(generation: UInt64)

    /// Cancel a hover-in debounce timer started by ``scheduleHoverDebounce(generation:)``, because the
    /// pointer left again before it fired, or a decisive gesture (click, hotkey) skipped the debounce
    /// entirely.
    case cancelHoverDebounce

    /// Start the exit-grace timer (about 250ms per the design), same common-mode scheduling requirement as
    /// ``scheduleHoverDebounce(generation:)``. On completion, feed back `exitGraceFired(display, generation:)`
    /// with `generation` echoed back unchanged.
    ///
    /// - Parameter generation: The generation stamped on this timer, for the same stale-fire protection as
    ///   ``scheduleHoverDebounce(generation:)`` (see ``NotchPanelState/exitGraceGeneration``).
    case scheduleExitGrace(generation: UInt64)

    /// Cancel an exit-grace timer started by ``scheduleExitGrace(generation:)``, because the pointer
    /// re-entered before it fired, the collapse it was guarding has already happened, or the timer fired
    /// while a lock forbade collapsing and is now being torn down without collapsing anything.
    case cancelExitGrace

    /// Install the global-plus-local `mouseMoved` monitor pair used to track pointer containment once a
    /// panel is expanding or expanded, per the "global monitors are silent for your own window" contract
    /// documented on `HerdPanel.swift`.
    case installPointerMonitors

    /// Remove the monitor pair installed by ``installPointerMonitors``, once the panel has fully collapsed.
    /// Never left installed while collapsed: a permanent global `mouseMoved` monitor wakes the process on
    /// every system-wide pointer move and is the single biggest idle-CPU risk named in the design review.
    case removePointerMonitors

    /// Order the panel's window off screen entirely, because ``NotchEvent/suspend(_:)`` arrived while it was
    /// visible (`expanding`, `expanded`, or `collapsing`).
    ///
    /// A dumb executor cannot infer window ordering from presentation changes alone, so suspending a visible
    /// panel names this effect explicitly rather than leaving the AppKit layer to guess that "now suspended"
    /// implies "now hidden". Suspending an already-``NotchPresentation/collapsed`` panel does **not** emit
    /// this effect: the collapsed pill's own visibility (shown at launch, hidden on a vanished display) is a
    /// controller responsibility outside this reducer's suspend/resume lifecycle. See ``showCollapsed``.
    case hidePanel

    /// Bring the panel's window back on screen showing the collapsed pill, because
    /// ``NotchEvent/resume(_:)`` arrived for a panel that ``hidePanel`` had previously ordered off screen.
    ///
    /// Only ever paired with a prior ``hidePanel``: resume always lands on
    /// ``NotchPresentation/collapsed`` (never back into whatever route was showing before suspension), so
    /// this is the one showable state resume can name.
    case showCollapsed
}
