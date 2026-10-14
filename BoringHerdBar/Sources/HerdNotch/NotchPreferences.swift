import Foundation
import NotchCore
import UsageKit

/// HerdNotch's own local settings: the interaction and appearance knobs that have no equivalent in the
/// shared `HerdHost/HerdPreferences` store, because they describe *how the notch itself behaves* (hover
/// timing, the collapsed pill, sticky-done duration, caffeinate auto-off) rather than herd data (watch
/// on/off, poll interval, session filter, remote paths), which stays in `HerdPreferences` and is shared
/// verbatim with `BoringHerdBar`.
///
/// A single `UserDefaults`-backed object rather than several free-standing globals, so `NotchSettingsView`
/// has one `@ObservedObject` to bind every notch-only control to, the same shape `HerdSettingsView` gets
/// from `HerdPreferences`. Modelled as a shared `ObservableObject` rather than static properties so every
/// observer (`NotchContentView`, the debug status-item menu, `NotchSettingsView`) sees a live change with
/// no manual refresh plumbing.
///
/// Thread-safety: main-actor isolated, like every other observable object in this target. `UserDefaults`
/// itself is thread-safe, but nothing here is written from off the main actor.
@MainActor
final class NotchPreferences: ObservableObject {
    /// The one instance every panel's content, the debug menu, the runtime consumers
    /// (`NotchCommandExecutor`, `NotchHerdModel`, `CaffeinateService`) and `NotchSettingsView` share.
    ///
    /// A singleton rather than a value threaded through every initializer: this is a single machine-wide
    /// settings store with no per-display variant, and the runtime types that read it (a per-display
    /// executor, a poller, a power-management service) would otherwise each need it plumbed through their
    /// own initializer for no behavioural difference from a shared one.
    static let shared = NotchPreferences()

    // MARK: - Defaults keys

    /// The `UserDefaults` key backing ``showCollapsedPill``.
    private static let showCollapsedPillKey = "herdNotchShowCollapsedPill"
    /// The `UserDefaults` key backing ``hoverInDelayMs``.
    private static let hoverInDelayMsKey = "herdNotchHoverInDelayMs"
    /// The `UserDefaults` key backing ``pageHoverDwellMs``.
    private static let pageHoverDwellMsKey = "herdNotchPageHoverDwellMs"
    /// The `UserDefaults` key backing ``exitGraceMs``.
    private static let exitGraceMsKey = "herdNotchExitGraceMs"
    /// The `UserDefaults` keys backing ``expandedWidth`` and ``expandedHeight``.
    private static let expandedWidthKey = "herdNotchExpandedWidth"
    private static let expandedHeightKey = "herdNotchExpandedHeight"
    /// The `UserDefaults` key backing ``stickyDoneSeconds``.
    private static let stickyDoneSecondsKey = "herdNotchStickyDoneSeconds"
    /// The `UserDefaults` key backing ``caffeinateAutoOffMinutes``.
    private static let caffeinateAutoOffMinutesKey = "herdNotchCaffeinateAutoOffMinutes"
    /// The `UserDefaults` key backing ``batteryAlertsEnabled``.
    private static let batteryAlertsEnabledKey = "herdNotchBatteryAlertsEnabled"
    /// The `UserDefaults` key backing ``batteryLowPercent``.
    private static let batteryLowPercentKey = "herdNotchBatteryLowPercent"
    /// The `UserDefaults` key backing ``batteryWarningPercent``.
    private static let batteryWarningPercentKey = "herdNotchBatteryWarningPercent"
    /// The `UserDefaults` key backing ``batteryCriticalPercent``.
    private static let batteryCriticalPercentKey = "herdNotchBatteryCriticalPercent"

