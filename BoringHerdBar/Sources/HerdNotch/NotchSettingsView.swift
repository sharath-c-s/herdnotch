import HerdHost
import HerdHotKey
import HerdPanelUI
import NotchCore
import SwiftUI
import UsageKit

/// HerdNotch's merged settings window: four tabs over the notch's own knobs (``NotchPreferences``) and the
/// shared herd-data form (`HerdHost/HerdSettingsView`).
///
/// "HerdNotch" holds Interaction, Appearance, Panel size and Status dots. "Agents" embeds `HerdSettingsView`
/// without its menu-bar-only controls. "Usage" holds the providers and alert bounds; "Power" holds keep-awake,
/// lid-closed mode, battery thresholds and system alerts.
///
/// Layout follows the same conventions `HerdSettingsView` established: section headings are small-caps
/// labels, not a grouped `Form`'s own row metrics, and explanatory prose lives in a `.help()` tooltip
/// rather than inline, except where it is what tells the user what a control does.
///
/// Thread-safety: main-actor isolated, like every SwiftUI view in this target; every `@ObservedObject`
/// here is itself `@MainActor`.
struct NotchSettingsView: View {
    /// The notch-only knobs the "HerdNotch" tab edits directly.
    @ObservedObject var notchPreferences: NotchPreferences

    /// The shared herd-data settings, forwarded straight to the embedded `HerdSettingsView`.
    @ObservedObject var herdPreferences: HerdPreferences

    /// Live registration state of the shared search shortcut, forwarded to `HerdSettingsView`.
    @ObservedObject var hotKeyStatus: HerdHotKeyStatus

    /// Every discovered session name, forwarded to `HerdSettingsView`.
    @ObservedObject var roster: HerdSessionRoster

    /// Lid-closed setup state; shared because `main.swift` builds the window without the window controller.
    @ObservedObject private var lid = LidSleepController.shared

    /// Last result of a lid-closed setup or removal, shown under its buttons.
    @State private var lidMessage: String?

    /// Drives the palette for the few places this form spends a token of its own, mirroring
    /// `HerdSettingsView`.
    @Environment(\.colorScheme) private var colorScheme

    /// Width of the window's content. Matches `HerdSettingsView`'s own width, so the two tabs read as one
    /// family rather than two differently-proportioned utilities.
    private static let contentWidth: CGFloat = 400

    /// Height of the `TabView` itself, sized so both tabs have room without the window needing a resize
    /// when switching between them.
    private static let tabViewHeight: CGFloat = 560

    var body: some View {
        TabView {
            notchTab
                .tabItem { Label("HerdNotch", systemImage: "sparkles") }
            HerdSettingsView(
                preferences: herdPreferences, hotKeyStatus: hotKeyStatus, roster: roster,
                showsMenuBarOnlyControls: false
            )
                .tabItem { Label("Agents", systemImage: "point.3.connected.trianglepath.dotted") }
            usageTab
                .tabItem { Label("Usage", systemImage: "gauge.with.dots.needle.67percent") }
            powerTab
                .tabItem { Label("Power", systemImage: "bolt.fill") }
        }
        .frame(width: Self.contentWidth, height: Self.tabViewHeight)
    }

