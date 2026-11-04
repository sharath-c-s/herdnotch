import CoreGraphics
import Testing

@testable import NotchGeometry

@Suite struct HealthLayoutTests {
    static let panels = [
        CGSize(width: 720, height: 320), CGSize(width: 760, height: 432), CGSize(width: 1000, height: 560),
    ]

    @Test(arguments: panels)
    func cardsDoNotOverlapAndStayInsidePanel(panel: CGSize) {
        let layout = HealthLayout(panel: panel)
        let frames = [layout.throttling, layout.improve, layout.shelf]
        let bounds = CGRect(origin: .zero, size: panel)

        for (index, frame) in frames.enumerated() {
            #expect(bounds.contains(frame))
            #expect(frame.minY >= layout.band.maxY)
            for other in frames[(index + 1)...] {
                #expect(!frame.intersects(other))
            }
        }
    }

    @Test(arguments: panels)
    func bandAndShelfMatchBentoSoNothingMovesOnPageSwitch(panel: CGSize) {
        let health = HealthLayout(panel: panel)
        let bento = BentoLayout(panel: panel)

        #expect(health.band == bento.band)
        #expect(health.bandLeftWidget == bento.bandLeftWidget)
        #expect(health.bandRightWidget == bento.bandRightWidget)
        #expect(health.shelf == bento.shelf)
    }

    @Test(arguments: panels)
    func throttlingIsWideLeftImproveIsRightColumnAndBothSitAboveShelf(panel: CGSize) {
        let health = HealthLayout(panel: panel)

        #expect(health.throttling.minX == BentoLayout.margin)
        #expect(health.improve.width == BentoLayout.rightColumnWidth)
        #expect(health.improve.maxX == panel.width - BentoLayout.margin)
        #expect(health.improve.minX - health.throttling.maxX == BentoLayout.gutter)
        #expect(health.throttling.minY == BentoLayout.cardsTop)
        #expect(health.improve.minY == BentoLayout.cardsTop)
        #expect(health.shelf.minY - health.throttling.maxY == BentoLayout.gutter)
        #expect(health.shelf.minY - health.improve.maxY == BentoLayout.gutter)
        #expect(health.throttling.width > health.improve.width)
    }
}