    /// `UserDefaults` keys for the usage meters, keep-awake conditions and system alerts.
    private static let usageAlertsEnabledKey = "herdNotchUsageAlertsEnabled"
    private static let usageClaudeEnabledKey = "herdNotchUsageClaudeEnabled"
    private static let usageCodexEnabledKey = "herdNotchUsageCodexEnabled"
    private static let usageOpenCodeEnabledKey = "herdNotchUsageOpenCodeEnabled"
    private static let usageAntigravityEnabledKey = "herdNotchUsageAntigravityEnabled"
    private static let usageWarnPercentKey = "herdNotchUsageWarnPercent"
    private static let usageCriticalPercentKey = "herdNotchUsageCriticalPercent"
    private static let keepAwakeWhileAgentsBusyKey = "herdNotchKeepAwakeWhileAgentsBusy"
    private static let keepAwakeAppBundleIdsKey = "herdNotchKeepAwakeAppBundleIds"
    private static let keepAwakeOnChargerKey = "herdNotchKeepAwakeOnCharger"
    private static let keepAwakeExternalDisplayKey = "herdNotchKeepAwakeExternalDisplay"
    private static let keepAwakeLidModeKey = "herdNotchKeepAwakeLidMode"
    private static let lidBatteryCutoffPercentKey = "herdNotchLidBatteryCutoffPercent"
    private static let systemAlertMemoryEnabledKey = "herdNotchSystemAlertMemoryEnabled"
    private static let systemAlertDiskEnabledKey = "herdNotchSystemAlertDiskEnabled"
    private static let systemAlertCpuEnabledKey = "herdNotchSystemAlertCpuEnabled"

    // MARK: - Ranges and shipped defaults

    /// Valid range for ``hoverInDelayMs``, in milliseconds. The reducer's own hover-debounce effect exists
    /// to reject a cursor merely passing over the collapsed target, so `0` (instant) is a legal, if twitchy,
    /// choice; `300` is generous enough to feel like a deliberate "press and hold" without being mistaken
    /// for the panel simply not responding.
    static let hoverInDelayMsRange: ClosedRange<Int> = 0...300
    /// Shipped default for ``hoverInDelayMs``: ~60ms, low enough to feel instant on intentional hover, high
    /// enough to reject a cursor merely passing over the collapsed target on its way elsewhere.
    static let hoverInDelayMsDefault = 60
    /// Valid range and default for ``pageHoverDwellMs``, in milliseconds.
    static let pageHoverDwellMsRange: ClosedRange<Int> = 100...3000
    static let pageHoverDwellMsDefault = 500

    /// Valid range for ``exitGraceMs``, in milliseconds. Below `100` the grace window is close enough to
    /// the hover-in delay that a pointer merely crossing the panel's edge would collapse it; above `600`
    /// the panel would visibly linger after the pointer has plainly left.
    static let exitGraceMsRange: ClosedRange<Int> = 100...600
    /// Shipped default for ``exitGraceMs``: ~250ms, per the interaction design.
    static let exitGraceMsDefault = 250

    /// Valid ranges and shipped defaults for the expanded panel's size, in points. The height default
    /// leaves room for the shelf strip below the cards; the 720 width floor keeps the band widgets clear
    /// of the 200pt notch dead zone.
    static let expandedWidthRange: ClosedRange<Int> = 720...1000
    static let expandedHeightRange: ClosedRange<Int> = 320...560
    static let expandedWidthDefault = 760
    static let expandedHeightDefault = 432

    /// Valid range for ``stickyDoneSeconds``, in seconds. `0` disables the sticky-done behaviour entirely
    /// (an agent's dot follows herdr's live status with no local memory); `300` (five minutes) is long
    /// enough to notice a completed run even after stepping away briefly, without a genuinely idle agent
    /// masquerading as freshly-done indefinitely.
    static let stickyDoneSecondsRange: ClosedRange<Int> = 0...300
    /// Shipped default for ``stickyDoneSeconds``: a minute, matching the design's original fixed window.
    static let stickyDoneSecondsDefault = 60

    /// Offered options for ``caffeinateAutoOffMinutes``, in minutes. `0` means "never auto-off". Discrete
    /// steps, not a range, because the settings surface offers this as a segmented picker rather than a
    /// slider — there is no meaningful in-between value a user would type by hand.
    static let caffeinateAutoOffMinutesOptions: [Int] = [0, 30, 60, 120]
    /// Shipped default for ``caffeinateAutoOffMinutes``: matches `CaffeinateService`'s original fixed
    /// one-hour auto-release.
    static let caffeinateAutoOffMinutesDefault = 60