    /// The notch-only settings tab: everything `NotchPreferences` exposes.
    private var notchTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                interactionSection
                appearanceSection
                panelSizeSection
                statusDotsSection
            }
            .padding(18)
            .frame(width: Self.contentWidth, alignment: .leading)
        }
    }

    // MARK: - Interaction

    /// Hover-in delay and exit grace, the two timers `NotchCommandExecutor` schedules on every hover.
    private var interactionSection: some View {
        section("Interaction") {
            labeledSlider(
                "Hover-in delay",
                value: Binding(
                    get: { Double(notchPreferences.hoverInDelayMs) },
                    set: { notchPreferences.hoverInDelayMs = Int($0) }
                ),
                range: Self.doubleRange(NotchPreferences.hoverInDelayMsRange),
                step: 10,
                valueText: "\(notchPreferences.hoverInDelayMs) ms"
            )
            .help("How long the pointer must sit over the collapsed pill before the notch expands.")
            labeledSlider(
                "Exit grace",
                value: Binding(
                    get: { Double(notchPreferences.exitGraceMs) },
                    set: { notchPreferences.exitGraceMs = Int($0) }
                ),
                range: Self.doubleRange(NotchPreferences.exitGraceMsRange),
                step: 10,
                valueText: "\(notchPreferences.exitGraceMs) ms"
            )
            .help("How long the pointer may stay outside the expanded panel before it collapses.")
            labeledSlider(
                "Page switch hover",
                value: Binding(
                    get: { Double(notchPreferences.pageHoverDwellMs) },
                    set: { notchPreferences.pageHoverDwellMs = Int($0) }
                ),
                range: Self.doubleRange(NotchPreferences.pageHoverDwellMsRange),
                step: 100,
                valueText: String(format: "%.1f s", Double(notchPreferences.pageHoverDwellMs) / 1000)
            )
            .help("How long the pointer rests on Herd or System before the page switches without a click.")
        }
    }

    // MARK: - Appearance

    /// Whether the collapsed pill is visible at all on a notchless display.
    private var appearanceSection: some View {
        section("Appearance") {
            Toggle(
                "Show shape on displays without a notch",
                isOn: Binding(
                    get: { notchPreferences.showCollapsedPill },
                    set: { notchPreferences.showCollapsedPill = $0 }
                )
            )
            .help(
                "Draws the collapsed notch shape. On a Mac with a physical notch the cutout itself cannot be hidden; "
                    + "off, a notchless display shows nothing until hovered."
            )
        }
    }

    // MARK: - Panel size

    /// Expanded panel width and height; every open panel re-lays out live.
    private var panelSizeSection: some View {
        section("Panel size") {
            labeledSlider(
                "Width",
                value: Binding(
                    get: { Double(notchPreferences.expandedWidth) },
                    set: { notchPreferences.expandedWidth = Int($0) }
                ),
                range: Self.doubleRange(NotchPreferences.expandedWidthRange),
                step: 10,
                valueText: "\(notchPreferences.expandedWidth) pt"
            )
            labeledSlider(
                "Height",
                value: Binding(
                    get: { Double(notchPreferences.expandedHeight) },
                    set: { notchPreferences.expandedHeight = Int($0) }
                ),
                range: Self.doubleRange(NotchPreferences.expandedHeightRange),
                step: 10,
                valueText: "\(notchPreferences.expandedHeight) pt"
            )
            Button("Reset to default") {
                notchPreferences.expandedWidth = NotchPreferences.expandedWidthDefault
                notchPreferences.expandedHeight = NotchPreferences.expandedHeightDefault
            }
        }
    }

    // MARK: - Status dots

    /// How long a just-finished agent's dot stays green.
    private var statusDotsSection: some View {
        section("Status dots") {
            labeledSlider(
                "Keep finished agents green for",
                value: Binding(
                    get: { Double(notchPreferences.stickyDoneSeconds) },
                    set: { notchPreferences.stickyDoneSeconds = Int($0) }
                ),
                range: Self.doubleRange(NotchPreferences.stickyDoneSecondsRange),
                step: 10,
                valueText: notchPreferences.stickyDoneSeconds == 0 ? "off" : "\(notchPreferences.stickyDoneSeconds) s"
            )
            .help("How long a just-finished agent keeps its dot green before fading to idle. 0 turns this off.")
        }
    }

    // MARK: - Battery

    /// Whether battery-threshold toasts fire, and the three percentage bounds that drive both those toasts
    /// and the utility band's ring color.
    private var batterySection: some View {
        section("Battery thresholds") {
            Toggle(
                "Battery alerts",
                isOn: Binding(
                    get: { notchPreferences.batteryAlertsEnabled },
                    set: { notchPreferences.batteryAlertsEnabled = $0 }
                )
            )
            .help("Shows a toast when the charge crosses low/warning/critical, or reaches 100% while charging.")
            labeledSlider(
                "Low",
                value: Binding(
                    get: { Double(notchPreferences.batteryLowPercent) },
                    set: { notchPreferences.batteryLowPercent = Int($0) }
                ),
                range: Self.doubleRange(NotchPreferences.batteryLowPercentRange),
                step: 1,
                valueText: "\(notchPreferences.batteryLowPercent)%"
            )
            .help("Charge percentage at or below which the battery indicator and alerts read as low.")
            labeledSlider(
                "Warning",
                value: Binding(
                    get: { Double(notchPreferences.batteryWarningPercent) },
                    set: { notchPreferences.batteryWarningPercent = Int($0) }
                ),
                range: Self.doubleRange(NotchPreferences.batteryWarningPercentRange),
                step: 1,
                valueText: "\(notchPreferences.batteryWarningPercent)%"
            )
            .help("Charge percentage at or below which the battery indicator and alerts read as warning.")
            labeledSlider(
                "Critical",
                value: Binding(
                    get: { Double(notchPreferences.batteryCriticalPercent) },
                    set: { notchPreferences.batteryCriticalPercent = Int($0) }
                ),
                range: Self.doubleRange(NotchPreferences.batteryCriticalPercentRange),
                step: 1,
                valueText: "\(notchPreferences.batteryCriticalPercent)%"
            )
            .help("Charge percentage at or below which the battery indicator and alerts read as critical.")
        }
    }

    // MARK: - Usage tab

    private var usageTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Providers") {
                    Toggle("Claude", isOn: $notchPreferences.usageClaudeEnabled)
                    Toggle("Codex", isOn: $notchPreferences.usageCodexEnabled)
                    Toggle("OpenCode", isOn: $notchPreferences.usageOpenCodeEnabled)
                    Toggle("Antigravity", isOn: $notchPreferences.usageAntigravityEnabled)
                        .help("Providers without credentials show as not set up. Usage is polled every 5 minutes.")
                }
                section("Warnings") {
                    Toggle("Usage alerts", isOn: $notchPreferences.usageAlertsEnabled)
                        .help("Toast when Claude or Codex session or weekly usage crosses a bound, or resets.")
                    labeledSlider(
                        "Warn at",
                        value: Binding(
                            get: { Double(notchPreferences.usageWarnPercent) },
                            set: { notchPreferences.usageWarnPercent = Int($0) }),
                        range: Self.doubleRange(NotchPreferences.usageWarnPercentRange), step: 1,
                        valueText: "\(notchPreferences.usageWarnPercent)%")
                    labeledSlider(
                        "Critical at",
                        value: Binding(
                            get: { Double(notchPreferences.usageCriticalPercent) },
                            set: { notchPreferences.usageCriticalPercent = Int($0) }),
                        range: Self.doubleRange(NotchPreferences.usageCriticalPercentRange), step: 1,
                        valueText: "\(notchPreferences.usageCriticalPercent)%")
                }
            }
            .padding(18)
            .frame(width: Self.contentWidth, alignment: .leading)
        }
    }

    // MARK: - Power tab

    private var powerTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                keepAwakeSection
                lidSection
                batterySection
                systemAlertsSection
            }
            .padding(18)
            .frame(width: Self.contentWidth, alignment: .leading)
        }
    }

    /// Automatic keep-awake conditions, OR-combined with the manual toggle, plus the caffeinate auto-off.
    private var keepAwakeSection: some View {
        section("Keep awake") {
            Toggle("While agents are busy", isOn: $notchPreferences.keepAwakeWhileAgentsBusy)
            VStack(alignment: .leading, spacing: 2) {
                Text("While these apps run (bundle ids, comma separated)").font(.system(size: 11))
                TextField("com.apple.dt.Xcode, com.apple.Terminal", text: $notchPreferences.keepAwakeAppBundleIds)
                    .textFieldStyle(.roundedBorder)
            }
            Toggle("While on the charger", isOn: $notchPreferences.keepAwakeOnCharger)
            Toggle("While an external display is connected", isOn: $notchPreferences.keepAwakeExternalDisplay)
            Picker(
                "Manual auto-off",
                selection: Binding(
                    get: { notchPreferences.caffeinateAutoOffMinutes },
                    set: { notchPreferences.caffeinateAutoOffMinutes = $0 }
                )
            ) {
                ForEach(NotchPreferences.caffeinateAutoOffMinutesOptions, id: \.self) { minutes in
                    Text(minutes == 0 ? "Never" : "\(minutes) min").tag(minutes)
                }
            }
            .pickerStyle(.segmented)
            .help(
                "How long the manual toggle holds the machine awake before releasing itself. "
                    + "Never means until you turn it off by hand. Automatic conditions never time out."
            )
        }
    }

    /// Lid-closed mode needs a one-time admin prompt to install a sudoers rule for `pmset disablesleep`.
    private var lidSection: some View {
        section("Lid closed") {
            Toggle("Stay awake with the lid closed", isOn: $notchPreferences.keepAwakeLidMode)
                .disabled(!lid.isSetUp)
            HStack {
                Text(lid.isSetUp ? "Set up" : "Not set up")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if lid.isSetUp {
                    Button("Remove") { Task { lidMessage = await lid.uninstall().message } }
                } else {
                    Button("Set up…") { Task { lidMessage = await lid.install().message } }
                }
            }
            if let lidMessage {
                Text(lidMessage).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            labeledSlider(
                "Lid mode battery cutoff",
                value: Binding(
                    get: { Double(notchPreferences.lidBatteryCutoffPercent) },
                    set: { notchPreferences.lidBatteryCutoffPercent = Int($0) }),
                range: Self.doubleRange(NotchPreferences.lidBatteryCutoffPercentRange), step: 1,
                valueText: "\(notchPreferences.lidBatteryCutoffPercent)%"
            )
            .help("On battery, lid-closed mode turns off at or below this charge.")
        }
    }

    private var systemAlertsSection: some View {
        section("System alerts") {
            Toggle("Memory pressure critical", isOn: $notchPreferences.systemAlertMemoryEnabled)
            Toggle("Disk space low", isOn: $notchPreferences.systemAlertDiskEnabled)
            Toggle("CPU above 90% for 2 minutes", isOn: $notchPreferences.systemAlertCpuEnabled)
        }
    }

    // MARK: - Chrome

    /// One titled group of settings, matching `HerdSettingsView`'s own heading style.
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

    /// Widens an `Int` preference's clamped range to the `ClosedRange<Double>` a `Slider` needs.
    ///
    /// - Parameter range: One of ``NotchPreferences``'s own `Int` ranges.
    /// - Returns: The same bounds, as `Double`.
    private static func doubleRange(_ range: ClosedRange<Int>) -> ClosedRange<Double> {
        Double(range.lowerBound)...Double(range.upperBound)
    }

    /// A labeled slider with its live value shown alongside, for the millisecond/second/percent knobs.
    ///
    /// - Parameters:
    ///   - label: The control's name.
    ///   - value: A binding over the underlying `Int` preference, widened to `Double` for `Slider`.
    ///   - range: The slider's bounds, matching the preference's own clamped range.
    ///   - step: The slider's step size.
    ///   - valueText: The formatted current value, shown to the right of the slider.
    /// - Returns: The labeled control.
    private func labeledSlider(
        _ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, valueText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.system(size: 11))
                Spacer()
                Text(valueText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }
}
