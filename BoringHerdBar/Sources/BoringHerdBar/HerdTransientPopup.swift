import AppKit
import HerdHost
import HerdKit
import HerdPanelUI
import SwiftUI

/// Content of the transient popup: what happened, to whom, in which session.
///
/// Uses the same glyphs and tints as the list rows, via ``AgentStatus/symbolName`` and
/// ``AgentStatus/tint``, so a red bang means the same thing wherever the user sees it.
private struct HerdPopupView: View {
    /// Which state the popup is announcing, which selects the dot.
    let status: AgentStatus
    /// Headline, for example `catalog_version_diff is waiting for you` or `3 waiting for you`.
    let title: String
    /// Whether ``title`` is a code identifier, and so should be set in the monospace face the rows
    /// use. Coalesced summaries are prose and are not.
    let titleIsIdentifier: Bool
    /// Optional second line with agent kind and session. Omitted for coalesced summaries.
    let detail: String?

    /// Drives the palette. Dark is the tuned target.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = HerdPalette.resolving(colorScheme)
        return HStack(spacing: 9) {
            // The same dot vocabulary as the rows: filled amber with a glow for waiting, a smaller
            // cool disc for anything else. The popup is a fragment of the panel, not its own idiom.
            Circle()
                .fill(palette.accent(for: status) ?? palette.textTertiary)
                .frame(width: status == .blocked ? 9 : 6, height: status == .blocked ? 9 : 6)
                .shadow(color: status == .blocked ? palette.blocked.opacity(0.6) : .clear, radius: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(
                        titleIsIdentifier
                            ? .system(size: 11.5, weight: .medium, design: .monospaced)
                            : .system(size: 12, weight: .medium)
                    )
                    .foregroundStyle(palette.textPrimary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 9.5))
                        .foregroundStyle(palette.textTertiary)
                }
            }
            .lineLimit(1)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        // The same opaque surface as the panel and the search window. Three surfaces doing three
        // different things is what let one of them become transparent enough to read the desktop
        // through, so they are now one decision.
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(palette.hairline)
        )
        .fixedSize()
    }
}

/// A small self-dismissing panel under the status item, announcing notable agent transitions.
///
/// Deliberately an `NSPanel` rather than a second `NSPopover`. A popover would anchor to the same
/// status item as the real panel and fight it for that anchor, and showing one activates the app. The
/// requirements here are the opposite of a popover's defaults: never take focus, never intercept a
/// click meant for whatever is underneath, and disappear on its own. A non-activating panel with
/// `ignoresMouseEvents` gives all three directly.
///
/// Coalescing rather than stacking: several transitions landing in one poll produce one panel that
/// says how many, because four panels appearing at once is worse than the information is worth.
///
/// Thread-safety: main-actor isolated, as all AppKit work must be.
@MainActor
final class HerdTransientPopup {
    /// Gap between the bottom of the menu bar and the top of the panel.
    private static let verticalInset: CGFloat = 6

    /// The panel, created lazily on first use so an app that never sees a transition never builds one.
    private var panel: NSPanel?

    /// The pending auto-dismiss. Cancelled and replaced on every new event, which is what keeps a
    /// second event from leaving an earlier timer alive to dismiss the newer content early.
    private var dismissWork: DispatchWorkItem?

    /// Shows a panel summarising this tick's notable transitions, if there are any.
    ///
    /// Only two kinds of transition qualify, per ``HerdTransition/isNewlyBlocked`` and
    /// ``HerdTransition/isCompleted``. Everything else, including anything involving
    /// ``AgentStatus/unknown``, is ignored as detection noise.
    ///
    /// - Parameters:
    ///   - transitions: This tick's status changes, from ``HerdTransitionTracker``.
    ///   - anchor: The status item button to position under.
    ///   - duration: Seconds to stay on screen before dismissing.
    func present(_ transitions: [HerdTransition], anchor: NSStatusBarButton?, duration: TimeInterval) {
        // De-duplicate by session-scoped key before counting. One tick cannot normally produce two
        // transitions for one pane, but counting by key rather than by array position means a
        // duplicate could never inflate "3 agents blocked" either.
        var blocked: [String: HerdTransition] = [:]
        var completed: [String: HerdTransition] = [:]
        for transition in transitions {
            if transition.isNewlyBlocked { blocked[transition.key] = transition }
            else if transition.isCompleted { completed[transition.key] = transition }
        }
        guard let content = Self.content(blocked: Array(blocked.values), completed: Array(completed.values))
        else { return }
        show(content, anchor: anchor, duration: duration)
    }

