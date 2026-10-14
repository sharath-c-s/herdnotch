import CoreGraphics
import Testing

@testable import NotchGeometry

/// Tests for the pure notch-vs-pill classifier.
///
/// Every metrics value here is hand-built rather than read from a real `NSScreen`, because the whole
/// point of `NotchGeometry` being pure CoreGraphics-over-values is that the headline risk — a notched
/// MacBook classifying as notchless the moment it is mirrored or scaled — is reproducible with plain
/// numbers and no window server. Frames use the same global, bottom-left-origin coordinate space
/// `ScreenMetrics` documents throughout.
@Suite struct NotchGeometryTests {

    /// A typical built-in notched MacBook display: 1512x982 points, a 37pt-tall notch safe area centered
    /// in a 192pt gap between the two auxiliary areas.
    private func notchedBuiltInDisplay() -> ScreenMetrics {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 945)
        let auxiliaryTopLeft = CGRect(x: 0, y: 945, width: 660, height: 37)
        let auxiliaryTopRight = CGRect(x: 852, y: 945, width: 660, height: 37)
        return ScreenMetrics(
            frame: frame,
            visibleFrame: visibleFrame,
            safeAreaTop: 37,
            auxiliaryTopLeft: auxiliaryTopLeft,
            auxiliaryTopRight: auxiliaryTopRight,
            menuBarAutoHides: false
        )
    }

    // MARK: - 1. Notched MacBook

    @Test func notchedDisplayClassifiesAsNotchedWithGapAsCollapsedFrame() {
        let metrics = notchedBuiltInDisplay()

        let layout = NotchGeometry.layout(for: metrics, expandedSize: CGSize(width: 400, height: 500))

        #expect(layout.kind == .notched)
        #expect(layout.collapsedFrame == CGRect(x: 660, y: 945, width: 192, height: 37))
        #expect(layout.collapsedFrame.maxY == metrics.frame.maxY)
    }

    // MARK: - 2. Same physical display, mirrored/scaled — the headline risk

    @Test func mirroredOrScaledNotchedDisplayReclassifiesAsPill() {
        let notched = notchedBuiltInDisplay()
        // Same physical display, but AppKit itself has stopped reporting the inset and the auxiliary
        // areas, exactly as it does while mirroring or on some scaled (non-native) resolutions.
        let mirrored = ScreenMetrics(
            frame: notched.frame,
            visibleFrame: notched.visibleFrame,
            safeAreaTop: 0,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil,
            menuBarAutoHides: false
        )

        let layout = NotchGeometry.layout(for: mirrored, expandedSize: CGSize(width: 400, height: 500))

        #expect(layout.kind == .pill)
    }

    // MARK: - 3. External notchless monitor

    @Test func externalNotchlessMonitorProducesPillClearOfLeftThird() {
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1920, height: 1055)
        let metrics = ScreenMetrics(
            frame: frame,
            visibleFrame: visibleFrame,
            safeAreaTop: 0,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil,
            menuBarAutoHides: false
        )

        let layout = NotchGeometry.layout(for: metrics, expandedSize: CGSize(width: 400, height: 500))
        let derivedMenuBarHeight = frame.maxY - visibleFrame.maxY

        #expect(layout.kind == .pill)
        #expect(layout.collapsedFrame.height <= derivedMenuBarHeight)
        #expect(layout.collapsedFrame.minX >= frame.width / 3)
        #expect(layout.collapsedFrame.maxX <= frame.width * 2 / 3)
    }

    // MARK: - 4. Menu-bar auto-hide

    @Test func autoHidingMenuBarStillProducesSaneHeightPinnedToPhysicalTop() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        // Auto-hide reserves no menu-bar space, so the visible frame's top matches the physical top;
        // only the Dock (at the bottom) is subtracted.
        let visibleFrame = CGRect(x: 0, y: 80, width: 1512, height: 902)
        let metrics = ScreenMetrics(
            frame: frame,
            visibleFrame: visibleFrame,
            safeAreaTop: 0,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil,
            menuBarAutoHides: true
        )

        let layout = NotchGeometry.layout(for: metrics, expandedSize: CGSize(width: 400, height: 500))

        #expect(layout.kind == .pill)
        #expect(layout.collapsedFrame.height == NotchGeometry.fallbackMenuBarHeight)
        #expect(layout.collapsedFrame.maxY == frame.maxY)
    }

    // MARK: - 5. Expanded frame

    @Test func expandedFrameIsCenteredPinnedToTopAndGrowsDownward() {
        let metrics = notchedBuiltInDisplay()

        let layout = NotchGeometry.layout(for: metrics, expandedSize: CGSize(width: 400, height: 500))

        #expect(layout.expandedFrame.width == 400)
        #expect(layout.expandedFrame.height == 500)
        #expect(layout.expandedFrame.midX == metrics.frame.midX)
        #expect(layout.expandedFrame.maxY == metrics.frame.maxY)
        #expect(layout.expandedFrame.minY == metrics.frame.maxY - 500)
    }

    @Test func expandedFrameWidthIsClampedToDisplayWidth() {
        let metrics = notchedBuiltInDisplay()

        let layout = NotchGeometry.layout(for: metrics, expandedSize: CGSize(width: 5000, height: 500))

        #expect(layout.expandedFrame.width == metrics.frame.width)
        #expect(layout.expandedFrame.midX == metrics.frame.midX)
    }

    @Test func expandedFrameHeightIsClampedToDisplayHeightMinus40() {
        let metrics = notchedBuiltInDisplay()

        let layout = NotchGeometry.layout(for: metrics, expandedSize: CGSize(width: 400, height: 5000))

        #expect(layout.expandedFrame.height == metrics.frame.height - 40)
        #expect(layout.expandedFrame.maxY == metrics.frame.maxY)
    }

    // MARK: - 6. Degenerate metrics guard

    @Test func overlappingAuxiliaryAreasClampToZeroWidthInsteadOfNegative() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 945)
        // A malformed report: the "left" auxiliary extends past where the "right" one begins.
        let auxiliaryTopLeft = CGRect(x: 0, y: 945, width: 900, height: 37)
        let auxiliaryTopRight = CGRect(x: 850, y: 945, width: 662, height: 37)
        let metrics = ScreenMetrics(
            frame: frame,
            visibleFrame: visibleFrame,
            safeAreaTop: 37,
            auxiliaryTopLeft: auxiliaryTopLeft,
            auxiliaryTopRight: auxiliaryTopRight,
            menuBarAutoHides: false
        )

        let layout = NotchGeometry.layout(for: metrics, expandedSize: CGSize(width: 400, height: 500))

        #expect(layout.kind == .notched)
        #expect(layout.collapsedFrame.width == 0)
        #expect(layout.collapsedFrame.width >= 0)
    }
}
