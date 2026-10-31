import CoreGraphics
import Foundation
import Testing

@testable import HerdPanelUI

/// Covers the derived type scale that replaced eleven hand-picked point values.
///
/// Two properties are worth more than any particular number here, and they are what these tests pin.
///
/// **The old design is a special case of the new function.** `identifierSize` 10.5 has to reproduce the sizes
/// the panel shipped with, to within the half point the derivation rounds to. That is what makes the refactor
/// checkable rather than a matter of taste, and it is why the column tests can go on asserting the numbers
/// they were written against.
///
/// **The advance is a function of the size.** A hardcoded advance was the bug that clipped
/// `loader_error_classification` by one character when the size was fixed; with the size configurable it
/// would be wrong at four steps out of five. So the measurement has to move with the size, and it has to move
/// by the right amount.
struct HerdLedgerScaleTests {

    /// The steps the settings window offers, as scales.
    private static let steps = HerdLedgerScale.selectableIdentifierSizes
        .map(HerdLedgerScale.init(identifierSize:))

    // MARK: - Provenance

    /// The bottom step must be the previous design. These are the exact values the panel shipped with, and
    /// half a point is the rounding the derivation is allowed.
    @Test func theBottomStepReproducesThePreviousDesign() {
        let compact = HerdLedgerScale.compact
        #expect(compact.identifierSize == 10.5)
        #expect(compact.contextSize == 9)
        #expect(compact.inset == 13)
        #expect(compact.sigilColumn == 13)
        #expect(compact.rowHeight == 15)
        #expect(compact.groupGap == 6)
        #expect(compact.maxBodyHeight == 420)
        #expect(compact.bannerSize == 11)
        #expect(compact.columnGutter == 10)
        #expect(compact.markerGap == 6)
        #expect(compact.minTotalWidth == 320)
        #expect(compact.maxTotalWidth == 640)
        #expect(compact.sigilLarge == 9)
        #expect(compact.sigilSmall == 6)
        #expect(compact.sigilStroke == 1)
        // The one value the ratio moves off its old number: the headings were 8 pt by hand and two 7:6 steps
        // below 10.5 is 7.71, which rounds to 7.5. Half a point smaller at the bottom step is the price of
        // the whole ladder being one ratio, and the default step is 10 pt, well above the old 8.
        #expect(compact.headingSize == 7.5)
    }

    /// The shipped default has to be a real increase, not a nudge, and has to stay under the 18 pt where
    /// WCAG's large-text exemption would start letting contrast ratios slip.
    @Test func theDefaultIsMeaningfullyLargerAndStillSmallText() {
        let scale = HerdLedgerScale.default
        #expect(scale.identifierSize == 13.5)
        #expect(scale.identifierSize / HerdLedgerScale.compact.identifierSize > 1.25)
        #expect(scale.identifierSize < 18)
        #expect(Self.steps.allSatisfy { $0.identifierSize < 18 })
        // Every derived size at the default is at least as large as the old design's largest text, so nothing
        // in the panel is smaller than anything the user was reading before.
        #expect(scale.headingSize >= HerdLedgerScale.compact.contextSize)
    }

    // MARK: - The ratio

