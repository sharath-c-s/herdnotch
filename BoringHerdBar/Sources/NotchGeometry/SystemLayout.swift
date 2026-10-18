import CoreGraphics

/// The System page's card frames. The band, its two widgets and the shelf come from ``BentoLayout``
/// unchanged, so nothing outside the card area moves when the page switches. Coordinates follow
/// ``BentoLayout``: origin top-left, relative to the panel.
public struct SystemLayout: Equatable, Sendable {
    public let band: CGRect
    public let bandLeftWidget: CGRect
    public let bandRightWidget: CGRect
    public let shelf: CGRect
    /// Left column, top.
    public let nowPlaying: CGRect
    /// Left column, below now playing.
    public let reminders: CGRect
    /// Right column, top.
    public let power: CGRect
    /// Right column, bottom.
    public let keepAwake: CGRect

    public init(panel: CGSize) {
        let bento = BentoLayout(panel: panel)
        band = bento.band
        bandLeftWidget = bento.bandLeftWidget
        bandRightWidget = bento.bandRightWidget
        shelf = bento.shelf

        let cardsBottom = bento.shelf.minY - BentoLayout.gutter
        let cardsHeight = max(0, cardsBottom - BentoLayout.cardsTop)
        let rightX = panel.width - BentoLayout.margin - BentoLayout.rightColumnWidth
        let leftWidth = max(0, rightX - BentoLayout.gutter - BentoLayout.margin)

        // Fixed-height now playing, reminders take the rest, but never taller than half the column.
        let nowPlayingH = max(0, min(BentoLayout.nowPlayingHeight, (cardsHeight - BentoLayout.gutter) / 2))
        nowPlaying = CGRect(x: BentoLayout.margin, y: BentoLayout.cardsTop, width: leftWidth, height: nowPlayingH)
        let remindersY = BentoLayout.cardsTop + nowPlayingH + BentoLayout.gutter
        reminders = CGRect(
            x: BentoLayout.margin, y: remindersY, width: leftWidth, height: max(0, cardsBottom - remindersY))

        // Two equal cards split the column; the gutter sits between them.
        let powerH = max(0, ((cardsHeight - BentoLayout.gutter) / 2).rounded(.down))
        power = CGRect(x: rightX, y: BentoLayout.cardsTop, width: BentoLayout.rightColumnWidth, height: powerH)
        let keepAwakeY = BentoLayout.cardsTop + powerH + BentoLayout.gutter
        keepAwake = CGRect(
            x: rightX, y: keepAwakeY, width: BentoLayout.rightColumnWidth,
            height: max(0, cardsBottom - keepAwakeY))
    }
}

/// Padding, spacing and header visibility of the keep-awake card's content, chosen so its three rows fit
/// without scrolling whenever the regular layout cannot.
public struct KeepAwakeMetrics: Equatable, Sendable {
    public let padding: CGFloat
    public let spacing: CGFloat
    public let showsHeader: Bool

    /// Content height of the three rows (state, lid, agents) plus, when shown, the header.
    public var contentHeight: CGFloat {
        let children = CGFloat(Self.rows) + (showsHeader ? 1 : 0)
        let header = showsHeader ? Self.headerHeight : 0
        return 2 * padding + header + CGFloat(Self.rows) * Self.rowHeight + (children - 1) * spacing
    }

    /// Generous upper bounds for the 13-14 pt content lines, so "fits" errs toward compacting.
    static let rows = 3
    static let rowHeight: CGFloat = 18
    static let headerHeight: CGFloat = 16

    public static let regular = KeepAwakeMetrics(padding: 12, spacing: 5, showsHeader: true)
    public static let compact = KeepAwakeMetrics(padding: 6, spacing: 2, showsHeader: false)

    /// Regular when it fits `cardHeight`, else compact.
    public static func fitting(cardHeight: CGFloat) -> KeepAwakeMetrics {
        regular.contentHeight <= cardHeight ? regular : compact
    }
}
