import AppKit
import HerdKit
import HerdPanelUI
import SwiftUI

/// Content of ``NotchToast``: a status dot, a headline, and (for a single transition) a detail line.
///
/// Deliberately the same shape and vocabulary as `BoringHerdBar/HerdTransientPopup`'s own
/// `HerdPopupView` — one state should never grow two different sentences depending on which app surface
/// announced it — adapted here to draw on `HerdPalette.cardFill` (the bento redesign's own card token)
/// rather than `HerdPalette.surface`, since this toast is conceptually a fourth, momentary bento card.
private struct NotchToastView: View {
    /// Which agent state is being announced, which selects the dot's colour, size and glow. `nil` for a
    /// non-agent toast (e.g. the caffeinate on/off announcement), which shows ``symbolName`` instead of a dot.
    var status: AgentStatus? = nil
    /// An SF Symbol shown in place of the status dot, for a non-agent toast (caffeinate). `nil` for an agent
    /// alert, which shows the ``status`` dot instead. Exactly one of ``status``/``symbolName`` is non-nil.
    var symbolName: String? = nil
    /// The tint for ``symbolName``, ignored when a status dot is shown.
    var symbolTint: Color = .clear
    /// Headline, for example `catalog_version_diff is waiting for you` or `Caffeinate on`.
    let title: String
    /// Optional second line with agent kind and session. Omitted for a coalesced summary or a simple message.
    var detail: String? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = HerdPalette.resolving(colorScheme)
        // `nil` only for the caffeine/battery message path, which is never coloured by an agent status.
        let accent = status.flatMap { palette.accent(for: $0) }
        return HStack(spacing: 9) {
            if let symbolName {
                Image(systemName: symbolName)
                    .font(.system(size: 13))
                    .foregroundStyle(symbolTint)
                    .accessibilityHidden(true)
            } else {
                Circle()
                    .fill(palette.accent(for: status ?? .idle) ?? palette.textTertiary)
                    .frame(width: status == .blocked ? 14 : 12, height: status == .blocked ? 14 : 12)
                    .shadow(color: (palette.accent(for: status ?? .idle) ?? palette.textTertiary).opacity(0.7), radius: 8)
                    // Decorative: the same state is already named in ``announcement``.
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(palette.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(accent?.opacity(0.55) ?? .white.opacity(0.12), lineWidth: 1.5)
        )
        // Only the agent-alert path (a non-nil ``status``) gets the loud outer glow; the caffeine/battery
        // message toast keeps its calmer look, so it does not borrow an urgency that is not its own.
        .shadow(color: (accent ?? .clear).opacity(status != nil ? 0.35 : 0), radius: 12, y: 2)
        .fixedSize()
        // A momentary, non-activating panel gets no VoiceOver focus of its own accord, so grouping it into
        // one clean announcement matters less for "will this be heard" than for "if it is inspected (e.g.
        // via the hover affordance this toast already offers), does it read as one sentence" — the same
        // "<agent> is waiting for you"/"<agent> finished" wording the headline already carries, not a
        // second, differently-worded copy of it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(announcement)
    }

    /// What VoiceOver reads for the whole toast: the headline, plus the detail line where one exists.
    private var announcement: String {
        guard let detail else { return title }
        return "\(title). \(detail)"
    }
}

/// A small, self-dismissing, non-activating panel that briefly announces a `NotchAlert` — the notch
/// equivalent of `BoringHerdBar/HerdTransientPopup`, shown near a collapsed pill instead of a status item.
///
/// **Deliberately independent of `NotchAnimator`/`NotchPanel`/the reveal mask.** Growing the real notch
/// panel just to show four words would mean touching the exact glitch-avoidance state machine this whole
/// phase is forbidden from changing (see this app's own `NotchCore` documentation). This is its own tiny
/// `NSPanel` instead, sized to its content and positioned under whichever collapsed pill
/// `NotchWindowController` asks it to announce for — architecturally identical to `HerdTransientPopup`
/// (a lazily-created, reused, non-activating, always-on-top panel with a cancel-and-reschedule dismiss
/// timer) with one deliberate difference: this one does **not** set `ignoresMouseEvents`, because hovering
/// or clicking it is what opens the real notch (see ``present(_:anchor:onOpen:)``).
///
/// Thread-safety: main-actor isolated, as all AppKit work must be.
@MainActor
final class NotchToast {
    /// Fallback seconds the toast stays on screen before auto-dismissing, absent a hover or click, for a
    /// caller that does not pass its own `dismissDelay` to ``present(_:anchor:dismissDelay:onOpen:)``. The
    /// design spec's own "~3-4s" range; picked at the midpoint, and equal to `HerdPreferences.popupDuration`'s
    /// own shipped default so the two agree when the caller does thread that preference through.
    private static let defaultDismissDelay: TimeInterval = 3.5

