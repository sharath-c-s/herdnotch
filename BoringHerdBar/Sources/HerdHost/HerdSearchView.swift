import HerdHotKey
import HerdKit
import HerdPanelUI
import SwiftUI

// Like `HerdListView`, this file imports only SwiftUI and HerdKit, so it lifts into the boringNotch
// fork unchanged. Everything host-specific, which here means the global hotkey and the window that
// presents this view, lives in `HerdGlobalHotKey.swift` and `HerdSearchWindow.swift`.
//
// Why this surface exists: the panel is a 420 pt scroll view, and at sixteen agents across four
// sessions the user's only way to reach a known pane is to scroll and read. Search turns that back
// into typing a name, which is what they would do in the terminal.

/// A search field over every pane in the snapshot, with fuzzy matching and keyboard selection.
///
/// Deliberately not a filter applied to ``HerdListView``. The list's job is to answer "which agent
/// needs me", and it answers it with a tree and a deliberately quiet hierarchy; search answers "where
/// is the one I am thinking of", which wants a flat, ranked list where every row is equally loud
/// because the user has already told you what they want. Filtering the tree would have produced
/// single-agent sessions nested three levels deep for no reason.
///
/// Thread-safety: a SwiftUI `View`, so main-actor by construction. Ranking runs synchronously in
/// ``results``, which is affordable: sixteen panes times four short fields per keystroke.
struct HerdSearchView: View {
    /// Every pane that can be searched, already flattened from the snapshot by the host.
    ///
    /// Passed in rather than derived from a `HerdSnapshot` here so the window can re-flatten only when
    /// the snapshot actually changes, instead of on every keystroke.
    let panes: [HerdPane]

    /// Invoked with the chosen pane on Return or on a click.
    let onSelect: (HerdPane) -> Void

    /// Invoked on Escape, to close the window.
    let onDismiss: () -> Void

    /// Drives the palette. Dark is the tuned target.
    @Environment(\.colorScheme) private var colorScheme

    /// What the user has typed.
    @State private var query = ""

    /// Index into ``results`` of the highlighted row.
    ///
    /// Zero rather than `nil`, which is the opposite of the panel's rule and is correct here. In the
    /// panel, pre-selecting a row would be the app guessing; here the user has typed a query, so the
    /// top hit is the answer they asked for and Return has to work without an arrow press first.
    @State private var selection = 0

    /// Whether the text field holds keyboard focus.
    ///
    /// Assigned on appear on purpose: this window is opened by a global hotkey specifically so the user
    /// can start typing, so anything other than an immediately focused field would be a bug.
    @FocusState private var isFieldFocused: Bool

    /// Tokens for the current scheme.
    private var palette: HerdPalette { .resolving(colorScheme) }

    /// The current ranking. Recomputed per keystroke; see the type doc for why that is affordable.
    private var results: [HerdPaneSearchResult] {
        HerdPaneSearch.rank(panes, query: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
            Divider().overlay(palette.hairline)
            if results.isEmpty {
                Text("No pane matches that.")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textTertiary)
                    .padding(.horizontal, HerdMetric.inset)
                    .padding(.vertical, 12)
            } else {
                resultList
            }
        }
        .frame(width: HerdMetric.panelWidth)
        // The same opaque `surface` the panel uses, not a material. The three surfaces in this app were
        // each doing something different, which is why one of them let the desktop read through it, and
        // an opaque base is also what keeps the measured contrast ratios true rather than dependent on
        // whatever happens to be behind the window.
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(palette.hairline)
        )
        .onAppear { isFieldFocused = true }
        // Arrows are handled above the field because a single-line `TextField` does not consume them,
        // and putting them here means the selection moves while the caret stays where the user is
        // typing. Return is `onSubmit` on the field itself, which is where the key actually lands.
        .onKeyPress(.upArrow) { move(by: -1); return .handled }
        .onKeyPress(.downArrow) { move(by: 1); return .handled }
        .onExitCommand(perform: onDismiss)
    }

    // MARK: Field

    /// The query field. One line, no label, no placeholder chrome beyond the prompt.
    private var field: some View {
        HStack(spacing: 8) {
            // The panel's own idle glyph, reused as the search mark. A magnifier would be a new
            // vocabulary item for no gain, and the hollow ring already means "nothing in particular".
            Circle()
                .strokeBorder(palette.textTertiary, lineWidth: 1)
                .frame(width: 6, height: 6)
                .frame(width: HerdMetric.dotColumn)
            // The same face and size as the identifiers below it, because what the user types here is
            // a fragment of one. Setting the query in the chrome face would put the thing being
            // matched and the thing it matches against in two different typefaces, which makes
            // comparing them harder for no reason. This is the design's existing identifier role, not
            // a new one.
            TextField("Find a pane", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(palette.textPrimary)
                .focused($isFieldFocused)
                .onSubmit(activate)
                // Any edit invalidates the old selection: the row that was highlighted may not even be
                // in the new results, and leaving the index alone would silently point at a different
                // pane than the one under the highlight.
                .onChange(of: query) { _, _ in selection = 0 }
        }
        .padding(.leading, HerdMetric.dotIndent)
        .padding(.trailing, HerdMetric.inset)
        .padding(.vertical, 11)
    }

    // MARK: Results

    /// The ranked rows, scrolling once there are more than fit.
    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        HerdSearchRow(
                            result: result,
                            palette: palette,
                            isSelected: index == selection
                        ) {
                            onSelect(result.pane)
                        }
                        .id(result.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 320)
            .onChange(of: selection) { _, index in
                guard results.indices.contains(index) else { return }
                proxy.scrollTo(results[index].id, anchor: .center)
            }
        }
    }

    // MARK: Keyboard

    /// Moves the highlight, clamped at both ends.
    ///
    /// Clamped rather than wrapping: a list that jumps from the last row back to the first makes the
    /// user check where they are on every press, and the result count here is small enough that the
    /// ends are always in sight.
    ///
    /// - Parameter offset: `-1` for the previous row, `+1` for the next.
    private func move(by offset: Int) {
        let count = results.count
        guard count > 0 else { return }
        selection = min(max(selection + offset, 0), count - 1)
    }

    /// Acts on the highlighted row, if there is one.
    private func activate() {
        guard results.indices.contains(selection) else { return }
        onSelect(results[selection].pane)
    }
}

