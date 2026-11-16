import HerdKit
import HerdPanelUI
import SwiftUI

/// The expanded agent row: one block with the agent's header, what it is waiting on, and buttons to answer it.
///
/// Pure display: every action leaves through a closure, so the host decides what "Allow" means. Text is
/// wrapped and capped to `viewport`, never ellipsized.
struct AgentPreviewCard: View {
    /// Mono 10 pt advance and line height, used to turn the viewport into columns and rows.
    private enum Metrics {
        static let charWidth = 6.1
        static let lineHeight = 12.0
        static let blockPadding = 8.0
        static let blockPaddingV = 6.0
        static let headerHeight = 20.0
        static let titleHeight = 14.0
        static let buttonHeight = 20.0
        static let gap = 4.0
        static let hookRowCap = 4
        static let tailRowCap = 6
    }

    let palette: HerdPalette
    let status: AgentStatus
    let agentName: String
    let route: PreviewRoute
    /// Last non-empty pane lines, for the preview-only route.
    let paneTail: [String]
    /// Preview-only text for agents without a pane to read.
    let fallbackText: String
    let isSent: Bool
    /// The scroll area the block sits in; the preview row count adapts to its height.
    let viewport: CGSize
    /// Decisions carry the token of the request the card shows, never the session.
    let onHook: (UInt64, HookDecision) -> Void
    /// Wrapped-input lines of a hook request; the host caches them per token.
    let hookLines: (PendingApproval) -> [String]
    /// `nil` index means Esc.
    let onPaneOption: (PanePrompt, Int?) -> Void
    /// Receives the shown hook request's token, if any, so the host can hand that request back to Claude.
    let onJump: (UInt64?) -> Void
    let onCollapse: () -> Void

    /// Buttons ignore taps briefly after the shown request changes, so a click aimed at the old one cannot land.
    @State private var isDisarmed = false
    @State private var rearmTask: Task<Void, Never>?

    private struct Action {
        let title: String
        let help: String
        var isPrimary = false
        let run: () -> Void
    }

    private var actions: [Action] {
        switch route {
        case .hook(let approval, let canAlways, let question):
            if let question {
                return question.labels.map { label in
                    Action(title: label, help: label) { onHook(approval.token, .answers([question.question: label])) }
                }
            }
            guard approval.request.toolName != "AskUserQuestion" else { return [] }
            var out = [Action(title: "Allow", help: "Allow this once", isPrimary: true) { onHook(approval.token, .allow) }]
            if canAlways {
                let help = PreviewText.alwaysHelp(approval.request.permissionSuggestions.first)
                out.append(Action(title: "Always", help: help) { onHook(approval.token, .always(suggestionIndex: 0)) })
            }
            out.append(Action(title: "Deny", help: "Deny this request") {
                onHook(approval.token, .deny(message: "Denied from HerdNotch"))
            })
            return out
        case .pane(let prompt):
            let options = prompt.options.enumerated().map { index, option in
                Action(title: PreviewText.shortLabel(option.label), help: option.label) { onPaneOption(prompt, index) }
            }
            return options + [Action(title: "Esc", help: "Cancel the prompt") { onPaneOption(prompt, nil) }]
        case .previewOnly:
            return []
        }
    }

    private var hookToken: UInt64? {
        if case .hook(let approval, _, _) = route { return approval.token }
        return nil
    }

    private var innerWidth: Double { max(80, viewport.width - 2 * Metrics.blockPadding) }

    private var buttonRows: Int {
        PreviewText.flowRows(
            widths: actions.map { Double($0.title.count) * 6.4 + 18 }, available: innerWidth, spacing: 6)
    }

    private var hookTitle: (name: String, detail: String?)? {
        guard case .hook(let approval, _, _) = route else { return nil }
        let request = approval.request
        let name = request.toolName == "AskUserQuestion" ? "Question" : ToolSummarizer.displayName(request.toolName)
        var detail: String?
        if request.toolName == "Bash", case .object(let input) = request.toolInput,
            case .string(let text)? = input["description"]
        {
            detail = text.split(whereSeparator: \.isNewline).first.map(String.init)
        }
        return (name, detail)
    }

    private var previewRows: [String] {
        let columns = Int(innerWidth / Metrics.charWidth)
        let rowCount = rowBudget
        switch route {
        case .hook(let approval, _, let question):
            if let question { return PreviewText.rows([question.question], columns: columns, maxRows: max(2, rowCount)) }
            let lines = hookLines(approval)
            // At least two rows: one line of the request plus the "more" marker, so Allow never sits above nothing.
            return PreviewText.rows(lines, columns: columns, maxRows: max(2, min(rowCount, Metrics.hookRowCap)))
        case .pane(let prompt):
            let lines = prompt.question.isEmpty ? ["Waiting for a choice"] : prompt.question
            return PreviewText.rows(lines, columns: columns, maxRows: rowCount, keepTail: true)
        case .previewOnly:
            let lines = paneTail.isEmpty ? [fallbackText] : paneTail
            return PreviewText.rows(lines, columns: columns, maxRows: min(rowCount, Metrics.tailRowCap), keepTail: true)
        }
    }