    /// Valid range for ``batteryLowPercent``, in percent.
    static let batteryLowPercentRange: ClosedRange<Int> = 15...50
    /// Shipped default for ``batteryLowPercent``.
    static let batteryLowPercentDefault = 20

    /// Valid range for ``batteryWarningPercent``, in percent.
    static let batteryWarningPercentRange: ClosedRange<Int> = 6...20
    /// Shipped default for ``batteryWarningPercent``.
    static let batteryWarningPercentDefault = 10

    /// Valid range for ``batteryCriticalPercent``, in percent.
    static let batteryCriticalPercentRange: ClosedRange<Int> = 1...10
    /// Shipped default for ``batteryCriticalPercent``.
    static let batteryCriticalPercentDefault = 5

    /// Usage warning bounds, in percent. The warning is kept strictly below the critical bound.
    static let usageWarnPercentRange: ClosedRange<Int> = 50...94
    static let usageWarnPercentDefault = 80
    static let usageCriticalPercentRange: ClosedRange<Int> = 60...99
    static let usageCriticalPercentDefault = 95

    /// Battery percentage at or below which lid-closed mode is refused while on battery.
    static let lidBatteryCutoffPercentRange: ClosedRange<Int> = 5...50
    static let lidBatteryCutoffPercentDefault = 20

    // MARK: - Published settings

    /// Whether the collapsed pill is drawn on a notchless display. Defaults to `false`: on hardware with
    /// no physical notch, a permanently visible floating pill is exactly the "boringNotch"-style chrome
    /// this app's design choices elsewhere try to avoid, so the shipped default is invisible-until-hovered.
    @Published var showCollapsedPill: Bool {
        didSet {
            guard showCollapsedPill != oldValue else { return }
            UserDefaults.standard.set(showCollapsedPill, forKey: Self.showCollapsedPillKey)
        }
    }

    /// How long the pointer must sit over a collapsed pill before the notch expands, in milliseconds.
    /// Clamped to ``hoverInDelayMsRange``. Read by `NotchCommandExecutor` at the moment each hover-debounce
    /// timer is scheduled, so a change here applies to the very next hover with no relaunch needed.
    @Published var hoverInDelayMs: Int {
        didSet {
            let clamped = Self.clamped(hoverInDelayMs, to: Self.hoverInDelayMsRange)
            if hoverInDelayMs != clamped {
                hoverInDelayMs = clamped
                return
            }
            guard hoverInDelayMs != oldValue else { return }
            UserDefaults.standard.set(hoverInDelayMs, forKey: Self.hoverInDelayMsKey)
        }
    }

    /// How long the pointer rests on the Herd/System page button before the page switches without a
    /// click. Clamped to ``pageHoverDwellMsRange``; read when each dwell starts.
    @Published var pageHoverDwellMs: Int {
        didSet {
            let clamped = Self.clamped(pageHoverDwellMs, to: Self.pageHoverDwellMsRange)
            if pageHoverDwellMs != clamped {
                pageHoverDwellMs = clamped
                return
            }
            guard pageHoverDwellMs != oldValue else { return }
            UserDefaults.standard.set(pageHoverDwellMs, forKey: Self.pageHoverDwellMsKey)
        }
    }

    /// Expanded panel width in points, clamped to ``expandedWidthRange``. `NotchWindowController`
    /// re-frames every panel live when it changes.
    @Published var expandedWidth: Int {
        didSet {
            let clamped = Self.clamped(expandedWidth, to: Self.expandedWidthRange)
            if expandedWidth != clamped {
                expandedWidth = clamped
                return
            }
            guard expandedWidth != oldValue else { return }
            UserDefaults.standard.set(expandedWidth, forKey: Self.expandedWidthKey)
        }
    }

