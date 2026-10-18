import AppKit
import HerdKit
import HerdPanelUI
import NotchCore
import NotchGeometry
import SwiftUI
import UniformTypeIdentifiers

/// The SwiftUI content hosted inside one display's `NotchPanel`.
///
/// This is the "Bento" redesign: sleek dark cards laid out two-dimensionally rather than the dense ledger
/// this file used to render — an agents hero card (scrolling breadcrumb list, or an in-card fuzzy search
/// over every agent), a Spotify now-playing card, and a reminders card, over a near-black gradient ground.
/// There is deliberately **no** per-route switch left in this view, same as before the redesign:
/// `NotchRoute/home`, `.herd`, `.reminders` and `.spotify` all render the exact same composite body (the
/// enum itself is untouched — `NotchCore`'s own logic is out of scope for this file to change — but
/// nothing here branches on it). A dedicated `NotchRoute/settings` case does not exist; the settings gear
/// in ``utilityBand`` calls ``onOpenSettings`` directly instead.
///
/// **What this redesign deliberately drops**, per the bento design spec's own codex-review resolution:
/// asymmetric card corners, notch-shaped flares, and a panel drop-shadow. All three would need a mask
/// refactor this phase is explicitly forbidden from touching (`NotchAnimator`/`NotchCore`/`NotchGeometry`
/// are untouched). Elevation instead comes from contrast alone: each card's ``HerdPalette/cardFill`` one
/// step above the panel's own near-black ground, a single hairline, and a 1px top highlight — no shadow,
/// no per-corner geometry.
///
/// - It reads `viewModel.presentation` to choose between the collapsed wings and the expanded surface, never
///   an animation-in-flight flag of its own: while `NotchAnimator` is growing or shrinking the container's
///   mask, this view is already showing whichever body its target state calls for, so the mask's motion is
///   a pure reveal/conceal of already-correct content rather than something this view needs to coordinate
///   with. `.collapsing` renders the *expanded* body, not the collapsed one: the shrinking mask is what
///   conceals the surface, and swapping the content out a frame early (before the mask has actually covered
///   it) is exactly the pop-then-shrink glitch an earlier adversarial review found — only `.collapsed`
///   itself, the animation's settled resting state, shows the wings.
/// - The whole expanded surface is a canvas of the user's chosen size (``NotchDisplayViewModel/expandedSize``),
///   and every card within it is placed at its ``BentoLayout`` frame regardless of its content: an
///   empty agents card, a not-running Spotify and a not-yet-authorized Reminders card all render into the
///   same frames, per the design spec's degenerate-state invariant.
///
/// Colours come from `HerdPalette`, the same tokens the ledger and search window use elsewhere in the app,
/// so the notch's look stays consistent with the rest of the app even though its layout no longer is.
struct NotchContentView: View {
    /// The observable presentation/route for this display, republished by `NotchWindowController` after
    /// every reducer call.
    @ObservedObject var viewModel: NotchDisplayViewModel

    /// The shared herd poller, owned by `NotchWindowController` and handed to every display's content:
    /// herd data is one machine-wide fact, not a per-display one, so every panel reads the same instance
    /// rather than each running its own poll loop.
    @ObservedObject var herdModel: NotchHerdModel

    /// The shared caffeinate toggle, owned by `NotchWindowController` for the same "one machine-wide fact"
    /// reason ``herdModel`` is shared: an idle-sleep assertion belongs to the process, not to whichever
    /// display's panel happens to be open, so every panel reads and drives the same instance.
    @ObservedObject var caffeinateService: CaffeinateService

    /// Manual/automatic keep-awake and lid mode over ``caffeinateService``; drives the band menu and the
    /// System page.
    @ObservedObject var keepAwakeService: KeepAwakeService
    @ObservedObject var lidSleepController: LidSleepController

    /// Battery health, watts and time remaining, for the System page and the battery ring's tooltip.
    @ObservedObject var powerInfoService: PowerInfoService

    /// Plan usage snapshots for the Herd page usage card.
    @ObservedObject var usageService: UsageService

    /// The shared macOS Reminders bridge, feeding ``remindersCard``. Shared for the same reason
    /// ``herdModel`` and ``caffeinateService`` are: one Reminders data set, not one per display.
    @ObservedObject var remindersService: RemindersService

    /// The shared Spotify now-playing/transport bridge, feeding ``nowPlayingCard``. Shared for the same
    /// "one machine-wide fact" reason as ``herdModel``, ``caffeinateService`` and ``remindersService``.
    @ObservedObject var spotifyService: SpotifyNowPlayingService

    /// The shared system-wide (Music, browsers, Podcasts, and Spotify too) now-playing bridge, feeding
    /// ``nowPlayingCard`` whenever ``spotifyService`` is not itself the currently playing source — see
    /// ``activeNowPlaying`` for the priority between the two. Shared for the same "one machine-wide fact"
    /// reason as ``spotifyService``.
    @ObservedObject var systemNowPlayingService: SystemNowPlayingService

    /// The Mac's internal-battery state, feeding ``batteryIndicator`` in the utility band. Shared for the
    /// same "one machine-wide fact" reason as the other services.
    @ObservedObject var batteryService: BatteryService

    /// What the collapsed notch's wings show. Shared across displays; see `LiveActivityModel`.
    @ObservedObject var liveActivity: LiveActivityModel

    /// The shared file shelf, feeding ``shelfCard``. One instance for every display, so all show the same
    /// files.
    @ObservedObject var shelfService: ShelfService

    /// Owns the keyboard-highlighted index into ``searchResults`` and the `isActive` flag
    /// `NotchPanel.sendEvent(_:)` consults before consuming an arrow keyDown — see ``SearchKeyNav``'s own
    /// documentation for why that lives in a reference type rather than a plain `@State` here, and for why
    /// a window-level `sendEvent(_:)` override, not a monitor owned by this view, is what actually moves
    /// the selection now. `@ObservedObject`, not `@StateObject`: `NotchWindowController` owns the one
    /// shared instance for the whole process (`NotchPanel.searchKeyNav` needs the same object this view
    /// reads from, so they can't each hold their own), and injects it here the same way it injects
    /// ``herdModel`` and the other shared services.
    @ObservedObject var searchKeyNav: SearchKeyNav

    /// Invoked when the user presses Escape while this content has focus, or by ``settingsButton`` after
    /// opening settings. `NotchWindowController` wires this to `NotchEvent.escape(_:)` for the owning
    /// display, reusing `HerdLedgerView`'s `.onExitCommand(perform:)` idiom rather than inventing a new
    /// dismissal path.
    let onEscape: () -> Void

    /// Invoked when the user clicks ``settingsButton``. `NotchWindowController` forwards this from
    /// `NotchAppDelegate`, the one place that actually owns the shared settings window (see that
    /// controller's own `onOpenSettings` documentation for why the wiring runs through it rather than this
    /// AppKit-free view depending on `HerdHost` directly).
    let onOpenSettings: () -> Void

    /// A drag began or ended over this panel (a file hovering the open panel, or a tile being dragged out).
    /// `NotchWindowController` maps them to `NotchEvent.dragBegan`/`dragEnded`, which hold the `.drag` lock
    /// so the panel cannot collapse under the drag.
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void

    /// Invoked when the user picks an agent, from either ``agentsHeroCard``'s browse-mode shortlist or its
    /// search-mode results. `NotchWindowController` forwards this to `HerdFocusService.focus(agent:in:)`
    /// and then collapses this display's panel — see that controller's own `onSelectAgent` documentation —
    /// so this view only ever has to report *which* agent was picked, never decide what "picking one" does.
    let onSelectAgent: (HerdSession, HerdAgent) -> Void

    /// Whether the collapsed pill is forced visible on a notchless display. Observed here (rather than
    /// read once) so the debug status-item menu's "Show Pill" toggle repaints every open panel live.
    @ObservedObject private var preferences = NotchPreferences.shared

    /// The clock shown in ``utilityBand``, refreshed once a second by ``clockTimer`` — and only while this
    /// view's expanded body is actually on screen, per the design spec's "timer fires only while panel
    /// open" rule.
    @State private var now: Date = Date()

    /// The one timer this file owns, ticking ``now`` once a second. Started in ``expandedBody``'s
    /// `.onAppear` and invalidated in its `.onDisappear`, so it exists for exactly as long as the expanded
    /// surface (`.expanding`/`.expanded`/`.collapsing`) is mounted and never while the panel is merely a
    /// collapsed pill or wings. A plain `Timer` on the main run loop's `.common` mode, not a `TimelineView` — the
    /// design spec explicitly forbids `TimelineView` here — and not a `DispatchSourceTimer` either, since
    /// that idiom is reserved elsewhere in this target for the Phase 1 glitch-avoidance machinery this view
    /// is not part of and must not entangle itself with.
    @State private var clockTimer: Timer?