    /// Rows left once the header, title line and button rows have their share of the viewport (at least one).
    private var rowBudget: Int {
        let buttons = buttonRows
        var used = 2 * Metrics.blockPaddingV + Metrics.headerHeight + Metrics.gap
        if hookTitle != nil { used += Metrics.titleHeight + Metrics.gap }
        if buttons > 0 { used += Double(buttons) * Metrics.buttonHeight + Double(buttons) * Metrics.gap }
        return max(1, Int((viewport.height - used) / Metrics.lineHeight))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            header
            if let title = hookTitle {
                (Text(title.name).font(.system(size: 10, weight: .semibold)).foregroundColor(palette.textPrimary)
                    + Text(title.detail.map { "  " + $0 } ?? "").font(.system(size: 10)).foregroundColor(palette.textTertiary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(previewRows.enumerated()), id: \.offset) { _, row in
                    Text(row)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if isSent {
                Text("Sent")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .frame(height: Metrics.buttonHeight)
            } else if !actions.isEmpty {
                FlowLayout(spacing: 6, rowSpacing: Metrics.gap) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                        PreviewButton(palette: palette, title: action.title, isPrimary: action.isPrimary, action: action.run)
                            .help(action.help)
                    }
                }
                .disabled(isDisarmed)
                .opacity(isDisarmed ? 0.5 : 1)
            }
        }
        .onChange(of: route.key) {
            isDisarmed = true
            rearmTask?.cancel()
            rearmTask = Task {
                try? await Task.sleep(for: .milliseconds(400))
                if !Task.isCancelled { isDisarmed = false }
            }
        }
        .onDisappear { rearmTask?.cancel() }
        .padding(.horizontal, Metrics.blockPadding)
        .padding(.vertical, Metrics.blockPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Dot, agent name and Jump: the same identity line the collapsed row shows, so the user sees which agent.
    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                Circle().fill(palette.accent(for: status) ?? palette.textTertiary)
                    .frame(width: 9, height: 9)
                    .padding(.trailing, 12)
                Text(agentName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onCollapse)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Agent \(agentName), \(status.phrase)")
            .accessibilityHint("Hides the preview.")
            PreviewButton(palette: palette, title: "Jump \u{2197}") { onJump(hookToken) }
        }
        .frame(height: Metrics.headerHeight)
    }
}

/// Wraps children onto further rows instead of truncating or stretching them.
private struct FlowLayout: Layout {
    let spacing: CGFloat
    let rowSpacing: CGFloat

    private func place(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width { size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (frames, CGSize(width: maxX, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        place(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laid = place(subviews, width: bounds.width)
        for (subview, frame) in zip(subviews, laid.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }
}

/// A compact text button; only the primary one carries the accent.
private struct PreviewButton: View {
    let palette: HerdPalette
    let title: String
    var isPrimary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isPrimary ? palette.surface : palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .frame(minHeight: 20)
                .background(isPrimary ? palette.done : palette.hoverFill, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }
}

/// Binds ``AgentPreviewCard`` to live state: the pending hook request, the pane tail and the jump path.
struct AgentPreviewHost: View {
    let palette: HerdPalette
    let entry: NotchAgentEntry
    @ObservedObject var herdModel: NotchHerdModel
    @ObservedObject var approvals: ApprovalCenter
    let viewport: CGSize
    let onSelectAgent: (HerdSession, HerdAgent) -> Void

    @State private var isSent = false
    @State private var sentTask: Task<Void, Never>?
    /// Set synchronously on a pane click so a double-click cannot start a second send.
    @State private var isSending = false

    private var sessionID: String? { entry.agent.agentSessionID }

    private var paneText: String? {
        entry.agent.source == .herdr ? herdModel.expandedPaneText?.text : nil
    }

    var body: some View {
        AgentPreviewCard(
            palette: palette,
            status: entry.effectiveStatus,
            agentName: entry.agent.displayIdentifier,
            route: PreviewRoute.resolve(approval: sessionID.flatMap { approvals.pending[$0] }, paneText: paneText),
            paneTail: Self.tail(paneText, count: 6),
            fallbackText: fallbackText,
            isSent: isSent,
            viewport: viewport,
            onHook: { token, decision in
                if approvals.decide(token: token, decision) { showSent() }
            },
            hookLines: { approvals.hookLines(for: $0) },
            onPaneOption: { prompt, index in
                guard !isSending else { return }
                isSending = true
                Task {
                    let outcome = await herdModel.sendPaneOption(entry, optionIndex: index, shown: prompt)
                    isSending = false
                    if outcome == .sent { showSent() }
                }
            },
            onJump: { token in
                if let token { approvals.decide(token: token, .passthrough) }
                onSelectAgent(entry.session, entry.agent)
            },
            onCollapse: { herdModel.expandedPaneID = nil }
        )
        .onDisappear { sentTask?.cancel() }
    }

    private var fallbackText: String {
        if entry.agent.source == .herdr { return "No output yet" }
        return entry.activity?.pendingAsk ?? entry.activity?.currentTool?.display ?? "No live preview for this agent"
    }

    private func showSent() {
        isSent = true
        sentTask?.cancel()
        sentTask = Task {
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { isSent = false }
        }
    }

    /// The last `count` non-empty lines, trimmed.
    static func tail(_ text: String?, count: Int) -> [String] {
        let lines = (text ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(lines.suffix(count))
    }
}