    /// Expanded panel height in points, clamped to ``expandedHeightRange``. See ``expandedWidth``.
    @Published var expandedHeight: Int {
        didSet {
            let clamped = Self.clamped(expandedHeight, to: Self.expandedHeightRange)
            if expandedHeight != clamped {
                expandedHeight = clamped
                return
            }
            guard expandedHeight != oldValue else { return }
            UserDefaults.standard.set(expandedHeight, forKey: Self.expandedHeightKey)
        }
    }

    /// How long the pointer may stay outside the expanded panel before it collapses, in milliseconds.
    /// Clamped to ``exitGraceMsRange``. Read by `NotchCommandExecutor` at the moment each exit-grace timer
    /// is scheduled, so a change here applies to the very next collapse with no relaunch needed.
    @Published var exitGraceMs: Int {
        didSet {
            let clamped = Self.clamped(exitGraceMs, to: Self.exitGraceMsRange)
            if exitGraceMs != clamped {
                exitGraceMs = clamped
                return
            }
            guard exitGraceMs != oldValue else { return }
            UserDefaults.standard.set(exitGraceMs, forKey: Self.exitGraceMsKey)
        }
    }

    /// How long a just-finished agent keeps rendering as done (green) after herdr flips its live status
    /// away from done, unless it is touched and goes back to working first. In seconds, clamped to
    /// ``stickyDoneSecondsRange``. Read live by `NotchHerdModel` on every poll.
    @Published var stickyDoneSeconds: Int {
        didSet {
            let clamped = Self.clamped(stickyDoneSeconds, to: Self.stickyDoneSecondsRange)
            if stickyDoneSeconds != clamped {
                stickyDoneSeconds = clamped
                return
            }
            guard stickyDoneSeconds != oldValue else { return }
            UserDefaults.standard.set(stickyDoneSeconds, forKey: Self.stickyDoneSecondsKey)
        }
    }

    /// How long the caffeinate assertion is held before it releases itself automatically, in minutes. `0`
    /// means never auto-off — the assertion is held until manually toggled off. Snapped to the nearest
    /// value in ``caffeinateAutoOffMinutesOptions`` rather than clamped to a range, since the settings
    /// surface offers exactly these discrete choices. Read by `CaffeinateService` each time it (re)schedules
    /// its auto-release timer.
    @Published var caffeinateAutoOffMinutes: Int {
        didSet {
            let snapped = Self.nearestOption(caffeinateAutoOffMinutes, in: Self.caffeinateAutoOffMinutesOptions)
            if caffeinateAutoOffMinutes != snapped {
                caffeinateAutoOffMinutes = snapped
                return
            }
            guard caffeinateAutoOffMinutes != oldValue else { return }
            UserDefaults.standard.set(caffeinateAutoOffMinutes, forKey: Self.caffeinateAutoOffMinutesKey)
        }
    }

    /// Whether battery-threshold toasts (``NotchWindowController/handleBatteryChange(_:)``) fire at all.
    /// Defaults to `true`.
    @Published var batteryAlertsEnabled: Bool {
        didSet {
            guard batteryAlertsEnabled != oldValue else { return }
            UserDefaults.standard.set(batteryAlertsEnabled, forKey: Self.batteryAlertsEnabledKey)
        }
    }

    /// Charge percentage at or below which the battery is considered "low". Clamped to
    /// ``batteryLowPercentRange``, then bumped above ``batteryWarningPercent``'s current value so the
    /// slider gives live feedback the instant the two would otherwise invert — only this property is
    /// reassigned here (never `batteryWarningPercent`), so there is no risk of the two `didSet`s
    /// re-entering each other.
    @Published var batteryLowPercent: Int {
        didSet {
            var clamped = Self.clamped(batteryLowPercent, to: Self.batteryLowPercentRange)
            clamped = max(clamped, batteryWarningPercent + 1)
            if batteryLowPercent != clamped {
                batteryLowPercent = clamped
                return
            }
            guard batteryLowPercent != oldValue else { return }
            UserDefaults.standard.set(batteryLowPercent, forKey: Self.batteryLowPercentKey)
        }
    }