    /// The panel, created lazily on first use so a session with no alerts never builds one.
    private var panel: NSPanel?

    /// The pending auto-dismiss. Cancelled and replaced on every new ``present(_:anchor:onOpen:)`` call,
    /// the same "a second event re-arms the timer rather than leaving the first one alive to dismiss the
    /// newer content early" rule `HerdTransientPopup.show(_:anchor:duration:)` documents.
    private var dismissWork: DispatchWorkItem?

    /// What to do if the user hovers or clicks the currently-showing toast. `nil` once dismissed, so a
    /// stray, already-scheduled hover callback from a toast that has since auto-dismissed cannot fire.
    private var onOpen: (() -> Void)?

    /// Whether the toast on screen is an agent alert, which a message toast must not replace.
    private var showingAgent = false

    /// At most one message toast that arrived while an agent toast was showing; shown when that toast
    /// auto-dismisses, dropped if it is dismissed any other way (the notch opened).
    private var pendingMessage: (() -> Void)?

    /// Shows a toast for `alert`, replacing whatever is currently shown and re-arming the auto-dismiss
    /// timer.
    ///
    /// - Parameters:
    ///   - alert: The coalesced transitions to announce. A no-op if ``content(for:)`` finds nothing to say
    ///     (which does not happen in practice, since `NotchHerdModel` only ever publishes a non-empty
    ///     alert, but this method does not assume that of its caller).
    ///   - anchor: The collapsed pill's own frame, in screen coordinates, to position under.
    ///   - dismissDelay: Seconds before the auto-dismiss timer fires, absent a hover or click.
    ///     `NotchWindowController` passes `HerdPreferences.popupDuration` here, so this toast honours the
    ///     same show-time setting the old `BoringHerdBar` transient popup already exposed, rather than a
    ///     value hardcoded independently of it. Defaults to ``defaultDismissDelay`` for a caller (or a
    ///     test) with no preferences store to read.
    ///   - onOpen: Invoked at most once, if the user hovers or clicks the toast before it auto-dismisses,
    ///     asking the caller to open the real notch on this same display.
    func present(
        _ alert: NotchAlert, anchor: CGRect, dismissDelay: TimeInterval = defaultDismissDelay,
        onOpen: @escaping () -> Void
    ) {
        guard let content = Self.content(for: alert) else { return }
        show(
            NotchToastView(status: content.status, title: content.title, detail: content.detail),
            anchor: anchor, dismissDelay: dismissDelay, isAgent: true, onOpen: onOpen
        )
    }

    /// Shows a simple message toast — a leading SF Symbol, a one-line title, no detail — for a non-agent
    /// announcement. Used by `NotchWindowController.showCaffeineToast(active:)` so toggling caffeinate while
    /// the notch is collapsed still gives on-screen "Caffeinate on/off" feedback, the way the top-bar cup
    /// glyph already does while the notch is open. Replaces and re-arms like ``present(_:...)``, except that it
    /// never replaces a showing agent toast: it queues (last one wins) and shows once that toast auto-dismisses.
    ///
    /// - Parameters:
    ///   - symbolName: The SF Symbol to show in place of an agent status dot.
    ///   - tint: The symbol's colour.
    ///   - title: The one-line message, e.g. `Caffeinate on`.
    ///   - anchor: The collapsed pill's own frame, in screen coordinates, to position under.
    ///   - dismissDelay: Seconds before auto-dismiss. Defaults to ``defaultDismissDelay``.
    ///   - onOpen: Invoked at most once if the user hovers or clicks the toast before it dismisses.
    func presentMessage(
        symbolName: String, tint: Color, title: String, anchor: CGRect,
        dismissDelay: TimeInterval = defaultDismissDelay, onOpen: @escaping () -> Void
    ) {
        let showNow: () -> Void = { [weak self] in
            self?.show(
                NotchToastView(symbolName: symbolName, symbolTint: tint, title: title),
                anchor: anchor, dismissDelay: dismissDelay, isAgent: false, onOpen: onOpen)
        }
        if showingAgent { pendingMessage = showNow } else { showNow() }
    }

