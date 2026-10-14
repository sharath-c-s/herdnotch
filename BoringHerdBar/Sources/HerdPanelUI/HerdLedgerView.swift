import HerdKit
import SwiftUI

// The panel's content, and the file that lifts into the boringNotch fork verbatim.
//
// It lives in its own library target rather than beside the app's host files, which makes most of the
// portability rule mechanical instead of aspirational: this target depends on HerdKit and nothing else, so
// it cannot see `HerdBarModel`, `HerdPreferences`, the status item or any other host type, and coupling to
// one fails to compile rather than failing review. AppKit is a system framework and stays importable by any
// macOS target, so keeping it out remains a rule a human enforces; the target boundary just reduces that to
// checking two import lines.
//
// Direction: LEDGER. The panel is a readout, so it is set as one. One monospaced face, one line per
// agent, fixed columns, no nesting. Hierarchy is columnar rather than spatial: the session and
// workspace columns print a value only when it changes, so grouping appears as whitespace the way it
// does in a real report, and no indentation ladder is needed. The leftmost 13 pt is a gutter of status
// sigils, which turns the panel's left edge into a barcode the eye reads in one saccade before it has
// read a single word.
//
// There is no motion anywhere in this file, and that is a hard requirement rather than a preference.
// A repeating SwiftUI animation never completes, so its transaction stays pending and
// `GraphHost.flushTransactions` runs on every pass of the run loop: measured at 19 % of a core with the
// panel merely open, and reported by the user at 99 %. A finite animation retriggered from the poll
// tick measured 18 %, so the cost is having any animation in flight over a popover whose backdrop
// AppKit recomposites, not the repeat. Status is therefore carried by shape, size, fill and weight.

// MARK: - Row model

/// One printed line of the ledger.
///
/// Flattening happens once, in ``HerdLedgerView/lines``, rather than inside nested `ForEach` views,
/// because elision is a property of the printed *sequence*: whether a session name prints depends on the
/// line before it, which a nested loop cannot see.
struct HerdLedgerLine: Identifiable {
    /// Stable identity, unique across sessions.
    let id: String
    /// The owning session, needed to act on the row.
    let session: HerdSession
    /// The agent, or `nil` for a stopped session's placeholder line.
    let agent: HerdAgent?
    /// The workspace containing ``agent``, resolved once here so the row never searches for it.
    let workspace: HerdWorkspace?
    /// Session name, or empty when the line above already printed it.
    let sessionText: String
    /// Workspace name, or empty when the line above already printed it.
    let workspaceText: String
    /// Whether this line begins a new session, and therefore gets the group gap above it.
    let startsGroup: Bool
    /// Whether this agent finished inside the model's recency window.
    ///
    /// Resolved once here rather than looked up per subview, so the row never has to know how the recency
    /// key is composed.
    let isRecentlyCompleted: Bool
    /// Whether the owning session is running but has no terminal attached.
    let isDetached: Bool
    /// Whether the owning session was reached through a forwarded socket rather than `~/.config/herdr`.
    ///
    /// Read from the session rather than passed in alongside, unlike ``isDetached``, because it is a
    /// property of how the session was discovered and travels inside the snapshot. Attachment is not: it
    /// costs a round trip the snapshot does not make.
    let isRemote: Bool
    /// Session-scoped markers to print on their own line, or empty on every other line.
    ///
    /// A line carrying markers is neither an agent row nor a session stand-in: it is the words `remote` and
    /// `no terminal` printed under the session name they describe, outside the grid. They used to share the
    /// session cell with the name, which made them part of the session column's measured content, and
    /// `no terminal` was the widest thing that column ever held. One detached session therefore set the
    /// width for every row in the panel. Putting them on their own line is what takes them out of the shared
    /// geometry entirely, rather than merely making them cheaper to measure.
    let markers: [String]

    /// For a line that stands in for a whole session rather than an agent, what to say about it.
    ///
    /// `nil` on an agent line. Non-nil covers every reason a session contributes no rows: it is stopped,
    /// it failed to answer, or it is running with nothing in it. All three must be visible. A session that
    /// silently vanishes is the exact failure the models were written to avoid, because the user cannot
    /// tell it apart from a broken panel, and this view reintroduced it by only ever emitting lines from
    /// inside a workspace loop.
    let placeholder: String?
    /// Whether ``placeholder`` reports a fault rather than a state, which selects its colour.
    let placeholderIsError: Bool
}

// MARK: - View

/// The session, workspace and agent ledger.
///
/// Renders a ``HerdSnapshot`` exactly as given: it never sorts and never counts, because the model layer
/// has already done both. Sorting in a `body` would re-run on every redraw and would let two surfaces
/// disagree about row order.
///
/// Thread-safety: a SwiftUI `View`, so main-actor by construction. The callbacks are invoked on the main
/// actor and must return promptly; a host needing blocking herdr I/O has to hop off the main thread
/// itself.
public struct HerdLedgerView: View {
    /// The tree to render, already ordered and aggregated by the model.
    let snapshot: HerdSnapshot

    /// Keys, from ``HerdUrgencyOrder/key(sessionName:paneId:)``, of agents that finished recently.
    ///
    /// The same set that ordered the snapshot, which is the point: the ordering floats these rows up and
    /// this marks them, so the user can see *why* a row moved. Ordering without the mark would silently
    /// promote an agent that looks identical to the idle ones beneath it, which is a reordering the user
    /// cannot account for and would read as the panel shuffling at random.
    let recentlyCompleted: Set<String>

    /// Names of sessions that are running but have no terminal attached to them.
    ///
    /// This is the fix for the bug the user actually reported. A herdr session is a headless server, so it
    /// can be running with live agents while no terminal is attached; clicking such an agent focuses the
    /// pane server-side, every call succeeds, and nothing appears to happen, because there was never a
    /// window to bring forward. The panel used to render those sessions as though they were switchable.
    ///
    /// It is not guesswork: `client.window_title.set` answers it in one round trip, reporting
    /// `no_foreground_client` for a running session with nothing attached.
    let detachedSessions: Set<String>

