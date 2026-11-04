import CoreGraphics

/// The Health page's card frames: a wide "Throttling" card on the left and an "Improve" card in the
/// right column, above the shelf. Band, widgets and shelf come from ``BentoLayout`` unchanged, so nothing
/// outside the card area moves when the page switches. Coordinates follow ``BentoLayout``.
public struct HealthLayout: Equatable, Sendable {
    public let band: CGRect
    public let bandLeftWidget: CGRect
    public let bandRightWidget: CGRect
    public let shelf: CGRect
    public let throttling: CGRect
    public let improve: CGRect

    public init(panel: CGSize) {
        let bento = BentoLayout(panel: panel)
        band = bento.band
        bandLeftWidget = bento.bandLeftWidget
        bandRightWidget = bento.bandRightWidget
        shelf = bento.shelf

        let cardsBottom = bento.shelf.minY - BentoLayout.gutter
        let cardsHeight = max(0, cardsBottom - BentoLayout.cardsTop)
        let rightX = panel.width - BentoLayout.margin - BentoLayout.rightColumnWidth
        throttling = CGRect(
            x: BentoLayout.margin, y: BentoLayout.cardsTop,
            width: max(0, rightX - BentoLayout.gutter - BentoLayout.margin), height: cardsHeight)
        improve = CGRect(
            x: rightX, y: BentoLayout.cardsTop, width: BentoLayout.rightColumnWidth, height: cardsHeight)
    }
}