    /// Whether the agents hero card is showing its search field and filtered results instead of the
    /// browse-mode list. Entered by ``enterSearchMode()``, which the `fn fn` global hotkey
    /// triggers via ``viewModel``'s `searchActivationToken` and the card's own footer/hover affordances
    /// trigger directly; left by completing a selection, by Escape on an empty query, or by the panel
    /// itself collapsing (reset in ``expandedBody``'s `.onDisappear`).
    @State private var isSearchMode = false
    /// Pending hover-dwell page switch; cancelled when the pointer leaves the button or the panel collapses.
    @State private var pageHoverWork: DispatchWorkItem?

    /// What the user has typed into the agents hero card's search field. Local, not published anywhere:
    /// like the reminders quick-add draft, an in-progress query is this one panel's own transient UI state.
    @State private var searchQuery = ""

    /// Whether the agents search field holds keyboard focus. Set on ``enterSearchMode()``, since a search
    /// mode entered specifically so the user can type has to actually be ready to receive it.
    @FocusState private var isSearchFieldFocused: Bool

    /// Card-level hover state, one per card, backing each card's hairline-brightens-on-hover per the design
    /// spec's "Card hover" rule. Three separate `@State`s rather than one shared value, since the three
    /// cards can be hovered independently.
    @State private var isHeroCardHovering = false
    @State private var isNowPlayingCardHovering = false
    /// The scrubber's in-flight drag position in seconds, `nil` when not dragging; drives the elapsed label.
    @State private var scrubLabelSeconds: Double?
    @State private var isRemindersCardHovering = false

    /// Per-card reveal progress (`0` hidden, `1` settled), driving the design spec's fade+rise stagger.
    /// Set by ``startRevealAnimation()`` on ``expandedBody``'s `.onAppear`. ``heroReveal`` also drives
    /// ``utilityBand``'s own fade, per the spec's "band fades with hero — one group" rule.
    @State private var heroReveal: Double = 0
    @State private var nowPlayingReveal: Double = 0
    @State private var remindersReveal: Double = 0

    /// The reminders quick-add row's in-progress draft and whether its inline field is showing. See
    /// ``reminderQuickAdd``.
    @State private var newReminderTitle: String = ""
    @State private var isAddingReminder = false
    @FocusState private var isReminderFieldFocused: Bool

    /// Reminder ids mid-complete: the circle has already filled and the title has already struck through,
    /// but ``RemindersService/complete(_:)`` (which is what actually removes the row) has not been called
    /// yet — see ``completeReminder(_:)`` for the 400ms choreography this backs.
    @State private var completingReminderIDs: Set<String> = []

    /// Miscellaneous small-control hover flags, each backing a single button's hover-only visual change.
    @State private var isOpenSpotifyHovering = false
    @State private var isQuickAddHovering = false
    @State private var isSettingsLinkHovering = false

    /// Whether a file drag is currently over the open panel; highlights ``shelfCard``'s border.
    @State private var isShelfDropTargeted = false

    /// Resolved once per redraw from the environment, matching `HerdPalette.resolving(_:)`'s existing
    /// convention elsewhere in the app.
    @Environment(\.colorScheme) private var colorScheme

    private var palette: HerdPalette { HerdPalette.resolving(colorScheme) }

    // MARK: - Layout constants (bento design spec's own frames)

    /// Card metrics that do not depend on the panel size; the frames themselves come from ``layout``.
    private enum Bento {
        /// Every card's corner radius.
        static let cardRadius: CGFloat = 16
        /// Inner padding for the now-playing and reminders cards.
        static let cardPadding: CGFloat = 14
        /// Inner padding for the agents hero card specifically — one step more than ``cardPadding``.
        static let heroPadding: CGFloat = 16
    }

    /// The card frames for this display's current panel size.
    private var layout: BentoLayout { BentoLayout(panel: viewModel.expandedSize) }

    private var systemLayout: SystemLayout { SystemLayout(panel: viewModel.expandedSize) }