    /// Every size in the panel, derived from one configurable base.
    ///
    /// Passed in rather than read from a preference, because this module may not see a host type. The host
    /// maps its own stored setting onto a ``HerdLedgerScale``, which is the same contract the banner uses:
    /// a value in, no knowledge of where it came from, so the file still lifts into another host unchanged.
    let scale: HerdLedgerScale

    /// One quiet sentence explaining why the rows are not the whole truth, or `nil` when they are.
    ///
    /// A plain optional string rather than the host's state enum, so this module needs no type from the
    /// app and the app needs no type from this module. The host maps its own state onto these two
    /// parameters, which is a smaller contract than sharing an enum and cannot drift.
    let banner: String?

    /// Whether ``banner`` describes a fault rather than a state, which selects its colour.
    let bannerIsError: Bool

    /// The fixed width a host gives this ledger, or `nil` (the default) for this view's original behaviour:
    /// measuring its own columns and sizing the surface around them, with no upper bound of its own.
    ///
    /// Opt-in, and `nil` by default, specifically so `BoringHerdBar` (which calls
    /// ``init(snapshot:recentlyCompleted:detachedSessions:scale:availableWidth:showsHeaderDivider:banner:bannerIsError:onSelectAgent:onSelectSession:onSelectWorkspace:onDismiss:)``
    /// without naming this parameter) is byte-for-byte unaffected by HerdNotch's Ledger+Rail layout needing
    /// this view to fit a fixed 488pt region instead. When set, ``fittedColumns`` shrinks ``HerdLedgerColumns/workspace``
    /// (never the agent identifier) to fit, the KIND column measures and prints a 4-character code with the
    /// full kind name moved into a `.help` tooltip, and the workspace cell's truncation mode switches from
    /// tail to middle — see the Ledger+Rail design spec's "AI agents ledger" section for why: a workspace
    /// name's most identifying characters are often at both ends (`herd-notch-ledger` vs. `herd-search-ui`),
    /// which tail truncation collapses to the same prefix.
    let availableWidth: CGFloat?

    /// Whether ``columnHeadings`` draws its own trailing hairline divider. `true` (the default) preserves
    /// this view's original look for `BoringHerdBar`, which owns no divider of its own above the ledger.
    /// HerdNotch's Ledger+Rail layout passes `false`: that layout's design spec calls for **exactly one**
    /// hairline in the whole open panel (under the top utility band), so a second one here, directly above
    /// a ledger that already sits below that band's own divider, would be a divider this view draws that the
    /// spec does not call for.
    let showsHeaderDivider: Bool

    /// Invoked when the user clicks an agent row, or presses Return on the selected one.
    ///
    /// Both the session and the agent are passed because an agent alone cannot be acted on: a `paneId`
    /// such as `w1:p1` is unique only within its session, and the host needs the session's `socketPath`
    /// to send anything.
    let onSelectAgent: (HerdSession, HerdAgent) -> Void

    /// Invoked when the user clicks a printed session name.
    let onSelectSession: (HerdSession) -> Void

    /// Invoked when the user clicks a printed workspace name.
    let onSelectWorkspace: (HerdSession, HerdWorkspace) -> Void

    /// Asks the host to close whatever surface is presenting this ledger, on Escape.
    ///
    /// Explicit rather than left to the popover, because this view takes keyboard focus in order to
    /// receive arrow keys, and a focused SwiftUI view that consumes key events is exactly the thing that
    /// can stop Escape reaching the window.
    let onDismiss: () -> Void

    /// Drives the palette. Dark is the tuned target.
    @Environment(\.colorScheme) private var colorScheme

    /// Which row the keyboard is on, or `nil` for none.
    ///
    /// Plain `@State` rather than `@FocusState`. SwiftUI hands focus to the first `.focusable()`
    /// descendant the moment the popover becomes key, so with per-row focus state the panel opened with
    /// row one already selected behind the scenes and the first Down press appeared to skip it. Selection
    /// that SwiftUI does not own cannot be pre-assigned.
    @State private var selectedRow: String?

    /// Whether the user has reached for the keyboard yet.
    ///
    /// Gates the selection ring so a mouse user never sees one they did not ask for, and gates Return so
    /// the keyboard cannot act on a row that is not visibly selected.
    @State private var isKeyboardActive = false

    /// The column widths currently in force.
    ///
    /// State rather than a computed property, because the widths have to be allowed to lag the content: see
    /// ``HerdLedgerColumns/widened(to:)`` for why they only grow while the panel is on screen. The initial
    /// value is measured in ``init(snapshot:recentlyCompleted:detachedSessions:banner:bannerIsError:onSelectAgent:onSelectSession:onSelectWorkspace:onDismiss:)``
    /// rather than left to `onAppear`, so the very first paint is already the right width. Seeding it later
    /// would show one frame at the wrong size and make the popover resize itself the moment it opened.
    @State private var columns: HerdLedgerColumns

    /// Creates the ledger.
    ///
    /// - Parameters:
    ///   - snapshot: The tree to render, already ordered by the model.
    ///   - recentlyCompleted: Keys of agents that finished inside the model's recency window.
    ///   - detachedSessions: Names of running sessions with no terminal attached.
    ///   - scale: Every size in the panel, derived from the configured identifier size.
    ///   - availableWidth: The fixed width a host gives this ledger, or `nil` (the default) for this view's
    ///     original self-sizing behaviour. See ``availableWidth``'s own documentation.
    ///   - showsHeaderDivider: Whether ``columnHeadings`` draws its own trailing hairline. `true` by default,
    ///     preserving this view's original look; see ``showsHeaderDivider``'s own documentation.
    ///   - banner: One sentence above the rows, or `nil`.
    ///   - bannerIsError: Whether ``banner`` is a fault rather than a state.
    ///   - onSelectAgent: Invoked with the session and agent when a row is activated.
    ///   - onSelectSession: Invoked when a printed session name is clicked.
    ///   - onSelectWorkspace: Invoked when a printed workspace name is clicked.
    ///   - onDismiss: Invoked on Escape.
    public init(
        snapshot: HerdSnapshot,
        recentlyCompleted: Set<String>,
        detachedSessions: Set<String>,
        scale: HerdLedgerScale,
        availableWidth: CGFloat? = nil,
        showsHeaderDivider: Bool = true,
        banner: String?,
        bannerIsError: Bool,
        onSelectAgent: @escaping (HerdSession, HerdAgent) -> Void,
        onSelectSession: @escaping (HerdSession) -> Void,
        onSelectWorkspace: @escaping (HerdSession, HerdWorkspace) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.recentlyCompleted = recentlyCompleted
        self.detachedSessions = detachedSessions
        self.scale = scale
        self.availableWidth = availableWidth
        self.showsHeaderDivider = showsHeaderDivider
        self.banner = banner
        self.bannerIsError = bannerIsError
        self.onSelectAgent = onSelectAgent
        self.onSelectSession = onSelectSession
        self.onSelectWorkspace = onSelectWorkspace
        self.onDismiss = onDismiss
        self._columns = State(
            initialValue: Self.measuredColumns(
                for: Self.printedLines(
                    snapshot: snapshot,
                    recentlyCompleted: recentlyCompleted,
                    detachedSessions: detachedSessions
                ),
                scale: scale,
                availableWidth: availableWidth
            )
        )
    }

