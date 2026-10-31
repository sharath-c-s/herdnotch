import CoreGraphics
import Foundation
import Testing

@testable import HerdPanelUI

/// Covers the column measurement that replaced five hand-sized constants.
///
/// The behaviour worth pinning is not any particular number of points, which depends on a system font that
/// may be retuned. It is the set of relationships the user actually reported: a narrower set of values must
/// produce a narrower panel, the `no terminal` marker must not size the session column at all, and no single
/// pathological label may push the popover past a ceiling. Those hold whatever the advance turns out to be,
/// so they are what these tests assert. The one absolute check is against the clipping bug that started all
/// of this.
struct HerdLedgerColumnsTests {

    /// The scale these tests measure against.
    ///
    /// Deliberately ``HerdLedgerScale/compact``, the 10.5 pt bottom step, rather than the shipped default.
    /// Every assertion below was written against the previous fixed design, and the derived scale is built so
    /// that 10.5 reproduces it: pinning them here keeps them testing the facts they were written for, and
    /// makes them a standing check that the derivation has not drifted away from its own origin. The scale
    /// itself is exercised at every step in ``HerdLedgerScaleTests``.
    private static let scale = HerdLedgerScale.compact

    /// The user's own ledger, unfiltered: four sessions, sixteen agents, one of them detached.
    private static let wide = HerdLedgerColumns.measuring(
        sessionNames: [
            "hail_mary",
            "default",
            "oncall_20-23_07"
        ],
        workspaces: ["shara", "shara_misc", "warehouse_cost", "work_misc", "sf-iceberg", "services"],
        identifiers: [
            "boring_notch_herdr", "1", "forget_me_not", "saas_me",
            "databricks_review", "masked_merge_impl", "claude", "loader_error_classification",
            "loader-memory-opt", "catalog_version_diff", "focal_review", "sf-iceberg-1",
            "slow_load", "databricks_schema_mismatch"
        ],
        kinds: ["claude", "codex"],
            scale: Self.scale
    )

    /// The same ledger with the two sessions the user disabled removed, which is the case that reported the
    /// bug: nothing recomputed, so the panel stayed as wide as it had been.
    private static let filtered = HerdLedgerColumns.measuring(
        sessionNames: [
            "hail_mary",
            "default"
        ],
        workspaces: ["shara", "shara_misc", "warehouse_cost", "work_misc", "sf-iceberg"],
        identifiers: [
            "boring_notch_herdr", "1", "forget_me_not", "saas_me",
            "databricks_review", "masked_merge_impl", "claude", "loader_error_classification",
            "loader-memory-opt", "catalog_version_diff", "focal_review", "sf-iceberg-1"
        ],
        kinds: ["claude", "codex"],
            scale: Self.scale
    )

    /// Panel width for a column table, using the ledger's real furniture.
    private static func width(_ columns: HerdLedgerColumns) -> CGFloat {
        columns.totalWidth(scale: Self.scale)
    }

    @Test func filteringSessionsNarrowsThePanel() {
        #expect(Self.width(Self.filtered) < Self.width(Self.wide))
        // The session column specifically, because that is the one the user pointed at: it lost its longest
        // name, and it no longer carries the detached marker at all.
        #expect(Self.filtered.session < Self.wide.session)
    }

    /// The session column is the longest session name and nothing else.
    ///
    /// This is the inversion of what these tests used to assert, and the reason is the defect the user
    /// reported. `no terminal` beside `oncall_20-23_07` was the widest content the session column ever held,
    /// so one detached session set the width for all sixteen rows and left a couple of hundred points of dead
    /// space between every session name and its workspace. The markers now print on a line of their own,
    /// outside the grid, so they are not an input to the measurement at all: the guarantee is structural, and
    /// this pins the arithmetic that goes with it.
    @Test func theSessionColumnIsTheLongestNameAndNothingMore() {
        let columns = HerdLedgerColumns.measuring(
            sessionNames: ["a_very_long_session_name", "tiny"],
            workspaces: ["w"], identifiers: ["a"], kinds: ["claude"],
            scale: Self.scale
        )
        let longestName = Self.scale.contextFace.width(of: "a_very_long_session_name")
        #expect(columns.session == longestName + Self.scale.columnGutter)
    }

    /// The regression itself, stated as the width it gives back.
    ///
    /// The user's own herd is the worst case for the old rule, because the detached session is also the one
    /// with the longest name: the marker was pure overhead on a column that was already as wide as it needed
    /// to be. Asserting the column is narrower than the old rule made it, by the full width of the marker and
    /// its gap, is what would catch the marker creeping back into the measurement.
    @Test func theDetachedMarkerNoLongerWidensTheSessionColumn() {
        let markerCost = Self.scale.markerGap
            + Self.scale.markerFace.width(of: HerdLedgerColumns.detachedMarker)
        #expect(markerCost > 0, "the marker has to cost something for this test to mean anything")
        let asMeasuredBefore = Self.scale.contextFace.width(of: "oncall_20-23_07")
            + markerCost
            + Self.scale.columnGutter
        #expect(Self.wide.session == asMeasuredBefore - markerCost)
    }

