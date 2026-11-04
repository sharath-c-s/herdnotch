import AppKit
import HerdKit
import HerdPanelUI
import NotchCore
import NotchGeometry
import SwiftUI

/// The Health page: what is limiting this Mac (left) and what to do about it (right), at their
/// ``HealthLayout`` frames. HerdNotch only points; it never quits or kills anything. No animation here.
struct HealthPageView: View {
    let layout: HealthLayout
    let palette: HerdPalette
    @ObservedObject var load: SystemLoadService
    let panes: [HerdPane]
    let onSelectAgent: (HerdSession, HerdAgent) -> Void

    private static let cardRadius: CGFloat = 16
    private static let activityMonitor = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")

    var body: some View {
        ZStack(alignment: .topLeading) {
            card(layout.throttling) { throttlingContent }
            card(layout.improve) { improveContent }
        }
        .frame(width: layout.shelf.maxX + BentoLayout.margin, height: layout.shelf.maxY + BentoLayout.margin, alignment: .topLeading)
        .onChange(of: externalAgents, initial: true) { _, agents in load.setExternalAgents(agents) }
    }

    /// Local agents (detected by process, `HerdAgent.pid` non-nil; herdr agents carry no pid) that the Claude
    /// registry may lack, such as Codex; the sampler merges them under the registry.
    private var externalAgents: [Int32: AgentIdentity] {
        var result: [Int32: AgentIdentity] = [:]
        for pane in panes {
            guard let pid = pane.agent.pid else { continue }
            result[pid] = AgentIdentity(label: pane.agent.displayName, sessionId: pane.agent.agentSessionID)
        }
        return result
    }

    // MARK: - Chrome

    private func card<Content: View>(_ frame: CGRect, @ViewBuilder content: () -> Content) -> some View {
        // Content can outgrow the card on a small panel, so the indicator stays visible.
        ScrollView(.vertical, showsIndicators: true) {
            content().padding(10).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .background(palette.cardFill)
        .overlay(
            RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous))
        .position(x: frame.midX, y: frame.midY)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(palette.textSecondary)
    }

    private func color(_ level: HealthLevel) -> Color {
        switch level {
        case .ok: palette.working
        case .elevated: Color.orange
        case .limiting: palette.blocked
        }
    }

    // MARK: - Throttling

    private var throttlingContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            header("THROTTLING")
            if let readings = load.readings {
                let rows = load.report?.rows ?? HealthReport.rows(for: readings)
                let half = (rows.count + 1) / 2
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) { ForEach(rows.prefix(half)) { statusRow($0) } }
                    VStack(alignment: .leading, spacing: 3) { ForEach(rows.dropFirst(half)) { statusRow($0) } }
                }
                if let report = load.report { listsContent(report) } else { line("Measuring processes…") }
            } else {
                line("Measuring…")
            }
        }
    }

    private func statusRow(_ row: HealthRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(row.title).foregroundStyle(palette.textSecondary)
                Spacer(minLength: 4)
                Text(row.value).foregroundStyle(color(row.level)).lineLimit(1)
            }
            .font(.system(size: 12))
            .monospacedDigit()
            if let fraction = row.fraction {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.10))
                        Capsule().fill(color(row.level)).frame(width: proxy.size.width * min(1, max(0, fraction)))
                    }
                }
                .frame(height: 3)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func listsContent(_ report: HealthReport) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 1) {
                    header("TOP CPU")
                    ForEach(report.topCPU, id: \.pid) { process in
                        usageRow(process.name, LoadFormat.percent(process.cpuPercent))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    header("TOP MEMORY")
                    ForEach(report.topMemory, id: \.pid) { process in
                        usageRow(process.name, LoadFormat.bytes(process.residentBytes) + (process.isSystem ? " rss" : ""))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !report.agentSwarms.isEmpty || !report.otherSwarms.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    header("SWARMS BY AGENT")
                    ForEach(report.agentSwarms.prefix(2)) { swarm in
                        Button(action: { select(swarm.agentPid, swarm.identity.sessionId) }) {
                            usageRow(
                                "\(swarm.identity.label): \(LoadFormat.agentSwarmTitle(swarm))",
                                "\(LoadFormat.percent(swarm.cpuPercent)) · \(LoadFormat.bytes(swarm.residentBytes))")
                        }
                        .buttonStyle(.plain)
                        .disabled(pane(pid: swarm.agentPid, sessionId: swarm.identity.sessionId) == nil)
                    }
                    ForEach(report.otherSwarms.prefix(max(0, 2 - report.agentSwarms.count)), id: \.family) { swarm in
                        usageRow(
                            LoadFormat.swarmTitle(swarm),
                            "\(LoadFormat.percent(swarm.cpuPercent)) · \(LoadFormat.bytes(swarm.residentBytes))")
                    }
                }
            }
        }
    }

    private func usageRow(_ name: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(name).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Text(value).lineLimit(1)
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(palette.textSecondary)
        .contentShape(Rectangle())
    }

    // MARK: - Improve

    private var improveContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            header("IMPROVE")
            if let report = load.report {
                if report.suggestions.isEmpty {
                    Text("Nothing to improve right now")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.working)
                } else {
                    ForEach(report.suggestions) { suggestionRow($0) }
                }
            } else {
                line("Measuring…")
            }
        }
    }

    private func suggestionRow(_ suggestion: HealthSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(suggestion.text)
                .font(.system(size: 12))
                .foregroundStyle(palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            switch suggestion.target {
            case .none:
                EmptyView()
            case .process:
                Button("Open Activity Monitor") { NSWorkspace.shared.open(Self.activityMonitor) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            case .agent(let pid, let sessionId):
                if pane(pid: pid, sessionId: sessionId) != nil {
                    Button("Jump to session") { select(pid, sessionId) }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
            }
        }
    }

    private func line(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(palette.textSecondary).lineLimit(1)
    }

    // MARK: - Jump

    private func pane(pid: Int32, sessionId: String?) -> HerdPane? {
        panes.first { $0.agent.pid == pid || (sessionId != nil && $0.agent.agentSessionID == sessionId) }
    }

    private func select(_ pid: Int32, _ sessionId: String?) {
        guard let pane = pane(pid: pid, sessionId: sessionId) else { return }
        onSelectAgent(pane.session, pane.agent)
    }
}