    /// Tokens for the current scheme.
    private var palette: HerdPalette { .resolving(colorScheme) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let banner {
                Text(banner)
                    .font(.system(size: scale.bannerSize))
                    .foregroundStyle(bannerIsError ? palette.blocked : palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, scale.inset)
                    .padding(.top, 11)
                    .padding(.bottom, 9)
            }
            if snapshot.sessions.isEmpty {
                Text("Run herdr in a terminal to start one.")
                    .font(.system(size: scale.bannerSize))
                    .foregroundStyle(palette.textTertiary)
                    .padding(.horizontal, scale.inset)
                    .padding(.bottom, 12)
            } else {
                columnHeadings
                ledgerBody
            }
        }
        .frame(
            width: columns.totalWidth(scale: scale),
            alignment: .leading
        )
        // The surface, actually applied. This is the fix for the defect that mattered most: the token was
        // documented and never painted, so the terminal read through the panel.
        .background(palette.surface)
        // Reseeded on presentation and only widened while presented. This is the whole of the anti-thrash
        // policy and it is two lines because the policy is monotone: see
        // ``HerdLedgerColumns/widened(to:)``. The panel narrows when it is next opened, which is when the
        // user who has just changed the session filter is looking at it.
        .onAppear { columns = fit(measuredColumns) }
        // A size change **replaces** the table rather than widening it. The grow-only rule exists to stop a
        // 1 Hz snapshot resizing the popover under a reading cursor, and a type-size change is not that: it
        // is a deliberate act whose whole point is visible, and stepping down from 16.5 pt would otherwise
        // leave the panel stuck at its widest until the next time it was opened.
        .onChange(of: scale) { _, _ in columns = fit(measuredColumns) }
        .onChange(of: measuredColumns) { _, measured in
            // An empty ledger resets outright rather than widening, so a panel that has shown a wide herd
            // and now shows none does not keep the space it no longer uses.
            //
            // `fit(_:)` is applied even on this grow-only path, not only in ``measuredColumns`` itself: when
            // ``availableWidth`` is set, `widened(to:)`'s per-column max can grow SESSION, AGENT or KIND past
            // what fits (each of those already came out of a `fit`-ted table, but the max of two different
            // fits is not itself guaranteed to still fit), and only re-clamping WORKSPACE after the merge
            // keeps every intermediate state, not just the first one, inside `availableWidth`.
            columns = fit(lines.isEmpty ? measured : columns.widened(to: measured))
        }
    }

    /// Re-clamps `columns` to fit ``availableWidth``, or returns it unchanged when ``availableWidth`` is
    /// `nil` — see ``HerdLedgerColumns/fitted(within:scale:)``'s own documentation for what "fit" means here
    /// (only ``HerdLedgerColumns/workspace`` ever shrinks).
    ///
    /// - Parameter columns: A freshly measured or merged column table.
    /// - Returns: `columns`, fitted to ``availableWidth`` if one was given.
    private func fit(_ columns: HerdLedgerColumns) -> HerdLedgerColumns {
        guard let availableWidth else { return columns }
        return columns.fitted(within: availableWidth, scale: scale)
    }

    /// The Ledger+Rail layout's 4-character KIND code for one agent kind (for example `"claude"` →
    /// `"clau"`), used for both the KIND column's measured width and its printed text whenever
    /// ``availableWidth`` is set.
    ///
    /// A flat 4-character prefix rather than a curated per-kind abbreviation table (`cc`/`cx`/`gm` and so
    /// on, as the design spec's own mock-up shows): a curated table needs updating every time a new agent
    /// kind ships, where a prefix needs none, and the full name is never actually lost — it moves to
    /// ``HerdLedgerRow``'s `.help` tooltip on the same cell rather than being discarded.
    ///
    /// - Parameter kind: The full kind string, for example `"claude"`.
    /// - Returns: The first four characters, or `kind` itself if it is already four characters or shorter.
    ///
    /// `fileprivate`, not `private`: ``HerdLedgerRow`` (this file's other type) calls it too, to print the
    /// same code this measured its column from, and `private` would not extend to a sibling type in the same
    /// file the way it does to an extension of the same type.
    fileprivate static func kindCode(_ kind: String) -> String { String(kind.prefix(4)) }

    /// Measures the columns one set of printed lines needs.
    ///
    /// Only lines that print into the grid contribute. A blank continuation cell constrains nothing, and a
    /// stopped or failed session's stand-in line, like a session-marker line, is drawn as a free line
    /// outside the grid, so its text is not in any column and must not size one. Filtering on `agent != nil`
    /// covers both, which is why the marker line is modelled as a line rather than as extra content inside
    /// an agent row.
    ///
    /// - Parameters:
    ///   - lines: The printed sequence.
    ///   - scale: The current scale, supplying the faces to measure in and the per-column clamps.
    ///   - availableWidth: The fixed width to fit within, or `nil` for this view's original unbounded
    ///     behaviour. When non-`nil`, the KIND column is measured from ``kindCode(_:)``'s 4-character codes
    ///     rather than the full kind strings, and the result is passed through
    ///     ``HerdLedgerColumns/fitted(within:scale:)`` before being returned.
    /// - Returns: The clamped column table.
    private static func measuredColumns(
        for lines: [HerdLedgerLine],
        scale: HerdLedgerScale,
        availableWidth: CGFloat?
    ) -> HerdLedgerColumns {
        let agentLines = lines.filter { $0.agent != nil }
        let measured = HerdLedgerColumns.measuring(
            sessionNames: agentLines.map(\.sessionText).filter { !$0.isEmpty },
            workspaces: agentLines.map(\.workspaceText),
            identifiers: agentLines.compactMap { $0.agent?.displayIdentifier },
            kinds: agentLines.compactMap { line in
                guard let kind = line.agent?.agent else { return nil }
                return availableWidth == nil ? kind : kindCode(kind)
            },
            scale: scale
        )
        guard let availableWidth else { return measured }
        return measured.fitted(within: availableWidth, scale: scale)
    }

    /// Every agent row in display order, flattened, so arrow keys walk the ledger as one list.
    ///
    /// Excludes stopped sessions' placeholder lines: they are not actionable, and stopping on them would
    /// make Down press twice to cross a session that has nothing in it.
    private var keyboardRows: [HerdLedgerLine] {
        lines.filter { $0.agent != nil }
    }

    /// The printed sequence, with repeated session and workspace values suppressed.
    ///
    /// Rebuilt per body evaluation rather than cached: the snapshot is already ordered and the ledger is
    /// tens of lines, so the walk is cheaper than the invalidation bookkeeping a cache would need.
    private var lines: [HerdLedgerLine] {
        Self.printedLines(
            snapshot: snapshot,
            recentlyCompleted: recentlyCompleted,
            detachedSessions: detachedSessions
        )
    }

    /// The column widths the current lines need, before the grow-only rule is applied.
    private var measuredColumns: HerdLedgerColumns {
        Self.measuredColumns(for: lines, scale: scale, availableWidth: availableWidth)
    }

    /// Builds the printed sequence.
    ///
    /// A static function rather than only a computed property because the widths have to be measured in
    /// `init`, before `self` exists as a view with state, and measuring needs the lines.
    ///
    /// - Parameters:
    ///   - snapshot: The tree to print, already ordered.
    ///   - recentlyCompleted: Recency keys, used to mark rows.
    ///   - detachedSessions: Names of running sessions with no terminal attached.
    /// - Returns: The lines in print order.
    private static func printedLines(
        snapshot: HerdSnapshot,
        recentlyCompleted: Set<String>,
        detachedSessions: Set<String>
    ) -> [HerdLedgerLine] {
        var out: [HerdLedgerLine] = []
        for session in snapshot.sessions {
            let isDetached = detachedSessions.contains(session.name)
            let agentCount = session.workspaces.reduce(0) { $0 + $1.agents.count }

            // Three ways a session contributes no agent rows, and all three have to say so. Reporting a
            // per-session error matters most: `HerdSnapshotBuilder` returns a running-but-failed session
            // with empty workspaces, so without this the session disappears from the panel while herdr
            // still lists its agents. That was found by reconciling the rows against `agent.list`.
            if let placeholder = Self.placeholder(for: session, agentCount: agentCount) {
                out.append(HerdLedgerLine(
                    id: "\(session.name)\u{1}placeholder",
                    session: session,
                    agent: nil,
                    workspace: nil,
                    sessionText: session.name,
                    workspaceText: "",
                    startsGroup: !out.isEmpty,
                    isRecentlyCompleted: false,
                    isDetached: isDetached,
                    isRemote: session.isRemote,
                    markers: [],
                    placeholder: placeholder.text,
                    placeholderIsError: placeholder.isError
                ))
                continue
            }
            var printedSession = false
            for workspace in session.workspaces {
                var printedWorkspace = false
                for agent in workspace.agents {
                    let key = HerdUrgencyOrder.key(sessionName: session.name, paneId: agent.paneId)
                    out.append(HerdLedgerLine(
                        id: key,
                        session: session,
                        agent: agent,
                        workspace: workspace,
                        sessionText: printedSession ? "" : session.name,
                        workspaceText: printedWorkspace ? "" : (workspace.label ?? workspace.workspaceId),
                        startsGroup: !printedSession && !out.isEmpty,
                        isRecentlyCompleted: recentlyCompleted.contains(key),
                        isDetached: isDetached,
                        isRemote: session.isRemote,
                        markers: [],
                        placeholder: nil,
                        placeholderIsError: false
                    ))
                    // Directly under the row that printed the name, because that is the name the markers are
                    // about and there is no other line in the group they could be read as belonging to. Once
                    // per session, like the name itself.
                    if !printedSession {
                        let markers = Self.markers(isDetached: isDetached, isRemote: session.isRemote)
                        if !markers.isEmpty {
                            out.append(HerdLedgerLine(
                                id: "\(session.name)\u{1}markers",
                                session: session,
                                agent: nil,
                                workspace: nil,
                                sessionText: "",
                                workspaceText: "",
                                startsGroup: false,
                                isRecentlyCompleted: false,
                                isDetached: isDetached,
                                isRemote: session.isRemote,
                                markers: markers,
                                placeholder: nil,
                                placeholderIsError: false
                            ))
                        }
                    }
                    printedSession = true
                    printedWorkspace = true
                }
            }
        }
        return out
    }

    /// The session-scoped markers to print for one session, in reading order.
    ///
    /// Remote comes first because it is the more fundamental of the two: it says which machine the session is
    /// on, and "no terminal" is then a fact about that machine.
    ///
    /// - Parameters:
    ///   - isDetached: Whether the session is running with no terminal attached.
    ///   - isRemote: Whether the session was reached through a forwarded socket.
    /// - Returns: The marker words, empty when the session needs no marker line at all.
    private static func markers(isDetached: Bool, isRemote: Bool) -> [String] {
        var out: [String] = []
        if isRemote { out.append(HerdLedgerColumns.remoteMarker) }
        if isDetached { out.append(HerdLedgerColumns.detachedMarker) }
        return out
    }

    /// What to print for a session that contributes no agent rows, or `nil` when it has rows.
    ///
    /// - Parameters:
    ///   - session: The session being printed.
    ///   - agentCount: How many agents it actually contains.
    /// - Returns: The stand-in text and whether it is a fault, or `nil` when the session has agents to
    ///   print instead.
    private static func placeholder(
        for session: HerdSession,
        agentCount: Int
    ) -> (text: String, isError: Bool)? {
        // A remote session that will not connect is not "stopped": the local end of a forward is a socket
        // this machine cannot see past, so what failed could be the tunnel, the far host, or the herdr
        // server on it, and the panel does not know which. Saying "stopped" would name one of the three and
        // would send the user to `herdr session start` on the wrong machine.
        if !session.running { return (session.isRemote ? "not reachable" : "stopped", false) }
        // Checked before the empty case, because a session that failed to answer also looks empty and the
        // reason is the useful part.
        if let error = session.error { return (error, true) }
        if agentCount == 0 { return ("no agents", false) }
        return nil
    }

    /// The scrollable body plus the keyboard contract.
    ///
    /// A `ScrollView` capped at ``HerdLedgerScale/maxBodyHeight`` even though sixteen agents across four
    /// sessions measure well under it, because there is no ceiling on either number and a panel taller
    /// than the screen is worse than a scroll. `VStack` rather than `LazyVStack`: laziness was measured to
    /// make no difference to the idle cost, and an eager stack is what lets the popover size itself
    /// correctly on first paint.
    ///
    /// ``ScrollViewReader`` scrolls to the keyboard selection explicitly, because selection here is plain
    /// state rather than focus, so SwiftUI does not do it for free. The `scrollTo` is deliberately not
    /// wrapped in `withAnimation`: nothing in this view animates.
    private var ledgerBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        HerdLedgerRow(
                            line: line,
                            columns: columns,
                            scale: scale,
                            palette: palette,
                            isSelected: isKeyboardActive && selectedRow == line.id,
                            isCompactLayout: availableWidth != nil,
                            onSelectAgent: { agent in onSelectAgent(line.session, agent) },
                            onSelectSession: { onSelectSession(line.session) },
                            onSelectWorkspace: { workspace in onSelectWorkspace(line.session, workspace) }
                        )
                        .id(line.id)
                    }
                }
                .padding(.bottom, scale.bottomPadding)
            }
            .frame(maxHeight: scale.maxBodyHeight)
            .onChange(of: selectedRow) { _, key in
                guard let key else { return }
                proxy.scrollTo(key, anchor: .center)
            }
        }
        // Focus lives on the container, not on the rows: it is what makes arrow keys reach this view at
        // all, and putting it here rather than on each row is what stops SwiftUI pre-selecting row one
        // when the popover becomes key.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
        .onKeyPress(.return) { activateSelection() ? .handled : .ignored }
        .onExitCommand(perform: onDismiss)
    }

    /// The column headings.
    ///
    /// Chrome that never changes, and it earns its keep: it is what tells the user in the first second
    /// that this is a table with columns rather than a list with odd spacing, and it gives the panel an
    /// identity without a title bar. Set in the same face and at ``HerdPalette/textTertiary``, so it
    /// clears the text floor rather than being decorative text nobody can read.
    private var columnHeadings: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: scale.sigilColumn)
            heading("session", width: columns.session)
            heading("workspace", width: columns.workspace)
            heading("agent", width: columns.identifier)
            heading("kind", width: columns.kind)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, scale.inset)
        .padding(.top, banner == nil ? 11 : 2)
        .padding(.bottom, 5)
        .overlay(alignment: .bottom) {
            // Gated on ``showsHeaderDivider``: HerdNotch's Ledger+Rail layout passes `false` because that
            // layout's design spec calls for exactly one hairline divider in the whole open panel, already
            // drawn under its own top utility band — a second one here would be a divider the spec does not
            // call for. `BoringHerdBar` never sets this parameter, so it keeps drawing this hairline exactly
            // as before.
            if showsHeaderDivider {
                Rectangle()
                    .fill(palette.hairline)
                    .frame(height: 1)
                    .padding(.horizontal, scale.inset)
            }
        }
        // A heading row is a label for the grid, not content, and reading four column names aloud before
        // every list is noise in VoiceOver.
        .accessibilityHidden(true)
    }

    /// One column heading, in the same face as everything else.
    ///
    /// - Parameters:
    ///   - text: The heading.
    ///   - width: Column width, so the heading and its column share one axis.
    /// - Returns: The heading view.
    private func heading(_ text: String, width: CGFloat) -> some View {
        Text(text.uppercased())
            .font(.system(size: scale.headingSize, weight: .medium, design: .monospaced))
            .tracking(scale.headingTracking)
            .foregroundStyle(palette.textTertiary)
            .frame(width: width, alignment: .leading)
    }

    /// Moves the keyboard selection by `offset` rows, clamped at both ends.
    ///
    /// The first arrow press selects the first row rather than the second, because nothing was selected
    /// before it.
    ///
    /// - Parameter offset: `-1` for the previous row, `+1` for the next.
    private func moveSelection(by offset: Int) {
        let keys = keyboardRows.map(\.id)
        guard !keys.isEmpty else { return }
        isKeyboardActive = true
        guard let current = selectedRow, let index = keys.firstIndex(of: current) else {
            selectedRow = offset > 0 ? keys.first : keys.last
            return
        }
        selectedRow = keys[min(max(index + offset, 0), keys.count - 1)]
    }

    /// Acts on the keyboard selection, if there is a visible one.
    ///
    /// - Returns: `true` when a row was activated, so the caller can report the key as handled.
    private func activateSelection() -> Bool {
        guard isKeyboardActive, let selectedRow,
              let line = keyboardRows.first(where: { $0.id == selectedRow }),
              let agent = line.agent
        else { return false }
        onSelectAgent(line.session, agent)
        return true
    }
}

