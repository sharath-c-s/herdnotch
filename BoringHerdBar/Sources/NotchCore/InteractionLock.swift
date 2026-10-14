import Foundation

/// A reason dismissal of an expanded panel is currently forbidden, held for as long as the underlying
/// interaction is in progress.
///
/// This is the fix for the specific glitch named in the design review: a scroll-momentum lock releasing
/// after the pointer has already left the panel must not leave the panel stuck open, but the panel must
/// also not collapse *underneath* an in-progress drag, mouse-down, or playlist-picker sheet just because
/// the pointer happens to have wandered outside the hit-testable frame during that interaction. A single
/// `OptionSet` rather than four independent booleans, because the reducer's dismissal check is "is any lock
/// held", not "which lock", and an option set makes that check `!locks.isEmpty` for every combination
/// instead of a chain of `||`.
///
/// Held on ``NotchPanelState``, a value type mutated only on the main actor by the AppKit layer's event
/// loop; ``InteractionLock`` itself carries no shared mutable state and is `Sendable` only because its
/// members require nothing more of a value type.
public struct InteractionLock: OptionSet, Sendable {
    /// The raw bit mask backing this option set, per the `OptionSet` requirement.
    public let rawValue: Int

    /// Creates a lock set from a raw bit mask.
    ///
    /// - Parameter rawValue: The bits to set; normally one of the static members or an OR of several.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The primary mouse button is currently down inside the panel.
    ///
    /// Acquired by ``NotchEvent/pressBegan(_:)`` and released by ``NotchEvent/pressEnded(_:pointerInside:)``,
    /// a pair distinct from `dragBegan`/`dragEnded` so a click-and-hold that has not yet become a recognised
    /// drag still blocks a phantom exit from collapsing the panel under the user's finger.
    public static let mouseDown = InteractionLock(rawValue: 1 << 0)

    /// A drag gesture (for example, scrubbing the Spotify progress bar) is in progress.
    public static let drag = InteractionLock(rawValue: 1 << 1)

    /// A scroll gesture's momentum phase has not yet settled.
    ///
    /// This is the lock the design review calls out by name: momentum scrolling keeps delivering events
    /// after the finger lifts, and a naive "pointer left, start the exit grace" rule fires mid-momentum,
    /// closing the panel while it is still visibly scrolling.
    public static let scrollMomentum = InteractionLock(rawValue: 1 << 2)

    /// The Spotify add-to-playlist picker (a nested search field and list) is open.
    ///
    /// Acquired by ``NotchEvent/playlistPickerOpened(_:)`` and released by
    /// ``NotchEvent/playlistPickerClosed(_:pointerInside:)``. Its own lock rather than reuse of ``mouseDown``
    /// or ``drag``, because the picker can be open with the pointer resting outside the notch panel's own
    /// frame entirely (a search field's suggestion list may render past the panel's edge), and none of the
    /// pointer-driven locks would otherwise cover that.
    public static let playlistPicker = InteractionLock(rawValue: 1 << 3)
}
