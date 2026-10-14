import Foundation

/// The complete, observable state of one display's notch panel.
///
/// This is the value the AppKit layer's SwiftUI content reads directly for anything the returned commands do
/// not cover. Per the contract documented on ``NotchInteractionReducer``, `reduce(_:)` already returns a
/// **complete** lifecycle/animation/timer/pointer-monitor/window-visibility command list for every call,
/// including any command needed for a display other than the triggering event's own because the
/// at-most-one-expanded invariant forced it to change too — a caller does not need to re-read `panels` to
/// discover a missed command. What commands never carry is panel **content**: which ``NotchRoute`` is on
/// screen is state, not an effect, so this struct's fields are all readable because the view is expected to
/// read `presentation` (`.expanded(route)`) or ``pendingRoute`` directly to know what to render, not because
/// a command describing it might be missing. See ``NotchInteractionReducer``'s "commands cover lifecycle...
/// never content" section for the full contract.
///
/// A plain value type, equatable and sendable, with no identity of its own beyond the dictionary key
/// (``NotchDisplayID``) it is stored under in ``NotchInteractionReducer/panels``. It is safe to read from
/// any thread a snapshot of it was already handed to, but it is only ever mutated on the main actor, inside
/// ``NotchInteractionReducer/reduce(_:)``, because that is where the AppKit layer's timers and monitors
/// live.
public struct NotchPanelState: Sendable, Equatable {
    /// The open/close lifecycle state, and, while expanded, the route being shown.
    public var presentation: NotchPresentation

    /// The interactions currently forbidding dismissal of this panel.
    ///
    /// Non-empty means an unlock-and-recheck is required before any exit path (hover, drag end, scroll
    /// momentum end, escape, hotkey) may schedule or perform a collapse; see ``NotchInteractionReducer``.
    public var locks: InteractionLock

    /// The generation stamped on whichever expand or collapse animation is currently in flight (or, when
    /// nothing is animating, the generation of the last one that was).
    ///
    /// Monotonically increasing, bumped by the reducer every time it emits a new
    /// ``NotchEffect/startExpand(generation:)`` or ``NotchEffect/startCollapse(generation:)``, including
    /// when the cross-panel invariant forces *this* panel into ``NotchPresentation/collapsing`` because
    /// some other display just started expanding. A caller reconciling that forced transition (see
    /// ``NotchInteractionReducer``) reads this field directly to learn the generation to animate, since no
    /// effect scoped to this display is returned from the reduce call that caused it.
    public var animationGeneration: UInt64

    /// Whether ``NotchEffect/scheduleHoverDebounce(generation:)`` is currently outstanding for this panel.
    ///
    /// Bookkeeping only: it lets the reducer ignore a `hoverDebounceFired` that arrives after the pointer
    /// already left and the panel is no longer ``NotchPresentation/collapsed``, and lets a second
    /// `hoverIntent` while one is already pending be a no-op instead of scheduling a redundant timer. See
    /// ``hoverDebounceGeneration`` for the belt-and-braces companion that disambiguates a stale fire even
    /// when this flag alone would not.
    public var hoverDebouncePending: Bool

    /// Whether ``NotchEffect/scheduleExitGrace(generation:)`` is currently outstanding for this panel.
    ///
    /// Bookkeeping only, mirroring ``hoverDebouncePending``: it is what a re-entering `hoverIntent` cancels
    /// (see ``NotchInteractionReducer``), and what stops a second exit event from scheduling a second grace
    /// timer while one is already running. See ``exitGraceGeneration`` for the companion generation.
    public var exitGracePending: Bool

    /// The generation stamped on whichever hover-debounce timer is currently outstanding (or, when none is,
    /// the generation of the last one that was), mirroring ``animationGeneration`` for a different timer.
    ///
    /// Bumped every time ``NotchEffect/scheduleHoverDebounce(generation:)`` is scheduled *and* every time a
    /// pending debounce is cancelled without firing. ``hoverDebouncePending`` alone answers "is a debounce
    /// outstanding right now"; this field additionally answers "is THIS specific fire the one currently
    /// outstanding" — the case the boolean cannot express is a cancel-then-immediate-reschedule where the
    /// AppKit layer's own `Timer`/`DispatchSourceTimer` teardown loses a race with the old one already
    /// firing. A `hoverDebounceFired(display, generation:)` is only honoured when its `generation` matches
    /// this field; see ``NotchInteractionReducer``.
    public var hoverDebounceGeneration: UInt64

    /// The generation stamped on whichever exit-grace timer is currently outstanding, mirroring
    /// ``hoverDebounceGeneration`` for ``NotchEffect/scheduleExitGrace(generation:)`` /
    /// `exitGraceFired(display, generation:)`.
    public var exitGraceGeneration: UInt64

    /// Whether a `hoverExit(pointerInside: false)` (or the equivalent drag/scroll/lock-released signal)
    /// arrived while this panel was ``NotchPresentation/expanding(_:)``.
    ///
    /// The expand animation cannot be aborted mid-flight without a generation bump that would also discard
    /// the trigger and target route it carries, so the reducer instead records the fact here and defers
    /// acting on it until the animation actually settles: see
    /// ``NotchInteractionReducer/handleAnimationSettled(display:generation:panel:)``. Without this flag, a
    /// pointer that flicks out during the ~180ms expand animation is silently dropped and the panel rests
    /// open forever with nothing outside it to generate another exit signal — the "stuck open on fast
    /// flick" glitch this type exists to prevent. Cleared on genuine re-entry (`hoverIntent` while still
    /// expanding) and always cleared by the time the panel leaves `expanding`.
    public var pointerOutsideDuringExpand: Bool

    /// The ``NotchRoute`` the panel will land on once its current (or most recent) expand animation settles.
    ///
    /// Set to ``NotchRoute/home`` whenever a fresh expansion begins (`hoverIntent`, `click`, `hotkeyToggle`),
    /// and updated by a ``NotchEvent/route(_:_:)`` event that arrives while still
    /// ``NotchPresentation/expanding(_:)``, so "open straight to a specific route" (for example, a hotkey
    /// bound to "open to Spotify") is representable without inventing a second expanding case. Once the
    /// panel is ``NotchPresentation/expanded(_:)`` this field is redundant with the route carried on that
    /// case and is not consulted again until the next expansion.
    public var pendingRoute: NotchRoute

    /// The state every panel starts in: closed, unlocked, generation zero, nothing pending, defaulting to
    /// the home route.
    ///
    /// Used by ``NotchInteractionReducer`` to lazily materialise a panel the first time any event names a
    /// display it has not seen before, so callers never have to register a display up front.
    static let initial = NotchPanelState(
        presentation: .collapsed,
        locks: [],
        animationGeneration: 0,
        hoverDebouncePending: false,
        exitGracePending: false,
        hoverDebounceGeneration: 0,
        exitGraceGeneration: 0,
        pointerOutsideDuringExpand: false,
        pendingRoute: .home
    )
}