// MARK: - Row

/// One printed line: a sigil, the elided context columns, the identifier, and the kind.
///
/// A separate `View` rather than a method on ``HerdLedgerView`` because it owns hover state, and `@State`
/// inside a `ForEach`-built subview is per-row, whereas a single flag on the parent would light every row
/// at once.
private struct HerdLedgerRow: View {
    /// The line to print.
    let line: HerdLedgerLine

    /// The column widths in force, so the row and the heading above it share one axis.
    let columns: HerdLedgerColumns

    /// Every size the row draws at.
    let scale: HerdLedgerScale

    /// Tokens for the current scheme.
    let palette: HerdPalette

    /// Whether the keyboard selection is on this row and visible.
    let isSelected: Bool

    /// Mirrors ``HerdLedgerView/availableWidth`` being non-`nil`. Switches the workspace cell's truncation
    /// from tail to middle and the kind cell's printed text from the full kind name to
    /// ``HerdLedgerView/kindCode(_:)``'s 4-character code (full name moved to that cell's `.help` tooltip
    /// instead), matching the column widths ``HerdLedgerView`` already measured for this same flag — see
    /// that view's documentation for why. `false` (this row's default construction path from `BoringHerdBar`)
    /// leaves both cells exactly as before.
    let isCompactLayout: Bool

