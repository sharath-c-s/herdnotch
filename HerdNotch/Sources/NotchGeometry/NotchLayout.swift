import CoreGraphics

/// Which of the two panel silhouettes ``NotchGeometry`` chose for a display, right now.
///
/// This is a per-classification result, not a per-Mac-model fact: the exact same physical MacBook
/// display can flip between the two cases from one call to the next, because ``NotchGeometry`` reads
/// live ``ScreenMetrics`` rather than a hardware identifier. See
/// ``NotchGeometry/layout(for:expandedSize:)`` for the classification rule.
public enum NotchKind: Sendable, Equatable {

    /// The display currently presents a physical notch cutout: the collapsed frame is the real
    /// camera-housing rectangle between the two auxiliary safe areas, not a synthesized shape.
    case notched

    /// The display currently presents no physical notch cutout — whether because it never has one, or
    /// because a notched MacBook has temporarily stopped reporting one (mirroring, a scaled resolution).
    /// The collapsed frame is a synthesized floating pill instead.
    case pill
}

/// The geometric result of classifying one display: which silhouette to draw, and the two frames that
/// silhouette occupies collapsed and expanded.
///
/// Every frame here is in the same **global, bottom-left-origin** coordinate space as the
/// ``ScreenMetrics`` it was computed from (i.e. `NSScreen.frame`'s space), so callers can hand these
/// rects straight to `NSWindow.setFrame(_:display:)` without a coordinate flip.
///
/// `NotchLayout` describes a geometric target, not an animation. Producing a fixed-size window at
/// `expandedFrame` and animating a layer mask between the two frames is the AppKit layer's job; this
/// type only says where the two endpoints are.
public struct NotchLayout: Sendable, Equatable {

    /// Which silhouette this layout is for. Determines how ``collapsedFrame`` was derived: the real
    /// notch gap for ``NotchKind/notched``, a synthesized pill for ``NotchKind/pill``.
    public let kind: NotchKind

    /// The frame of the small, always-visible collapsed presentation.
    ///
    /// For ``NotchKind/notched``, this is the exact rectangle of the physical camera-housing cutout: its
    /// top edge is the physical top of the display. For ``NotchKind/pill``, this is a synthesized
    /// floating pill of fixed size, also pinned to the physical top of the display, sized and positioned
    /// so it cannot overlap the left-hand app menu or the right-hand status items.
    ///
    /// The top edge of this frame is always pinned to the display's physical top edge (`frame.maxY` on
    /// the ``ScreenMetrics`` it was computed from), never to `visibleFrame.maxY`, so a menu bar that
    /// auto-hides and un-hides never moves the collapsed frame.
    public let collapsedFrame: CGRect

    /// The frame of the panel when a user interaction has expanded it.
    ///
    /// Centered horizontally on the display's midpoint, with its top edge pinned to the same physical
    /// top edge as ``collapsedFrame`` (`frame.maxY`), growing downward. This is a geometric target, not
    /// a live animation frame: the caller creates a fixed-size window here and animates between
    /// ``collapsedFrame`` and this rect with a layer mask.
    public let expandedFrame: CGRect

    /// The corner radius to apply to the expanded panel's rounded corners.
    ///
    /// Only the expanded presentation uses this: the notched collapsed frame is a sharp-cornered
    /// rectangle (it has to exactly match the physical cutout, which has no rounding to speak of at this
    /// scale), and the pill collapsed frame's rounding is a simple function of its own height rather than
    /// a value that needs to travel with the layout. See ``NotchGeometry/expandedCornerRadius``.
    public let cornerRadius: CGFloat

    /// Creates a layout result. Public so tests can build expected values without calling
    /// ``NotchGeometry`` twice.
    ///
    /// - Parameters:
    ///   - kind: Which silhouette this layout represents.
    ///   - collapsedFrame: The collapsed presentation's frame (global, bottom-left origin).
    ///   - expandedFrame: The expanded presentation's frame (global, bottom-left origin).
    ///   - cornerRadius: The corner radius for the expanded presentation.
    public init(kind: NotchKind, collapsedFrame: CGRect, expandedFrame: CGRect, cornerRadius: CGFloat) {
        self.kind = kind
        self.collapsedFrame = collapsedFrame
        self.expandedFrame = expandedFrame
        self.cornerRadius = cornerRadius
    }
}
