import Foundation
import HerdKit
import SwiftUI
import Testing

@testable import HerdPanelUI

/// Tests for the status palette: the status-to-hue mapping, and the contrast floors under it.
///
/// The contrast half exists because the palette grew from two saturated colours to four on a preference
/// rather than on a measurement, and the measurement is the part that must not be lost in the trade. Every
/// number in ``HerdPalette``'s doc tables is asserted here, so a later tweak that dims a hue below its floor
/// fails a test instead of shipping and being noticed on a bright day six months later.
///
/// Ratios are computed from SwiftUI's own resolved colour rather than from hex strings copied into the test.
/// `Color.Resolved` exposes `linearRed`/`linearGreen`/`linearBlue`, which are already in the linear space
/// WCAG's relative-luminance formula wants, so there is no sRGB transfer function to reimplement and get
/// subtly wrong. Reading the value SwiftUI will actually draw also means the test cannot pass against a hex
/// literal that the shipped `Color` no longer matches.
struct HerdPaletteTests {

    /// Minimum ratio for anything drawn as text.
    ///
    /// 4.5:1 rather than 3:1 because every face in the app is under 18 pt at every step of
    /// ``HerdLedgerScale/selectableIdentifierSizes``, so WCAG's large-text exemption never applies.
    private static let textFloor = 4.5

    /// Minimum ratio for a non-text indicator: a dot, a ring, a triangle, a checkmark.
    private static let markFloor = 3.0

    /// WCAG 2.1 relative luminance of a resolved colour.
    ///
    /// - Parameter colour: A colour resolved against an environment.
    /// - Returns: Relative luminance in `0...1`.
    private func luminance(_ colour: Color.Resolved) -> Double {
        0.2126 * Double(colour.linearRed)
            + 0.7152 * Double(colour.linearGreen)
            + 0.0722 * Double(colour.linearBlue)
    }