    /// Hosts `content` in the reused toast panel, positions it under `anchor`, shows it, and arms the
    /// cancel-and-reschedule auto-dismiss timer. The one place the panel is built/positioned/shown, shared
    /// by ``present(_:...)`` and ``presentMessage(...)``.
    private func show(
        _ content: some View, anchor: CGRect, dismissDelay: TimeInterval, isAgent: Bool, onOpen: @escaping () -> Void
    ) {
        self.onOpen = onOpen
        showingAgent = isAgent

        let hosted = content
            .onHover { [weak self] hovering in if hovering { self?.openAndDismiss() } }
            .onTapGesture { [weak self] in self?.openAndDismiss() }
        let view = NSHostingView(rootView: hosted)
        view.setFrameSize(view.fittingSize)

        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        panel.contentView = view
        panel.setContentSize(view.fittingSize)
        panel.setFrameOrigin(Self.origin(for: view.fittingSize, anchor: anchor))
        panel.orderFrontRegardless()

        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let next = self.pendingMessage
            self.dismiss()
            next?()
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissDelay, execute: work)
    }

    /// Hides the toast immediately, with no `onOpen` callback. Called on its own auto-dismiss timer, and
    /// by `NotchWindowController` the instant any display's panel actually expands through some other
    /// path (hover/click on the pill itself, or `fn fn`), so a toast is never left showing over an already
    /// open notch.
    func dismiss() {
        dismissWork?.cancel()
        dismissWork = nil
        panel?.orderOut(nil)
        onOpen = nil
        showingAgent = false
        pendingMessage = nil
    }

    /// Runs ``onOpen`` once, then dismisses — backing both the hover and the click affordance, since both
    /// mean the same thing here ("open the notch").
    private func openAndDismiss() {
        let callback = onOpen
        dismiss()
        callback?()
    }

    /// Builds the headline/detail/status this toast shows, or `nil` for an empty alert.
    ///
    /// Mirrors `HerdTransientPopup.content(blocked:completed:)` exactly: a single transition gets the
    /// agent's own name and its session; several get a count, because naming four agents in a toast on
    /// screen for a few seconds is not readable, and a mix of blocked and done agents reads as two clauses
    /// rather than a single ambiguous word.
    ///
    /// - Parameter alert: The batch to summarise.
    /// - Returns: The dot's status, the headline, and an optional detail line — or `nil` if `alert.entries`
    ///   is empty.
    private static func content(for alert: NotchAlert) -> (status: AgentStatus, title: String, detail: String?)? {
        let blocked = alert.entries.filter { $0.status == .blocked }
        let done = alert.entries.filter { $0.status == .done }
        guard !blocked.isEmpty || !done.isEmpty else { return nil }

        if blocked.count == 1, done.isEmpty {
            let entry = blocked[0]
            return (
                .blocked,
                "\(entry.agent.displayIdentifier) is waiting for you",
                entry.pendingAsk ?? entry.detail ?? "\(entry.agent.agent) · \(entry.session.name)"
            )
        }
        if done.count == 1, blocked.isEmpty {
            let entry = done[0]
            return (
                .done,
                "\(entry.agent.displayIdentifier) finished",
                entry.detail ?? "\(entry.agent.agent) · \(entry.session.name)"
            )
        }

        var parts: [String] = []
        if !blocked.isEmpty { parts.append("\(blocked.count) waiting for you") }
        if !done.isEmpty { parts.append("\(done.count) finished") }
        // Waiting wins the dot whenever any agent needs the user, matching `HerdTransientPopup`'s own
        // roll-up precedence.
        return (blocked.isEmpty ? .done : .blocked, parts.joined(separator: ", "), nil)
    }

    /// Builds the panel with the window flags this toast needs.
    ///
    /// - `.nonactivatingPanel` plus `becomesKeyOnlyIfNeeded` so showing it never activates the app or
    ///   steals keyboard focus from whatever the user is typing into.
    /// - **Not** `ignoresMouseEvents`: unlike `HerdTransientPopup`, this toast is itself clickable/hoverable
    ///   (see ``present(_:anchor:onOpen:)``).
    /// - `.statusBar` level so it floats above ordinary windows, like the notch it hangs from.
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
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        return panel
    }

    /// The origin that centers the toast horizontally under `anchor` and hangs it just below it, clamped
    /// onto the anchor's own screen.
    ///
    /// - Parameters:
    ///   - size: The toast's content size.
    ///   - anchor: The collapsed pill's own screen-coordinate frame.
    /// - Returns: An origin in screen coordinates.
    private static func origin(for size: CGSize, anchor: CGRect) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: anchor.midX, y: anchor.midY)) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor
        let gap: CGFloat = 6
        let x = min(
            max(anchor.midX - size.width / 2, visible.minX + 8),
            visible.maxX - size.width - 8
        )
        let y = anchor.minY - size.height - gap
        return NSPoint(x: x, y: y)
    }
}
