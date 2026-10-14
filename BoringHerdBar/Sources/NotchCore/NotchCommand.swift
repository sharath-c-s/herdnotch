import Foundation

/// One ``NotchEffect`` the caller must perform, tagged with the ``NotchDisplayID`` it targets.
///
/// This is the reducer's actual return type, replacing a bare `[NotchEffect]` that was implicitly scoped to
/// whichever display the triggering ``NotchEvent`` named. That implicit scoping could not express the one
/// cross-panel transition this reducer enforces — the at-most-one-expanded invariant forcing some *other*
/// display's panel into ``NotchPresentation/collapsing`` — without either lying about which display an
/// effect belonged to, or requiring the caller to separately diff ``NotchInteractionReducer/panels`` after
/// every call to notice a display the returned effects never mentioned.
///
/// `NotchCommand` closes that gap: every command names its own display, so
/// `NotchInteractionReducer/reduce(_:)` can return a genuinely complete instruction list — the event's own
/// display *and* any other display the at-most-one-expanded invariant just forced to collapse — in one
/// array. The AppKit controller's job becomes "for each command, dispatch `command.effect` to the panel
/// keyed by `command.display`", a dumb per-display executor with no reconciliation pass over `panels`
/// required. See ``NotchInteractionReducer`` for the full contract this enables.
public struct NotchCommand: Sendable, Equatable {
    /// The display this command's effect must be carried out on.
    ///
    /// Not necessarily the display named by the event that produced it: a command in this position can name
    /// another display entirely, when the at-most-one-expanded invariant forced that display's panel to
    /// start collapsing in the same `reduce(_:)` call.
    public let display: NotchDisplayID

    /// The side effect the caller must perform for ``display``.
    public let effect: NotchEffect

    /// Creates a command pairing an effect with the display it targets.
    ///
    /// - Parameters:
    ///   - display: The display the effect must be carried out on.
    ///   - effect: The side effect to perform.
    public init(display: NotchDisplayID, effect: NotchEffect) {
        self.display = display
        self.effect = effect
    }
}