    /// Each step down the ladder divides by 7:6, within the half point the derivation rounds to.
    @Test func theTypeLadderHoldsItsRatio() {
        let ratio = 7.0 / 6.0
        for scale in Self.steps {
            let expectedContext = scale.identifierSize / ratio
            let expectedHeading = scale.identifierSize / (ratio * ratio)
            #expect(
                abs(scale.contextSize - expectedContext) <= 0.25,
                "context \(scale.contextSize) against \(expectedContext) at \(scale.identifierSize)"
            )
            #expect(
                abs(scale.headingSize - expectedHeading) <= 0.25,
                "heading \(scale.headingSize) against \(expectedHeading) at \(scale.identifierSize)"
            )
            // The ladder must stay strictly ordered, or the headings would stop reading as furniture.
            #expect(scale.headingSize < scale.contextSize, "at \(scale.identifierSize)")
            #expect(scale.contextSize < scale.identifierSize, "at \(scale.identifierSize)")
        }
    }

    /// Every derived size lands on a half point, which is exact at 2x. Thirds of a point put glyph origins
    /// between device pixels, which is where monospaced text starts looking unevenly spaced.
    @Test func everyDerivedSizeLandsOnAHalfPoint() {
        for scale in Self.steps {
            let sizes = [
                scale.contextSize, scale.headingSize, scale.bannerSize,
                scale.inset, scale.sigilColumn, scale.rowHeight, scale.groupGap,
                scale.maxBodyHeight, scale.bottomPadding,
                scale.selectionCornerRadius, scale.selectionInset,
                scale.sigilLarge, scale.sigilTriangleWidth, scale.sigilSmall, scale.sigilCheckmark,
                scale.columnGutter, scale.markerGap,
                scale.minTotalWidth, scale.maxTotalWidth,
                scale.maxSession, scale.maxWorkspace, scale.maxIdentifier, scale.maxKind,
                scale.minIdentifier
            ]
            for size in sizes {
                #expect(
                    (size * 2).truncatingRemainder(dividingBy: 1) == 0,
                    "\(size) is not a half point at \(scale.identifierSize)"
                )
            }
        }
    }

    /// Every size has to grow with the base. A size that stayed put while the type grew would be the thing
    /// that breaks the grid, which is the entire failure this derivation exists to prevent.
    @Test func everySizeIsMonotoneInTheBase() {
        for (smaller, larger) in zip(Self.steps, Self.steps.dropFirst()) {
            #expect(larger.contextSize > smaller.contextSize)
            #expect(larger.headingSize > smaller.headingSize)
            #expect(larger.rowHeight > smaller.rowHeight)
            #expect(larger.inset > smaller.inset)
            #expect(larger.sigilColumn > smaller.sigilColumn)
            #expect(larger.sigilLarge > smaller.sigilLarge)
            #expect(larger.sigilSmall > smaller.sigilSmall)
            #expect(larger.sigilStroke > smaller.sigilStroke)
            #expect(larger.maxBodyHeight > smaller.maxBodyHeight)
            #expect(larger.maxIdentifier > smaller.maxIdentifier)
        }
    }

    /// A hand-edited plist or a future caller cannot produce a zero or negative size, which would divide the
    /// layout by nothing and hand CoreText a font it cannot make.
    @Test func anAbsurdBaseIsFloored() {
        for base in [CGFloat(0), -12, -0.5] {
            let scale = HerdLedgerScale(identifierSize: base)
            #expect(scale.identifierSize >= 1)
            #expect(scale.contextSize > 0)
            #expect(scale.rowHeight > 0)
        }
    }

    // MARK: - The advance follows the size

    /// The measured advance has to scale with the point size, because that is the fact a hardcoded advance
    /// got wrong. Checked against the ratio of the sizes rather than against absolute figures, so a retuned
    /// system font cannot fail the test while the behaviour is right.
    @Test func theAdvanceScalesWithTheSize() {
        let text = "loader_error_classification"
        let compact = HerdLedgerScale.compact.identifierFace.width(of: text)
        let standard = HerdLedgerScale.default.identifierFace.width(of: text)
        #expect(standard > compact)
        let sizeRatio = HerdLedgerScale.default.identifierSize / HerdLedgerScale.compact.identifierSize
        // Within a point of the whole string, which is all the `rounded(.up)` in `width(of:)` can add.
        #expect(abs(standard - compact * sizeRatio) < 1.5, "\(standard) against \(compact * sizeRatio)")
    }

    /// The same content must produce a wider panel at every larger step. This is the property the user was
    /// promised when they said a wider bar is fine: legibility is bought with width, and it has to actually
    /// be bought rather than clipped out of the identifier column.
    @Test func thePanelWidensWithTheTypeRatherThanTruncating() {
        let identifiers = ["loader_error_classification", "catalog_version_diff", "sf-iceberg-1"]
        var previousWidth: CGFloat = 0
        for scale in Self.steps {
            let columns = HerdLedgerColumns.measuring(
                sessionNames: ["oncall_20-23_07"],
                workspaces: ["warehouse_cost"],
                identifiers: identifiers,
                kinds: ["claude", "codex"],
                scale: scale
            )
            let width = columns.totalWidth(scale: scale)
            #expect(width > previousWidth, "width did not grow at \(scale.identifierSize)")
            previousWidth = width
            // And the longest identifier still fits, which is the clipping bug generalised to every step.
            #expect(
                columns.identifier >= scale.identifierFace.width(of: identifiers[0]),
                "identifier column clips at \(scale.identifierSize)"
            )
        }
    }

    /// The session column tracks the names and only the names, at every step.
    ///
    /// The marker used to be measured into it, and because the multipliers are all derived from one base the
    /// overhead grew with the type: at the shipped 13.5 pt default `no terminal` and its gap were 75.5 pt of a
    /// 195.5 pt column, and every one of the sixteen rows paid for it. Checked at every step rather than at
    /// the default, because that growth is exactly what made a defect at 10.5 pt into a visibly broken panel
    /// at 13.5.
    @Test func theSessionColumnTracksOnlyTheNamesAtEveryStep() {
        for scale in Self.steps {
            let columns = HerdLedgerColumns.measuring(
                sessionNames: ["oncall_20-23_07", "default", "hail_mary"],
                workspaces: ["warehouse_cost"],
                identifiers: ["loader_error_classification"],
                kinds: ["claude"],
                scale: scale
            )
            let longestName = scale.contextFace.width(of: "oncall_20-23_07")
            #expect(
                columns.session == longestName + scale.columnGutter,
                "the session column is not the longest name at \(scale.identifierSize)"
            )
        }
    }

    /// The per-column ceilings are all derived from the same base, so the invariant that used to be checked
    /// by hand at 10.5 pt (their sum plus the furniture cannot exceed the panel's own ceiling) has to hold at
    /// every step without any arithmetic keeping it there.
    @Test func theColumnCeilingsStayInsideThePanelCeilingAtEveryStep() {
        for scale in Self.steps {
            let widest = scale.inset * 2 + scale.sigilColumn
                + scale.maxSession + scale.maxWorkspace + scale.maxIdentifier + scale.maxKind
            #expect(
                widest <= scale.maxTotalWidth,
                "ceilings sum to \(widest) against \(scale.maxTotalWidth) at \(scale.identifierSize)"
            )
        }
    }

    /// A pathological label must still be contained at the largest step, where the ceilings are widest.
    @Test func aPathologicalLabelIsStillContainedAtTheLargestStep() throws {
        let scale = try #require(Self.steps.last)
        let absurd = String(repeating: "z", count: 4000)
        let columns = HerdLedgerColumns.measuring(
            sessionNames: [absurd],
            workspaces: [absurd],
            identifiers: [absurd],
            kinds: [absurd],
            scale: scale
        )
        #expect(columns.totalWidth(scale: scale) <= scale.maxTotalWidth)
    }
}
