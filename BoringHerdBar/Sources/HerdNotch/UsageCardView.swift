import HerdPanelUI
import NotchCore
import SwiftUI
import UsageKit

extension UsageProvider {
    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .openCode: "OpenCode"
        case .antigravity: "Antigravity"
        }
    }
}

/// Formatting for the usage meters: pure, so the card and the toasts agree.
enum UsageFormat {
    /// "42m", "1h 4m", "3d"; empty when the reset time is unknown.
    static func timeToReset(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        return duration(date.timeIntervalSince(now))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "now" }
        return ShortDuration.format(seconds: seconds, showsSeconds: false, showsDays: true)
    }

    static func windowLabel(_ window: UsageWindow) -> String {
        switch window.label {
        case "Session": "5h"
        case "Weekly": "wk"
        case "Monthly": "mo"
        default: window.periodSeconds == 7 * 86400 ? "\(window.label) wk" : window.label
        }
    }

    /// "$4", dropping cents when whole.
    static func dollars(_ value: Double) -> String {
        value.rounded() == value
            ? "$\(Int(value))" : String(format: "$%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func extraText(_ extra: UsageExtra) -> String {
        switch extra {
        case .claudeExtraUsage(let used, let limit):
            return limit.map { "extra \(dollars(used)) / \(dollars($0))" } ?? "extra \(dollars(used))"
        case .codexCredits(let credits, let usd):
            return "credits \(credits) (\(dollars(usd)))"
        }
    }
}

/// One provider's block on the System page: name, plan, a thin bar per window, and its state.
struct UsageCardView: View {
    let provider: UsageProvider
    let snapshot: UsageSnapshot?
    let palette: HerdPalette
    let now: Date
    let warnPercent: Int
    let criticalPercent: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if let snapshot, !isNotSetUp {
                windows(snapshot)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isNotSetUp: Bool {
        if case .notSetUp = snapshot?.state { return true }
        return false
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(provider.displayName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isNotSetUp ? palette.textSecondary : palette.textPrimary)
            if let plan = snapshot?.plan {
                Text(plan).font(.system(size: 11)).foregroundStyle(palette.textTertiary)
            }
            Spacer(minLength: 4)
            if let note = UsageStatus.note(for: snapshot, now: now) {
                Text(note).font(.system(size: 12)).foregroundStyle(palette.textSecondary).lineLimit(1)
            }
        }
    }

    private var dimmed: Bool { UsageStatus.isDimmed(snapshot, now: now) }

    private func windows(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(snapshot.windows.enumerated()), id: \.offset) { _, window in
                row(window)
            }
            if let extra = snapshot.extra {
                Text(UsageFormat.extraText(extra)).font(.system(size: 12)).foregroundStyle(palette.textSecondary)
            }
        }
        .opacity(dimmed ? 0.5 : 1)
    }

    private func row(_ window: UsageWindow) -> some View {
        let percent = min(max(window.usedPercent, 0), 100)
        return HStack(spacing: 8) {
            Text(UsageFormat.windowLabel(window))
                .font(.system(size: 12))
                .foregroundStyle(palette.textSecondary)
                .frame(width: 78, alignment: .leading)
                .lineLimit(1)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.hairline)
                    Capsule().fill(color(percent)).frame(width: proxy.size.width * percent / 100)
                }
            }
            .frame(height: 6)
            Text("\(Int(percent.rounded()))%")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(palette.textPrimary)
                .frame(width: 46, alignment: .trailing)
            Text(UsageFormat.timeToReset(window.resetsAt, now: now))
                .font(.system(size: 12))
                .foregroundStyle(palette.textTertiary)
                .frame(width: 56, alignment: .trailing)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(UsageFormat.windowLabel(window)) \(Int(percent.rounded())) percent used")
    }

    /// Green below the warning bound, amber from it, red from the critical bound.
    private func color(_ percent: Double) -> Color {
        if percent >= Double(criticalPercent) { return palette.blocked }
        if percent >= Double(warnPercent) { return palette.working }
        return palette.done
    }
}
