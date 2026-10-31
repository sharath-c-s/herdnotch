import CoreGraphics
// CoreText, and deliberately not AppKit. The panel target's rule is "SwiftUI and HerdKit only" so that
// the file lifts into another host unchanged, and the reason the rule exists is AppKit: a view that
// reaches for `NSFont` or `NSScreen` stops being portable. CoreText is a lower-level text-shaping
// framework with no window server, no application object and no appearance, so importing it costs the
// portability rule nothing while giving the columns an exact answer instead of an estimated one.
import CoreText
import Foundation

// MARK: - Face

/// One typographic face the ledger is set in, and the exact width it renders a string at.
///
/// Every column in the ledger holds monospaced text, which is what makes the widths computable rather
/// than negotiated: the panel can be sized before it is laid out, so nothing has to measure itself on
/// screen and then ask its parent to grow, which is the feedback loop that made an earlier layout
/// oscillate.
///
/// Widths come from CoreText rather than from a character count times a remembered advance, and that is now
/// load-bearing rather than merely accurate. **The advance is a function of the point size**, so with the
/// size configurable there is no single number to remember: this face measures 6.4907 pt per character at
/// 10.5 pt and 8.3452 pt at 13.5 pt. A hardcoded advance would be wrong for four of the five sizes the
/// settings window offers. It was already wrong for the one it was written for, which is how this was found:
/// a previous pass recorded 6.45 pt against a real 6.4907 pt, so 27 characters of
/// `loader_error_classification` needed 175.25 pt rather than the 174.15 pt the old number predicted, and a
/// column declared at 174 pt clipped the single most important row in the panel by one character.
struct HerdLedgerFace: Sendable, Equatable {
    /// Point size, matching the `Font.system(size:)` the column's `Text` uses.
    let size: CGFloat

    /// Extra space added after every character, matching SwiftUI's `.tracking(_:)`.
    ///
    /// Applied per character including the last, which is what SwiftUI does, so a heading's measured width
    /// matches the box SwiftUI reserves for it rather than being one tracking step short.
    let tracking: CGFloat

    /// Creates a face.
    ///
    /// - Parameters:
    ///   - size: Point size.
    ///   - tracking: Extra space per character, zero for body text.
    init(size: CGFloat, tracking: CGFloat = 0) {
        self.size = size
        self.tracking = tracking
    }

    /// The width `text` occupies in this face, rounded up to a whole point.
    ///
    /// Rounded up rather than to nearest, because a column half a point short truncates and a column half
    /// a point wide is invisible.
    ///
    /// - Parameter text: The string to measure. Empty measures zero.
    /// - Returns: Width in points.
    /// - Note: The attributed string is built with `CFAttributedStringCreate` and `kCTFontAttributeName`
    ///   rather than with `NSAttributedString` and `.font`. That is not a stylistic choice: the `.font`
    ///   attribute key is declared by AppKit and UIKit, not by Foundation, so writing it here compiles only
    ///   as long as some other file in this module happens to import AppKit transitively through SwiftUI.
    ///   It did compile, which is exactly the problem: the portability rule this target exists to enforce
    ///   would have been broken by an expression that never named AppKit at all.
    func width(of text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let attributes = [kCTFontAttributeName: Self.font(ofSize: size)] as CFDictionary
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes) else {
            return 0
        }
        let line = CTLineCreateWithAttributedString(attributed)
        let glyphs = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        return (glyphs + CGFloat(text.count) * tracking).rounded(.up)
    }

    /// The widest of several strings in this face.
    ///
    /// - Parameter texts: Strings to measure. Empty returns zero.
    /// - Returns: The largest width, in points.
    func widest(of texts: [String]) -> CGFloat {
        texts.reduce(0) { max($0, width(of: $1)) }
    }

    /// The monospaced system face at a given size, resolved through public CoreText API only.
    ///
    /// Resolved by asking for the system UI font and copying it with the monospace symbolic trait, rather
    /// than by name. Naming it was tried and is a trap: `CTFontCreateWithName("SFMono-Regular", …)`
    /// silently returns **Helvetica**, whose advance at 10.5 pt is 8.75 pt, so a column sized from it would
    /// be a third too wide and the mistake would look like a design decision.
    /// `CTFontCreateUIFontForLanguage(.userFixedPitch, …)` is also wrong: it returns Menlo, at 6.32 pt.
    /// The trait copy returns `.AppleSystemUIFontMonospaced-Regular`, which is the face SwiftUI's
    /// `design: .monospaced` actually uses, verified by comparing against
    /// `NSFont.monospacedSystemFont(ofSize:weight:)` in a throwaway harness that was allowed to import
    /// AppKit.
    ///
    /// Weight is not a parameter because it does not need to be: the ledger sets some cells in medium and
    /// semibold, and in a monospaced face every weight advances identically, measured equal for regular and
    /// medium at every size the settings window offers.
    ///
    /// - Parameter size: Point size.
    /// - Returns: The monospaced face, falling back to the plain system face if the trait copy fails, which
    ///   would over-measure rather than clip.
    private static func font(ofSize size: CGFloat) -> CTFont {
        let system = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        return CTFontCreateCopyWithSymbolicTraits(
            system, size, nil, .monoSpaceTrait, .monoSpaceTrait
        ) ?? system
    }
}

