import CoreGraphics
import Testing

@testable import NotchGeometry

@Suite struct SystemLayoutTests {
    static let panels = [
        CGSize(width: 720, height: 320), CGSize(width: 760, height: 432), CGSize(width: 1000, height: 560),
    ]

    @Test(arguments: panels)
    func cardsDoNotOverlapAndStayInsidePanel(panel: CGSize) {
        let layout = SystemLayout(panel: panel)
        let frames = [layout.usage, layout.power, layout.keepAwake, layout.shelf]
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
        let system = SystemLayout(panel: panel)
        let bento = BentoLayout(panel: panel)

        #expect(system.band == bento.band)
        #expect(system.bandLeftWidget == bento.bandLeftWidget)
        #expect(system.bandRightWidget == bento.bandRightWidget)
        #expect(system.shelf == bento.shelf)
    }

    @Test(arguments: panels)
    func cardsFillTheSameAreaAsBentoCards(panel: CGSize) {
        let system = SystemLayout(panel: panel)
        let bento = BentoLayout(panel: panel)

        #expect(system.usage == bento.agents)
        #expect(system.power.minX == bento.nowPlaying.minX)
        #expect(system.power.width == BentoLayout.rightColumnWidth)
        #expect(system.keepAwake.width == BentoLayout.rightColumnWidth)
        #expect(system.power.minY == BentoLayout.cardsTop)
        #expect(system.keepAwake.minY - system.power.maxY == BentoLayout.gutter)
        #expect(system.shelf.minY - system.keepAwake.maxY == BentoLayout.gutter)
    }

    @Test func minimumSizeSplitsTheRightColumnEvenly() {
        let layout = SystemLayout(panel: CGSize(width: 720, height: 320))

        #expect(layout.power == CGRect(x: 452, y: 54, width: 252, height: 75))
        #expect(layout.keepAwake == CGRect(x: 452, y: 141, width: 252, height: 75))
    }

    @Test(arguments: panels)
    func keepAwakeRowsFitWithoutScrollingAtEverySize(panel: CGSize) {
        let layout = SystemLayout(panel: panel)
        let metrics = KeepAwakeMetrics.fitting(cardHeight: layout.keepAwake.height)

        #expect(metrics.contentHeight <= layout.keepAwake.height)
    }

    @Test func minimumSizeCompactsTheKeepAwakeCardAndLargerKeepsTheHeader() {
        let small = SystemLayout(panel: CGSize(width: 720, height: 320))
        let large = SystemLayout(panel: CGSize(width: 1000, height: 560))

        #expect(KeepAwakeMetrics.fitting(cardHeight: small.keepAwake.height) == .compact)
        #expect(KeepAwakeMetrics.fitting(cardHeight: large.keepAwake.height) == .regular)
    }
}