// MARK: - Result row

/// One ranked pane: status dot, tab label with the matched characters lit, agent kind, session, and
/// the working directory underneath.
///
/// Two lines rather than one because the identifier alone does not disambiguate: the same tab label
/// legitimately appears in two sessions, and a match earned by the `cwd` has to show the `cwd` or the
/// row looks like it was returned at random.
private struct HerdSearchRow: View {
    /// The ranked pane to render.
    let result: HerdPaneSearchResult

    /// Tokens for the current scheme.
    let palette: HerdPalette

    /// Whether this is the keyboard's current row.
    let isSelected: Bool

    /// Invoked on click.
    let onSelect: () -> Void

    /// Whether the cursor is over this row.
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            HerdStatusDot(status: result.pane.agent.agentStatus, palette: palette)
                .frame(width: HerdMetric.dotColumn)
            // Nudged down so the dot sits on the first line's baseline rather than centred across
            // both, which would leave it floating between the two texts belonging to neither.
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    highlighted(
                        HerdPaneSearch.text(of: .tabLabel, for: result.pane),
                        offsets: result.matchedField == .tabLabel ? result.matchedOffsets : [],
                        base: palette.textSecondary
                    )
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)

                    Text(result.pane.agent.agent.uppercased())
                        .font(.system(size: 9, weight: .medium))
                        .tracking(0.6)
                        .foregroundStyle(palette.textTertiary)

                    Spacer(minLength: 4)

                    highlighted(
                        result.pane.session.name,
                        offsets: result.matchedField == .sessionName ? result.matchedOffsets : [],
                        base: palette.textTertiary
                    )
                    .font(.system(size: 9.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                }

                highlighted(
                    result.pane.agent.cwd,
                    offsets: result.matchedField == .cwd ? result.matchedOffsets : [],
                    base: palette.textTertiary
                )
                .font(.system(size: 9.5))
                .lineLimit(1)
                .truncationMode(.head)
            }
            .padding(.leading, HerdMetric.dotGap)
        }
        .padding(.leading, HerdMetric.dotIndent)
        .padding(.trailing, HerdMetric.inset)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Selection is a ring plus a wash, not a solid fill. A `hairline` fill on its own was measured
        // at 1.28:1 against the surface, which is far under the 3:1 a state indicator needs, so the
        // thing telling the user which row Return would take was the weakest mark on screen. The ring
        // is `textSecondary` at 6.80:1 and does the actual signalling; the wash stays subtle so the row
        // texts keep the contrast they were measured for.
        .background(isHovering || isSelected ? palette.hairline.opacity(0.5) : .clear)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(isSelected ? palette.textSecondary : .clear, lineWidth: 1)
                // Inset by the same 6 pt the panel's selection ring uses. Run to the edges it read as a
                // pair of dividers above and below the row rather than as a box around it.
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onSelect)
    }

    /// Renders `text` with the characters at `offsets` lifted to ``HerdPalette/textPrimary``.
    ///
    /// Built by concatenating one `Text` per character rather than with `AttributedString`, because
    /// concatenated `Text` is what lets the whole thing still truncate and line-limit as a single run.
    /// The highlight is a step up the existing text ramp rather than a new accent, which is what keeps
    /// the two-saturated-colours rule intact on this surface as well.
    ///
    /// - Parameters:
    ///   - text: The string to render.
    ///   - offsets: Character offsets to lift. Empty renders the whole string at `base`, which is the
    ///     empty-query case and must stay comfortably readable rather than dimming a list the user
    ///     deliberately opened.
    ///   - base: Colour for the characters the query did not match. The tab label passes
    ///     ``HerdPalette/textSecondary`` because it is the content being chosen between; the `cwd` and
    ///     the session pass ``HerdPalette/textTertiary`` because they are context.
    /// - Returns: A single `Text` value.
    private func highlighted(_ text: String, offsets: [Int], base: Color) -> Text {
        guard !offsets.isEmpty else { return Text(text).foregroundColor(base) }
        let lit = Set(offsets)
        return text.enumerated().reduce(Text("")) { accumulated, pair in
            accumulated + Text(String(pair.element))
                .foregroundColor(lit.contains(pair.offset) ? palette.textPrimary : base)
        }
    }
}