// MARK: - Scale

/// Every size in the ledger, derived from one number.
///
/// This replaced a flat list of five hand-picked point sizes and a dozen more hand-picked lengths. The list
/// was not merely untidy: the user reported the panel as too small to read, and there was no single place to
/// change that, because the identifier size, the context size, the heading size, the row height, the gutter,
/// the sigil diameters and every column ceiling were independent constants that happened to look right
/// together. Raising one would have broken the grid the whole direction depends on.
///
/// **The ratio is 7:6**, and it was measured off the existing design rather than picked from a scale
/// generator: the shipped context size was 9 pt against a 10.5 pt identifier, which is exactly 6:7. Each step
/// down the type ladder therefore divides by 7/6 (about 1.167), and every length is a fixed multiple of the
/// identifier size, chosen so that **an `identifierSize` of 10.5 reproduces the previous design to within
/// half a point**. That property is what makes the change checkable rather than a matter of taste: the old
/// numbers are a special case of the new function, not something it approximates.
///
/// Derived values are rounded to the nearest **half point**. Whole points would visibly quantise a 7:6 ratio
/// over a five-step range, and thirds of a point put glyph origins between device pixels at 2x, which is
/// where monospaced text starts looking unevenly spaced. Halves are exact at 2x.
///
/// Sizes are an **explicit control**, not `@ScaledMetric` and not a semantic `Font.TextStyle`, and that is a
/// decision rather than an omission. Three reasons, in order of weight. The panel is a measured table: its
/// column widths come from CoreText at a specific point size, and that measurement happens before layout, so
/// the size has to be a number this code holds rather than a Dynamic Type multiplier resolved inside a view
/// body. The user asked to tune this by eye, which a system-wide setting cannot do per app. And macOS has no
/// Dynamic Type control comparable to iOS's, so honouring it would tie a deliberately tunable readout to a
/// setting most users never touch. The explicit steps are also what let the *whole* scale move together,
/// including the row height and the gutter, which per-`Text` text styles could not.
///
/// Thread-safety: an immutable `Sendable` value. Building one is a couple of dozen multiplications, so the
/// panel makes one per body evaluation rather than caching it.
public struct HerdLedgerScale: Sendable, Equatable {

    // MARK: The one number

    /// Point size of the agent identifier, and the base every other size is derived from.
    public let identifierSize: CGFloat

    /// The sizes offered in the settings window, in points.
    ///
    /// Five discrete steps 1.5 pt apart rather than a free numeric field. A free field would let a user pick
    /// 13.37 pt, whose derived context and heading sizes land on thirds of a point and quantise unevenly
    /// against the monospace grid; it would also invite tuning by fractions, which is exactly what having a
    /// ratio is meant to prevent. The bottom step is the previous design, kept so anyone who preferred it can
    /// have it back.
    public static let selectableIdentifierSizes: [CGFloat] = [10.5, 12, 13.5, 15, 16.5]

    /// The shipped size: 13.5 pt, up from 10.5.
    ///
    /// A 29 % increase rather than a nudge, and chosen against the system rather than by eye. macOS sets
    /// ordinary interface text at 13 pt and its small control text at 11 pt, so the old identifier sat below
    /// the *small* system size on the one surface whose entire job is to be scanned, while the context
    /// columns at 9 pt and the headings at 8 pt were below anything the system ships at all. At 13.5 the
    /// identifier is a shade above ordinary interface text, which is right for a monospaced readout, because
    /// `.AppleSystemUIFontMonospaced` has a smaller x-height than the proportional system face at the same
    /// nominal size.
    ///
    /// Still under 18 pt, so WCAG's large-text exemption does not apply at any step and every ratio in
    /// ``HerdPalette`` is still measured against the 4.5:1 bar. Raising the size buys no contrast relief.
    public static let defaultIdentifierSize: CGFloat = 13.5

