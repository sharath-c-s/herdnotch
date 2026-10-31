import CoreGraphics

/// The expanded notch panel's card frames, derived from the panel size. Coordinates are SwiftUI-style:
/// origin top-left, y growing down, relative to the panel's own bounds.
///
/// The Herd page: agents card on the left, usage card in a full-height right column.
public struct BentoLayout: Equatable, Sendable {
    public static let margin: CGFloat = 16
    public static let gutter: CGFloat = 12
    public static let bandHeight: CGFloat = 44
    public static let cardsTop: CGFloat = 54
    /// The System page's right column (power, keep awake).
    public static let rightColumnWidth: CGFloat = 252
    /// The Herd page's right column: wide enough for a usage row (78 label, bar, 46 percent, 56 reset, 8 spacing, 12 padding).
    public static let usageColumnWidth: CGFloat = 300
    public static let nowPlayingHeight: CGFloat = 128
    public static let shelfHeight: CGFloat = 76

    /// The full-width utility band.
    public let band: CGRect
    /// Clock/date flank and caffeinate/settings flank inside the band. They stay clear of a centred
    /// 200pt notch zone only from a 720pt panel width up.
    public let bandLeftWidget: CGRect
    public let bandRightWidget: CGRect
    public let agents: CGRect
    public let usage: CGRect
    /// The full-width strip at the bottom, inside the margins.
    public let shelf: CGRect

    public init(panel: CGSize) {
        let inner = panel.width - 2 * Self.margin
        band = CGRect(x: 0, y: 0, width: panel.width, height: Self.bandHeight)
        bandLeftWidget = CGRect(x: Self.margin, y: 4, width: 244, height: 36)
        bandRightWidget = CGRect(x: panel.width - 36 - 224, y: 4, width: 224, height: 36)

        let shelfY = panel.height - Self.margin - Self.shelfHeight
        shelf = CGRect(x: Self.margin, y: shelfY, width: inner, height: Self.shelfHeight)

        let cardsBottom = shelfY - Self.gutter
        let cardsHeight = max(0, cardsBottom - Self.cardsTop)
        let rightX = panel.width - Self.margin - Self.usageColumnWidth
        agents = CGRect(
            x: Self.margin, y: Self.cardsTop,
            width: max(0, rightX - Self.gutter - Self.margin), height: cardsHeight)
        usage = CGRect(x: rightX, y: Self.cardsTop, width: Self.usageColumnWidth, height: cardsHeight)
    }
}
