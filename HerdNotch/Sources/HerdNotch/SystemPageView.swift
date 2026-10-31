import HerdPanelUI
import NotchCore
import NotchGeometry
import SwiftUI

/// The System page: power and keep-awake cards (now playing and reminders are drawn by `NotchContentView`) at their ``SystemLayout`` frames. The shelf is not drawn
/// here; `NotchContentView` keeps it on both pages. No animation anywhere on this page.
struct SystemPageView: View {
    let layout: SystemLayout
    let palette: HerdPalette
    /// The band clock's tick, so "45m left" counts down without a timer of its own.
    let now: Date
    @ObservedObject var power: PowerInfoService
    @ObservedObject var battery: BatteryService
    @ObservedObject var keepAwake: KeepAwakeService
    @ObservedObject var caffeinate: CaffeinateService
    @ObservedObject var lid: LidSleepController
    @ObservedObject private var preferences = NotchPreferences.shared
    /// The last `lid.install()` failure or cancellation, shown under the Lid closed row; `nil` after success.
    @State private var lidSetupMessage: String?

    private static let cardRadius: CGFloat = 16

    var body: some View {
        ZStack(alignment: .topLeading) {
            card(layout.power) { powerContent }
            card(layout.keepAwake, padding: keepAwakeMetrics.padding) { keepAwakeContent }
        }
        .frame(width: layout.shelf.maxX + BentoLayout.margin, height: layout.shelf.maxY + BentoLayout.margin, alignment: .topLeading)
    }

    // MARK: - Chrome

    private func card<Content: View>(
        _ frame: CGRect, padding: CGFloat = 12, @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            content().padding(padding).frame(maxWidth: .infinity, alignment: .topLeading)
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
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(palette.textSecondary)
    }

    // MARK: - Power

    private var powerContent: some View {
        let snapshot = power.snapshot
        return VStack(alignment: .leading, spacing: 6) {
            header("POWER")
            if battery.hasBattery {
                HStack(spacing: 10) {
                    line("Battery \(battery.percent ?? 0)%", primary: true)
                    line("health \(snapshot.healthPercent.map { "\($0)%" } ?? "--")")
                }
                line(powerDetail(snapshot))
                line("cycles \(PowerFormat.cycleText(snapshot.cycleCount))")
            } else {
                line("No battery")
            }
        }
    }

    private func powerDetail(_ snapshot: PowerInfoService.Snapshot) -> String {
        var parts: [String] = []
        if snapshot.isCharging || snapshot.onCharger { parts.append("on charger") }
        if let watts = snapshot.watts { parts.append(PowerFormat.wattsText(watts)) }
        if snapshot.isCharging {
            if snapshot.timeToFullMinutes != nil { parts.append("\(PowerFormat.timeRemaining(minutes: snapshot.timeToFullMinutes)) to full") }
        } else if !snapshot.onCharger {
            parts.append("\(PowerFormat.timeRemaining(minutes: snapshot.timeToEmptyMinutes)) left")
        }
        return parts.joined(separator: " · ")
    }

    private func line(_ text: String, primary: Bool = false) -> some View {
        Text(text)
            .font(.system(size: primary ? 15 : 13, weight: primary ? .semibold : .regular))
            .foregroundStyle(primary ? palette.textPrimary : palette.textSecondary)
            .lineLimit(1)
    }

    // MARK: - Keep awake

    private var keepAwakeMetrics: KeepAwakeMetrics { .fitting(cardHeight: layout.keepAwake.height) }

    private var keepAwakeContent: some View {
        VStack(alignment: .leading, spacing: keepAwakeMetrics.spacing) {
            if keepAwakeMetrics.showsHeader { header("KEEP AWAKE") }
            Button(action: keepAwake.toggleManual) {
                HStack(spacing: 6) {
                    Image(systemName: caffeinate.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .foregroundStyle(caffeinate.isActive ? palette.working : palette.textSecondary)
                    Text(stateText).foregroundStyle(palette.textPrimary)
                }
                .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Click to toggle keep awake")
            .accessibilityLabel("Keep awake: \(stateText)")
            if lid.isSetUp {
                checkbox("Lid closed", isOn: $preferences.keepAwakeLidMode)
            } else {
                HStack(spacing: 6) {
                    line("Lid closed")
                    Button("Set up…") { Task { lidSetupMessage = await lid.install().message } }
                        .buttonStyle(.link)
                        .font(.system(size: 13))
                }
                if let lidSetupMessage { line(lidSetupMessage) }
            }
            checkbox("While agents busy", isOn: $preferences.keepAwakeWhileAgentsBusy)
        }
    }

    private var stateText: String {
        guard caffeinate.isActive else { return "off" }
        var text = keepAwake.manualOn ? "on" : "on (auto)"
        if let end = caffeinate.autoOffDate { text += " · \(UsageFormat.duration(end.timeIntervalSince(now))) left" }
        return text
    }

    /// A plain `Button`, like the band's controls, rather than a `Toggle` checkbox.
    private func checkbox(_ title: String, isOn: Binding<Bool>) -> some View {
        Button(action: { isOn.wrappedValue.toggle() }) {
            HStack(spacing: 6) {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn.wrappedValue ? palette.working : palette.textSecondary)
                Text(title).foregroundStyle(palette.textSecondary)
            }
            .font(.system(size: 13))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn.wrappedValue ? "on" : "off")
    }
}