    /// The shipped scale.
    public static let `default` = HerdLedgerScale(identifierSize: defaultIdentifierSize)

    /// The previous design, retained as the bottom step and used by the tests that pin the old numbers.
    public static let compact = HerdLedgerScale(identifierSize: 10.5)

    /// One step of the type ladder: 7:6, measured off the shipped 10.5 pt identifier and 9 pt context.
    private static let ratio: CGFloat = 7.0 / 6.0

    // MARK: Type

    /// Session, workspace and kind columns. One step below the identifier.
    public let contextSize: CGFloat

    /// Column headings and the session-scoped markers. Two steps below the identifier.
    ///
    /// One size for both because they are the same register, small furniture beside a name, and because the
    /// session column has to reserve room for a marker in whatever face it is drawn in. Two sizes would be
    /// two things to keep in step for no visible gain.
    public let headingSize: CGFloat

    /// The banner and the empty-state sentence, which are prose in the chrome face rather than table cells.
    public let bannerSize: CGFloat

    /// Tracking on the column headings, scaled so letter-spacing stays proportional to the glyphs.
    public let headingTracking: CGFloat

    // MARK: Geometry

    /// Outer margin.
    public let inset: CGFloat

    /// The status gutter. Narrow, and at the reading origin, because it holds the answer.
    public let sigilColumn: CGFloat

    /// Height of one agent line.
    public let rowHeight: CGFloat

    /// Extra space above the first row of a new session, which is what makes elision read as grouping.
    public let groupGap: CGFloat

    /// Ceiling on the scrollable body, so the popover cannot grow past the screen on a huge herd.
    ///
    /// Scales with the type, because a fixed 420 pt would have started scrolling a sixteen-agent herd one
    /// step up from the default and the user would have been trading legibility for a scroll without being
    /// told. Measured: sixteen agents across four sessions need 405 pt at the 13.5 pt default against a
    /// 540 pt cap, and 492 pt at the 16.5 pt top step against a 660 pt cap, so nothing scrolls at any step
    /// for a herd this size.
    public let maxBodyHeight: CGFloat

    /// Padding below the last row.
    public let bottomPadding: CGFloat

    /// Corner radius of the keyboard selection ring.
    public let selectionCornerRadius: CGFloat

    /// Horizontal inset of the keyboard selection ring inside the row.
    public let selectionInset: CGFloat

    // MARK: Sigils

    /// Diameter of the `blocked` disc, the height of the `working` triangle, and the width of the gutter's
    /// centring box.
    public let sigilLarge: CGFloat

    /// Width of the `working` triangle, slightly narrower than it is tall so it reads as pointing.
    public let sigilTriangleWidth: CGFloat

    /// Diameter of the `idle` ring and the side of the `unknown` square.
    public let sigilSmall: CGFloat

    /// Point size of the just-finished checkmark.
    public let sigilCheckmark: CGFloat

    /// Stroke width of the hollow sigils, scaled so a ring does not thin to nothing beside 16.5 pt text.
    public let sigilStroke: CGFloat

    // MARK: Columns

    /// Trailing gutter inside every column except the last, so adjacent values never touch.
    let columnGutter: CGFloat

    /// Space between the two session markers when a remote session also has nothing attached to it, and the
    /// indent of the marker line under the session name it belongs to.
    let markerGap: CGFloat

    /// Narrowest the whole panel may be.
    ///
    /// Reached only by a herd of very short names. Below this the banner sentence and the stand-in lines,
    /// which wrap rather than widening the panel, start wrapping into an unreadable ribbon.
    let minTotalWidth: CGFloat

    /// Widest the whole panel may be.
    ///
    /// Not enforced by clamping the sum, which would silently steal width from one column to pay for
    /// another. It is a consequence of the per-column ceilings, which are all derived from the same base, so
    /// the relationship that held at 10.5 pt holds at every step without any arithmetic to keep it there.
    let maxTotalWidth: CGFloat

    /// Ceiling on the session column.
    let maxSession: CGFloat

    /// Ceiling on the workspace column.
    let maxWorkspace: CGFloat

    /// Ceiling on the identifier column.
    let maxIdentifier: CGFloat

    /// Ceiling on the kind column.
    let maxKind: CGFloat