    /// Charge percentage at or below which the battery is considered "warning". Clamped to
    /// ``batteryWarningPercentRange``, then bounded into `(batteryCriticalPercent + 1)...(batteryLowPercent
    /// - 1)` for live slider feedback. `neighborCeiling` is floored at `neighborFloor` rather than built as
    /// a `ClosedRange`, so a critical/low pair pinched too close together to leave a legal gap clamps to
    /// `neighborFloor` instead of crashing on an inverted range.
    @Published var batteryWarningPercent: Int {
        didSet {
            var clamped = Self.clamped(batteryWarningPercent, to: Self.batteryWarningPercentRange)
            let neighborFloor = batteryCriticalPercent + 1
            let neighborCeiling = max(neighborFloor, batteryLowPercent - 1)
            clamped = min(max(clamped, neighborFloor), neighborCeiling)
            if batteryWarningPercent != clamped {
                batteryWarningPercent = clamped
                return
            }
            guard batteryWarningPercent != oldValue else { return }
            UserDefaults.standard.set(batteryWarningPercent, forKey: Self.batteryWarningPercentKey)
        }
    }

    /// Charge percentage at or below which the battery is considered "critical". Clamped to
    /// ``batteryCriticalPercentRange``, then bumped below ``batteryWarningPercent``'s current value for
    /// live slider feedback, mirroring ``batteryLowPercent``'s own "only clamp the edited property" rule.
    @Published var batteryCriticalPercent: Int {
        didSet {
            var clamped = Self.clamped(batteryCriticalPercent, to: Self.batteryCriticalPercentRange)
            clamped = min(clamped, batteryWarningPercent - 1)
            if batteryCriticalPercent != clamped {
                batteryCriticalPercent = clamped
                return
            }
            guard batteryCriticalPercent != oldValue else { return }
            UserDefaults.standard.set(batteryCriticalPercent, forKey: Self.batteryCriticalPercentKey)
        }
    }

    /// ``batteryLowPercent``/``batteryWarningPercent``/``batteryCriticalPercent`` as a ``BatteryThresholds``,
    /// delegating to ``BatteryAlert/ordered(low:warning:critical:)`` for the strict `critical < warning <
    /// low` the classifier needs — each per-setting `didSet` above already gives live UI feedback against
    /// its immediate neighbours, but this is the defensive backstop against a hand-edited plist or a
    /// same-tick multi-slider drag still landing on an inverted or equal triple.
    var batteryThresholds: BatteryThresholds {
        BatteryAlert.ordered(low: batteryLowPercent, warning: batteryWarningPercent, critical: batteryCriticalPercent)
    }

    /// Whether usage threshold and reset toasts fire at all.
    @Published var usageAlertsEnabled: Bool {
        didSet {
            guard usageAlertsEnabled != oldValue else { return }
            UserDefaults.standard.set(usageAlertsEnabled, forKey: Self.usageAlertsEnabledKey)
        }
    }

    /// Whether the Claude usage meter is fetched and shown.
    @Published var usageClaudeEnabled: Bool {
        didSet {
            guard usageClaudeEnabled != oldValue else { return }
            UserDefaults.standard.set(usageClaudeEnabled, forKey: Self.usageClaudeEnabledKey)
        }
    }

    /// Whether the Codex usage meter is fetched and shown.
    @Published var usageCodexEnabled: Bool {
        didSet {
            guard usageCodexEnabled != oldValue else { return }
            UserDefaults.standard.set(usageCodexEnabled, forKey: Self.usageCodexEnabledKey)
        }
    }

    /// Whether the OpenCode usage meter is fetched and shown.
    @Published var usageOpenCodeEnabled: Bool {
        didSet {
            guard usageOpenCodeEnabled != oldValue else { return }
            UserDefaults.standard.set(usageOpenCodeEnabled, forKey: Self.usageOpenCodeEnabledKey)
        }
    }

    /// Whether the Antigravity usage meter is fetched and shown.
    @Published var usageAntigravityEnabled: Bool {
        didSet {
            guard usageAntigravityEnabled != oldValue else { return }
            UserDefaults.standard.set(usageAntigravityEnabled, forKey: Self.usageAntigravityEnabledKey)
        }
    }

