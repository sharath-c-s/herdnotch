import CoreGraphics

/// The pure classifier that decides, per display and per current configuration, whether to draw a real
/// notch or a floating pill, and where the collapsed and expanded frames sit.
///
/// `NotchGeometry` takes only ``ScreenMetrics`` (plain values) in and returns only ``NotchLayout``
/// (plain values) out. It imports CoreGraphics for `CGRect`/`CGFloat`/`CGSize` and nothing else — no
/// AppKit, no `NSScreen`, no window server — so every rule below is testable with hand-built numbers.
/// The AppKit layer's job is a thin adapter: read the live `NSScreen` fields into a ``ScreenMetrics``,
/// call ``layout(for:expandedSize:)``, and hand the two frames to a window.
public enum NotchGeometry {

    /// The width of the synthesized pill in the ``NotchKind/pill`` case, before the middle-third clamp
    /// in ``layout(for:expandedSize:)`` is applied.
    ///
    /// 200pt is a starting point sized to comfortably hold the collapsed pill's contents while staying
    /// well inside the display's middle third on every display this app has been built for; the clamp is
    /// what actually guarantees no overlap with the app menu or status items on narrower displays.
    public static let defaultPillWidth: CGFloat = 200

    /// The pill's height when the real menu-bar height cannot be derived because
    /// ``ScreenMetrics/menuBarAutoHides`` is `true` (auto-hide reserves no permanent menu-bar space, so
    /// `frame.maxY - visibleFrame.maxY` is `0` and useless as a height).
    ///
    /// 24pt matches the height of a non-notched Mac's default menu bar, which is the closest sane
    /// approximation available without a reserved region to measure.
    public static let fallbackMenuBarHeight: CGFloat = 24

    /// The corner radius applied to the expanded presentation's rounded corners. See
    /// ``NotchLayout/cornerRadius``.
    public static let expandedCornerRadius: CGFloat = 12

    /// Classifies `metrics` and computes both the collapsed and expanded frames for the resulting
    /// silhouette.
    ///
    /// ## Classification
    ///
    /// The display is ``NotchKind/notched`` only when **both** ``ScreenMetrics/safeAreaTop`` is greater
    /// than `0` **and** both ``ScreenMetrics/auxiliaryTopLeft`` and ``ScreenMetrics/auxiliaryTopRight``
    /// are non-`nil`. Every other combination — including a notched MacBook that is currently mirroring
    /// another display or running a scaled resolution, where AppKit itself stops reporting the inset and
    /// the auxiliary areas — classifies as ``NotchKind/pill``. This check runs on every call rather than
    /// being cached against a hardware fact, precisely because that combination is the dynamic,
    /// per-configuration signal the whole library exists to get right: a notched Mac that has
    /// (temporarily) gone notchless must draw the pill, not crash or draw a phantom notch-shaped hole.
    ///
    /// ## Collapsed frame, notched
    ///
    /// The exact camera-housing rectangle: horizontally the gap between `auxiliaryTopLeft.maxX` and
    /// `auxiliaryTopRight.minX`, height `safeAreaTop`, top edge pinned to `frame.maxY` (the display's
    /// physical top edge, not `visibleFrame.maxY` — using the visible frame would move the notch every
    /// time the menu bar auto-hides, when the physical cutout obviously never moves). If the two
    /// auxiliary rects overlap or leave a zero-width gap (a malformed or degenerate report), the width is
    /// clamped to `0` rather than going negative, so the result is always a valid, non-crashing `CGRect`.
    ///
    /// ## Collapsed frame, pill
    ///
    /// A fixed-size pill, ``defaultPillWidth`` wide, centered on `frame.midX`, then clamped so it never
    /// extends past `frame.width / 3` — the boundary of the display's own middle third — which keeps it
    /// clear of the left-hand app menu and the right-hand status items by construction, on any display
    /// width, without needing to know the actual size of either. Its height is the menu bar's reserved
    /// height (`frame.maxY - visibleFrame.maxY`) when ``ScreenMetrics/menuBarAutoHides`` is `false`, or
    /// ``fallbackMenuBarHeight`` when it is `true` (there is no reserved region to measure in that case).
    /// Its top edge, like the notched case, is pinned to `frame.maxY`.
    ///
    /// ## Expanded frame, both kinds
    ///
    /// Width is `expandedSize.width` clamped to `frame.width` (never wider than the display), height is
    /// `expandedSize.height` unclamped, centered horizontally on `frame.midX`, top edge pinned to
    /// `frame.maxY` and growing downward. This is a geometric target only: creating a fixed-size window
    /// there and animating a layer mask between the two frames is the AppKit layer's responsibility.
    ///
    /// - Parameters:
    ///   - metrics: The display's current geometry-relevant state.
    ///   - expandedSize: The desired size of the expanded presentation.
    /// - Returns: The classified ``NotchLayout`` for `metrics`.
    public static func layout(for metrics: ScreenMetrics, expandedSize: CGSize) -> NotchLayout {
        let kind = classify(metrics)
        let collapsedFrame: CGRect
        switch kind {
        case .notched:
            collapsedFrame = notchedCollapsedFrame(metrics)
        case .pill:
            collapsedFrame = pillCollapsedFrame(metrics)
        }
        return NotchLayout(
            kind: kind,
            collapsedFrame: collapsedFrame,
            expandedFrame: expandedFrame(metrics, expandedSize: expandedSize),
            cornerRadius: expandedCornerRadius
        )
    }

    /// Applies the classification rule documented on ``layout(for:expandedSize:)``.
    private static func classify(_ metrics: ScreenMetrics) -> NotchKind {
        guard
            metrics.safeAreaTop > 0,
            metrics.auxiliaryTopLeft != nil,
            metrics.auxiliaryTopRight != nil
        else {
            return .pill
        }
        return .notched
    }

    /// Builds the notched collapsed frame documented on ``layout(for:expandedSize:)``.
    ///
    /// Precondition: only called after ``classify(_:)`` returned `.notched`, so both auxiliary rects are
    /// known non-`nil`; force-unwrapping here reflects that invariant rather than re-deriving it.
    private static func notchedCollapsedFrame(_ metrics: ScreenMetrics) -> CGRect {
        let left = metrics.auxiliaryTopLeft!
        let right = metrics.auxiliaryTopRight!
        let minX = min(left.maxX, right.minX)
        let width = max(0, right.minX - left.maxX)
        let height = metrics.safeAreaTop
        return CGRect(x: minX, y: metrics.frame.maxY - height, width: width, height: height)
    }

    /// Builds the pill collapsed frame documented on ``layout(for:expandedSize:)``.
    private static func pillCollapsedFrame(_ metrics: ScreenMetrics) -> CGRect {
        let menuBarHeight = metrics.menuBarAutoHides
            ? fallbackMenuBarHeight
            : max(0, metrics.frame.maxY - metrics.visibleFrame.maxY)
        let middleThirdWidth = metrics.frame.width / 3
        let width = min(defaultPillWidth, middleThirdWidth)
        let x = metrics.frame.midX - width / 2
        let y = metrics.frame.maxY - menuBarHeight
        return CGRect(x: x, y: y, width: width, height: menuBarHeight)
    }

    /// Builds the expanded frame documented on ``layout(for:expandedSize:)``, shared by both kinds.
    private static func expandedFrame(_ metrics: ScreenMetrics, expandedSize: CGSize) -> CGRect {
        let width = min(expandedSize.width, metrics.frame.width)
        let height = min(expandedSize.height, max(0, metrics.frame.height - 40))
        let x = metrics.frame.midX - width / 2
        let y = metrics.frame.maxY - height
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