    var body: some View {
        Group {
            switch viewModel.presentation {
            case .expanding, .expanded, .collapsing:
                expandedBody
            case .collapsed, .suspended:
                collapsedBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onExitCommand(perform: onEscape)
    }

    // MARK: - Collapsed wings

    /// The collapsed pill's fill plus the live activity wings.
    ///
    /// On a real physical notch (``NotchKind/notched``) the base fill always draws, in black to merge with
    /// the display's own cutout, and the wings sit either side of it inside the widened mask. On a
    /// notchless display (``NotchKind/pill``) it draws nothing at all unless
    /// ``NotchPreferences/showCollapsedPill`` is on, and then the same content sits inside the pill
    /// without widening it. Hover and click are `NotchHoverView`'s job, independent of what draws here.
    private var collapsedBody: some View {
        ZStack(alignment: .top) {
            if viewModel.layoutKind == .pill, !preferences.showCollapsedPill {
                Color.clear
            } else {
                Rectangle().fill(viewModel.layoutKind == .notched ? Color.black : palette.surface)
                if preferences.showLiveActivity, viewModel.presentation == .collapsed {
                    CollapsedWingsView(
                        activity: liveActivity.activity,
                        isNotched: viewModel.layoutKind == .notched,
                        notchRect: viewModel.notchRect,
                        panelWidth: viewModel.expandedSize.width,
                        palette: palette
                    )
                }
            }
        }
    }

    // MARK: - Expanded surface: the bento

    /// The whole open panel: a near-black gradient ground, the utility band and its one hairline, the
    /// notch/pill dead zone painted over whatever would otherwise sit beneath it, and the cards at
    /// their exact ``Bento`` frames.
    ///
    /// Every element is placed with `.position(x:y:)` at the design spec's own absolute panel coordinates
    /// rather than inferred from nested `HStack`/`VStack` auto-layout, which is what lets this body match
    /// the spec's frame table directly instead of approximating it through spacer math.
    private var expandedBody: some View {
        ZStack(alignment: .topLeading) {
            groundGradient
            utilityBandLeft.position(x: layout.bandLeftWidget.midX, y: layout.bandLeftWidget.midY)
            utilityBandRight.position(x: layout.bandRightWidget.midX, y: layout.bandRightWidget.midY)
            deadZone
            Rectangle()
                .fill(palette.hairline)
                .frame(width: layout.band.width, height: 1)
                .position(x: layout.band.midX, y: layout.band.maxY)
                .opacity(heroReveal)
            // A plain content swap: no animation, same expanded frame, shelf on both pages.
            if viewModel.page == .system {
                SystemPageView(
                    layout: systemLayout, palette: palette, now: now, power: powerInfoService,
                    battery: batteryService, keepAwake: keepAwakeService, caffeinate: caffeinateService,
                    lid: lidSleepController
                )
                .opacity(heroReveal)
                nowPlayingCard
                remindersCard
            } else {
                agentsHeroCard
                UsagePageCard(frame: layout.usage, palette: palette, now: now, usage: usageService)
                    .opacity(heroReveal)
            }
            shelfCard
        }
        .frame(width: viewModel.expandedSize.width, height: viewModel.expandedSize.height, alignment: .topLeading)
        .clipped()
        // The only SwiftUI drop target. The collapsed pill's `NotchHoverView` is a separate NSView layered
        // above this one, so AppKit routes any given drop to exactly one of them.
        .onDrop(of: [.fileURL], isTargeted: shelfDropTargetBinding, perform: handleShelfDrop)
        .onAppear(perform: startRevealAnimation)
        .onAppear(perform: startClock)
        .onDisappear(perform: stopClock)
        .onDisappear {
            // The panel just collapsed (or was suspended): search mode is this one open session's own
            // transient state, not something that should still be active — key, focused, mid-query — the
            // next time this display opens. Clearing ``SearchKeyNav/isActive`` here (in addition to the
            // empty-Escape path in ``agentsSearchField``) covers every other way search mode can end,
            // including a completed selection collapsing the panel out from under it — and stops
            // `NotchPanel.sendEvent(_:)` from consuming Up/Down for a display that is no longer showing the
            // search field at all.
            pageHoverWork?.cancel()
            pageHoverWork = nil
            viewModel.page = .herd
            isSearchMode = false
            searchQuery = ""
            searchKeyNav.selection = 0
            searchKeyNav.isActive = false
        }
        .onChange(of: viewModel.searchActivationToken) { _, _ in enterSearchMode() }
    }

    /// The panel ground: `#000000` at the top fading to `#0B0B0D` at the bottom, painted as a plain SwiftUI
    /// background inside the existing panel — the design spec's own "ground is darker than surface, must
    /// recede" rule, satisfied entirely in SwiftUI with no change to the panel's own material or mask.
    private var groundGradient: some View {
        LinearGradient(
            colors: [Color.black, Color(red: 0x0B / 255, green: 0x0B / 255, blue: 0x0D / 255)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(width: viewModel.expandedSize.width, height: viewModel.expandedSize.height)
    }

    /// The notch/pill's own dead zone, painted flat black directly over whatever the ground/band would
    /// otherwise show there — "nothing interactive/textual there; painted black", per the design spec.
    ///
    /// Sized and positioned from ``NotchDisplayViewModel/notchRect``, which `NotchWindowController` derives
    /// from the real `NotchGeometry` cutout for a physical notch, or a fixed `200x36` guess for a
    /// synthesized pill — see that property's own documentation.
    private var deadZone: some View {
        Rectangle()
            .fill(Color.black)
            .frame(width: viewModel.notchRect.width, height: viewModel.notchRect.height)
            .position(x: viewModel.notchRect.midX, y: viewModel.notchRect.midY)
    }

    // MARK: - Utility band

    /// Left flank: clock and date, left-aligned starting at `x16`, vertically centered in the 44pt band.
    private var utilityBandLeft: some View {
        HStack(spacing: 8) {
            Text(clockText)
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(palette.textPrimary)
            Text(dateText)
                .font(.system(size: 12))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
                .fixedSize()
            pageSwitcher
            Spacer(minLength: 0)
        }
        .frame(width: 244, height: 36, alignment: .leading)
        .opacity(heroReveal)
    }

    /// `● Herd  ○ System`: switches the expanded content between the two pages on click or a hover dwell.
    /// Plain buttons, no animation.
    private var pageSwitcher: some View {
        HStack(spacing: 2) {
            pageButton("Herd", page: .herd)
            pageButton("System", page: .system)
        }
    }

    private func pageButton(_ title: String, page: NotchPage) -> some View {
        let selected = viewModel.page == page
        return Button(action: { viewModel.page = page }) {
            HStack(spacing: 4) {
                Image(systemName: selected ? "circle.fill" : "circle")
                    .font(.system(size: 6))
                Text(title).font(.system(size: 11, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? palette.textPrimary : palette.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering in
            pageHoverWork?.cancel()
            pageHoverWork = nil
            guard hovering, !selected, !isSearchMode else { return }
            let work = DispatchWorkItem { [viewModel] in viewModel.page = page }
            pageHoverWork = work
            let dwell = Double(NotchPreferences.shared.pageHoverDwellMs) / 1000
            DispatchQueue.main.asyncAfter(deadline: .now() + dwell, execute: work)
        }
        .help("Hover or click to show \(title)")
        .accessibilityLabel("\(title) page")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Right flank: caffeinate toggle and settings gear, right-aligned so the cluster's own trailing edge
    /// lands at `x684` (16pt short of the panel's own right edge, per the design spec's utility band frame).
    private var utilityBandRight: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if batteryService.hasBattery { batteryIndicator }
            caffeinateToggle
            settingsButton
        }
        .frame(width: 224, height: 36, alignment: .trailing)
        .opacity(heroReveal)
    }

    /// A ~28pt circular gauge that fills clockwise from 12 o'clock by charge percentage, shown only on Macs
    /// with an internal battery. Ring color follows ``BatteryTier`` (``NotchPreferences/batteryThresholds``)
    /// per the spec's status-color discipline (color only where it means something) — still tier-colored
    /// while charging, since a charging battery sitting at 8% is still worth flagging red. A small
    /// `bolt.fill` badge overlays the ring while charging.
    private var batteryIndicator: some View {
        let percent = batteryService.percent ?? 0
        let fraction = Double(percent) / 100
        let tier = BatteryAlert.tier(percent: percent, thresholds: NotchPreferences.shared.batteryThresholds)
        let tierColor = palette.color(for: tier)
        return ZStack {
            Circle()
                .stroke(palette.hairline, lineWidth: 3)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tierColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(percent)")
                .font(.system(size: 9, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(palette.textSecondary)
        }
        .frame(width: 27, height: 27)
        .overlay(alignment: .bottomTrailing) {
            if batteryService.isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(tierColor)
                    .padding(1)
                    .background(Circle().fill(palette.surface))
                    .offset(x: 1, y: 1)
            }
        }
        .help(batteryTooltip(percent: percent))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Battery \(percent) percent\(batteryService.isCharging ? ", charging" : "")")
    }

    /// One line for the battery ring's hover: "health 91% · 9.4 W · 3h 12m left", falling back to the plain
    /// charge when the detail readings are unavailable.
    private func batteryTooltip(percent: Int) -> String {
        let info = powerInfoService.snapshot
        var parts: [String] = []
        if let health = info.healthPercent { parts.append("health \(health)%") }
        if let watts = info.watts { parts.append(PowerFormat.wattsText(watts)) }
        if batteryService.isCharging {
            if info.timeToFullMinutes != nil { parts.append("\(PowerFormat.timeRemaining(minutes: info.timeToFullMinutes)) to full") }
        } else if info.timeToEmptyMinutes != nil {
            parts.append("\(PowerFormat.timeRemaining(minutes: info.timeToEmptyMinutes)) left")
        }
        let head = "Battery \(percent)%\(batteryService.isCharging ? ", charging" : "")"
        return parts.isEmpty ? head : parts.joined(separator: " · ")
    }

    /// Built once: a `DateFormatter` per render is costly. They keep the locale they were built with.
    private static let formatters = (
        clockText: templateFormatter("HH:mm"), dateText: templateFormatter("EEE d"),
        dueHour: templateFormatter("ha"), dueWeekday: templateFormatter("EEE"), dueDate: templateFormatter("MMM d")
    )

    private static func templateFormatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    /// `09:41`-style clock text, from ``now``.
    private var clockText: String {
        Self.formatters.clockText.string(from: now)
    }

    /// `Sat 30`-style date text (short, so the page switcher fits the 244pt left widget), from ``now``.
    private var dateText: String {
        Self.formatters.dateText.string(from: now)
    }

    /// The keep-awake control: click toggles, the menu arrow opens presets and the lid/agents options. The
    /// icon shows the active mode (cup, filled cup, or laptop while lid-closed mode is holding).
    private var caffeinateToggle: some View {
        let active = caffeinateService.isActive
        let symbol = keepAwakeService.lidActive ? "laptopcomputer" : (active ? "cup.and.saucer.fill" : "cup.and.saucer")
        return Menu {
            // Keyed off the live assertion: toggleManual turns off any hold, including a condition-only one.
            Button(active ? "Turn off" : "Turn on") { keepAwakeService.toggleManual() }
            Divider()
            Button("For 15 minutes") { keepAwakeService.setManual(on: true, minutes: 15) }
            Button("For 1 hour") { keepAwakeService.setManual(on: true, minutes: 60) }
            Button("For 2 hours") { keepAwakeService.setManual(on: true, minutes: 120) }
            Button("Until turned off") { keepAwakeService.setManual(on: true, minutes: nil) }
            Divider()
            if lidSleepController.isSetUp {
                Toggle("Lid closed", isOn: $preferences.keepAwakeLidMode)
            } else {
                Button("Lid closed (set up in Settings)") {}.disabled(true)
            }
            Toggle("While agents busy", isOn: $preferences.keepAwakeWhileAgentsBusy)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? palette.working : palette.textSecondary)
                .frame(width: 28, height: 28)
        } primaryAction: {
            keepAwakeService.toggleManual()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Keep awake: \(active ? "on" : "off") (⌃⇧C)")
        .accessibilityLabel(active ? "Keep awake: on" : "Keep awake: off")
        .accessibilityHint("Toggles keeping this Mac awake. The menu has timers and lid-closed mode.")
    }

    /// The settings gear: opens the shared settings window via ``onOpenSettings`` and closes this panel via
    /// ``onEscape``.
    private var settingsButton: some View {
        NotchIconButton(
            systemName: "gearshape",
            tint: palette.textSecondary,
            hoverFill: palette.hoverFill,
            action: {
                onOpenSettings()
                onEscape()
            }
        )
        .help("Settings…")
        .accessibilityLabel("Settings")
        .accessibilityHint("Opens Herd settings.")
    }

    /// Starts (or restarts) ``clockTimer``, ticking ``now`` once a second. See ``clockTimer``'s own
    /// documentation for why this is a plain `Timer`, not a `TimelineView` or a `DispatchSourceTimer`.
    private func startClock() {
        stopClock()
        now = Date()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in now = Date() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    /// Invalidates and forgets ``clockTimer``. Called on `expandedBody`'s `.onDisappear`, so the clock never
    /// ticks while the panel is collapsed.
    private func stopClock() {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    /// Fades+rises every card (and the band, alongside the hero card) in once, staggered 30ms apart,
    /// hero→now-playing→reminders, the instant ``expandedBody`` mounts. A single finite pass, never
    /// repeating or synced to the mask's own reveal progress — the design spec's codex-review resolution
    /// for this rejects both a `TimelineView` and any coupling to `NotchAnimator`'s own timing.
    ///
    /// Honours Reduce Motion by skipping straight to fully revealed, the same contract
    /// `NotchCommandExecutor.startExpand(display:generation:)` already applies to the mask's own reveal
    /// animation.
    private func startRevealAnimation() {
        heroReveal = 0
        nowPlayingReveal = 0
        remindersReveal = 0
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            heroReveal = 1
            nowPlayingReveal = 1
            remindersReveal = 1
            return
        }
        withAnimation(.easeOut(duration: 0.18)) { heroReveal = 1 }
        withAnimation(.easeOut(duration: 0.18).delay(0.03)) { nowPlayingReveal = 1 }
        withAnimation(.easeOut(duration: 0.18).delay(0.06)) { remindersReveal = 1 }
    }

    // MARK: - Card chrome

    /// Wraps `content` in one bento card: ``HerdPalette/cardFill``, a 1px hairline that brightens on hover
    /// (120ms in, instant out — no scale/translate/fill change, per the design spec), and a 1px top
    /// highlight for the "light from above" look. Placed at `frame`'s exact panel-absolute position.
    ///
    /// - Parameters:
    ///   - frame: The card's exact bento frame.
    ///   - isHovering: This card's own hover flag, so cards can each brighten independently.
    ///   - content: The card's own interior, already expected to apply its own padding.
    private func bentoCard<Content: View>(
        frame: CGRect,
        isHovering: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            .background(palette.cardFill)
            .overlay(cardTopHighlight)
            .overlay(
                RoundedRectangle(cornerRadius: Bento.cardRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(isHovering.wrappedValue ? 0.12 : 0.07), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Bento.cardRadius, style: .continuous))
            .onHover { hovering in
                if hovering {
                    withAnimation(.easeInOut(duration: 0.12)) { isHovering.wrappedValue = true }
                } else {
                    isHovering.wrappedValue = false
                }
            }
            .position(x: frame.midX, y: frame.midY)
    }

    /// A 1px white-6% line across a card's own top edge, clipped by the card's rounded corners once the
    /// caller applies its own `.clipShape` — the design spec's "light from above" elevation cue.
    private var cardTopHighlight: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Agents hero card

    private var agentsHeroCard: some View {
        bentoCard(frame: layout.agents, isHovering: $isHeroCardHovering) {
            VStack(alignment: .leading, spacing: 10) {
                agentsHeader
                Group {
                    if isSearchMode {
                        agentsSearchContent
                    } else if herdModel.topAgents.isEmpty {
                        agentsEmptyState
                    } else {
                        agentsBrowseList
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                agentsFooter
            }
            .padding(Bento.heroPadding)
        }
        .opacity(heroReveal)
        .offset(y: (1 - heroReveal) * 8)
    }

    /// `AGENTS` uppercase label, plus the nonzero status dot-counts (blocked leftmost), per the design
    /// spec's header row.
    private var agentsHeader: some View {
        HStack {
            Text("AGENTS")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(palette.textSecondary)
            Spacer(minLength: 8)
            agentsHeaderCounts
        }
        .frame(height: 18)
    }

    /// `●2 ●1 ●3`: a 6pt status-colour dot beside a neutral count, nonzero statuses only, blocked leftmost.
    private var agentsHeaderCounts: some View {
        let counts = herdModel.counts
        let entries: [(AgentStatus, Int)] = [
            (.blocked, counts.blocked),
            (.working, counts.working),
            (.done, counts.done),
            (.idle, counts.idle),
        ].filter { $0.1 > 0 }
        return HStack(spacing: 8) {
            ForEach(entries.indices, id: \.self) { index in
                HStack(spacing: 4) {
                    Circle()
                        .fill(dotColor(entries[index].0))
                        .frame(width: 6, height: 6)
                    Text("\(entries[index].1)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                }
            }
        }
        // A colour dot beside a bare number reads to VoiceOver as an unlabelled swatch plus a digit with
        // no unit — one combined stop naming each status in the same vocabulary the row itself uses
        // (``AgentStatus/phrase``) says what the count actually means.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entries.map { "\($0.1) \($0.0.phrase)" }.joined(separator: ", "))
    }

    /// The browse-mode list of every live agent, from ``NotchHerdModel/topAgents``, scrolling when taller
    /// than the card. Scroll momentum is locked panel-wide by `NotchPanel`, so a fling cannot collapse it.
    private var agentsBrowseList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(herdModel.topAgents) { entry in
                    NotchBreadcrumbRow(
                        palette: palette,
                        status: entry.effectiveStatus,
                        sessionName: entry.session.name,
                        workspaceLabel: entry.workspace.label ?? entry.workspace.workspaceId,
                        agentName: entry.agent.displayIdentifier,
                        agentKind: entry.agent.agent == entry.agent.displayIdentifier ? "" : entry.agent.agent,
                        trailingText: entry.relativeAge,
                        activity: entry.activity,
                        isSearchSelected: false,
                        onTap: { onSelectAgent(entry.session, entry.agent) }
                    )
                }
            }
        }
    }

    /// The empty state: nothing herdr reports as blocked, working, idle, or recently done.
    private var agentsEmptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 22))
                .foregroundStyle(palette.textTertiary)
            Text("The herd is quiet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.textSecondary)
            Text("No active agents · fn fn to search all")
                .font(.system(size: 11))
                .foregroundStyle(palette.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// `fn fn to search` in browse mode (clickable — enters search mode itself, the same as
    /// pressing `fn fn`); `type to search` in search mode, since the counts/footer hint is meaningless once
    /// the user is already typing.
    private var agentsFooter: some View {
        Group {
            if isSearchMode {
                Text("type to search")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textTertiary)
            } else {
                Button(action: enterSearchMode) {
                    agentsBrowseFooterLabel
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 16)
    }

    /// The browse-mode footer's own label: an `fn fn` chip and `to search`, as a 60%-opacity hint.
    private var agentsBrowseFooterLabel: some View {
        HStack(spacing: 4) {
            Text("fn fn")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(palette.textTertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
            Text("to search")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.textTertiary)
        }
        .opacity(0.6)
    }

    /// The search-mode field plus its filtered results — up to every agent in ``herdModel``'s snapshot, not
    /// not a capped list, ranked by `HerdPaneSearch`.
    private var agentsSearchContent: some View {
        VStack(spacing: 6) {
            agentsSearchField
            if searchResults.isEmpty {
                Text("No agent matches that.")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                agentsSearchResultList
            }
        }
        // Keeps ``SearchKeyNav/resultCount`` in step with the ranking so its own Down-arrow clamp never
        // selects past the end of a list that just got shorter mid-keystroke — ``SearchKeyNav`` has no way
        // to read a SwiftUI computed property itself, so this view has to push the count in.
        // `initial: true` covers the very first render of search mode, not just subsequent query edits.
        .onChange(of: searchResults.count, initial: true) { _, count in searchKeyNav.resultCount = count }
    }

    /// The query field: focused whenever ``enterSearchMode()`` runs, Return activates the highlighted
    /// result, Escape clears the draft first and only leaves search mode on a second, empty-field Escape —
    /// mirroring the reminders quick-add field's own two-step Escape exactly (see ``reminderQuickAdd``).
    ///
    /// Up/Down do not live here as `.onKeyPress` handlers — a focused single-line `TextField`'s AppKit
    /// field editor is the key responder, so it consumes arrow keys as caret motion before SwiftUI's own
    /// `.onKeyPress` ever sees them, on this view or any ancestor. `NotchPanel.sendEvent(_:)` owns the
    /// arrows instead, consulting ``searchKeyNav``'s ``SearchKeyNav/isActive`` flag (set `true` in
    /// ``enterSearchMode()``, `false` wherever search mode ends) — see that override's own documentation
    /// for why a window-level `sendEvent(_:)` override, not anything reachable from this view, is what
    /// actually has to intercept the keyDown.
    private var agentsSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(palette.textTertiary)
                // Decorative: the field's own accessibility label already says "search", so this glyph
                // would only be a second, unlabelled stop right beside it.
                .accessibilityHidden(true)
            TextField("Search agents", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(palette.textPrimary)
                .focused($isSearchFieldFocused)
                .onSubmit(activateSearchSelection)
                .onChange(of: searchQuery) { _, _ in searchKeyNav.selection = 0 }
                .accessibilityLabel("Search agents")
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .onExitCommand {
            if searchQuery.isEmpty {
                isSearchMode = false
                searchKeyNav.isActive = false
            } else {
                searchQuery = ""
            }
        }
    }

    /// The ranked results list, scrolling once there are more than fit, keeping the keyboard selection in
    /// view exactly as `HerdSearchView.resultList` does.
    private var agentsSearchResultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(searchResults.enumerated()), id: \.element.id) { index, result in
                        NotchBreadcrumbRow(
                            palette: palette,
                            status: result.pane.agent.agentStatus,
                            sessionName: result.pane.session.name,
                            workspaceLabel: result.pane.workspaceLabel,
                            agentName: result.pane.agent.displayIdentifier,
                            agentKind: result.pane.agent.agent == result.pane.agent.displayIdentifier
                                ? "" : result.pane.agent.agent,
                            trailingText: "",
                            activity: herdModel.activityByTranscriptID[
                                AgentActivityTracker.transcriptID(
                                    session: result.pane.session, agent: result.pane.agent) ?? ""],
                            isSearchSelected: index == searchKeyNav.selection,
                            onTap: { selectSearchResult(result) }
                        )
                        .id(result.id)
                    }
                }
            }
            .onChange(of: searchKeyNav.selection) { _, index in
                guard searchResults.indices.contains(index) else { return }
                proxy.scrollTo(searchResults[index].id, anchor: .center)
            }
        }
    }

    /// Every pane in ``herdModel``'s current snapshot, flattened for search. Recomputed per redraw, which
    /// `HerdPaneSearch`'s own documentation calls out as affordable at this scale.
    private var searchPanes: [HerdPane] {
        HerdPane.flatten(herdModel.snapshot)
    }

    /// The current ranking against ``searchQuery``. An empty query returns ``searchPanes`` itself, already
    /// in urgency order, so opening search with nothing typed shows the most urgent panes first.
    private var searchResults: [HerdPaneSearchResult] {
        HerdPaneSearch.rank(searchPanes, query: searchQuery)
    }

    /// Enters search mode, focuses the field, resets ``searchKeyNav``'s selection to the first result, and
    /// marks it active so `NotchPanel.sendEvent(_:)` starts intercepting Up/Down for this display. Called
    /// by ``viewModel``'s `searchActivationToken` changing (the `fn fn` hotkey path, which also makes this
    /// display's panel key — see `NotchWindowController.send(_:)`'s key-window contract — so the field
    /// below is actually first responder and ready to type into) and directly by ``agentsFooter``'s
    /// browse-mode button.
    private func enterSearchMode() {
        viewModel.page = .herd
        isSearchMode = true
        isSearchFieldFocused = true
        searchKeyNav.selection = 0
        searchKeyNav.isActive = true
    }

    /// Acts on the highlighted search result, if there is one. Backs the field's `onSubmit`.
    private func activateSearchSelection() {
        guard searchResults.indices.contains(searchKeyNav.selection) else { return }
        selectSearchResult(searchResults[searchKeyNav.selection])
    }

    /// Reports a chosen search result the same way ``agentsBrowseList`` reports a chosen shortlist row.
    private func selectSearchResult(_ result: HerdPaneSearchResult) {
        onSelectAgent(result.pane.session, result.pane.agent)
    }

    /// A status's accent, falling back to `textTertiary` for `unknown` — `HerdPalette.accent(for:)` returns
    /// `nil` there by design (see that method's own documentation), and this card always needs some colour
    /// to draw its dots in.
    private func dotColor(_ status: AgentStatus) -> Color {
        palette.accent(for: status) ?? palette.textTertiary
    }

    // MARK: - Shelf

    private var shelfCard: some View {
        bentoCard(frame: layout.shelf, isHovering: .constant(false)) {
            ShelfStripView(
                service: shelfService, palette: palette, onDragBegan: onDragBegan, onDragEnded: onDragEnded)
        }
        .overlay(
            RoundedRectangle(cornerRadius: Bento.cardRadius, style: .continuous)
                .strokeBorder(palette.working, lineWidth: 2)
                .frame(width: layout.shelf.width, height: layout.shelf.height)
                .position(x: layout.shelf.midX, y: layout.shelf.midY)
                .opacity(isShelfDropTargeted ? 1 : 0)
                .allowsHitTesting(false)
        )
        .opacity(remindersReveal)
    }

    /// `isTargeted` also drives the reducer's `.drag` lock, so a drag that starts over the open panel
    /// keeps it open.
    private var shelfDropTargetBinding: Binding<Bool> {
        Binding(
            get: { isShelfDropTargeted },
            set: { targeted in
                guard targeted != isShelfDropTargeted else { return }
                isShelfDropTargeted = targeted
                if targeted { onDragBegan() } else { onDragEnded() }
            })
    }

    private func handleShelfDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        // Release the lock now; a later `isTargeted = false` from SwiftUI is then a no-op in the binding.
        if isShelfDropTargeted {
            isShelfDropTargeted = false
            onDragEnded()
        }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in fileProviders {
                if let url = await Self.fileURL(from: provider) { urls.append(url) }
            }
            shelfService.add(urls)
        }
        return true
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    // MARK: - Now-playing card

    private var nowPlayingCard: some View {
        bentoCard(frame: systemLayout.nowPlaying, isHovering: $isNowPlayingCardHovering) {
            nowPlayingContent
                .padding(Bento.cardPadding)
        }
        .opacity(nowPlayingReveal)
        .offset(y: (1 - nowPlayingReveal) * 8)
    }

    /// The now-playing card's single active source, chosen from ``spotifyService`` and
    /// ``systemNowPlayingService`` by priority, which is what lets the card show "the currently playing
    /// app's media regardless of which app it is" (this spike's own goal) while still preferring Spotify's
    /// richer, AppleScript-backed surface — precise scrub-seek and a fetchable artwork URL rather than raw
    /// bytes — whenever Spotify itself is the one actually playing:
    ///
    /// 1. Spotify, if it is currently playing.
    /// 2. The system source (Music, a browser tab, Podcasts, or Spotify itself as MediaRemote sees it), if
    ///    *it* is currently playing.
    /// 3. Spotify, paused, if it has a track loaded at all.
    /// 4. The system source, paused, if it has an entry at all.
    /// 5. `nil` — nothing is playing anywhere; ``nowPlayingContent`` falls back to
    ///    ``spotifyService/playbackState``'s own `.runningNoTrack`/`.notRunning` idle rendering, which by
    ///    this priority list is the only shape left for that state to be in whenever this is `nil`.
    private var activeNowPlaying: ActiveNowPlaying? {
        switch NowPlayingPick.pick(spotify: spotifyService.playbackState, system: systemNowPlayingService.playbackState) {
        case .spotify(let now): return spotifyActiveNowPlaying(now)
        case .system(let now): return systemActiveNowPlaying(now)
        case nil: return nil
        }
    }

    /// Builds ``ActiveNowPlaying`` from Spotify's own state, wiring transport (including `seek(to:)`)
    /// straight to ``spotifyService`` — exactly the "something MediaRemote can't (or at least isn't
    /// confirmed to) do" capability `SystemNowPlayingService`'s own documentation names as the reason to
    /// keep this path alongside the new system source.
    private func spotifyActiveNowPlaying(_ now: SpotifyNowPlayingService.NowPlaying) -> ActiveNowPlaying {
        ActiveNowPlaying(
            title: now.title,
            artist: now.artist,
            isPlaying: now.isPlaying,
            positionSeconds: now.positionSeconds,
            durationSeconds: now.durationSeconds,
            artwork: .url(now.artworkURLString),
            onPlayPause: spotifyService.playPause,
            onNext: spotifyService.next,
            onPrevious: spotifyService.previous,
            onSeek: { seconds in spotifyService.seek(to: seconds) }
        )
    }

    /// Builds ``ActiveNowPlaying`` from the system-wide source; seeks through the mediaremote-adapter.
    private func systemActiveNowPlaying(_ now: SystemNowPlayingService.NowPlaying) -> ActiveNowPlaying {
        ActiveNowPlaying(
            title: now.title,
            artist: now.artist,
            isPlaying: now.isPlaying,
            positionSeconds: now.positionSeconds,
            durationSeconds: now.durationSeconds,
            artwork: now.artworkData.map(NowPlayingArtwork.data) ?? .unavailable,
            onPlayPause: systemNowPlayingService.playPause,
            onNext: systemNowPlayingService.next,
            onPrevious: systemNowPlayingService.previous,
            onSeek: { seconds in systemNowPlayingService.seek(to: seconds) }
        )
    }

    /// The card's states, per the design spec: a live track from ``activeNowPlaying`` (art, title, artist,
    /// transport, scrub — now sourced from *any* app, not just Spotify), Spotify running with nothing
    /// loaded, or Spotify not running at all.
    private var nowPlayingContent: some View {
        Group {
            if let now = activeNowPlaying {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        nowPlayingArt(now)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(now.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(palette.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .help(now.title)
                            Text(now.artist)
                                .font(.system(size: 11))
                                .foregroundStyle(palette.textSecondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            HStack(spacing: 4) {
                                transportButton("backward.fill", size: 12, label: "Previous track", action: now.onPrevious)
                                transportButton(
                                    now.isPlaying ? "pause.fill" : "play.fill", size: 16,
                                    label: now.isPlaying ? "Pause \(now.title)" : "Play \(now.title)",
                                    action: now.onPlayPause
                                )
                                transportButton("forward.fill", size: 12, label: "Next track", action: now.onNext)
                            }
                        }
                    }
                    .frame(height: 56)

                    NotchScrubBar(
                        positionSeconds: now.positionSeconds,
                        durationSeconds: now.durationSeconds,
                        onSeek: { seconds in now.onSeek?(seconds) },
                        formatTime: Self.formatDuration,
                        elapsedLabel: $scrubLabelSeconds
                    )
                    HStack {
                        Text(Self.formatDuration(scrubLabelSeconds ?? now.positionSeconds))
                        Spacer()
                        Text(Self.formatDuration(now.durationSeconds))
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(palette.textTertiary)
                }
            } else {
                // Reached only when NEITHER source has a track — see ``activeNowPlaying``'s priority list.
                // Now that this card is system-wide (any app via MediaRemote, not just Spotify), the idle
                // copy is generic "Nothing playing" rather than the old Spotify-specific "Spotify isn't
                // running / Open Spotify": pushing Spotify makes no sense when the user might simply have no
                // media playing anywhere, or be about to play something in a browser or Music.
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 20))
                        .foregroundStyle(palette.textTertiary)
                    Text("Nothing playing")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The 56x56 art tile: a hairline ring, and full opacity only while actually playing (0.7 while
    /// paused) — the one motion-free way this card marks "paused" beyond the transport glyph itself.
    /// Renders from a URL (Spotify's own source) or raw bytes (the system source), or a plain placeholder
    /// glyph when neither source supplied any — see ``NowPlayingArtwork``.
    ///
    /// - Parameter now: The current active-source snapshot.
    private func nowPlayingArt(_ now: ActiveNowPlaying) -> some View {
        Group {
            switch now.artwork {
            case .url(let urlString):
                AsyncImage(url: URL(string: urlString)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    nowPlayingArtPlaceholder
                }
            case .data(let data):
                if let nsImage = NSImage(data: data) {
                    Image(nsImage: nsImage).resizable().aspectRatio(contentMode: .fill)
                } else {
                    nowPlayingArtPlaceholder
                }
            case .unavailable:
                nowPlayingArtPlaceholder
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .opacity(now.isPlaying ? 1 : 0.7)
    }

    /// The plain "no artwork" glyph, shared by every ``nowPlayingArt(_:)`` branch that has nothing to draw.
    private var nowPlayingArtPlaceholder: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.white.opacity(0.05))
            .overlay(Image(systemName: "music.note").foregroundStyle(palette.textTertiary))
    }

    /// One 28x28pt transport control, drawn with no button chrome.
    ///
    /// - Parameters:
    ///   - systemName: The SF Symbol to draw.
    ///   - size: Point size (12pt for skip controls, 16pt for play/pause, per the design spec).
    ///   - label: What VoiceOver announces for this icon-only control — the play/pause button's own
    ///     caller names the current track in it, since that button is the one whose state (and target)
    ///     actually changes with what is playing.
    ///   - action: Forwarded straight to the matching `SpotifyNowPlayingService` transport method.
    private func transportButton(
        _ systemName: String, size: CGFloat, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(palette.textPrimary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// `mm:ss`, from a duration in seconds.
    private static func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Reminders card

    private var remindersCard: some View {
        bentoCard(frame: systemLayout.reminders, isHovering: $isRemindersCardHovering) {
            VStack(alignment: .leading, spacing: 8) {
                remindersHeader
                remindersBody
            }
            .padding(Bento.cardPadding)
        }
        .opacity(remindersReveal)
        .offset(y: (1 - remindersReveal) * 8)
    }

    /// `REMINDERS` uppercase label, plus a `+N` overflow count once more than 3 incomplete reminders exist.
    private var remindersHeader: some View {
        let overflow = max(0, remindersService.items.count - 3)
        return HStack {
            Text("REMINDERS")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(palette.textSecondary)
            Spacer(minLength: 8)
            if remindersService.authorizationState == .authorized, overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textTertiary)
            }
        }
        .frame(height: 16)
    }

    /// The item area: one of the three access states, or (once authorized) every incomplete reminder in a
    /// scrollable list plus the permanent quick-add row — the header and quick-add always stay put, only
    /// the scrolling list between them changes shape or count.
    private var remindersBody: some View {
        Group {
            switch remindersService.authorizationState {
            case .notDetermined:
                reminderAuthPrompt(
                    message: "Herd needs access to Reminders",
                    actionTitle: "Grant Access",
                    action: remindersService.requestAccess
                )
            case .denied:
                reminderDeniedPrompt
            case .authorized:
                VStack(alignment: .leading, spacing: 0) {
                    if remindersService.items.isEmpty {
                        reminderEmptyState
                    } else {
                        // A `ScrollView` rather than the fixed `.prefix(3)` list this used to be: the card
                        // itself keeps its fixed bento frame, but the reminders it holds no longer cap out
                        // at 3 — this is the only part of the card's content region that scrolls, so the
                        // header above and ``reminderQuickAdd`` below both stay pinned regardless of how
                        // many rows are in view.
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(remindersService.items) { item in
                                    reminderRow(item)
                                        // Explicit, stable identity per row (on top of `ForEach`'s own
                                        // `Identifiable`-driven diffing) so a row's in-flight completion
                                        // animation and its `Button` action stay bound to the same
                                        // `ReminderItem.id` through a `refresh()`-driven reflow, rather than
                                        // SwiftUI reusing a view slot across two different reminders mid-list
                                        // change.
                                        .id(item.id)
                                }
                            }
                        }
                        .frame(maxHeight: .infinity)
                        .animation(.easeOut(duration: 0.18), value: remindersService.items)
                    }
                    reminderQuickAdd
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The `notDetermined`/`denied` access states share this one-sentence-plus-capsule shape; `denied`'s own
    /// underline-on-hover link is ``reminderDeniedPrompt`` instead, since it is not a capsule button.
    ///
    /// - Parameters:
    ///   - message: The one-sentence explanation.
    ///   - actionTitle: The capsule button's label.
    ///   - action: Invoked on tap.
    private func reminderAuthPrompt(message: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: action) {
                Text(actionTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The `denied`/`restricted` state: a sentence plus an underline-on-hover "Open Settings…" link, rather
    /// than a capsule button — the design spec draws this one differently from `notDetermined`'s "Grant
    /// Access" because there is nothing this app can do to fix it itself; the user has to leave to do that.
    private var reminderDeniedPrompt: some View {
        VStack(spacing: 6) {
            Text("Reminders access is off")
                .font(.system(size: 12))
                .foregroundStyle(palette.textSecondary)
            Button(action: openReminderPrivacySettings) {
                Text("Open Settings…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSettingsLinkHovering ? palette.textSecondary : palette.textTertiary)
                    .underline(isSettingsLinkHovering)
            }
            .buttonStyle(.plain)
            .onHover { isSettingsLinkHovering = $0 }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Opens System Settings' Reminders privacy pane, backing the `denied` state's "Open Settings…" link.
    private func openReminderPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// The authorized-and-empty state: everything is done.
    private var reminderEmptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 18))
                .foregroundStyle(palette.done.opacity(0.8))
            Text("All clear")
                .font(.system(size: 12))
                .foregroundStyle(palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One reminder row: a completion circle, the title (struck through mid-complete), and a due-date chip
    /// (future: `textTertiary`; overdue: `blocked` red).
    ///
    /// - Parameter item: The reminder to draw.
    private func reminderRow(_ item: RemindersService.ReminderItem) -> some View {
        let isCompleting = completingReminderIDs.contains(item.id)
        return HStack(spacing: 10) {
            Button(action: { completeReminder(item) }) {
                ZStack {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 1.5)
                        .opacity(isCompleting ? 0 : 1)
                    Circle()
                        .fill(palette.done)
                        .opacity(isCompleting ? 1 : 0)
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.white)
                        .opacity(isCompleting ? 1 : 0)
                }
                .frame(width: 14, height: 14)
                // The visual circle stays 14x14, but the tappable region is padded out to 22x22: a
                // too-small hit target was one of the candidate causes for "ticking doesn't always
                // complete it", and `.contentShape` extends what counts as "inside the button" without
                // changing how it looks.
                .padding(4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isCompleting)
            // The circle/checkmark ZStack has no text of its own; without this VoiceOver would announce
            // it as an unlabelled button.
            .accessibilityLabel("Complete")
            .accessibilityHint("Marks \"\(item.title)\" as done.")

            Group {
                Text(item.title)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textPrimary)
                    .strikethrough(isCompleting, color: palette.textPrimary.opacity(0.5))
                    .opacity(isCompleting ? 0.5 : 1)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                if let dueDate = item.dueDate {
                    Text(Self.dueChipText(dueDate, now: now))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(dueDate < now ? palette.blocked : palette.textTertiary)
                }
            }
            // One stop for "title, due" rather than two separately-focused texts (the completion button,
            // just above, stays its own separate stop with its own action).
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                item.dueDate.map { "\(item.title), due \(Self.dueChipText($0, now: now))" } ?? item.title
            )
        }
        .frame(height: 26)
    }

    /// Fills the circle green with a check and strikes the title through immediately (the design spec's
    /// "click circle → fills done + white check + title strikethrough 50%" step), then waits 400ms before
    /// actually calling `RemindersService.complete(_:)` — which is what removes the row, letting
    /// ``remindersBody``'s own `.animation(value:)` fade+reflow the list once, per the spec's "then 400ms
    /// delay, row fades 180ms, reflow (finite once)" choreography.
    ///
    /// - Parameter item: The reminder being completed.
    private func completeReminder(_ item: RemindersService.ReminderItem) {
        guard !completingReminderIDs.contains(item.id) else { return }
        completingReminderIDs.insert(item.id)
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            remindersService.complete(item)
            completingReminderIDs.remove(item.id)
        }
    }

    /// A due-date chip's text: `2pm` today, `Mon` within the next week, `Sep 4` otherwise — matching the
    /// design spec's own three examples.
    ///
    /// - Parameters:
    ///   - date: The reminder's due date.
    ///   - now: The instant to measure "today"/"this week" against.
    private static func dueChipText(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return Self.formatters.dueHour.string(from: date)
        }
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
        ).day ?? 0
        if days > 0, days < 7 {
            return Self.formatters.dueWeekday.string(from: date)
        }
        return Self.formatters.dueDate.string(from: date)
    }

    /// The permanent last row: `＋ Add reminder` until clicked, then an inline borderless field with its own
    /// two-step Escape (clear the draft first, cancel back to the button on a second, empty-field Escape).
    private var reminderQuickAdd: some View {
        Group {
            if isAddingReminder {
                TextField("New reminder", text: $newReminderTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textPrimary)
                    .tint(palette.done)
                    .focused($isReminderFieldFocused)
                    .onSubmit(commitNewReminder)
                    .onExitCommand {
                        if newReminderTitle.isEmpty {
                            cancelNewReminder()
                        } else {
                            newReminderTitle = ""
                        }
                    }
            } else {
                Button(action: startAddingReminder) {
                    Text("＋ Add reminder")
                        .font(.system(size: 12))
                        .foregroundStyle(isQuickAddHovering ? palette.textSecondary : palette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .background(
                    isQuickAddHovering ? palette.hoverFill : .clear, in: RoundedRectangle(cornerRadius: 6)
                )
                .onHover { isQuickAddHovering = $0 }
            }
        }
        .frame(height: 18)
    }

    /// Swaps the quick-add button for its inline field and focuses it.
    private func startAddingReminder() {
        isAddingReminder = true
        isReminderFieldFocused = true
    }

    /// Commits the draft via `RemindersService.addReminder(title:)` and swaps back to the button.
    private func commitNewReminder() {
        remindersService.addReminder(title: newReminderTitle)
        newReminderTitle = ""
        isAddingReminder = false
    }

    /// Discards the draft and swaps back to the button, with no reminder created.
    private func cancelNewReminder() {
        newReminderTitle = ""
        isAddingReminder = false
    }
}

// MARK: - Small reusable views

/// A 28x28 icon button with a hoverFill circle behind it on hover — ``NotchContentView``'s caffeinate
/// toggle and settings gear share this exact shape.
private struct NotchIconButton: View {
    /// The SF Symbol to draw, at 13pt per the design spec's utility band metrics.
    let systemName: String
    /// The glyph's own colour (already state-dependent where the caller needs that, e.g. caffeinate on/off).
    let tint: Color
    /// The circle painted behind the glyph on hover.
    let hoverFill: Color
    /// Invoked on click.
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(isHovering ? hoverFill : .clear))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// One agent row shared by ``NotchContentView``'s browse list and its search results, so the two modes
/// render identically.
///
/// Line 1: status dot, agent name (takes the remaining width), context ring, then the trailing slot (age,
/// or a `chevron.right` on hover; search rows pass `""`). Line 2 is always present so every row has the
/// same height: see ``detailLine``. The workspace is not drawn, but VoiceOver still reads it.
private struct NotchBreadcrumbRow: View {
    static let height: CGFloat = 40

    let palette: HerdPalette
    let status: AgentStatus
    let sessionName: String
    let workspaceLabel: String
    let agentName: String
    /// The agent's kind (`claude`, `codex`, …), or `""` when it equals the agent name.
    let agentKind: String
    /// Browse mode's relative age (`"2m"`, `"1h"`); `""` for a search-mode row, which has none.
    let trailingText: String
    /// Transcript-derived activity; `nil` (remote, non-claude, or not yet read) leaves line 2 without it.
    var activity: AgentActivity? = nil
    /// Whether this is the keyboard's current row, in search mode. Always `false` in browse mode, which has
    /// no keyboard selection of its own.
    let isSearchSelected: Bool
    /// Invoked on click.
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            mainLine
            // Reserved even when empty so line 1 does not jump as activity comes and goes.
            Text(detailLine ?? " ")
                .font(.system(size: 10))
                .foregroundStyle(palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                // Aligns under the agent name: status dot (9) plus its 12pt trailing padding.
                .padding(.leading, 21)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background(
            isSearchSelected ? palette.hoverFill.opacity(1) : (isHovering ? palette.hoverFill : .clear),
            in: RoundedRectangle(cornerRadius: 8)
        )
        // The keyboard-selected search row gets a clear coloured ring (in its own status hue) on top of the
        // fill, so arrow-key navigation is obviously distinct from a plain mouse hover — a subtle fill alone
        // read as "not highlighted" on device.
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isSearchSelected ? (palette.accent(for: status) ?? palette.textSecondary) : .clear,
                    lineWidth: 1.5
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering in
            if hovering {
                withAnimation(.easeInOut(duration: 0.12)) { isHovering = true }
            } else {
                isHovering = false
            }
        }
        // One combined VoiceOver stop per row, in the same order (agent, state, kind, workspace, session)
        // as `HerdLedgerRow.accessibilityLabel`, so an agent never has two differently-shaped announcements.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Focuses this agent's pane and closes the notch.")
    }

    /// Line 1: dot, agent name, context ring and the trailing slot.
    private var mainLine: some View {
        HStack(spacing: 0) {
            ZStack {
                Circle().fill(palette.accent(for: status) ?? palette.textTertiary)
                Circle().fill(Color.white.opacity(0.15)).frame(width: 2, height: 2).offset(x: -1.5, y: -1.5)
            }
            .frame(width: 9, height: 9)
            .padding(.trailing, 12)

            Text(agentName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Spacer(minLength: 4)

            if let fraction = activity?.contextFraction {
                contextRing(fraction)
                    .padding(.trailing, 6)
                    .help(activity?.contextTokens.map {
                        "\($0.formatted(.number.notation(.compactName))) / \((activity?.contextLimit ?? 0).formatted(.number.notation(.compactName))) context"
                    } ?? "")
            }

            if isHovering {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.textTertiary)
            } else if !trailingText.isEmpty {
                Text(trailingText)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textTertiary)
            }
        }
    }

    /// Line 2: session, kind and activity, via `agentRowDetail`; `nil` when there is nothing to say.
    private var detailLine: String? {
        agentRowDetail(sessionName: sessionName, kind: agentKind, activityText: activityLine)
    }

    /// The current tool (or `thinking…` while working with nothing pending), then the running-subagent
    /// badge. `nil` when there is nothing to say.
    private var activityLine: String? {
        guard let activity else { return nil }
        var parts: [String] = []
        if status == .working || status == .blocked {
            if let tool = activity.currentTool {
                parts.append(tool.display)
            } else if status == .working {
                parts.append("thinking\u{2026}")
            }
        }
        if activity.runningSubagents > 0 {
            parts.append("+\(activity.runningSubagents) subagent\(activity.runningSubagents == 1 ? "" : "s")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// Green below 60%, orange to 85%, red above.
    private func contextRing(_ fraction: Double) -> some View {
        let color = fraction > 0.85 ? palette.blocked : (fraction >= 0.60 ? palette.working : palette.done)
        return ZStack {
            Circle().stroke(palette.hairline, lineWidth: 2)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 12, height: 12)
    }

    /// What VoiceOver reads for this row: unlike the visual row, it keeps the workspace and the kind.
    private var accessibilityLabel: String {
        var parts = ["Agent \(agentName)"]
        if !agentKind.isEmpty { parts.append(agentKind) }
        parts.append("status \(status.phrase)")
        parts.append("workspace \(workspaceLabel)")
        if !sessionName.isEmpty { parts.append("session \(sessionName)") }
        if let line = activityLine { parts.append(line) }
        if let fraction = activity?.contextFraction { parts.append("context \(Int(fraction * 100)) percent full") }
        return parts.joined(separator: ", ")
    }
}

/// Where a now-playing card's (or the collapsed wings') artwork comes from: Spotify's own AppleScript
/// bridge hands back a URL to fetch (`AsyncImage`'s own job); `SystemNowPlayingService` hands back raw bytes
/// it already has from `MediaRemote`; either source may have supplied neither at all.
private enum NowPlayingArtwork {
    case url(String)
    case data(Data)
    case unavailable
}

/// The now-playing card's (and the collapsed wings') single rendered source, already resolved from whichever
/// of ``NotchContentView/spotifyService``/``NotchContentView/systemNowPlayingService`` is currently active —
/// see ``NotchContentView/activeNowPlaying`` for the priority between the two. A plain value type so the
/// card's own rendering code (``NotchContentView/nowPlayingContent``, ``NotchContentView/nowPlayingArt(_:)``)
/// never has to branch on *which* service produced it.
private struct ActiveNowPlaying {
    let title: String
    let artist: String
    let isPlaying: Bool
    let positionSeconds: Double
    let durationSeconds: Double
    let artwork: NowPlayingArtwork
    /// Forwards straight to the owning service's own transport method.
    let onPlayPause: () -> Void
    let onNext: () -> Void
    let onPrevious: () -> Void
    /// Seeks the source that produced this track, to an absolute position in seconds.
    let onSeek: ((Double) -> Void)?
}

/// A borderless scrub bar: a 3pt track, a 3pt fill, and a 9pt knob shown only while hovering or dragging.
/// Dragging shows the position locally and commits one seek on release. Disabled when `durationSeconds`
/// is not positive. Draws exactly what it is given: no animation, per the design spec.
private struct NotchScrubBar: View {
    let positionSeconds: Double
    let durationSeconds: Double
    /// Called once per gesture, on release, with an absolute position in seconds.
    let onSeek: (Double) -> Void
    let formatTime: (Double) -> String
    /// Mirrors the in-flight drag position (seconds) for the elapsed label, `nil` when idle.
    @Binding var elapsedLabel: Double?

    @State private var isHovering = false
    @State private var dragRatio: Double?

    private var isSeekable: Bool { durationSeconds > 0 }
    private var shownSeconds: Double { dragRatio.map { $0 * durationSeconds } ?? positionSeconds }

    var body: some View {
        GeometryReader { geometry in
            let ratio = isSeekable ? min(max(shownSeconds / durationSeconds, 0), 1) : 0
            let knobX = geometry.size.width * ratio
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12)).frame(height: 3)
                Capsule().fill(Color.white.opacity(0.45)).frame(width: knobX, height: 3)
                if isSeekable && (isHovering || dragRatio != nil) {
                    Circle().fill(Color.white).frame(width: 9, height: 9).offset(x: knobX - 4.5)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isSeekable, geometry.size.width > 0 else { return }
                        let r = min(max(value.location.x / geometry.size.width, 0), 1)
                        dragRatio = r
                        elapsedLabel = r * durationSeconds
                    }
                    .onEnded { _ in commit() },
                including: isSeekable ? .all : .none
            )
        }
        .frame(height: 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(formatTime(shownSeconds)) of \(formatTime(durationSeconds))")
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityAdjustableAction { direction in
            guard isSeekable else { return }
            let step: Double = direction == .increment ? 10 : -10
            onSeek(min(max(positionSeconds + step, 0), durationSeconds))
        }
    }

    private func commit() {
        guard let r = dragRatio else { return }
        dragRatio = nil
        elapsedLabel = nil
        onSeek(r * durationSeconds)
    }
}

/// The live activity beside the collapsed notch. On a notched display the left wing ends at
/// `notchRect.minX` and the right wing starts at `notchRect.maxX`; the widened mask clips whatever falls
/// outside the current wings. On a pill display the same two halves sit inside the pill.
private struct CollapsedWingsView: View {
    let activity: CollapsedActivity
    let isNotched: Bool
    /// The cutout in this view's top-left-origin space.
    let notchRect: CGRect
    let panelWidth: CGFloat
    let palette: HerdPalette

    /// Wing width per side when only a glyph and a count show; the announce wing is wider and truncates.
    private static let compactWing: CGFloat = 30
    private static let announceWing: CGFloat = 150
    private static let outerInset: CGFloat = 6

    /// The notch fill is black in every color scheme, so wings there use fixed light foregrounds.
    private var primary: Color { isNotched ? .white : palette.textPrimary }

    private var announce: String? {
        if case .playing(_, let text?) = activity, !text.isEmpty { return text }
        return nil
    }

    var body: some View {
        if activity != .none {
            if isNotched {
                let wing = announce == nil ? Self.compactWing : Self.announceWing
                // Content is anchored to the cutout edges, so a wing width change only moves the outer
                // edge and the content never jumps while the mask is still animating.
                HStack(spacing: 0) {
                    leading.padding(.leading, Self.outerInset).frame(width: wing, alignment: .trailing)
                    Color.clear.frame(width: notchRect.width)
                    trailing.padding(.trailing, Self.outerInset).frame(width: wing, alignment: .leading)
                }
                .animation(.easeInOut(duration: 0.22), value: wing)
                .frame(height: notchRect.height)
                .offset(x: notchRect.midX - panelWidth / 2)
            } else {
                HStack(spacing: 8) {
                    leading.frame(maxWidth: .infinity, alignment: .leading)
                    trailing
                }
                .padding(.horizontal, 10)
                .frame(width: NotchGeometry.defaultPillWidth, height: NotchGeometry.fallbackMenuBarHeight)
            }
        }
    }

    @ViewBuilder
    private var leading: some View {
        switch activity {
        case .none:
            EmptyView()
        case .blocked:
            Circle().fill(palette.blocked).frame(width: 7, height: 7)
        case .playing(let bundleID, _):
            HStack(spacing: 6) {
                sourceIcon(bundleID)
                if let announce {
                    Text(announce)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        case .agents:
            Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold)).foregroundStyle(isNotched ? Color.white : palette.working)
        case .battery(_, let charging):
            Image(systemName: charging ? "battery.100.bolt" : "battery.100")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(charging ? palette.done : primary)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch activity {
        case .none:
            EmptyView()
        case .blocked(let count), .agents(let count):
            countText("\(count)")
        case .playing:
            EqualizerBars()
        case .battery(let percent, _):
            countText("\(percent)%")
        }
    }

    private func countText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(primary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    @ViewBuilder
    private func sourceIcon(_ bundleID: String?) -> some View {
        if let bundleID, let icon = AppIconCache.icon(for: bundleID) {
            Image(nsImage: icon).resizable().frame(width: 18, height: 18)
        } else {
            Image(systemName: "music.note").font(.system(size: 12, weight: .semibold)).foregroundStyle(primary)
        }
    }
}

/// Four bars bouncing at different rates. Exists only while the activity is `.playing` and the notch is
/// collapsed, so the repeat animation never runs while the panel is open or nothing plays.
private struct EqualizerBars: View {
    @State private var raised = false

    private static let lows: [CGFloat] = [3, 5, 4, 3]
    private static let highs: [CGFloat] = [11, 8, 12, 9]
    private static let periods: [Double] = [0.45, 0.6, 0.5, 0.7]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 2, height: raised ? Self.highs[index] : Self.lows[index])
                    .animation(.easeInOut(duration: Self.periods[index]).repeatForever(autoreverses: true), value: raised)
            }
        }
        .frame(height: 14)
        .onAppear { raised = true }
        .accessibilityHidden(true)
    }
}
