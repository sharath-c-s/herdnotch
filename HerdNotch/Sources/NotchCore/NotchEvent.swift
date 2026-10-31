import Foundation

/// Everything that can happen to a notch panel, expressed as data so ``NotchInteractionReducer`` can
/// consume it with no clock, no timer and no I/O of its own.
///
/// Every case below carries the ``NotchDisplayID`` it targets as its first associated value, so
/// `NotchInteractionReducer/reduce(_:)` needs only the event to know which panel to update. This is
/// deliberate: "hover display A while an exit grace is pending on display B" has to be a representable,
/// testable case, and a display identity that lived outside the event (for example, as a second parameter
/// to `reduce`) would be a second source of truth the caller could pass out of sync with whichever timer or
/// tracking area actually produced the event. Timer-shaped events (`hoverDebounceFired`, `exitGraceFired`,
/// `animationSettled`) are always fed back in by the AppKit layer once the corresponding ``NotchEffect``
/// has actually completed; the reducer never assumes time has passed on its own.
public enum NotchEvent: Sendable, Equatable {
    /// The pointer entered the collapsed pill's tracking area, or re-entered a panel with a pending exit
    /// grace or collapse.
    ///
    /// - Parameter display: The panel the pointer entered.
    case hoverIntent(NotchDisplayID)

    /// The hover debounce timer scheduled by ``NotchEffect/scheduleHoverDebounce(generation:)`` ran to
    /// completion without being cancelled by an intervening exit.
    ///
    /// - Parameters:
    ///   - display: The panel whose debounce timer fired.
    ///   - generation: The generation the AppKit layer was handed when the timer was scheduled, echoed back
    ///     unchanged. Compared against ``NotchPanelState/hoverDebounceGeneration``; a mismatch means this
    ///     fire raced a cancel-then-reschedule and is a complete no-op — belt-and-braces alongside the
    ///     `hoverDebouncePending` flag, for the case where the timer object itself was not actually torn
    ///     down in time.
    case hoverDebounceFired(NotchDisplayID, generation: UInt64)

    /// The pointer left the region being watched while a panel was open or opening.
    ///
    /// - Parameters:
    ///   - display: The panel being watched.
    ///   - pointerInside: Whether the pointer is nevertheless still considered inside the panel's
    ///     hit-tested frame (accounting for hysteresis). `false` is what actually starts the exit grace;
    ///     `true` exists because the AppKit layer may deliver this event from a monitor that fires on
    ///     motion generally, not only on true tracking-area exit, and a same-event recheck is simpler than
    ///     requiring the caller to filter it first.
    case hoverExit(NotchDisplayID, pointerInside: Bool)

    /// The exit grace timer scheduled by ``NotchEffect/scheduleExitGrace(generation:)`` ran to completion
    /// without being cancelled by an intervening re-entry.
    ///
    /// - Parameters:
    ///   - display: The panel whose exit grace timer fired.
    ///   - generation: The generation the AppKit layer was handed when the timer was scheduled, echoed back
    ///     unchanged. Compared against ``NotchPanelState/exitGraceGeneration``, same stale-fire protection as
    ///     ``hoverDebounceFired(_:generation:)``.
    case exitGraceFired(NotchDisplayID, generation: UInt64)

    /// The user clicked the collapsed pill.
    ///
    /// - Parameter display: The panel that was clicked.
    case click(NotchDisplayID)

    /// The global hot key fired, targeting the panel the AppKit layer has decided owns it (normally the
    /// pointer's current screen).
    ///
    /// - Parameter display: The panel to toggle.
    case hotkeyToggle(NotchDisplayID)

    /// A drag gesture began inside the panel (for example, the Spotify scrub bar).
    ///
    /// - Parameter display: The panel the drag began in.
    case dragBegan(NotchDisplayID)

    /// A file drag from outside the app entered the panel's collapsed pill.
    ///
    /// Expands a collapsed or collapsing panel with ``NotchTrigger/fileDrag`` and takes the `.drag` lock at
    /// once; released by ``dragEnded(_:pointerInside:)``. While expanded or expanding it only takes the lock.
    ///
    /// - Parameter display: The panel the drag entered.
    case fileDragEntered(NotchDisplayID)

    /// A drag gesture ended.
    ///
    /// - Parameters:
    ///   - display: The panel the drag was in.
    ///   - pointerInside: Whether the pointer is inside the panel's frame now that the drag is over;
    ///     determines whether ending the drag also starts the exit grace.
    case dragEnded(NotchDisplayID, pointerInside: Bool)

    /// A scroll gesture's momentum phase began (`NSEvent.Phase.began` reported `momentumPhase` non-empty).
    ///
    /// - Parameter display: The panel the scroll happened over.
    case scrollMomentumBegan(NotchDisplayID)

