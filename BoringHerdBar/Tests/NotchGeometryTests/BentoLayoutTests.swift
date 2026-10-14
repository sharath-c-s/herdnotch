import CoreGraphics
import Testing

@testable import NotchGeometry

@Suite struct BentoLayoutTests {

    @Test func reproducesPreviousHardCodedFrames() {
        // Old panel was 720x344 with no shelf; 344 + 88 (shelf 76 + gutter 12) is the same card area.
        let layout = BentoLayout(panel: CGSize(width: 720, height: 344 + 88))

        #expect(layout.band == CGRect(x: 0, y: 0, width: 720, height: 44))
        #expect(layout.agents == CGRect(x: 16, y: 54, width: 424, height: 274))
        #expect(layout.nowPlaying == CGRect(x: 452, y: 54, width: 252, height: 128))
        #expect(layout.reminders == CGRect(x: 452, y: 194, width: 252, height: 134))
    }

    @Test func defaultSizeFrames() {
        let layout = BentoLayout(panel: CGSize(width: 760, height: 432))

        #expect(layout.agents == CGRect(x: 16, y: 54, width: 464, height: 274))
        #expect(layout.nowPlaying == CGRect(x: 492, y: 54, width: 252, height: 128))
        #expect(layout.reminders == CGRect(x: 492, y: 194, width: 252, height: 134))
        #expect(layout.shelf == CGRect(x: 16, y: 340, width: 728, height: 76))
    }

    @Test func minimumSizeFrames() {
        let layout = BentoLayout(panel: CGSize(width: 720, height: 320))

        #expect(layout.agents == CGRect(x: 16, y: 54, width: 424, height: 162))
        #expect(layout.nowPlaying == CGRect(x: 452, y: 54, width: 252, height: 75))
        #expect(layout.reminders == CGRect(x: 452, y: 141, width: 252, height: 75))
        #expect(layout.shelf == CGRect(x: 16, y: 228, width: 688, height: 76))
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
        let cards = [layout.agents, layout.nowPlaying, layout.reminders, layout.shelf]
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