    /// Confirms that a pane was focused, naming the session it lives in.
    ///
    /// This exists because of a failure the app cannot detect. A herdr session is a headless server, so
    /// it can be running with agents working while no terminal client is attached to it. Clicking such
    /// an agent succeeds on every herdr call, then raises a terminal that is showing a different
    /// session, and absolutely nothing appears to happen. Whether a client is attached is not
    /// observable from outside herdr: the API has no method that reports it and no event that announces
    /// it, and the `herdr-client.sock` beside every session's API socket is created by the server, not
    /// by a client, so it answers whether or not anyone is attached.
    ///
    /// Since the state cannot be detected, the honest fix is to stop the click being silent. Naming the
    /// session tells the user where the focus landed, so a terminal still showing something else
    /// becomes a fact they can see rather than an app that looks broken. The remedy itself,
    /// `herdr session attach <name>`, is in the row's tooltip; nothing here spawns a process.
    ///
    /// - Parameters:
    ///   - identifier: The pane's display identifier, set in the row's monospace face.
    ///   - sessionName: The session the pane lives in.
    ///   - anchor: The status item button to position under.
    ///   - duration: Seconds to stay on screen.
    func confirmFocus(
        identifier: String,
        sessionName: String,
        anchor: NSStatusBarButton?,
        duration: TimeInterval
    ) {
        show(
            Summary(
                status: .idle,
                title: identifier,
                titleIsIdentifier: true,
                detail: "focused in \(sessionName)"
            ),
            anchor: anchor,
            duration: duration
        )
    }

    /// Hides the panel immediately, used when the real popover opens so the two do not overlap.
    func dismiss() {
        dismissWork?.cancel()
        dismissWork = nil
        panel?.orderOut(nil)
    }

    /// Builds the headline and detail for one tick's events, or `nil` when nothing qualifies.
    ///
    /// A single event gets the agent's name and its session; several get a count, because naming four
    /// agents in a two-line panel is not readable in the four seconds it is on screen.
    ///
    /// - Parameters:
    ///   - blocked: Agents that just became blocked.
    ///   - completed: Agents that just finished working.
    /// - Returns: The status to tint by, the headline, and an optional detail line.
    private static func content(
        blocked: [HerdTransition],
        completed: [HerdTransition]
    ) -> Summary? {
        if blocked.isEmpty && completed.isEmpty { return nil }

        // The same words as the row tooltip, so one state never has two names.
        if blocked.count == 1, completed.isEmpty {
            let transition = blocked[0]
            return Summary(
                status: .blocked,
                title: "\(transition.agent.displayIdentifier) is waiting for you",
                titleIsIdentifier: false,
                detail: "\(transition.agent.agent) · \(transition.sessionName)"
            )
        }
        if completed.count == 1, blocked.isEmpty {
            let transition = completed[0]
            return Summary(
                status: .idle,
                title: "\(transition.agent.displayIdentifier) finished",
                titleIsIdentifier: false,
                detail: "\(transition.agent.agent) · \(transition.sessionName)"
            )
        }

        var parts: [String] = []
        if !blocked.isEmpty { parts.append("\(blocked.count) waiting for you") }
        if !completed.isEmpty { parts.append("\(completed.count) finished") }
        // Waiting wins the dot whenever any agent needs the user, matching the roll-up precedence.
        return Summary(
            status: blocked.isEmpty ? .idle : .blocked,
            title: parts.joined(separator: ", "),
            titleIsIdentifier: false,
            detail: nil
        )
    }