    /// Floor on the identifier column, over and above its heading.
    ///
    /// The heading `AGENT` is narrow, and a panel whose widest tab label is `db` would otherwise print the
    /// column the user is actually reading in a slot barely wider than the word. This keeps it wide enough
    /// for a typical label whatever the current herd happens to contain.
    let minIdentifier: CGFloat

    // MARK: Faces

    /// The identifier column's face.
    var identifierFace: HerdLedgerFace { HerdLedgerFace(size: identifierSize) }

    /// The session, workspace and kind columns' face.
    var contextFace: HerdLedgerFace { HerdLedgerFace(size: contextSize) }

    /// The markers' face.
    var markerFace: HerdLedgerFace { HerdLedgerFace(size: headingSize) }

    /// Height of the session-marker line, which prints under a session's name rather than in the grid.
    ///
    /// A normal 1.4 line-height factor on the marker's own type size, and computed rather than stored
    /// because it is the one length in this scale with no ancestor in the previous design: markers used to
    /// share an agent row, so there was no such line to have a height. It is deliberately well under
    /// ``rowHeight``, since the line is furniture between two agent rows of the same session and a full row
    /// of space would read as a missing agent.
    var markerRowHeight: CGFloat { Self.half(headingSize * 1.4) }

    /// The column headings' face, tracking included so a heading is measured as SwiftUI draws it.
    var headingFace: HerdLedgerFace { HerdLedgerFace(size: headingSize, tracking: headingTracking) }

    // MARK: Derivation

    /// Derives the whole scale from the identifier size.
    ///
    /// Every multiplier below is the previous design's value divided by 10.5, so passing 10.5 returns the
    /// previous design. They are written as that division rather than as a decimal so the provenance is
    /// visible in the source and a later change to one of them cannot be mistaken for a rounding tweak.
    ///
    /// - Parameter identifierSize: Point size of the agent identifier. Any positive value works; the
    ///   settings window restricts itself to ``selectableIdentifierSizes``.
    public init(identifierSize: CGFloat) {
        let base = max(1, identifierSize)
        self.identifierSize = base

        contextSize = Self.half(base / Self.ratio)
        headingSize = Self.half(base / (Self.ratio * Self.ratio))
        bannerSize = Self.half(base * (11 / 10.5))
        headingTracking = base * (0.8 / 10.5)

        inset = Self.half(base * (13 / 10.5))
        sigilColumn = Self.half(base * (13 / 10.5))
        rowHeight = Self.half(base * (15 / 10.5))
        groupGap = Self.half(base * (6 / 10.5))
        maxBodyHeight = Self.half(base * (420 / 10.5))
        bottomPadding = Self.half(base * (10 / 10.5))
        selectionCornerRadius = Self.half(base * (3 / 10.5))
        selectionInset = Self.half(base * (6 / 10.5))

        sigilLarge = Self.half(base * (9 / 10.5))
        sigilTriangleWidth = Self.half(base * (8 / 10.5))
        sigilSmall = Self.half(base * (6 / 10.5))
        sigilCheckmark = Self.half(base * (7 / 10.5))
        // Deliberately not snapped to a half point. A 1 pt hairline is correct at the bottom step, and a
        // hairline that jumped to 1.5 pt would read as a weight change rather than a size change. It grows
        // continuously instead, which at 16.5 pt is 1.57 pt and still reads as a hairline.
        sigilStroke = base * (1 / 10.5)

        columnGutter = Self.half(base * (10 / 10.5))
        markerGap = Self.half(base * (6 / 10.5))
        minTotalWidth = Self.half(base * (320 / 10.5))
        maxTotalWidth = Self.half(base * (640 / 10.5))
        maxSession = Self.half(base * (190 / 10.5))
        maxWorkspace = Self.half(base * (130 / 10.5))
        maxIdentifier = Self.half(base * (220 / 10.5))
        maxKind = Self.half(base * (60 / 10.5))
        minIdentifier = Self.half(base * (120 / 10.5))
    }

    /// The nearest half point.
    ///
    /// - Parameter value: An unrounded derived size.
    /// - Returns: `value` snapped to a multiple of 0.5.
    private static func half(_ value: CGFloat) -> CGFloat {
        (value * 2).rounded() / 2
    }
}

// MARK: - Columns