    /// Usage percentage that raises the first warning toast. Clamped to ``usageWarnPercentRange`` and kept
    /// below ``usageCriticalPercent``.
    @Published var usageWarnPercent: Int {
        didSet {
            var clamped = Self.clamped(usageWarnPercent, to: Self.usageWarnPercentRange)
            clamped = min(clamped, usageCriticalPercent - 1)
            if usageWarnPercent != clamped {
                usageWarnPercent = clamped
                return
            }
            guard usageWarnPercent != oldValue else { return }
            UserDefaults.standard.set(usageWarnPercent, forKey: Self.usageWarnPercentKey)
        }
    }

    /// Usage percentage that raises the critical toast. Clamped to ``usageCriticalPercentRange`` and kept
    /// above ``usageWarnPercent``.
    @Published var usageCriticalPercent: Int {
        didSet {
            var clamped = Self.clamped(usageCriticalPercent, to: Self.usageCriticalPercentRange)
            clamped = max(clamped, usageWarnPercent + 1)
            if usageCriticalPercent != clamped {
                usageCriticalPercent = clamped
                return
            }
            guard usageCriticalPercent != oldValue else { return }
            UserDefaults.standard.set(usageCriticalPercent, forKey: Self.usageCriticalPercentKey)
        }
    }

    /// Keep the Mac awake while any agent is working.
    @Published var keepAwakeWhileAgentsBusy: Bool {
        didSet {
            guard keepAwakeWhileAgentsBusy != oldValue else { return }
            UserDefaults.standard.set(keepAwakeWhileAgentsBusy, forKey: Self.keepAwakeWhileAgentsBusyKey)
        }
    }

    /// Comma-separated bundle ids; keep the Mac awake while any of these apps is running.
    @Published var keepAwakeAppBundleIds: String {
        didSet {
            guard keepAwakeAppBundleIds != oldValue else { return }
            UserDefaults.standard.set(keepAwakeAppBundleIds, forKey: Self.keepAwakeAppBundleIdsKey)
        }
    }

    /// Keep the Mac awake while on the charger.
    @Published var keepAwakeOnCharger: Bool {
        didSet {
            guard keepAwakeOnCharger != oldValue else { return }
            UserDefaults.standard.set(keepAwakeOnCharger, forKey: Self.keepAwakeOnChargerKey)
        }
    }

    /// Keep the Mac awake while an external display is connected.
    @Published var keepAwakeExternalDisplay: Bool {
        didSet {
            guard keepAwakeExternalDisplay != oldValue else { return }
            UserDefaults.standard.set(keepAwakeExternalDisplay, forKey: Self.keepAwakeExternalDisplayKey)
        }
    }

    /// Keep the Mac awake with the lid closed (`pmset disablesleep`) while a hold is active.
    @Published var keepAwakeLidMode: Bool {
        didSet {
            guard keepAwakeLidMode != oldValue else { return }
            UserDefaults.standard.set(keepAwakeLidMode, forKey: Self.keepAwakeLidModeKey)
        }
    }

    /// Battery percentage at or below which lid-closed mode is refused on battery. Clamped to
    /// ``lidBatteryCutoffPercentRange``.
    @Published var lidBatteryCutoffPercent: Int {
        didSet {
            let clamped = Self.clamped(lidBatteryCutoffPercent, to: Self.lidBatteryCutoffPercentRange)
            if lidBatteryCutoffPercent != clamped {
                lidBatteryCutoffPercent = clamped
                return
            }
            guard lidBatteryCutoffPercent != oldValue else { return }
            UserDefaults.standard.set(lidBatteryCutoffPercent, forKey: Self.lidBatteryCutoffPercentKey)
        }
    }

    /// Whether the critical memory-pressure toast fires.
    @Published var systemAlertMemoryEnabled: Bool {
        didSet {
            guard systemAlertMemoryEnabled != oldValue else { return }
            UserDefaults.standard.set(systemAlertMemoryEnabled, forKey: Self.systemAlertMemoryEnabledKey)
        }
    }