    /// WCAG 2.1 contrast ratio between two colours.
    ///
    /// - Parameters:
    ///   - foreground: The mark or text colour.
    ///   - background: The surface it is drawn on.
    /// - Returns: A ratio from 1 (identical) to 21 (black on white).
    private func ratio(_ foreground: Color, on background: Color) -> Double {
        let environment = EnvironmentValues()
        let a = luminance(foreground.resolve(in: environment))
        let b = luminance(background.resolve(in: environment))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Asserts one token clears its floor against both backgrounds it can be drawn on.
    ///
    /// Both, not just the surface: a row under the cursor is filled with ``HerdPalette/hoverFill``, which is
    /// lighter, so the hover state is always the tighter of the two measurements and is the one an
    /// eyeballed palette gets wrong.
    ///
    /// - Parameters:
    ///   - colour: The token to measure.
    ///   - palette: The palette it came from, supplying both backgrounds.
    ///   - floor: ``textFloor`` or ``markFloor``.
    ///   - name: Token name, for the failure message.
    private func expect(
        _ colour: Color,
        in palette: HerdPalette,
        clears floor: Double,
        _ name: String
    ) {
        let onSurface = ratio(colour, on: palette.surface)
        let onHover = ratio(colour, on: palette.hoverFill)
        #expect(
            onSurface >= floor,
            "\(name) on surface measured \(onSurface), floor \(floor)"
        )
        #expect(
            onHover >= floor,
            "\(name) on hoverFill measured \(onHover), floor \(floor)"
        )
    }

    // MARK: Mapping

    @Test("every status herdr can report has an accent, and only unknown is colourless")
    func accentsCoverEveryStatus() {
        for palette in [HerdPalette.dark, HerdPalette.light] {
            #expect(palette.accent(for: .blocked) != nil)
            #expect(palette.accent(for: .done) != nil)
            #expect(palette.accent(for: .working) != nil)
            #expect(palette.accent(for: .idle) != nil)
            // Colourless on purpose: a hue is a claim about what the agent is doing, and `unknown` is the
            // case where the app has no such claim to make.
            #expect(palette.accent(for: .unknown) == nil)
        }
    }

    @Test("the accent for each status is that status's own token, not a borrowed one")
    func accentsAreDistinct() {
        for palette in [HerdPalette.dark, HerdPalette.light] {
            let environment = EnvironmentValues()
            let hues = [AgentStatus.blocked, .done, .working, .idle]
                .compactMap { palette.accent(for: $0) }
                .map { $0.resolve(in: environment) }
            // Four statuses, four different colours. A duplicate here would mean two states that the user
            // is meant to tell apart at a glance render identically.
            #expect(hues.count == 4)
            #expect(Set(hues.map { "\($0.red),\($0.green),\($0.blue)" }).count == 4)
        }
    }

    @Test("done has its own word, distinct from idle")
    func donePhrase() {
        #expect(AgentStatus.done.phrase == "done")
        #expect(AgentStatus.done.phrase != AgentStatus.idle.phrase)
    }

    // MARK: Contrast, dark

    @Test("every dark token clears its floor on both the surface and the hover fill")
    func darkContrast() {
        let palette = HerdPalette.dark

        expect(palette.textPrimary, in: palette, clears: Self.textFloor, "textPrimary")
        expect(palette.textSecondary, in: palette, clears: Self.textFloor, "textSecondary")
        expect(palette.textTertiary, in: palette, clears: Self.textFloor, "textTertiary")
        expect(palette.textIdle, in: palette, clears: Self.textFloor, "textIdle")

        // `blocked` and `done` are drawn as text, on the identifier of a row and (for `blocked`) on the
        // banner, the stand-in lines and the settings warnings, so they carry the text floor.
        expect(palette.blocked, in: palette, clears: Self.textFloor, "blocked")
        expect(palette.done, in: palette, clears: Self.textFloor, "done")

        // `working` and `idle` are only ever marks.
        expect(palette.working, in: palette, clears: Self.markFloor, "working")
        expect(palette.idle, in: palette, clears: Self.markFloor, "idle")
    }

    // MARK: Contrast, light

    @Test("every light token clears its floor on both the surface and the hover fill")
    func lightContrast() {
        let palette = HerdPalette.light

        expect(palette.textPrimary, in: palette, clears: Self.textFloor, "textPrimary")
        expect(palette.textSecondary, in: palette, clears: Self.textFloor, "textSecondary")
        expect(palette.textTertiary, in: palette, clears: Self.textFloor, "textTertiary")
        expect(palette.textIdle, in: palette, clears: Self.textFloor, "textIdle")

        expect(palette.blocked, in: palette, clears: Self.textFloor, "blocked")
        expect(palette.done, in: palette, clears: Self.textFloor, "done")

        expect(palette.working, in: palette, clears: Self.markFloor, "working")
        expect(palette.idle, in: palette, clears: Self.markFloor, "idle")
    }

    // MARK: Contrast, cardFill

    /// `cardFill` itself is decorative — see its own documentation for why it carries no contrast floor —
    /// but the bento notch layout draws every one of these tokens directly on top of it (agent
    /// identifiers, session/workspace text, status dots, the done checkmark, the blocked due-label), so
    /// what actually needs measuring is that they still clear their usual floor against this new
    /// background, not just against ``HerdPalette/surface`` and ``HerdPalette/hoverFill``.
    @Test("every token the bento layout draws on cardFill still clears its floor there, in both palettes")
    func cardFillHoldsTheUsualFloors() {
        for palette in [HerdPalette.dark, HerdPalette.light] {
            func onCardFill(_ colour: Color, clears floor: Double, _ name: String) {
                let measured = ratio(colour, on: palette.cardFill)
                #expect(measured >= floor, "\(name) on cardFill measured \(measured), floor \(floor)")
            }

            onCardFill(palette.textPrimary, clears: Self.textFloor, "textPrimary")
            onCardFill(palette.textSecondary, clears: Self.textFloor, "textSecondary")
            onCardFill(palette.textTertiary, clears: Self.textFloor, "textTertiary")
            onCardFill(palette.textIdle, clears: Self.textFloor, "textIdle")
            onCardFill(palette.blocked, clears: Self.textFloor, "blocked")
            onCardFill(palette.done, clears: Self.textFloor, "done")

            onCardFill(palette.working, clears: Self.markFloor, "working")
            onCardFill(palette.idle, clears: Self.markFloor, "idle")
        }
    }

    // MARK: Emphasis

    @Test("idle is the quietest of the four hues, and no louder than the grey ring it replaced")
    func idleStaysRecessive() {
        // The reason this is pinned: idle is fourteen of sixteen rows on an ordinary day, so it is the one
        // hue that could drown the other three by sheer count. It was chosen to sit at the loudness of the
        // `textTertiary` ring it replaced, and this asserts that property rather than the hex value, so a
        // future re-pick has to preserve the intent rather than the literal.
        for palette in [HerdPalette.dark, HerdPalette.light] {
            let idle = ratio(palette.idle, on: palette.surface)
            #expect(idle <= ratio(palette.blocked, on: palette.surface))
            #expect(idle <= ratio(palette.done, on: palette.surface))
            #expect(idle <= ratio(palette.working, on: palette.surface))
            #expect(idle <= ratio(palette.textTertiary, on: palette.surface) + 0.1)
        }
    }
}
