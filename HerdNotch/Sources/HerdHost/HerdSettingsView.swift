import HerdHotKey
import HerdKit
import HerdPanelUI
import HerdShortcut
import SwiftUI

/// The settings form: every configurable value in the app, in one small window.
///
/// It replaces a right-click `NSMenu` plus two documented `defaults write` invocations, and the menu was not
/// merely inconvenient, it was wrong in two ways a menu cannot fix. Its session list was built from the
/// *filtered* snapshot, so deselecting a session removed it from the list and there was no way to select it
/// again. And a shortcut cannot be recorded in a menu at all, so the app's one keyboard affordance was
/// unrebindable by clicking.
///
/// Layout follows `DESIGN.md` where the document has an opinion, which for a form is mostly about type: the
/// content that is a **code identifier** (session names, socket paths, a bundle identifier, the shortcut
/// itself) is set in the monospaced face, and prose chrome is not. Colour stays inside the two-accent budget:
/// ``HerdPalette/blocked`` is the only accent used, and only where something is actually wrong. Standard
/// macOS controls carry everything else, because a form is a form and reimplementing a checkbox to match a
/// palette would be costume rather than discipline.
///
/// There is no animation in this file, for the reason the panel has none: any animation in flight keeps
/// SwiftUI's transaction machinery running every pass of the run loop. A settings window is not the popover
/// whose backdrop AppKit recomposites, so the cost would be smaller, but the rule is cheaper to keep than to
/// re-measure.
public struct HerdSettingsView: View {
    /// Every setting, observed so the form redraws when something outside it changes a value.
    @ObservedObject var preferences: HerdPreferences

    /// Whether the global shortcut is actually registered, which the stored preference cannot say.
    @ObservedObject var hotKeyStatus: HerdHotKeyStatus

    /// Every discovered session name, including ones the filter is hiding.
    @ObservedObject var roster: HerdSessionRoster

    /// Drives the palette for the few places this form spends a token of its own.
    @Environment(\.colorScheme) private var colorScheme

    /// Whether to show the controls only the menu-bar app reads (panel text size, the waiting notification,
    /// the menu-bar popup, window-title stamping). `HerdNotch` embeds this view with `false`.
    private let showsMenuBarOnlyControls: Bool

    /// Public so `HerdNotch`'s merged settings window (a different module) can embed this view as its
    /// "Agents" tab.
    public init(
        preferences: HerdPreferences, hotKeyStatus: HerdHotKeyStatus, roster: HerdSessionRoster,
        showsMenuBarOnlyControls: Bool = true
    ) {
        self.preferences = preferences
        self.hotKeyStatus = hotKeyStatus
        self.roster = roster
        self.showsMenuBarOnlyControls = showsMenuBarOnlyControls
    }

    /// Width of the window's content.
    ///
    /// Narrow on purpose: this is a small utility form, not a control panel. The number is the
    /// widest the longest label needs rather than a round figure, and the sections scroll rather than the
    /// window growing, so adding a setting later cannot push it past a laptop screen.
    private static let contentWidth: CGFloat = 400

    /// Ceiling on the scrollable body.
    ///
    /// The window sizes itself to its content up to this, so on a herd of four sessions almost nothing has
    /// to be scrolled, and a herd of twenty scrolls rather than growing past a laptop screen. The sessions
    /// section is the only one whose height is not fixed, which is why a ceiling is needed at all.
    ///
    /// Most of the explanatory copy that used to sit under a control is now that control's tooltip. Prose
    /// under every setting is how a utility window turns into a document: it doubled the height, and a
    /// sentence explaining a checkbox is exactly what a tooltip is for. The two places prose stayed inline
    /// are where it is a warning rather than an explanation (window-title stamping turned off) or an
    /// instruction the user needs before they can type anything at all (the format of the remote paths).
    private static let maxBodyHeight: CGFloat = 700