    /// A scroll gesture's momentum phase ended.
    ///
    /// - Parameters:
    ///   - display: The panel the scroll happened over.
    ///   - pointerInside: Whether the pointer is inside the panel's frame now that momentum has settled.
    case scrollMomentumEnded(NotchDisplayID, pointerInside: Bool)

    /// The primary mouse button went down inside the panel.
    ///
    /// - Parameter display: The panel the press began in.
    case pressBegan(NotchDisplayID)

    /// The primary mouse button was released.
    ///
    /// - Parameters:
    ///   - display: The panel the press was in.
    ///   - pointerInside: Whether the pointer is inside the panel's frame now that the press is over;
    ///     determines whether releasing also starts the exit grace, same as ``dragEnded(_:pointerInside:)``.
    case pressEnded(NotchDisplayID, pointerInside: Bool)

    /// The Spotify add-to-playlist picker opened.
    ///
    /// - Parameter display: The panel the picker opened in.
    case playlistPickerOpened(NotchDisplayID)

    /// The Spotify add-to-playlist picker closed.
    ///
    /// - Parameters:
    ///   - display: The panel the picker was in.
    ///   - pointerInside: Whether the pointer is inside the panel's frame now that the picker is closed;
    ///     the picker's suggestion list can render past the panel's own edge, so this is not assumed from the
    ///     close alone.
    case playlistPickerClosed(NotchDisplayID, pointerInside: Bool)

    /// Any held ``InteractionLock`` was released by something other than one of the paired begin/end events
    /// above.
    ///
    /// Every lock this reducer knows about now has its own begin/end pair (``dragBegan(_:)``/
    /// ``dragEnded(_:pointerInside:)``, ``scrollMomentumBegan(_:)``/``scrollMomentumEnded(_:pointerInside:)``,
    /// ``pressBegan(_:)``/``pressEnded(_:pointerInside:)``, ``playlistPickerOpened(_:)``/
    /// ``playlistPickerClosed(_:pointerInside:)``), so this event is a generic escape hatch — a defensive
    /// full clear for a lock the AppKit layer released through some path other than its own paired end event
    /// — rather than the primary way any specific lock is released.
    ///
    /// - Parameters:
    ///   - display: The panel the lock was held on.
    ///   - pointerInside: Whether the pointer is inside the panel's frame now that the lock has cleared.
    ///     This is the event the design review calls out: a lock releasing with the pointer already gone
    ///     must be able to start the exit grace immediately, not wait for another hover event that may
    ///     never come.
    case lockReleased(NotchDisplayID, pointerInside: Bool)

    /// The user pressed Escape while a panel was expanded.
    ///
    /// - Parameter display: The expanded panel.
    case escape(NotchDisplayID)

    /// The user asked to switch the expanded panel's content.
    ///
    /// - Parameters:
    ///   - display: The panel to retarget.
    ///   - route: The route to switch to.
    case route(NotchDisplayID, NotchRoute)

    /// The system is going to sleep, this display is about to vanish, or some other reason this panel must
    /// be forced closed without running the normal collapse animation or leaving any timer live.
    ///
    /// - Parameter display: The panel to suspend.
    case suspend(NotchDisplayID)

    /// The system has woken, or the display has returned, and this panel may resume normal operation.
    ///
    /// - Parameter display: The panel to resume.
    case resume(NotchDisplayID)

    /// An expand or collapse animation kicked off by ``NotchEffect/startExpand(generation:)`` or
    /// ``NotchEffect/startCollapse(generation:)`` has finished running.
    ///
    /// - Parameters:
    ///   - display: The panel that was animating.
    ///   - generation: The generation the AppKit layer was told to animate. Compared against the panel's
    ///     in-flight generation so a completion racing a newer, retargeted animation is recognised as stale
    ///     and ignored; see ``NotchInteractionReducer`` for the full contract.
    case animationSettled(NotchDisplayID, generation: UInt64)

    /// The panel this event targets, read from whichever case it is.
    ///
    /// A single accessor rather than a `switch` repeated at every call site inside the reducer, since every
    /// case carries exactly one display identity as its first associated value.
    public var display: NotchDisplayID {
        switch self {
        case .hoverIntent(let display): return display
        case .hoverDebounceFired(let display, _): return display
        case .hoverExit(let display, _): return display
        case .exitGraceFired(let display, _): return display
        case .click(let display): return display
        case .hotkeyToggle(let display): return display
        case .dragBegan(let display): return display
        case .fileDragEntered(let display): return display
        case .dragEnded(let display, _): return display
        case .scrollMomentumBegan(let display): return display
        case .scrollMomentumEnded(let display, _): return display
        case .pressBegan(let display): return display
        case .pressEnded(let display, _): return display
        case .playlistPickerOpened(let display): return display
        case .playlistPickerClosed(let display, _): return display
        case .lockReleased(let display, _): return display
        case .escape(let display): return display
        case .route(let display, _): return display
        case .suspend(let display): return display
        case .resume(let display): return display
        case .animationSettled(let display, _): return display
        }
    }
}
