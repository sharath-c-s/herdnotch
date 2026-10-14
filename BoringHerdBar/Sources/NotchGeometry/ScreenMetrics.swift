import CoreGraphics

/// Everything ``NotchGeometry`` needs to know about one display, captured as plain values.
///
/// `ScreenMetrics` exists so the classifier never touches `NSScreen`: an `NSScreen` is a live handle
/// into the window server, it cannot be constructed in a unit test, and its `auxiliaryTopLeftArea` /
/// `auxiliaryTopRightArea` / `safeAreaInsets` are exactly the fields that go stale or report zero the
/// moment a notched MacBook is mirrored to an external display or dropped into certain scaled
/// resolutions — the headline risk this whole library exists to make testable. By copying those fields
/// out into a value type at the AppKit boundary, every classification rule below becomes an ordinary
/// value-in, value-out function that a test can drive with numbers instead of a real screen.
///
/// All rects are in **global screen coordinates with a bottom-left origin** (the same space
/// `NSScreen.frame` and `NSScreen.visibleFrame` already use), so `maxY` is always the physical top edge
/// of the display and `minY` the physical bottom, regardless of how many displays are arranged above or
/// below one another.
public struct ScreenMetrics: Sendable, Equatable {

    /// The display's full frame, top to bottom, edge to edge, in global bottom-left-origin coordinates.
    ///
    /// This is the frame to pin collapsed geometry to (`frame.maxY`), never `visibleFrame.maxY`: see
    /// ``menuBarAutoHides`` for why the visible frame's top edge moves and the physical frame's does not.
    public let frame: CGRect

    /// The display's frame with the menu bar and Dock subtracted, in the same coordinate space as
    /// ``frame``.
    ///
    /// Used only to *derive* the menu-bar height for the pill layout (`frame.maxY - visibleFrame.maxY`)
    /// when the menu bar is known to be reserving space; it is deliberately never used to place the top
    /// edge of a collapsed frame, because that top edge would then jump every time the menu bar
    /// auto-hides and un-hides.
    public let visibleFrame: CGRect

    /// The height, in points, of the notch's safe-area inset at the top of the display, or `0` when
    /// the display is not currently presenting a physical notch cutout — including a genuinely
    /// notchless display, a notched MacBook whose panel is mirroring another display, and a notched
    /// MacBook running a scaled (non-native) resolution where AppKit stops reporting the inset.
    ///
    /// This is intentionally a dynamic, per-configuration value rather than a static "this Mac model has
    /// a notch" fact: the same physical MacBook display can report a positive inset one moment and `0`
    /// the next, purely because of a display-mode change the user made in System Settings. See
    /// ``NotchGeometry/layout(for:expandedSize:)`` for how that reclassifies the layout on the fly.
    public let safeAreaTop: CGFloat

    /// The menu-bar-height rectangle to the left of the physical notch cutout, or `nil` whenever
    /// ``safeAreaTop`` is `0` for any of the reasons documented there.
    public let auxiliaryTopLeft: CGRect?

    /// The menu-bar-height rectangle to the right of the physical notch cutout, or `nil` whenever
    /// ``safeAreaTop`` is `0` for any of the reasons documented there.
    public let auxiliaryTopRight: CGRect?

    /// Whether "Automatically hide and show the menu bar" is on for this display.
    ///
    /// When `true`, macOS reserves no permanent menu-bar space, so `frame.maxY - visibleFrame.maxY` is
    /// `0` and cannot be used to size the pill's height; ``NotchGeometry`` falls back to a fixed default
    /// in that case instead. See ``NotchGeometry/fallbackMenuBarHeight``.
    public let menuBarAutoHides: Bool

    /// Creates a snapshot of one display's geometry-relevant state.
    ///
    /// - Parameters:
    ///   - frame: The display's full frame (global, bottom-left origin).
    ///   - visibleFrame: The display's frame minus the menu bar and Dock, same coordinate space.
    ///   - safeAreaTop: The notch safe-area inset height, or `0` when no notch is currently presented.
    ///   - auxiliaryTopLeft: The rect left of the notch cutout, or `nil` when no notch is presented.
    ///   - auxiliaryTopRight: The rect right of the notch cutout, or `nil` when no notch is presented.
    ///   - menuBarAutoHides: Whether the menu bar auto-hides on this display.
    public init(
        frame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryTopLeft: CGRect?,
        auxiliaryTopRight: CGRect?,
        menuBarAutoHides: Bool
    ) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeft = auxiliaryTopLeft
        self.auxiliaryTopRight = auxiliaryTopRight
        self.menuBarAutoHides = menuBarAutoHides
    }
}
