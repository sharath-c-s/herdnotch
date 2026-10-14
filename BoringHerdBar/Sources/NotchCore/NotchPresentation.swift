import Foundation

/// The open/close lifecycle state of a single display's notch panel, independent of what it is showing.
///
/// Five cases rather than a boolean, because the glitches this whole library exists to prevent all live in
/// the states a boolean cannot represent: an animation that is *in flight* (``expanding(_:)``,
/// ``collapsing``) is a materially different state from one that has *settled* (``expanded(_:)``,
/// ``collapsed``), because only a settled state is safe to treat as the ground truth for "is the pointer
/// supposed to be inside this panel right now". ``suspended`` is separate again, because sleep/wake and a
/// vanished display are not user dismissals and must not run the collapse animation or its exit-grace
/// machinery on the way there.
public enum NotchPresentation: Sendable, Equatable {
    /// The pill is showing and nothing else. The steady state for a panel nobody is using.
    case collapsed

    /// An expand animation is in flight, carrying the ``NotchTrigger`` that started it.
    ///
    /// Distinct from ``expanded(_:)`` so an `animationSettled` that arrives before the animation is even
    /// finished, or with a stale generation, has an unambiguous "not yet" state to leave unchanged.
    case expanding(NotchTrigger)

    /// The panel is fully open and showing `route`.
    case expanded(NotchRoute)

    /// A collapse animation is in flight. The mirror image of ``expanding(_:)``.
    case collapsing

    /// Forced closed by something other than user dismissal: sleep, a vanished display, or an explicit
    /// `suspend` event.
    ///
    /// Kept apart from ``collapsed`` even though both are visually "closed", because resuming from
    /// suspension is a distinct, deliberate transition (``NotchEvent/resume``) rather than something a
    /// stray `hoverIntent` should be able to reach on its own; a panel should not spring back open because
    /// the pointer happened to cross a sleeping machine's lid sensor.
    case suspended
}