    /// Invoked when the row is activated.
    let onSelectAgent: (HerdAgent) -> Void

    /// Invoked when the printed session name is clicked.
    let onSelectSession: () -> Void

    /// Invoked when the printed workspace name is clicked.
    let onSelectWorkspace: (HerdWorkspace) -> Void

    /// Whether the cursor is over the line.
    @State private var isHovering = false

    var body: some View {
        if !line.markers.isEmpty {
            markerLine
        } else if line.agent == nil {
            stoppedLine
        } else {
            agentLine
        }
    }

    /// The session-scoped markers, printed under the session name on a line of their own.
    ///
    /// Outside the grid, like ``stoppedLine``, and for the same reason: it is not a row, so it must not size
    /// a column or pretend to be one. That is the whole fix. `no terminal` beside the name made it the
    /// widest content the session column ever held, so one detached session widened the column for all
    /// sixteen rows and left a couple of hundred points of dead space between every session name and its
    /// workspace. On its own line it is measured by nothing, and the session column is back to being as wide
    /// as the longest session name.
    ///
    /// Deliberately shorter than an agent row. At a full ``HerdLedgerScale/rowHeight`` the line would read as
    /// a row with a missing agent; at ``HerdLedgerScale/markerRowHeight`` it reads as an annotation on the
    /// name above it, which is what it is.
    ///
    /// Indented by ``HerdLedgerScale/markerGap`` past the session column's own origin, so it sits under the
    /// name rather than under the status gutter, and hangs slightly inside it the way a continuation should.
    private var markerLine: some View {
        HStack(spacing: scale.markerGap) {
            Spacer().frame(width: scale.sigilColumn + scale.markerGap)
            ForEach(line.markers, id: \.self) { marker($0) }
            Spacer(minLength: 0)
        }
        .frame(height: scale.markerRowHeight)
        .padding(.horizontal, scale.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(sessionHelp)
        // Hidden from VoiceOver because it is a duplicate there, not because it is decorative: every agent
        // row of this session already ends with ", session has no terminal attached" or ", remote session",
        // so reading the words again between rows one and two would be noise.
        .accessibilityHidden(true)
    }

    /// A stopped session, printed as a free line rather than squeezed into the grid.
    ///
    /// It has no workspace, no agent and no status, so aligning it to columns bought nothing and cost the
    /// session column the extra width that the one long session name would have needed. A line that is
    /// not a row should not pretend to be one.
    ///
    /// It carries the `herdr session attach` advice, because that is the scope the advice applies to: a
    /// client attaches to a session, not to a pane, and the previous build put the same sentence on all
    /// sixteen agent rows where it was untrue most of the time.
    private var stoppedLine: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: scale.sigilColumn)
            Text(line.session.name)
                .font(.system(size: scale.contextSize, design: .monospaced))
                .foregroundStyle(palette.textTertiary)
            // A remote session that contributes no rows is the commonest way a forward is seen to be
            // broken, so the marker has to be here too, not only on agent lines. Without it a dead tunnel
            // is indistinguishable from a local session the user stopped on purpose.
            if line.isRemote {
                marker(HerdLedgerColumns.remoteMarker)
            }
            Text(line.placeholder ?? "")
                .font(.system(size: scale.contextSize, design: .monospaced))
                // An error is the one place a session line spends the attention colour, because a session
                // that is running and not answering is the only session-level fact the user can act on.
                .foregroundStyle(line.placeholderIsError ? palette.blocked : palette.textTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(height: scale.rowHeight)
        .padding(.horizontal, scale.inset)
        .padding(.top, scale.groupGap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(stoppedHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            line.isRemote
                ? "Remote session \(line.session.name), not reachable"
                : "Session \(line.session.name), not running"
        )
    }

    /// The tooltip on a session that contributes no rows.
    ///
    /// Split by locality because the remedies are on different machines. `herdr session start` is the right
    /// advice for a local session and useless for a forwarded one, where the thing to check is the tunnel
    /// and the socket path it terminates at, so the tooltip names that path.
    private var stoppedHelp: String {
        guard line.isRemote else {
            return "\(line.session.name) is not running\nherdr session start \(line.session.name)"
        }
        return """
        \(line.session.name) is a forwarded remote session and is not answering.
        Check the ssh -L forward and the socket at \(line.session.socketPath)
        """
    }

    /// One agent, printed into the grid.
    private var agentLine: some View {
        HStack(spacing: 0) {
            HerdLedgerSigil(
                status: line.agent?.agentStatus,
                isRecentlyCompleted: line.isRecentlyCompleted,
                scale: scale,
                palette: palette
            )
                .frame(width: scale.sigilColumn, alignment: .leading)

            // Clickable only when printed. A blank continuation cell is not a target, because a target
            // the user cannot see is a trap.
            //
            // The name and nothing else. Session-scoped markers used to share this cell and are now on their
            // own line, which is what stopped them sizing the column; see ``HerdLedgerRow/markerLine``.
            Text(line.sessionText)
                .font(.system(size: scale.contextSize, design: .monospaced))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: columns.session, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { if !line.sessionText.isEmpty { onSelectSession() } }
                .help(sessionHelp)

            Text(line.workspaceText)
                .font(.system(size: scale.contextSize, design: .monospaced))
                .foregroundStyle(palette.textTertiary)
                .lineLimit(1)
                // Middle truncation under ``isCompactLayout`` (HerdNotch's Ledger+Rail layout, which shrinks
                // this column to fit ``HerdLedgerView/availableWidth``): a workspace name's most identifying
                // characters are often at both ends (`herd-notch-ledger` vs. `herd-search-ui`), which tail
                // truncation collapses to the same shared prefix. `BoringHerdBar`'s unbounded workspace
                // column keeps tail truncation, since it rarely truncates at all.
                .truncationMode(isCompactLayout ? .middle : .tail)
                .frame(width: columns.workspace, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !line.workspaceText.isEmpty, let workspace = line.workspace else { return }
                    onSelectWorkspace(workspace)
                }

            Text(line.agent.map(\.displayIdentifier) ?? "")
                .font(.system(size: scale.identifierSize, weight: identifierWeight, design: .monospaced))
                .foregroundStyle(identifierColour)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: columns.identifier, alignment: .leading)

            Text(kindText)
                .font(.system(size: scale.contextSize, design: .monospaced))
                .foregroundStyle(palette.textTertiary)
                .lineLimit(1)
                .frame(width: columns.kind, alignment: .leading)
                // Only meaningful (non-empty) when ``isCompactLayout`` actually shortened the printed text —
                // `BoringHerdBar`'s uncompacted kind cell already prints the full name, so a tooltip
                // repeating it would be noise.
                .help(isCompactLayout ? (line.agent?.agent ?? "") : "")

            Spacer(minLength: 0)
        }
        .frame(height: scale.rowHeight)
        .padding(.horizontal, scale.inset)
        .padding(.top, line.startsGroup ? scale.groupGap : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Hover is a wash, not a coloured band: the row leans forward rather than being struck through
        // with a marker. The composited value is a measured token, so the 4.63:1 floor on it is a fact.
        .background(isHovering ? palette.hoverFill : .clear)
        // The selection ring is drawn rather than inherited, because these are custom views with no
        // system focus decoration. `textSecondary` at 1 pt is 6.80:1 against the surface, which is
        // unmistakable without introducing a third accent.
        .overlay(
            RoundedRectangle(cornerRadius: scale.selectionCornerRadius)
                .strokeBorder(isSelected ? palette.textSecondary : .clear, lineWidth: 1)
                .padding(.horizontal, scale.selectionInset)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { if let agent = line.agent { onSelectAgent(agent) } }
        // Three lines and it stops: identifier and status, the working directory, the pane id. A fourth
        // line offering the attach remedy was on every row in the previous build, was untrue most of the
        // time, and covered a third of the panel. That advice now lives on the session, once.
        .help(agentHelp)
        // The previous build exposed nothing to VoiceOver at all. The row is a button, and its label says
        // what it is, what state it is in, and where it lives, in that order, because the identifier is
        // what the user is looking for and the location is context.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(
            line.isDetached
                ? "Selects this pane in herdr. No terminal is attached, so no window will come forward."
                : "Focuses this pane in its terminal"
        )
    }

    /// One session-scoped marker, in the register `DESIGN.md` reserves for a limitation to know about.
    ///
    /// Set in ``HerdPalette/textTertiary`` at 5.21:1 rather than in an accent: a detached or remote session
    /// is a limitation, not an alarm, and the two saturated colours are spent on agent state. It stays well
    /// clear of the 4.5:1 floor, which still applies because it is text and because no step of the type scale
    /// reaches WCAG's 18 pt large-text exemption.
    ///
    /// Factored out because it is drawn from two places, the marker line and a stopped session's line, and
    /// two copies of the modifier chain would be two places for the register to drift.
    ///
    /// - Parameter text: The marker word.
    /// - Returns: The marker view.
    private func marker(_ text: String) -> some View {
        Text(text)
            .font(.system(size: scale.headingSize, weight: .medium, design: .monospaced))
            .foregroundStyle(palette.textTertiary)
            .lineLimit(1)
    }

    /// The kind cell's printed text: the full kind name normally, or ``HerdLedgerView/kindCode(_:)``'s
    /// 4-character code under ``isCompactLayout``, matching the same choice ``HerdLedgerView``'s own
    /// column-measuring pass already made for this row's ``columns/kind`` width.
    private var kindText: String {
        guard let kind = line.agent?.agent else { return "" }
        return isCompactLayout ? HerdLedgerView.kindCode(kind) : kind
    }

    /// Weight of the identifier.
    ///
    /// All three exception states step to semibold, so the loudest rows are marked by weight as well as by
    /// hue and by sigil. That redundancy is the point: it is what keeps them separable from idle on a
    /// laptop screen in a bright room, where hue is the first channel to go, and it is what replaced the
    /// motion this design is not allowed to use.
    ///
    /// `done` joined the set when it stopped being folded into `unknown`. A finished agent is something to
    /// walk over to, so it belongs with the rows that are doing or wanting something rather than with the
    /// idle bulk.
    private var identifierWeight: Font.Weight {
        switch line.agent?.agentStatus {
        case .blocked, .done, .working: .semibold
        default: .regular
        }
    }

    /// Colour of the identifier.
    ///
    /// Blocked takes the red and done takes the green, both of which are text-floor tokens for exactly this
    /// use. Working takes ``HerdPalette/textPrimary`` rather than its own amber, because the amber is a mark
    /// colour that does not clear the 4.5:1 text floor in light mode, and because two coloured identifiers
    /// are already the most this column should carry. Everything else sits on ``HerdPalette/textIdle``.
    /// Hover overrides all of it, which doubles as the way to read a recessive row without clicking it.
    private var identifierColour: Color {
        if isHovering { return palette.identifierHover }
        if line.isRecentlyCompleted { return palette.textPrimary }
        return switch line.agent?.agentStatus {
        case .blocked: palette.blocked
        case .done: palette.done
        case .working: palette.textPrimary
        default: palette.textIdle
        }
    }

    /// The three-line row tooltip.
    private var agentHelp: String {
        guard let agent = line.agent else { return "" }
        return """
        \(agent.displayIdentifier) · \(agent.agentStatus.phrase)
        \(agent.cwd)
        \(agent.paneId)
        """
    }

    /// The session cell's tooltip, which is where the attach advice belongs.
    ///
    /// The advice is now conditional, which is the whole improvement.
    ///
    /// The previous build put "Nothing happened? No terminal is attached" on all sixteen agent rows, where
    /// it was untrue most of the time and therefore ignored. Attachment turned out to be detectable after
    /// all, so the sentence appears only on the sessions it is actually true of, once per session, and it
    /// states the fact rather than asking the user to guess at it.
    private var sessionHelp: String {
        guard !line.sessionText.isEmpty else { return "" }
        // Remote is checked first because it explains more: for a forwarded session the attach advice would
        // be advice about the wrong machine, and no local terminal can ever be raised for it, so saying
        // where it lives is both the more useful fact and the one that makes the missing raise expected.
        if line.isRemote {
            return """
            \(line.session.name) is a forwarded remote session at \(line.session.socketPath).
            Selecting a pane moves the cursor on the remote host. No local window comes forward.
            """
        }
        guard line.isDetached else { return "Focus \(line.session.name)" }
        return """
        \(line.session.name) has no terminal attached, so there is no window to bring forward.
        herdr session attach \(line.session.name)
        """
    }

    /// What VoiceOver reads for this row.
    private var accessibilityLabel: String {
        guard let agent = line.agent else { return "" }
        let workspace = line.workspace?.label ?? line.workspace?.workspaceId ?? ""
        // "just finished" rather than "idle" for a remembered completion, because that is what the
        // checkmark says and one state must not have two names across two output channels.
        let state = line.isRecentlyCompleted && agent.agentStatus == .idle
            ? "just finished"
            : agent.agentStatus.phrase
        let attachment = line.isDetached ? ", session has no terminal attached" : ""
        let remoteness = line.isRemote ? ", remote session" : ""
        return "\(agent.displayIdentifier), "
            + "\(state), "
            + "\(agent.agent), "
            + "workspace \(workspace) in session \(line.session.name)"
            + remoteness
            + attachment
    }
}

// MARK: - Sigil

/// The status glyph in the left gutter.
///
/// Five distinct shapes, at four distinct sizes, in four colours. The redundancy is deliberate and it is
/// what replaces motion: shape survives a bright room, greyscale, and colour vision deficiency, none of
/// which hue does. The blocked disc is more than twice the area of an idle ring, because breaking the
/// visual rhythm of a column of identical marks is the loudest thing a table can do, and it costs nothing
/// on the fifteen glances out of sixteen when it does not happen.
///
/// `working` is a filled triangle rather than a disc so that shape, not only hue, separates it from
/// blocked, and it is drawn in the palette's amber because the status item, the transient popup and the
/// search window all draw a working agent in that amber. A ledger that made working grey would be the one
/// surface in the app where the state looked like something else.
///
/// `done` is a checkmark, which is the same glyph the recency mark uses and deliberately so: there is one
/// shape in this vocabulary for "finished", and the two cases differ only in colour. herdr's own `done`
/// is green, because it is a fact the server reported; the inferred `working -> idle` recency mark stays
/// `textPrimary`, because it is this app's guess rather than herdr's statement.
private struct HerdLedgerSigil: View {
    /// The status to draw, or `nil` for a stopped session's line, which draws nothing.
    let status: AgentStatus?

