import CoreGraphics
import Testing

@testable import NotchGeometry

@Suite struct BentoLayoutTests {

    @Test func defaultSizeFrames() {
        let layout = BentoLayout(panel: CGSize(width: 760, height: 432))

        #expect(layout.band == CGRect(x: 0, y: 0, width: 760, height: 44))
        #expect(layout.agents == CGRect(x: 16, y: 54, width: 416, height: 274))
        #expect(layout.usage == CGRect(x: 444, y: 54, width: 300, height: 274))
        #expect(layout.shelf == CGRect(x: 16, y: 340, width: 728, height: 76))
    }

    @Test func minimumSizeFrames() {
        let layout = BentoLayout(panel: CGSize(width: 720, height: 320))

        #expect(layout.agents == CGRect(x: 16, y: 54, width: 376, height: 162))
        #expect(layout.usage == CGRect(x: 404, y: 54, width: 300, height: 162))
        #expect(layout.shelf == CGRect(x: 16, y: 228, width: 688, height: 76))
    }

    /// One usage row: 78 label + 46 percent + 56 reset + 3 gaps of 8, plus the card's 12pt padding each side.
    @Test(arguments: [
        CGSize(width: 720, height: 320), CGSize(width: 760, height: 432), CGSize(width: 1000, height: 560),
    ])
    func usageColumnFitsRowsWithABarAndAgentsStayReadable(panel: CGSize) {
        let layout = BentoLayout(panel: panel)
        let fixedRowWidth: CGFloat = 78 + 46 + 56 + 3 * 8 + 2 * 12

        #expect(layout.usage.width - fixedRowWidth >= 60)
        #expect(layout.agents.width >= 376)
    }

    @Test(arguments: [720, 760, 1000])
    func bandWidgetsStayClearOfCentredNotchZone(width: Int) {
        let layout = BentoLayout(panel: CGSize(width: CGFloat(width), height: 320))
        let notch = CGRect(x: CGFloat(width) / 2 - 100, y: 0, width: 200, height: 36)

        #expect(!layout.bandLeftWidget.intersects(notch))
        #expect(!layout.bandRightWidget.intersects(notch))
        #expect(layout.band.contains(layout.bandLeftWidget))
        #expect(layout.band.contains(layout.bandRightWidget))
    }

    @Test(arguments: [
        CGSize(width: 720, height: 320), CGSize(width: 760, height: 432),
        CGSize(width: 1000, height: 560), CGSize(width: 720, height: 432),
    ])
    func framesDoNotOverlapAndStayInsidePanel(panel: CGSize) {
        let layout = BentoLayout(panel: panel)
        let cards = [layout.agents, layout.usage, layout.shelf]
        let bounds = CGRect(origin: .zero, size: panel)

        for (index, frame) in cards.enumerated() {
            #expect(bounds.contains(frame))
            #expect(frame.minY >= layout.band.maxY)
            for other in cards[(index + 1)...] {
                #expect(!frame.intersects(other))
            }
        }
        #expect(bounds.contains(layout.band))
    }

    @Test func shelfSitsAtTheBottomInsideTheMargin() {
        let layout = BentoLayout(panel: CGSize(width: 800, height: 480))

        #expect(layout.shelf.maxY == 480 - BentoLayout.margin)
        #expect(layout.shelf.height == BentoLayout.shelfHeight)
        #expect(layout.shelf.minX == BentoLayout.margin)
        #expect(layout.shelf.maxX == 800 - BentoLayout.margin)
        #expect(layout.agents.maxY + BentoLayout.gutter == layout.shelf.minY)
    }
}