    /// Whether the low-disk-space toast fires.
    @Published var systemAlertDiskEnabled: Bool {
        didSet {
            guard systemAlertDiskEnabled != oldValue else { return }
            UserDefaults.standard.set(systemAlertDiskEnabled, forKey: Self.systemAlertDiskEnabledKey)
        }
    }

    /// Whether the sustained-CPU toast fires.
    @Published var systemAlertCpuEnabled: Bool {
        didSet {
            guard systemAlertCpuEnabled != oldValue else { return }
            UserDefaults.standard.set(systemAlertCpuEnabled, forKey: Self.systemAlertCpuEnabledKey)
        }
    }

    /// The providers whose usage is fetched and shown.
    var enabledUsageProviders: Set<UsageProvider> {
        var providers: Set<UsageProvider> = []
        if usageClaudeEnabled { providers.insert(.claude) }
        if usageCodexEnabled { providers.insert(.codex) }
        if usageOpenCodeEnabled { providers.insert(.openCode) }
        if usageAntigravityEnabled { providers.insert(.antigravity) }
        return providers
    }

    /// The enabled automatic keep-awake conditions.
    var keepAwakeConditions: KeepAwakeConditions {
        let ids = keepAwakeAppBundleIds.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return KeepAwakeConditions(
            anyAgentWorking: keepAwakeWhileAgentsBusy, appRunningBundleIds: Set(ids),
            onCharger: keepAwakeOnCharger, externalDisplay: keepAwakeExternalDisplay)
    }