/// The ledger's column widths, measured from the values actually on screen at the current size.
///
/// These used to be five constants, sized by hand for the longest value across every session the user had.
/// That was wrong in a way the user found immediately: disabling two sessions through the session filter
/// removed the long values but not the space reserved for them, so the panel stayed 506 pt wide with a
/// `SESSION` column that was mostly empty. Nothing recomputed, because there was nothing to recompute.
///
/// Widths are now a function of the printed lines **and the type size**, so they follow the filter, the
/// arrival and departure of agents, whether a detached or remote session is on screen, and the size the user
/// picked in the settings window. The panel's own width is their sum, which keeps it the consequence of its
/// content rather than a round number chosen first.
///
/// Every width is clamped between the width of its own column heading and a per-column ceiling, both of which
/// scale with the type. The floor keeps `WORKSPACE` from truncating in a panel showing only workspaces called
/// `db`; the ceiling stops a pathological tab label from pushing the popover wider than the screen. A value
/// that hits its ceiling truncates exactly as it did before, in each column's existing mode.
struct HerdLedgerColumns: Sendable, Equatable {
    /// The session column, wide enough for the widest printed session name and nothing else.
    ///
    /// Session-scoped markers are deliberately not in it. See ``detachedMarker``.
    let session: CGFloat

    /// The workspace column.
    let workspace: CGFloat

    /// The agent identifier column, the one holding unbounded user-chosen tab labels.
    let identifier: CGFloat

    /// The agent kind column. Tight, because it only ever holds a known agent kind such as `claude`.
    let kind: CGFloat

    /// The marker printed under a detached session's name.
    ///
    /// Declared here rather than in the row because it is a fact about the ledger's vocabulary, and because
    /// it is deliberately **not** part of any column's measurement: it prints on its own line, outside the
    /// grid. It used to share the session cell, and that is the defect this fixed. `oncall_20-23_07` plus
    /// `no terminal` was the widest thing the session column ever held, so one detached session set the
    /// column width for every row in the panel and left a couple of hundred points of dead space between
    /// each session name and the workspace beside it. The marker was the widest content on screen doing the
    /// least work.
    static let detachedMarker = "no terminal"

    /// The marker printed under the name of a session reached through a forwarded socket.
    ///
    /// The same mechanism as ``detachedMarker`` rather than a new one, and that is the point. `DESIGN.md`
    /// forbids a third accent and says to distinguish with weight, space or position instead; a lowercase
    /// word in `textTertiary` under the session name is exactly the register a remote session belongs in,
    /// because it is a limitation to know about (no window can be brought forward, the tunnel is another
    /// thing that can be down) rather than an alarm. Position is now carrying more of that job than it did,
    /// which is if anything closer to what `DESIGN.md` asks for.
    ///
    /// Both markers can appear together, for a remote session with nothing attached on the far side, and
    /// they share one line.
    static let remoteMarker = "remote"

    /// The panel width these columns imply.
    ///
    /// - Parameter scale: The scale the columns were measured at, which supplies the furniture.
    /// - Returns: Total width, never below ``HerdLedgerScale/minTotalWidth``.
    func totalWidth(scale: HerdLedgerScale) -> CGFloat {
        max(
            scale.minTotalWidth,
            scale.inset * 2 + scale.sigilColumn + session + workspace + identifier + kind
        )
    }

    /// The widths needed by the values in one printed ledger, at one size.
    ///
    /// - Parameters:
    ///   - sessionNames: One entry per line that prints a session name. Lines whose session cell is blank
    ///     because the line above printed it are excluded by the caller, since a blank cell constrains
    ///     nothing. Lines standing in for a whole session are excluded too, as are the session-marker lines:
    ///     all of those are drawn as free lines outside the grid, so their text belongs to no column and
    ///     must not size one. That exclusion is the fix for the session column being sized by
    ///     ``detachedMarker`` rather than by the names it exists to hold.
    ///   - workspaces: Every printed workspace name.
    ///   - identifiers: Every printed agent identifier.
    ///   - kinds: Every printed agent kind.
    ///   - scale: The current scale, supplying both the faces to measure in and the clamps. Passing it
    ///     rather than reading a static is the whole of what makes the size configurable: the advance is a
    ///     function of the point size, so a table measured at one size is simply wrong at another.
    /// - Returns: The clamped column table.
    static func measuring(
        sessionNames: [String],
        workspaces: [String],
        identifiers: [String],
        kinds: [String],
        scale: HerdLedgerScale
    ) -> HerdLedgerColumns {
        let contextFace = scale.contextFace
        let headingFace = scale.headingFace
        let gutter = scale.columnGutter
        return HerdLedgerColumns(
            session: clamp(
                contextFace.widest(of: sessionNames) + gutter,
                lower: headingFace.width(of: "SESSION") + gutter,
                upper: scale.maxSession
            ),
            workspace: clamp(
                contextFace.widest(of: workspaces) + gutter,
                lower: headingFace.width(of: "WORKSPACE") + gutter,
                upper: scale.maxWorkspace
            ),
            identifier: clamp(
                scale.identifierFace.widest(of: identifiers) + gutter,
                lower: max(headingFace.width(of: "AGENT") + gutter, scale.minIdentifier),
                upper: scale.maxIdentifier
            ),
            // No trailing gutter: the kind column is last, and the panel's own inset already separates it
            // from the edge.
            kind: clamp(
                contextFace.widest(of: kinds),
                lower: headingFace.width(of: "KIND"),
                upper: scale.maxKind
            )
        )
    }

