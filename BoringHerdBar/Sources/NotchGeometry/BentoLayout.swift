import CoreGraphics

/// The expanded notch panel's card frames, derived from the panel size. Coordinates are SwiftUI-style:
/// origin top-left, y growing down, relative to the panel's own bounds.
///
/// At `720x432` (the old `720x344` plus the shelf strip) the band and the three cards match the previous
/// hard-coded frames exactly.
public struct BentoLayout: Equatable, Sendable {
    public static let margin: CGFloat = 16
    public static let gutter: CGFloat = 12
    public static let bandHeight: CGFloat = 44
    public static let cardsTop: CGFloat = 54
    public static let rightColumnWidth: CGFloat = 252
    public static let nowPlayingHeight: CGFloat = 128
    public static let shelfHeight: CGFloat = 76

    /// The full-width utility band.
    public let band: CGRect
    /// Clock/date flank and caffeinate/settings flank inside the band. They stay clear of a centred
    /// 200pt notch zone only from a 720pt panel width up.
    public let bandLeftWidget: CGRect
    public let bandRightWidget: CGRect
    public let agents: CGRect
    public let nowPlaying: CGRect
    public let reminders: CGRect
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
        let rightX = panel.width - Self.margin - Self.rightColumnWidth
        agents = CGRect(
            x: Self.margin, y: Self.cardsTop,
            width: max(0, rightX - Self.gutter - Self.margin), height: cardsHeight)

        // Same split as before (fixed-height now-playing, reminders take the rest), but never taller than
        // half the column, so a short panel does not squash reminders.
        let nowPlayingH = max(0, min(Self.nowPlayingHeight, (cardsHeight - Self.gutter) / 2))
        nowPlaying = CGRect(
            x: rightX, y: Self.cardsTop, width: Self.rightColumnWidth, height: nowPlayingH)
        let remindersY = Self.cardsTop + nowPlayingH + Self.gutter
        reminders = CGRect(
            x: rightX, y: remindersY, width: Self.rightColumnWidth,
            height: max(0, cardsBottom - remindersY))
    }
}
