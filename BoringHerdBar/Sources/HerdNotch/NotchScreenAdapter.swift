import AppKit
import CoreGraphics
import Foundation
import NotchGeometry

/// Translates a live `NSScreen` into the plain values `NotchCore` and `NotchGeometry` need, and nothing
/// more.
///
/// Both of those libraries are deliberately AppKit-free so their rules are testable with hand-built
/// numbers; this type is the thin, un-tested seam where a real window server value is read once and
/// converted into the value type the pure libraries actually consume. It has no state of its own and no
/// side effects, so "thin, pure-ish adapter" is a description of its shape, not a promise it is covered by
/// the same unit tests `NotchGeometryTests` already runs against hand-built `ScreenMetrics`.
enum NotchScreenAdapter {

    /// Reads the stable per-display identity AppKit hides inside a bag of loosely-typed device
    /// description values.
    ///
    /// `NotchCore` keys every panel's state on this identity rather than `NSScreen` object identity,
    /// because `NSScreen` instances are recreated on every `didChangeScreenParametersNotification` (even
    /// when the underlying physical display has not changed at all), which would make "the same display"
    /// unrecognisable across a reconcile pass.
    ///
    /// - Parameter screen: The screen to identify.
    /// - Returns: The display's `CGDirectDisplayID`, or `nil` if AppKit did not populate the
    ///   `NSScreenNumber` key (observed only for a screen that is already in the process of vanishing).
    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard
            let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber
        else {
            return nil
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }

    /// Snapshots the geometry-relevant state of `screen` into a `ScreenMetrics` value.
    ///
    /// This is called on every reconcile, never cached, because the whole point of `ScreenMetrics` is
    /// that the same physical display can report a different snapshot from one call to the next —
    /// mirroring or a scaled resolution zeroes `safeAreaTop` and the auxiliary areas on an otherwise
    /// notched MacBook, which is exactly the dynamic reclassification `NotchGeometry` exists to handle.
    ///
    /// ``ScreenMetrics/menuBarAutoHides`` has no direct AppKit accessor, so it is derived rather than read:
    /// when "Automatically hide and show the menu bar" is on, macOS reserves no permanent menu-bar space,
    /// so `visibleFrame`'s top edge coincides with `frame`'s top edge. That is precisely the condition
    /// `NotchGeometry`'s pill-height fallback needs to detect, so comparing the two edges (with a small
    /// tolerance for floating-point noise) is a faithful proxy rather than an approximation of a different
    /// question.
    ///
    /// - Parameter screen: The screen to snapshot.
    /// - Returns: The `ScreenMetrics` value `NotchGeometry.layout(for:expandedSize:)` classifies.
    static func metrics(for screen: NSScreen) -> ScreenMetrics {
        let frame = screen.frame
        let visibleFrame = screen.visibleFrame
        let menuBarAutoHides = abs(frame.maxY - visibleFrame.maxY) < 0.5
        return ScreenMetrics(
            frame: frame,
            visibleFrame: visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
            auxiliaryTopRight: screen.auxiliaryTopRightArea,
            menuBarAutoHides: menuBarAutoHides
        )
    }
}