    /// This table widened, per column, to also fit `other`.
    ///
    /// This is the anti-thrash rule, and the reason it is a widening rather than a replacement is the poll
    /// rate. The snapshot arrives once a second, so recomputing widths from it directly would let an agent
    /// appearing or finishing resize the popover under the user's cursor while they are reading it. Within
    /// one presentation of the panel the widths therefore only ever grow: a new longest label makes the
    /// panel wider once and it stays, and nothing makes it narrower.
    ///
    /// Shrinking happens on the next presentation instead, because the caller reseeds from a fresh
    /// measurement when the panel appears. That is what makes the user's own case work: they change the
    /// session filter, reopen the panel, and it is narrower. It also keeps the rule monotone and therefore
    /// incapable of oscillating, which a hysteresis counter would not have been.
    ///
    /// A **type size change is deliberately not put through this rule**, because it is not a content change:
    /// stepping down from 16.5 pt to 12 pt has to narrow the panel at once or the setting looks broken, so
    /// the caller replaces the table outright when the scale changes.
    ///
    /// - Parameter other: A freshly measured table.
    /// - Returns: The per-column maximum of the two.
    func widened(to other: HerdLedgerColumns) -> HerdLedgerColumns {
        HerdLedgerColumns(
            session: max(session, other.session),
            workspace: max(workspace, other.workspace),
            identifier: max(identifier, other.identifier),
            kind: max(kind, other.kind)
        )
    }

    /// This table, shrunk to fit inside `availableWidth`, for a host (HerdNotch's Ledger+Rail layout) that
    /// gives the ledger a fixed region rather than letting it size the surface around itself.
    ///
    /// Only ``workspace`` ever shrinks. Per the Ledger+Rail design spec ("shrink WORKSPACE before AGENT"),
    /// the agent identifier is the column the whole ledger exists to show, so it is never touched here; kind
    /// and session are likewise left alone, since kind is expected to already have been measured from its
    /// caller's own compacted (4-character) strings and session rarely needs the room. If shrinking
    /// ``workspace`` all the way to its own heading's width still does not fit `availableWidth`, this returns
    /// that floor rather than shrinking further — an overflow past that point is accepted (the row's own
    /// `.truncationMode(.middle)` still keeps the printed text readable) rather than crushing the workspace
    /// column to something narrower than its own column heading.
    ///
    /// - Parameters:
    ///   - availableWidth: The fixed width the caller has for the whole ledger, sigil gutter and outer insets
    ///     included.
    ///   - scale: The scale this table was measured at, supplying the outer insets, the sigil gutter width
    ///     and the WORKSPACE heading's own floor.
    /// - Returns: This table with ``workspace`` clamped down to fit, or unchanged if it already fits.
    func fitted(within availableWidth: CGFloat, scale: HerdLedgerScale) -> HerdLedgerColumns {
        let fixedWidth = scale.inset * 2 + scale.sigilColumn + session + identifier + kind
        let workspaceBudget = availableWidth - fixedWidth
        let workspaceFloor = scale.headingFace.width(of: "WORKSPACE")
        let fittedWorkspace = max(workspaceFloor, min(workspace, workspaceBudget))
        guard fittedWorkspace != workspace else { return self }
        return HerdLedgerColumns(session: session, workspace: fittedWorkspace, identifier: identifier, kind: kind)
    }

    /// Clamps a measured width between a floor and a ceiling.
    ///
    /// The floor wins when the two cross, which cannot happen with the multipliers above but would be the
    /// safer answer if a heading were ever renamed to something longer than its column's ceiling.
    ///
    /// - Parameters:
    ///   - value: The measured width.
    ///   - lower: Floor.
    ///   - upper: Ceiling.
    /// - Returns: `value` inside the bounds.
    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        max(lower, min(value, upper))
    }
}