    /// Loads every stored value, registering the shipped defaults first so a key nobody has ever written
    /// reads back as this type's own sensible default rather than `UserDefaults`'s zero-value fallback
    /// (which would otherwise clamp a never-set ``hoverInDelayMs`` down to `0`, not `60`). Every loaded
    /// value is still clamped/snapped defensively, so a hand-edited plist cannot produce an out-of-range
    /// timer or an unsupported caffeinate option.
    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Self.hoverInDelayMsKey: Self.hoverInDelayMsDefault,
            Self.pageHoverDwellMsKey: Self.pageHoverDwellMsDefault,
            Self.exitGraceMsKey: Self.exitGraceMsDefault,
            Self.expandedWidthKey: Self.expandedWidthDefault,
            Self.expandedHeightKey: Self.expandedHeightDefault,
            Self.stickyDoneSecondsKey: Self.stickyDoneSecondsDefault,
            Self.caffeinateAutoOffMinutesKey: Self.caffeinateAutoOffMinutesDefault,
            Self.batteryAlertsEnabledKey: true,
            Self.batteryLowPercentKey: Self.batteryLowPercentDefault,
            Self.batteryWarningPercentKey: Self.batteryWarningPercentDefault,
            Self.batteryCriticalPercentKey: Self.batteryCriticalPercentDefault,
            Self.usageAlertsEnabledKey: true,
            Self.usageClaudeEnabledKey: true,
            Self.usageCodexEnabledKey: true,
            Self.usageOpenCodeEnabledKey: false,
            Self.usageAntigravityEnabledKey: false,
            Self.usageWarnPercentKey: Self.usageWarnPercentDefault,
            Self.usageCriticalPercentKey: Self.usageCriticalPercentDefault,
            Self.lidBatteryCutoffPercentKey: Self.lidBatteryCutoffPercentDefault,
            Self.systemAlertMemoryEnabledKey: true,
            Self.systemAlertDiskEnabledKey: true,
            Self.systemAlertCpuEnabledKey: true
        ])
        showCollapsedPill = defaults.bool(forKey: Self.showCollapsedPillKey)
        hoverInDelayMs = Self.clamped(
            defaults.integer(forKey: Self.hoverInDelayMsKey), to: Self.hoverInDelayMsRange
        )
        pageHoverDwellMs = Self.clamped(
            defaults.integer(forKey: Self.pageHoverDwellMsKey), to: Self.pageHoverDwellMsRange
        )
        exitGraceMs = Self.clamped(
            defaults.integer(forKey: Self.exitGraceMsKey), to: Self.exitGraceMsRange
        )
        expandedWidth = Self.clamped(
            defaults.integer(forKey: Self.expandedWidthKey), to: Self.expandedWidthRange
        )
        expandedHeight = Self.clamped(
            defaults.integer(forKey: Self.expandedHeightKey), to: Self.expandedHeightRange
        )
        stickyDoneSeconds = Self.clamped(
            defaults.integer(forKey: Self.stickyDoneSecondsKey), to: Self.stickyDoneSecondsRange
        )
        caffeinateAutoOffMinutes = Self.nearestOption(
            defaults.integer(forKey: Self.caffeinateAutoOffMinutesKey), in: Self.caffeinateAutoOffMinutesOptions
        )
        batteryAlertsEnabled = defaults.bool(forKey: Self.batteryAlertsEnabledKey)
        batteryLowPercent = Self.clamped(
            defaults.integer(forKey: Self.batteryLowPercentKey), to: Self.batteryLowPercentRange
        )
        batteryWarningPercent = Self.clamped(
            defaults.integer(forKey: Self.batteryWarningPercentKey), to: Self.batteryWarningPercentRange
        )
        batteryCriticalPercent = Self.clamped(
            defaults.integer(forKey: Self.batteryCriticalPercentKey), to: Self.batteryCriticalPercentRange
        )
        usageAlertsEnabled = defaults.bool(forKey: Self.usageAlertsEnabledKey)
        usageClaudeEnabled = defaults.bool(forKey: Self.usageClaudeEnabledKey)
        usageCodexEnabled = defaults.bool(forKey: Self.usageCodexEnabledKey)
        usageOpenCodeEnabled = defaults.bool(forKey: Self.usageOpenCodeEnabledKey)
        usageAntigravityEnabled = defaults.bool(forKey: Self.usageAntigravityEnabledKey)
        let critical = Self.clamped(
            defaults.integer(forKey: Self.usageCriticalPercentKey), to: Self.usageCriticalPercentRange)
        usageCriticalPercent = critical
        usageWarnPercent = min(
            Self.clamped(defaults.integer(forKey: Self.usageWarnPercentKey), to: Self.usageWarnPercentRange),
            critical - 1)
        keepAwakeWhileAgentsBusy = defaults.bool(forKey: Self.keepAwakeWhileAgentsBusyKey)
        keepAwakeAppBundleIds = defaults.string(forKey: Self.keepAwakeAppBundleIdsKey) ?? ""
        keepAwakeOnCharger = defaults.bool(forKey: Self.keepAwakeOnChargerKey)
        keepAwakeExternalDisplay = defaults.bool(forKey: Self.keepAwakeExternalDisplayKey)
        keepAwakeLidMode = defaults.bool(forKey: Self.keepAwakeLidModeKey)
        lidBatteryCutoffPercent = Self.clamped(
            defaults.integer(forKey: Self.lidBatteryCutoffPercentKey), to: Self.lidBatteryCutoffPercentRange)
        systemAlertMemoryEnabled = defaults.bool(forKey: Self.systemAlertMemoryEnabledKey)
        systemAlertDiskEnabled = defaults.bool(forKey: Self.systemAlertDiskEnabledKey)
        systemAlertCpuEnabled = defaults.bool(forKey: Self.systemAlertCpuEnabledKey)
    }

    /// Clamps `value` into `range`.
    ///
    /// - Parameters:
    ///   - value: The raw value, from `UserDefaults` or a UI control.
    ///   - range: The inclusive bounds to clamp into.
    /// - Returns: `value`, clamped into `range`.
    private static func clamped(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Snaps `value` to the closest entry in `options`.
    ///
    /// - Parameters:
    ///   - value: The raw value, from `UserDefaults` or a UI control.
    ///   - options: The discrete choices offered, never empty.
    /// - Returns: The closest option to `value`, or `value` itself if `options` is empty (defensive; never
    ///   happens with this type's own non-empty option lists).
    private static func nearestOption(_ value: Int, in options: [Int]) -> Int {
        options.min(by: { abs($0 - value) < abs($1 - value) }) ?? value
    }
}