    /// Whether this agent finished inside the model's recency window.
    ///
    /// Takes precedence over `idle`, which is what such an agent's status actually is. Without the mark the
    /// ordering would promote a row that looked exactly like the idle ones beneath it, and an unexplained
    /// reorder reads as the panel shuffling at random.
    let isRecentlyCompleted: Bool

    /// Every size the sigil draws at. The gutter is a column of shapes, so they scale with the type or the
    /// barcode the panel's left edge is meant to be stops reading as one.
    let scale: HerdLedgerScale

    /// Tokens for the current scheme.
    let palette: HerdPalette

    var body: some View {
        Group {
            if isRecentlyCompleted, status == .idle {
                // A checkmark, because it is the one glyph that means "done" without a caption, and it is
                // a fourth distinct shape rather than a fourth colour. Set at `textPrimary`, so a finished
                // agent sits at the top of the grey ramp with the working ones and clearly above idle.
                Image(systemName: "checkmark")
                    .font(.system(size: scale.sigilCheckmark, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
            } else {
                statusSigil
            }
        }
        .frame(width: scale.sigilLarge, alignment: .center)
    }

    /// The shape for the agent's actual status.
    @ViewBuilder
    private var statusSigil: some View {
        Group {
            switch status {
            case .blocked:
                Circle()
                    .fill(palette.blocked)
                    .frame(width: scale.sigilLarge, height: scale.sigilLarge)
            case .done:
                // The same checkmark the recency mark draws, in herdr's green rather than `textPrimary`.
                // One shape for "finished", two colours for who said so.
                Image(systemName: "checkmark")
                    .font(.system(size: scale.sigilCheckmark, weight: .bold))
                    .foregroundStyle(palette.done)
            case .working:
                HerdLedgerTriangle()
                    .fill(palette.working)
                    .frame(width: scale.sigilTriangleWidth, height: scale.sigilLarge)
            case .unknown:
                Rectangle()
                    .strokeBorder(palette.textSecondary, lineWidth: scale.sigilStroke)
                    .frame(width: scale.sigilSmall, height: scale.sigilSmall)
            case .idle:
                // A hollow ring in the `idle` blue at 5.05:1. The previous build drew this in `hairline` at
                // 1.28:1, which meant the mark whose entire job is to confirm an agent is alive could not
                // be seen on the fourteen rows where it appeared. The blue that replaced the interim
                // `textTertiary` grey is pitched at the same loudness, so the state gained a name without
                // the row gaining emphasis.
                Circle()
                    .strokeBorder(palette.idle, lineWidth: scale.sigilStroke)
                    .frame(width: scale.sigilSmall, height: scale.sigilSmall)
            case nil:
                EmptyView()
            }
        }
    }
}

/// A right-pointing triangle, used for the `working` sigil.
private struct HerdLedgerTriangle: Shape {
    /// Builds the triangle inside the given rectangle.
    ///
    /// - Parameter rect: The frame to fill.
    /// - Returns: A closed three-point path pointing right.
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