    public var body: some View {
        let palette = HerdPalette.resolving(colorScheme)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                shortcutSection(palette)
                if showsMenuBarOnlyControls { panelSection }
                watchingSection
                agentsSection
                alertsSection
                sessionsSection(palette)
                terminalSection(palette)
                remoteSection(palette)
            }
            .padding(18)
            .frame(width: Self.contentWidth, alignment: .leading)
        }
        .frame(width: Self.contentWidth)
        .frame(maxHeight: Self.maxBodyHeight)
    }

    // MARK: - Shortcut

    /// The global shortcut, its live registration state, and how the default is reached.
    private func shortcutSection(_ palette: HerdPalette) -> some View {
        section("Shortcut") {
            HStack(alignment: .top, spacing: 10) {
                HerdShortcutField(
                    shortcut: Binding(
                        get: { preferences.searchShortcut },
                        set: { preferences.searchShortcut = $0 }
                    ),
                    onReset: { preferences.resetSearchShortcut() }
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Opens pane search")
                        .font(.system(size: 11))
                    // The one place the accent appears in this window, and it appears only when the stored
                    // shortcut and the live registration disagree. That case is why this line exists: Carbon
                    // refuses a combination another application already owns, and the previous build reported
                    // that to standard error, where nobody launching from the Finder ever sees it.
                    Text(hotKeyStatus.explanation)
                        .font(.system(size: 10))
                        .foregroundStyle(
                            hotKeyStatus.isRegistered ? palette.textTertiary : palette.blocked
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if preferences.searchShortcut != .fnDoubleTap {
                Button("Use fn fn again") { preferences.resetSearchShortcut() }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Panel

    /// The ledger's type size, which drives every other size in the panel.
    ///
    /// One picker rather than several, because ``HerdLedgerScale`` derives the context size, the heading size,
    /// the row height, the gutter, the sigil diameters and the column ceilings from this one number at a fixed
    /// 7:6 ratio. Exposing the derived sizes too would let a user break the grid the whole direction depends
    /// on, and would be four more things to store that mean one thing.
    ///
    /// Discrete steps rather than a stepper or a slider. The derived sizes are rounded to half points, which
    /// are exact at 2x; an arbitrary fractional base lands them on thirds of a point, where monospaced text
    /// starts looking unevenly spaced against its own grid. The label states the consequence the user is
    /// actually trading against, because the panel gets wider as the type grows and they should not have to
    /// discover that.
    private var panelSection: some View {
        section("Panel") {
            Picker(
                "Text size",
                selection: Binding(
                    get: { preferences.ledgerTextSize },
                    set: { preferences.ledgerTextSize = $0 }
                )
            ) {
                ForEach(HerdLedgerScale.selectableIdentifierSizes, id: \.self) { size in
                    Text(String(format: "%g pt", size)).tag(size)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 190)
            .help(
                "Sets the whole panel: every other size follows at a 7:6 ratio. The panel gets wider as the "
                    + "type grows, because the columns are measured from what is in them."
            )
        }
    }

    // MARK: - Watching

    /// Whether to poll, and how often.
    private var watchingSection: some View {
        section("Watching") {
            Toggle(
                "Watch herd sessions",
                isOn: Binding(get: { preferences.isEnabled }, set: { preferences.isEnabled = $0 })
            )
            Picker(
                "Poll every",
                selection: Binding(
                    get: { preferences.pollInterval },
                    set: { preferences.pollInterval = $0 }
                )
            ) {
                ForEach(HerdPreferences.selectablePollIntervals, id: \.self) { interval in
                    Text(String(format: "%g s", interval)).tag(interval)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 190)
            .disabled(!preferences.isEnabled)
            .help("Only while the panel is open. Closed, it backs off to 5 s.")
        }
    }

    // MARK: - Agents

    /// Where agents come from, whether a click jumps to a local agent, and when a finish is announced.
    private var agentsSection: some View {
        section("Agents") {
            Picker(
                "Source",
                selection: Binding(
                    get: { preferences.agentSourceMode },
                    set: { preferences.agentSourceMode = $0 }
                )
            ) {
                Text("herdr only").tag(AgentSourceMode.herdr)
                Text("Local only").tag(AgentSourceMode.local)
                Text("Both").tag(AgentSourceMode.both)
            }
            .pickerStyle(.menu)
            .frame(width: 190)
            .help(
                "Both: sessions in herdr come from herdr, and Claude and Codex sessions outside it are found "
                    + "locally. Local agents appear under a session named local."
            )
            Toggle(
                "Jump to agent on click",
                isOn: Binding(
                    get: { preferences.jumpToAgentEnabled },
                    set: { preferences.jumpToAgentEnabled = $0 }
                )
            )
            .help(
                "Brings a local agent's terminal tab, tmux pane or IDE forward. Off, clicking a local agent "
                    + "does nothing. herdr agents always focus their pane."
            )
            Stepper(
                value: Binding(
                    get: { preferences.longTaskMinutes },
                    set: { preferences.longTaskMinutes = $0 }
                ),
                in: 0...HerdPreferences.maxLongTaskMinutes
            ) {
                Text(
                    preferences.longTaskMinutes == 0
                        ? "Long task: off"
                        : "Long task: \(preferences.longTaskMinutes) min"
                )
                .font(.system(size: 11))
            }
            .help(
                "herdr finishes always toast; longer ones show how long they ran. Agents outside herdr toast "
                    + "on finishing only after this long (1 min when off)."
            )
        }
    }

    // MARK: - Alerts

    /// The notification and the transient popup, which are independent on purpose.
    private var alertsSection: some View {
        section("Alerts") {
            if showsMenuBarOnlyControls {
                Toggle(
                    "Notify when an agent is waiting for you",
                    isOn: Binding(
                        get: { preferences.notifiesOnBlocked },
                        set: { preferences.notifiesOnBlocked = $0 }
                    )
                )
                Toggle(
                    "Show a popup under the menu bar on changes",
                    isOn: Binding(get: { preferences.showsPopup }, set: { preferences.showsPopup = $0 })
                )
            }
            Picker(
                showsMenuBarOnlyControls ? "Popup stays for" : "Toast stays for",
                selection: Binding(
                    get: { preferences.popupDuration },
                    set: { preferences.popupDuration = $0 }
                )
            ) {
                ForEach(HerdPreferences.selectablePopupDurations, id: \.self) { duration in
                    Text(String(format: "%g s", duration)).tag(duration)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 190)
            .disabled(showsMenuBarOnlyControls && !preferences.showsPopup)
        }
    }

    // MARK: - Sessions

    /// Which sessions appear, listing every session discovery has seen.
    ///
    /// The list is ``HerdSessionRoster``, not the panel's snapshot, and that is the fix for the defect the
    /// menu had: a filter is a list of exclusions, so the control that edits it must show the excluded
    /// items or they are unreachable.
    private func sessionsSection(_ palette: HerdPalette) -> some View {
        section("Sessions") {
            if visibleNames.isEmpty {
                Text("No sessions discovered yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visibleNames, id: \.self) { name in
                    Toggle(isOn: binding(forSession: name)) {
                        // A session name is an identifier, so it is set as one.
                        Text(name).font(.system(size: 11, design: .monospaced))
                    }
                }
                if visibleNames.contains(LocalAgentSource.sessionName) {
                    Text("local = agents found outside herdr")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if !preferences.sessionFilter.isEmpty {
                    Button("Show all sessions") { preferences.sessionFilter = [] }
                        .controlSize(.small)
                        .help("Every session ticked is stored as no filter, so a new session is included.")
                }
            }
        }
        .help("Every session discovery has found, including ones currently hidden.")
    }

    /// The roster minus the synthetic local session when only herdr is the source, since it cannot appear then.
    private var visibleNames: [String] {
        preferences.agentSourceMode == .herdr
            ? roster.names.filter { $0 != LocalAgentSource.sessionName } : roster.names
    }

    /// A checkbox binding for one session.
    ///
    /// The get is `filter.isEmpty || filter.contains(name)`, because an empty filter means "all" and must
    /// therefore read as every box ticked, which is what the panel shows.
    ///
    /// The set has the awkward case, and it is the same one the menu had to handle: unticking a box while
    /// the filter is empty cannot simply remove the name, since removing from an empty list is a no-op. The
    /// filter is first expanded to every session currently known, then the name is removed, so the first
    /// untick means "all except this" rather than "only this". Removing the last remaining name leaves an
    /// empty filter, which means all again, so the list can never be filtered down to nothing.
    ///
    /// - Parameter name: The session the checkbox controls.
    /// - Returns: A two-way binding over ``HerdPreferences/sessionFilter``.
    private func binding(forSession name: String) -> Binding<Bool> {
        Binding(
            get: {
                let filter = preferences.sessionFilter
                return filter.isEmpty || filter.contains(name)
            },
            set: { isOn in
                var filter = preferences.sessionFilter
                if filter.isEmpty { filter = roster.names }
                if isOn {
                    if !filter.contains(name) { filter.append(name) }
                } else {
                    filter.removeAll { $0 == name }
                }
                // Every box ticked is the same thing as no filter, and storing it as no filter means a
                // session appearing later is included rather than silently excluded by a stale list.
                preferences.sessionFilter = Set(filter) == Set(roster.names) ? [] : filter
            }
        )
    }

    // MARK: - Terminal

    /// Which terminal to raise, and whether to write window titles into it.
    private func terminalSection(_ palette: HerdPalette) -> some View {
        section("Terminal") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Terminal app")
                    .font(.system(size: 11))
                TextField(
                    "Auto-detect",
                    text: Binding(
                        get: { preferences.terminalBundleId ?? "" },
                        set: { preferences.terminalBundleId = $0 }
                    )
                )
                // A bundle identifier is an identifier.
                .font(.system(size: 11, design: .monospaced))
                .textFieldStyle(.roundedBorder)
            }
            .help(
                "Used to raise herdr panes, and for agents outside herdr when their terminal cannot be "
                    + "detected. Leave empty to detect automatically."
            )
            if showsMenuBarOnlyControls {
                Toggle(
                    "Stamp herdr: <session> on terminal window titles",
                    isOn: Binding(
                        get: { preferences.stampsWindowTitles },
                        set: { preferences.stampsWindowTitles = $0 }
                    )
                )
                // Inline only when off, because then it is a warning about two features the user has just
                // switched off without being told. On, it is an explanation, so it is a tooltip.
                .help("The write is also how attachment is detected, which is what the no terminal marker reports.")
                if !preferences.stampsWindowTitles {
                    Text("No no terminal marker, and a row click raises the terminal app, not the right window.")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.blocked)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Remote

    /// Extra socket paths to scan, which is the whole of the remote-session feature.
    private func remoteSection(_ palette: HerdPalette) -> some View {
        section(showsMenuBarOnlyControls ? "Remote sessions" : "Remote herdr sessions") {
            if preferences.agentSourceMode == .local {
                Text("herdr only")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Toggle(
                "Scan extra socket paths",
                isOn: Binding(
                    get: { preferences.scansRemotePaths },
                    set: { preferences.scansRemotePaths = $0 }
                )
            )
            .disabled(preferences.agentSourceMode == .local)
            Text("One socket or directory per line. Forward them with ssh -L; see the README.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            // A plain multi-line text field rather than a table with add and remove buttons. The value is a
            // list of paths, editing it is editing text, and a table would be three controls and a selection
            // model to express what a newline already expresses.
            TextEditor(
                text: Binding(
                    get: { preferences.remotePaths.joined(separator: "\n") },
                    set: { text in
                        preferences.remotePaths = text
                            .split(separator: "\n", omittingEmptySubsequences: false)
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    }
                )
            )
            // Paths are identifiers too, and a monospaced field is also the only way a typo in a long path
            // is findable by eye.
            .font(.system(size: 11, design: .monospaced))
            .frame(height: 62)
            .overlay(
                RoundedRectangle(cornerRadius: 5).strokeBorder(palette.hairline, lineWidth: 1)
            )
            .disabled(!preferences.scansRemotePaths || preferences.agentSourceMode == .local)
        }
    }

    // MARK: - Chrome

    /// One titled group of settings.
    ///
    /// A hand-rolled heading plus a `VStack` rather than `Form` with `Section`, because a grouped `Form`
    /// insists on its own row metrics and label column, and this window has rows that are not label-value
    /// pairs (the recorder, the session list, the path editor). Fighting the form style cost more code than
    /// not using it.
    ///
    /// - Parameters:
    ///   - title: Section heading.
    ///   - content: The controls.
    /// - Returns: The section.
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