    /// The marker line is furniture, not a row, and its height has to say so.
    ///
    /// At a full row height the line would read as a row with a missing agent, which is the one thing this
    /// ledger must never look like: a silently missing agent is the failure the panel exists to prevent.
    @Test func theMarkerLineIsShorterThanAnAgentRow() {
        for size in HerdLedgerScale.selectableIdentifierSizes {
            let scale = HerdLedgerScale(identifierSize: size)
            #expect(scale.markerRowHeight < scale.rowHeight, "at \(size)")
            // And tall enough for the marker's own glyphs, so the line cannot clip what it exists to show.
            #expect(scale.markerRowHeight > scale.headingSize, "at \(size)")
        }
    }

    /// The regression the old constants shipped with.
    ///
    /// `loader_error_classification` is the single most important row in the panel and a column declared at
    /// 174 pt clipped it by one character, because the advance had been recorded as 6.45 pt when the face
    /// really advances 6.4907 pt. Measured rather than multiplied, the column now has to be wider than the
    /// string it holds, and this asserts the inequality rather than the number so that a retuned system font
    /// cannot make the test wrong while the layout stays right.
    @Test func longestRealIdentifierIsNotClipped() {
        let text = "loader_error_classification"
        let needed = Self.scale.identifierFace.width(of: text)
        #expect(needed > 174)
        #expect(Self.wide.identifier >= needed)
    }

    @Test func kindColumnIsTightAroundKnownAgentKinds() {
        // No trailing gutter on the last column, so it is exactly the widest kind and nothing more.
        #expect(Self.wide.kind == Self.scale.contextFace.width(of: "claude"))
        #expect(Self.wide.kind < 40)
    }

    @Test func headingsAlwaysFitTheirColumn() {
        let empty = HerdLedgerColumns.measuring(
            sessionNames: [], workspaces: [], identifiers: [], kinds: [], scale: Self.scale
        )
        #expect(empty.session >= Self.scale.headingFace.width(of: "SESSION"))
        #expect(empty.workspace >= Self.scale.headingFace.width(of: "WORKSPACE"))
        #expect(empty.identifier >= Self.scale.headingFace.width(of: "AGENT"))
        #expect(empty.kind >= Self.scale.headingFace.width(of: "KIND"))
    }

    @Test func aPathologicalLabelCannotWidenThePanelPastTheCeiling() {
        let absurd = String(repeating: "z", count: 4000)
        let columns = HerdLedgerColumns.measuring(
            sessionNames: [absurd],
            workspaces: [absurd], identifiers: [absurd], kinds: [absurd],
            scale: Self.scale
        )
        #expect(Self.width(columns) <= Self.scale.maxTotalWidth)
    }

    @Test func aHerdOfVeryShortNamesStillGivesAReadablePanel() {
        let columns = HerdLedgerColumns.measuring(
            sessionNames: ["a"],
            workspaces: ["b"], identifiers: ["c"], kinds: ["d"],
            scale: Self.scale
        )
        #expect(Self.width(columns) == Self.scale.minTotalWidth)
    }

    /// The anti-thrash rule, which is the reason the widths are state rather than a computed property.
    @Test func wideningNeverNarrowsAColumn() {
        let grown = Self.wide.widened(to: Self.filtered)
        #expect(grown == Self.wide)
        // And the other direction does grow, so a genuinely longer label still appears in full.
        #expect(Self.filtered.widened(to: Self.wide) == Self.wide)
    }

    @Test func wideningIsPerColumnRatherThanAllOrNothing() {
        let narrowSessionWideAgent = HerdLedgerColumns.measuring(
            sessionNames: ["a"],
            workspaces: ["b"],
            identifiers: ["an_extremely_descriptive_tab_label"],
            kinds: ["claude"],
            scale: Self.scale
        )
        let grown = Self.filtered.widened(to: narrowSessionWideAgent)
        #expect(grown.session == Self.filtered.session)
        #expect(grown.identifier == narrowSessionWideAgent.identifier)
        #expect(grown.identifier > Self.filtered.identifier)
    }

    /// The face has to be the monospaced one, not the proportional fallback.
    ///
    /// Resolving it by name was tried and silently produced Helvetica, whose advance at 10.5 pt is 8.75 pt,
    /// so every column would have been a third too wide and the mistake would have looked deliberate. In a
    /// monospaced face two strings of equal length measure equal, which is the cheapest way to assert the
    /// right font was found without hard-coding a number the system may retune.
    @Test func measuredFaceIsMonospaced() {
        let face = Self.scale.identifierFace
        #expect(face.width(of: "iiiiii") == face.width(of: "WWWWWW"))
        #expect(face.width(of: "ii") < face.width(of: "iiii"))
    }

    @Test func trackingIsChargedPerCharacter() {
        let plain = HerdLedgerFace(size: 8)
        let tracked = HerdLedgerFace(size: 8, tracking: 0.8)
        let text = "WORKSPACE"
        // Rounded up on both sides, so the difference is within a point of nine tracking steps.
        let difference = tracked.width(of: text) - plain.width(of: text)
        #expect(abs(difference - CGFloat(text.count) * 0.8) <= 1)
    }

    @Test func emptyStringMeasuresZero() {
        #expect(Self.scale.contextFace.width(of: "") == 0)
    }
}