    /// One tick's events, reduced to what the panel shows.
    private struct Summary {
        /// Selects the dot's colour and size.
        let status: AgentStatus
        /// Headline text.
        let title: String
        /// Whether the headline is a bare code identifier.
        let titleIsIdentifier: Bool
        /// Second line, or `nil` for a coalesced summary.
        let detail: String?
    }

    /// Creates or reuses the panel, positions it under the status item, and arms the dismiss timer.
    ///
    /// - Parameters:
    ///   - content: Headline, detail and tint.
    ///   - anchor: The status item button. When absent the panel is centred at the top of the main
    ///     screen, which is what happens if the status item has not been created yet.
    ///   - duration: Seconds before auto-dismissal.
    private func show(
        _ content: Summary,
        anchor: NSStatusBarButton?,
        duration: TimeInterval
    ) {
        let view = NSHostingView(
            rootView: HerdPopupView(
                status: content.status,
                title: content.title,
                titleIsIdentifier: content.titleIsIdentifier,
                detail: content.detail
            )
        )
        view.setFrameSize(view.fittingSize)

        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        panel.contentView = view
        panel.setContentSize(view.fittingSize)
        panel.setFrameOrigin(Self.origin(for: view.fittingSize, anchor: anchor))
        // `orderFrontRegardless` rather than `makeKeyAndOrderFront`: the panel must appear without
        // the app activating or the panel becoming key, so whatever the user is typing into keeps
        // the keyboard.
        panel.orderFrontRegardless()
        if let dir = ProcessInfo.processInfo.environment["HERDBAR_POPUP_DUMP"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                HerdDebugCapture.write(view, to: "\(dir)/popup-\(Int(Date().timeIntervalSince1970)).png")
            }
        }

        // Cancelling before rescheduling is what makes a second event re-arm the timer rather than
        // leave the first one alive to dismiss the newer content early.
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Builds the panel with the window flags the requirements imply.
    ///
    /// - `.nonactivatingPanel` plus `becomesKeyOnlyIfNeeded` so showing it never activates the app.
    /// - `ignoresMouseEvents` so it can never swallow a click aimed at whatever is beneath it.
    /// - `.statusBar` level so it floats above ordinary windows, like the menu bar it hangs from.
    /// - `.canJoinAllSpaces` and `.stationary` so it does not drag a Space switch along with it.
    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        return panel
    }

    /// Bottom-left origin that puts the panel just below the status item, kept on screen.
    ///
    /// - Parameters:
    ///   - size: The panel's content size.
    ///   - anchor: The status item button, if it exists.
    /// - Returns: An origin in screen coordinates.
    private static func origin(for size: CGSize, anchor: NSStatusBarButton?) -> NSPoint {
        guard let screen = anchor?.window?.screen ?? NSScreen.main else { return .zero }
        let visible = screen.visibleFrame

        // Vertically the panel hangs just under the menu bar. `visibleFrame` already excludes the
        // menu bar, so its top edge is exactly the boundary to stay below. Deriving this from the
        // status item's own window instead put the panel at y 6 to 53, overlapping the menu bar and
        // covering the very status item it is anchored to.
        let y = visible.maxY - size.height - verticalInset

        // Horizontally right-align to the status item, then clamp so a wide panel under a
        // right-hand item cannot hang off the edge of the display.
        let itemMaxX: CGFloat
        if let anchor, let window = anchor.window {
            itemMaxX = window.convertToScreen(anchor.convert(anchor.bounds, to: nil)).maxX
        } else {
            itemMaxX = visible.midX + size.width / 2
        }
        let x = min(
            max(itemMaxX - size.width, visible.minX + 8),
            visible.maxX - size.width - 8
        )
        return NSPoint(x: x, y: y)
    }
}
