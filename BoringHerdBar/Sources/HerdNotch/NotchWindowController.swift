import AppKit
import Combine
import Foundation
import HerdHost
import HerdKit
import HerdPanelUI
import NotchCore
import NotchGeometry
import SwiftUI
import UsageKit

/// The observable slice of one display's `NotchPanelState` that the SwiftUI content actually renders.
///
/// `NotchPanelState` itself is not observed directly: it is a plain value type living inside
/// `NotchInteractionReducer.panels`, with no publishing of its own, and `NotchInteractionReducer` has no
/// public initializer for it either (only `NotchWindowController` is meant to hold the reducer, never the
/// view layer). This type is the seam — `NotchWindowController` copies out just `presentation` and
/// `pendingRoute` after every `reduce(_:)` call and republishes them, so the SwiftUI content can read
/// "what to render" without ever touching the reducer or needing an event to arrive; per
/// `NotchInteractionReducer`'s "commands cover lifecycle... never content" contract, content is state to be
/// read, not an effect to be told about.
///
/// Defaults to collapsed/home, matching `NotchPanelState`'s own `.initial` default for a display no event
/// has named yet.
/// Which page the expanded panel shows. Pure view state: never reaches the reducer, and resets to `.herd` on collapse.
enum NotchPage: Equatable {
    case herd, system
}

@MainActor
final class NotchDisplayViewModel: ObservableObject {
    /// The page the expanded content renders; a plain content swap inside the same expanded frame.
    @Published var page: NotchPage = .herd

    /// The open/close lifecycle state, mirrored from `NotchPanelState.presentation`.
    @Published var presentation: NotchPresentation = .collapsed

    /// The route to render once (or while) expanded, mirrored from `NotchPanelState.pendingRoute`.
    @Published var pendingRoute: NotchRoute = .home

    /// Which silhouette this display's collapsed pill currently is, mirrored from the layout
    /// `NotchWindowController` computes on every reconcile pass (see `NotchGeometry.layout(for:expandedSize:)`).
    /// `NotchContentView` reads this, not `NotchPanelState`, because the notch/pill classification is
    /// geometry, not interaction state, and lives outside the reducer entirely.
    @Published var layoutKind: NotchKind = .pill

    /// The physical notch/pill's own rect, in this panel's SwiftUI content view's coordinate space
    /// (top-left origin, growing down — the opposite of the `CGRect`s `NotchGeometry`/AppKit trade in,
    /// which are screen/window coordinates with a bottom-left origin), so the bento utility band can size
    /// its dead zone from the *real* cutout instead of a guessed constant.
    ///
    /// `NotchWindowController` derives this from the same `NotchGeometry.NotchLayout` it already converts
    /// into `NotchHoverView`'s own frame (see `NotchWindowController.notchRect(for:)`) on every panel
    /// build or reconcile pass, and republishes it here. Falls back to ``fallbackRect(panelWidth:)`` for a `.pill`
    /// display — see that property's own documentation for why a synthesized pill is not treated as a real
    /// cutout for this purpose.
    @Published var notchRect: CGRect = NotchDisplayViewModel.fallbackRect(
        panelWidth: CGFloat(NotchPreferences.expandedWidthDefault))

    /// The panel's actual expanded size (preferences, clamped to the display), published so
    /// `NotchContentView` lays out with `BentoLayout` from it. Placeholder until the first reconcile.
    @Published var expandedSize = CGSize(
        width: NotchPreferences.expandedWidthDefault, height: NotchPreferences.expandedHeightDefault)

    /// The dead-zone rect used when there is no real notch cutout to measure: a synthesized `.pill`
    /// display, or (defensively) a display this controller has not yet computed a layout for. `200x36pt`,
    /// centered horizontally in a panel `panelWidth` wide and pinned to the top — the same footprint the
    /// bento design spec's utility band reserves for a real notch, so a notchless Mac's dead zone still
    /// reads as "deliberately reserved" rather than an arbitrary gap that happens to match no geometry.
    static func fallbackRect(panelWidth: CGFloat) -> CGRect {
        CGRect(x: (panelWidth - 200) / 2, y: 0, width: 200, height: 36)
    }

    /// Bumped by `NotchWindowController.send(_:)` the instant an `fn fn`-triggered expansion settles into
    /// `.expanded` (see that method's key-window contract documentation), so the bento agents hero card can
    /// distinguish "the user typed the search shortcut" from an ordinary hover/click open, which must stay
    /// non-key and in browse mode. `NotchContentView` observes it with `.onChange(of:)`; only the fact that
    /// it changed matters (its own value carries no meaning) — that is what lets the view react with a
    /// plain "enter search mode and focus the field" rather than branching on a value.
    @Published var searchActivationToken: Int = 0
}

/// The AppKit composition root's central controller: owns one `NotchPanel` per display, the single
/// `NotchInteractionReducer` instance driving all of them, and the `NotchCommandExecutor` that turns its
/// output into real side effects.
///
/// ## The central event pump
///
/// `send(_:)` is the only path any AppKit-originated signal — a tracking area's `mouseEntered`, a click, a
/// hotkey, a timer fire, an animation settle, a sleep/wake/Space notification — is allowed to reach the
/// reducer through. It does exactly three things, in order: run the event through
/// `NotchInteractionReducer.reduce(_:)`, republish every touched display's `NotchDisplayViewModel` (the
/// triggering display and any other display the at-most-one-expanded invariant also touched), then hand
/// every returned `NotchCommand` to the executor. Nothing in this type second-guesses which commands come
/// back or filters them; per `NotchCommand`'s own contract the array is already complete.
///
/// ## Reconcile, debounced
///
/// `NSApplication.didChangeScreenParametersNotification` fires in bursts — one notification per property
/// that changed, sometimes several in a row for a single physical event like a display being unplugged.
/// `reconcileScreens()` is therefore never called directly from the notification handler; it is scheduled
/// on a cancel-and-reschedule `DispatchWorkItem` about 300ms out, so a burst collapses into one reconcile
/// pass. A reconcile pass:
///
/// - Reads `NSScreen.screens` once. If it is empty, the pass does nothing and waits for the next
///   notification — an empty screen list is a known **transient** state during sleep/wake and display
///   reattachment, not a real "every display vanished" signal, and acting on it would tear down every panel
///   only to immediately rebuild them a moment later.
/// - For each live screen, builds a fresh `NotchGeometry` layout from a fresh `ScreenMetrics` snapshot and
///   either creates a new panel (a display that just appeared) or updates an existing one's geometry in
///   place (this is where notched↔pill reclassification actually takes effect, since `NotchGeometry`
///   reads the display's *current* configuration on every call).
/// - For a panel whose display no longer appears in `NSScreen.screens`, sends it `suspend` (so every timer
///   and monitor it owns is torn down through the same path a real suspend takes) and then removes it from
///   this controller's and the executor's bookkeeping. It is deliberately **not** removed from
///   `NotchInteractionReducer.panels`: that dictionary has no delete operation, and leaving a `.suspended`
///   entry behind is not a leak worth avoiding, because a display identity that reconnects later
///   (unplug/replug the same monitor) then correctly resumes from `.suspended` instead of starting cold —
///   the reconcile pass sends it `resume` the moment it reappears among `NSScreen.screens`, through the
///   same `send(_:)` pump every other event uses, rather than leaving it parked in `.suspended` forever
///   (the reducer ignores every event but `resume` while suspended, so nothing else would ever revive it).
///
/// Displays are keyed throughout by `CGDirectDisplayID` (via `NotchScreenAdapter.displayID(for:)`), never
/// `NSScreen` object identity, because AppKit recreates `NSScreen` instances on every parameters-changed
/// notification even when the underlying physical display has not changed.
///
/// ## Tracking area vs. pointer monitors
///
/// Each panel's `NotchHoverView` (see `NotchPanel.swift`) covers only the collapsed pill's own rect and is
/// the *only* source of `hoverIntent`. Once a panel is expanding or expanded, this controller relies
/// entirely on `NotchCommandExecutor`'s pointer monitors for containment — see that type's documentation
/// for why a tracking area's `mouseExited` is unreliable once the panel itself starts growing.
///
/// ## Lifecycle notifications
///
/// Sleep (`NSWorkspace.willSleepNotification`) sends `suspend` for every known display; wake
/// (`didWakeNotification`) sends `resume`. `NSWorkspace.activeSpaceDidChangeNotification` fires only after
/// a Space transition has already completed (there is no pre-transition hook), so this controller reacts
/// to it by sending `escape` for every display — a no-op for anything not currently expanded, and an
/// immediate, ungraceful collapse for whichever panel was expanded, so a Space switch never strands an open
/// panel on a Space the user just left.
///
/// ## Thread safety
///
/// Main-actor isolated, like every other type in this target. The reducer is a plain value type mutated
/// only inside `send(_:)`, which is only ever called on the main actor.
@MainActor
final class NotchWindowController: NSObject {

    /// The content size every display's expanded panel is built at, from the user's panel-size settings.
    ///
    /// `NotchGeometry.layout(for:expandedSize:)` clamps both dimensions to the display, so a small display
    /// is still handled correctly. Read fresh on every reconcile pass.
    private static var expandedSize: CGSize {
        CGSize(
            width: NotchPreferences.shared.expandedWidth,
            height: NotchPreferences.shared.expandedHeight)
    }

    /// How long a burst of `didChangeScreenParametersNotification` postings is allowed to settle before a
    /// reconcile pass actually runs.
    private static let reconcileDebounce: TimeInterval = 0.3

    /// The alpha ``NotchPanel/containerView`` is set to while its material is "hidden" per
    /// ``updateContainerVisibility(display:)``.
    ///
    /// `alphaValue`, deliberately never `isHidden`. `containerView` is the direct superview of both the
    /// SwiftUI hosting view and `NotchHoverView` (see ``makePanel(for:layout:)``), and `NSView.isHidden`
    /// propagates to every subview — setting it here would take `NotchHoverView` down with it and silently
    /// kill hover-to-expand on a notchless display with the pill hidden, the "fully click-through, mouse
    /// events drop" trap this fix must not fall into. `alphaValue` composites down through the whole layer
    /// subtree instead (so a near-zero value here does make the collapsed pill's blur read as fully
    /// invisible), but it is orthogonal to hit-testing: `NSView.hitTest(_:)` and `NSTrackingArea` delivery
    /// are both alpha-blind, so `NotchHoverView.mouseEntered(with:)` keeps firing at this alpha exactly as
    /// it does at `1.0`. Deliberately not a literal `0` either, even though AppKit's own opacity compositing
    /// (unlike a fully transparent, click-through window region) does not itself drop hit-testing at zero —
    /// this stays a hair above zero as a defensive margin against ever answering "is this view visible" with
    /// "no" in some future check that keys off exact-zero alpha instead of `isHidden`.
    private static let hiddenMaterialAlpha: CGFloat = 0.001

    /// Everything this controller owns for one display's window: the panel itself, the hover view driving
    /// `hoverIntent`/`click`, and the view model feeding its SwiftUI content.
    private struct DisplayPanel {
        let panel: NotchPanel
        let hoverView: NotchHoverView
        let viewModel: NotchDisplayViewModel
    }

    /// The single state machine driving every display. A plain value type; every mutation happens inside
    /// `send(_:)`.
    private var reducer = NotchInteractionReducer()

    /// The one herd poller for the whole process, shared by every display's `NotchContentView`. Herd data
    /// is a fact about the machine herdr runs on, not about which display is showing it, so one instance
    /// and one poll loop serve every panel rather than each display running its own.
    ///
    /// Not `private`: `NotchAppDelegate`, the composition root, wires the fn-fn search window and the
    /// settings window's session roster to this same instance, so a search or a settings change acts on
    /// the data the notch is actually showing rather than a second, separate poll. It is still a `let`, so
    /// there is nothing to protect against external mutation. Nothing else needs it — `NotchContentView`
    /// already gets its own reference passed down through `makePanel(for:layout:)`.
    let herdModel: NotchHerdModel

    /// The caffeinate toggle, shared by every display's home surface and by `NotchAppDelegate`'s status-item
    /// menu item and Ctrl-Ctrl hotkey. One instance for the same reason ``herdModel`` is one instance: an
    /// idle-sleep assertion is a fact about the machine, not about which display's panel happens to be open,
    /// so there is exactly one to toggle regardless of how many notch panels exist. Not `private`, mirroring
    /// ``herdModel``'s own visibility, so `NotchAppDelegate` can register the Ctrl-Ctrl hotkey against it and
    /// keep its status-item menu item's checkmark in sync via `$isActive`.
    let caffeinateService = CaffeinateService()

    /// The macOS Reminders bridge backing `NotchRoute/reminders`, shared for the same "one machine-wide
    /// fact" reason as ``herdModel`` and ``caffeinateService``: the incomplete-reminders list is a fact
    /// about the user's Reminders data, not about which display's panel is open. Not `private`, so
    /// `NotchAppDelegate`'s status-item menu item can route a display to `.reminders`.
    let remindersService = RemindersService()

    /// The file shelf, shared by every display for the same "one machine-wide fact" reason as
    /// ``remindersService``: one cache directory, one set of files.
    let shelfService = ShelfService()

    /// The Spotify now-playing/transport bridge backing `NotchRoute/spotify`, shared for the same
    /// "one machine-wide fact" reason as ``herdModel``, ``caffeinateService`` and ``remindersService``:
    /// Spotify's own playback state is one fact, not one per display. Not `private`, so `NotchAppDelegate`'s
    /// status-item menu item can route a display to `.spotify`.
    let spotifyService = SpotifyNowPlayingService()

    /// The system-wide (Music, browsers, Podcasts, and Spotify too) now-playing bridge backing the
    /// now-playing card whenever ``spotifyService`` itself is not the currently playing source. Shared for
    /// the same "one machine-wide fact" reason as ``spotifyService``. Not `private`, mirroring
    /// ``spotifyService``'s own visibility. See `SystemNowPlayingService`'s own documentation for the
    /// private-`MediaRemote`-framework probe this spike ran before adding it, and what it found on this
    /// machine (macOS 26.2).
    let systemNowPlayingService = SystemNowPlayingService()

    /// The Mac's internal-battery state, backing the utility band's battery indicator. Shared for the same
    /// "one machine-wide fact" reason as the other services; event-driven, so it costs nothing while idle.
    let batteryService = BatteryService()

    /// Shared with the settings window (see ``LidSleepController/shared``).
    let lidSleepController = LidSleepController.shared

    /// Manual toggle, automatic conditions and lid-closed mode over ``caffeinateService``.
    lazy var keepAwakeService = KeepAwakeService(caffeinate: caffeinateService, lid: lidSleepController)

    /// The single entry for the ⌃⇧C hotkey and the status-item menu, so they share the manual-off snooze.
    func toggleKeepAwake() { keepAwakeService.toggleManual() }

    /// Battery health, cycles, watts and time remaining for the System page; event-driven.
    let powerInfoService = PowerInfoService()

    /// Memory, disk and CPU samples, running only while an alert category is enabled.
    let systemAlertMonitor = SystemAlertMonitor()

    /// Plan usage for Claude, Codex, OpenCode and Antigravity, polled every 5 minutes.
    let usageService = UsageService()

    /// The one `SearchKeyNav` for the whole process, shared by every display's panel and `NotchContentView`
    /// for the same "one machine-wide fact" reason ``herdModel`` and the other services above are shared —
    /// except here the fact is "which display's search mode, if any, is live", not persistent data, and at
    /// most one display can be `.expanded` (and therefore in search mode) at a time per
    /// `NotchInteractionReducer`'s own invariant, so one instance for every panel to point its `NotchPanel`
    /// at is correct rather than one per display. `NotchPanel.searchKeyNav` holds this only `weak`, so this
    /// `let` is the object's sole owner.
    let searchKeyNav = SearchKeyNav()

    /// Invoked when any display's `NotchContentView` settings gear is clicked. `nil` until
    /// `NotchAppDelegate` sets it (right after constructing this controller, before ``start()``), since this
    /// controller has no settings window of its own — `NotchAppDelegate` is the one place that owns
    /// `HerdSettingsWindow`, and every panel's content forwards its gear-button click here rather than this
    /// AppKit-free-adjacent controller reaching into `HerdHost` directly.
    var onOpenSettings: (() -> Void)?

    /// Invoked when the user picks an agent — from the agents hero card's browse-mode shortlist or its
    /// search-mode results — to focus its pane and raise its terminal. `nil` until `NotchAppDelegate` sets
    /// it to `HerdFocusService.focus(agent:in:)`, mirroring ``onOpenSettings``'s own "the AppKit-free
    /// controller does not own the host-side service, so the composition root wires it in" shape.
    /// Collapsing the panel afterward is this controller's own job, not the closure's — see
    /// ``makePanel(for:layout:)``, which composes this with `send(.escape(display))` per display, the same
    /// pattern `onOpenSettings`'s own call site in `NotchContentView` uses for its settings gear.
    var onSelectAgent: ((HerdSession, HerdAgent) -> Void)?

    /// Per-display AppKit windows and SwiftUI plumbing, keyed by `CGDirectDisplayID`.
    private var displayPanels: [NotchDisplayID: DisplayPanel] = [:]

    /// The dumb, faithful executor this controller hands every returned `NotchCommand` to.
    private lazy var executor = NotchCommandExecutor { [weak self] event in
        self?.send(event)
    }

    /// The in-flight (or most recently scheduled) reconcile work item, replaced rather than stacked on
    /// every `didChangeScreenParametersNotification`, so a burst of notifications collapses into one pass.
    private var reconcileWorkItem: DispatchWorkItem?

    /// Subscribes ``refreshAllContainerVisibility()`` to every change of
    /// ``NotchPreferences/showCollapsedPill``, so the debug status-item menu's "Show Pill" toggle updates a
    /// resting collapsed panel's material live, the same way it already repaints `NotchContentView`'s own
    /// SwiftUI content (see that type's `preferences` property). See ``start()`` for why the subscription
    /// hops through a `Task { @MainActor in }` rather than acting directly inside `sink`'s closure.
    private var preferencesCancellable: AnyCancellable?

    /// Re-frames every panel (via ``reconcileScreens()``) when the panel-size preferences change.
    private var panelSizeCancellable: AnyCancellable?

    /// The transient blocked/done toast, shared for the whole process the same way ``herdModel`` is: one
    /// alert is one machine-wide event, not a per-display one. See ``handleAlert(_:)``.
    private let toast = NotchToast()

    /// The screen-edge glow ``handleAlert(_:)`` flashes alongside ``toast``. Never fired for the
    /// caffeine/battery message toasts — an agent blocking/finishing is the one event loud enough to
    /// warrant lighting up the screen's edges, not every transient message this controller shows.
    private let edgeGlow = NotchEdgeGlow()

    /// Settings source shared with the app delegate, held here (rather than only forwarded to
    /// ``herdModel`` in ``init(preferences:)``) so ``handleAlert(_:)`` can read
    /// `HerdPreferences.popupDuration` — the notch toast honours the same show-time setting the old
    /// `BoringHerdBar` transient popup already exposed, rather than a value hardcoded independently of it.
    private let preferences: HerdPreferences

    /// Subscribes ``handleAlert(_:)`` to every new ``NotchHerdModel/alert``. Held only to keep the
    /// subscription alive; never read.
    private var herdAlertCancellable: AnyCancellable?

    /// Subscribes ``handleBatteryChange(_:)`` to every ``BatteryService/percent`` update. Held only to
    /// keep the subscription alive; never read.
    private var batteryCancellable: AnyCancellable?

    /// The last charge percentage ``handleBatteryChange(_:)`` saw, so it can tell a fresh crossing from a
    /// reading that is merely still below a bound it already toasted about. `nil` until the first reading
    /// arrives, which ``BatteryAlert/crossedTier(previous:current:charging:thresholds:)`` and
    /// ``BatteryAlert/justReachedFull(previous:current:charging:)`` both treat as "nothing to compare yet".
    private var lastBatteryPercent: Int?

    /// Keep-awake inputs, each updated from its own event source and pushed together by
    /// ``pushKeepAwakeInputs()``.
    private var inputAgentWorking = false
    private var inputRunningBundleIds: Set<String> = []
    private var inputOnCharger = false
    private var inputExternalDisplay = false
    private var inputBatteryPercent: Int?

    /// Subscriptions for the usage, power, keep-awake and system-alert wiring. Held to keep them alive.
    private var systemCancellables: Set<AnyCancellable> = []

    /// Each live display's collapsed pill frame, in screen coordinates — `NotchGeometry.NotchLayout.collapsedFrame`
    /// as of the last reconcile pass. Kept only for ``toast``, which needs a screen-coordinate anchor to
    /// position under and has no `NotchEvent`/`NotchCommand` of its own to carry one on; every other
    /// consumer of this same frame (``NotchHoverView``, `NotchCommandExecutor`) already gets it converted
    /// to window-local coordinates at the point it is computed, in ``makePanel(for:layout:)`` and
    /// ``updateGeometry(display:existing:layout:)``.
    private var collapsedScreenFrames: [NotchDisplayID: CGRect] = [:]

    /// Creates the controller and its poller.
    ///
    /// - Parameter preferences: Settings source shared with the app delegate, threaded down to
    ///   ``herdModel`` so the watch switch, poll interval, session filter and remote paths all read from
    ///   the one store `HerdNotch/HerdSettingsWindow` (via `HerdHost`) edits.
    init(preferences: HerdPreferences) {
        self.herdModel = NotchHerdModel(preferences: preferences)
        self.preferences = preferences
        super.init()
    }

    /// The single process-exit teardown hook, called from `applicationWillTerminate`. Every service that
    /// holds system state past its own lifetime (power assertions, `pmset` overrides) releases it here.
    func shutdown() {
        keepAwakeService.shutdown()
        caffeinateService.releaseForShutdown()
    }

    /// Builds the initial set of panels and subscribes to every lifecycle notification this controller
    /// reacts to. Called once, from the app delegate, after `NSApp` has finished launching.
    func start() {
        lidSleepController.recoverIfNeeded()
        herdModel.start()
        remindersService.start()
        shelfService.onMessage = { [weak self] message in self?.showShelfToast(message) }
        shelfService.start()
        reconcileScreens()
        preferencesCancellable = NotchPreferences.shared.$showCollapsedPill.sink { [weak self] _ in
            // Hopping through `Task { @MainActor in }`, the same idiom `NotchCommandExecutor`'s monitor and
            // timer callbacks already use, rather than acting directly inside `sink`'s closure: Combine's
            // `sink` handler carries no actor isolation of its own, and deferring one main-actor turn also
            // sidesteps `@Published`'s `willSet`-like timing (the new value is not yet stored when `sink`
            // fires — see this property's own documentation), so `NotchPreferences.shared.showCollapsedPill`
            // reads back correctly by the time ``refreshAllContainerVisibility()`` actually runs.
            Task { @MainActor in
                self?.refreshAllContainerVisibility()
            }
        }
        panelSizeCancellable = NotchPreferences.shared.$expandedWidth
            .combineLatest(NotchPreferences.shared.$expandedHeight)
            .dropFirst()
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                // Same main-actor hop as above: `@Published` fires before the new value is stored.
                Task { @MainActor in
                    self?.reconcileScreens()
                }
            }
        herdAlertCancellable = herdModel.$alert.compactMap { $0 }.sink { [weak self] alert in
            // Same `Task { @MainActor in }` hop as ``preferencesCancellable`` above, and for the identical
            // reason: `sink`'s closure carries no actor isolation of its own.
            Task { @MainActor in
                self?.handleAlert(alert)
            }
        }
        batteryCancellable = batteryService.$percent.sink { [weak self] percent in
            // Same `Task { @MainActor in }` hop as ``preferencesCancellable`` above, and for the identical
            // reason: `sink`'s closure carries no actor isolation of its own.
            Task { @MainActor in
                self?.handleBatteryChange(percent)
            }
        }
        startSystemServices()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(workspaceWillSleep),
            name: NSWorkspace.willSleepNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
    }

    /// The one path every event reaches `NotchInteractionReducer.reduce(_:)` through. See this type's
    /// documentation for the full contract.
    ///
    /// - Parameter event: The event to apply.
    /// - Returns: The commands the reducer produced, already dispatched to the executor by the time this
    ///   returns. Returned mainly so callers (the debug menu) can inspect what happened in a test build;
    ///   ordinary callers ignore it.
    @discardableResult
    func send(_ event: NotchEvent) -> [NotchCommand] {
        // Read before `reduce(_:)` mutates the reducer's own state, specifically so the `.animationSettled`
        // handling below can still see which `NotchTrigger` started this expansion — by the time a settled
        // expand has landed in `.expanded(route)`, the reducer has already discarded the `.expanding(trigger)`
        // case that carried it (`NotchTrigger` only exists on `NotchPresentation/expanding(_:)`), so this is
        // the last point this method can read it at all. See the key-window contract below for why the
        // trigger, not just "did an expand settle", is what this method needs.
        let previousPresentation = reducer.panels[event.display]?.presentation
        let commands = reducer.reduce(event)
        updateViewModel(for: event.display)
        for command in commands {
            updateViewModel(for: command.display)
        }
        for command in commands {
            executor.execute(command)
        }
        updateHerdModelActivity()
        // **Key-window contract:** a click on the collapsed pill makes the panel key; so does the `fn fn`
        // search shortcut, since typing into the search field it opens is the entire point — a hover-opened
        // panel does neither, so hovering the notch never steals keyboard focus from whatever the user was
        // doing. `makeKey()` lives here, once `reduce(_:)` has actually run, rather than as a side effect of
        // the raw animator completion (see `NotchCommandExecutor.startExpand`): only after this call can this
        // controller ask the reducer whether the display this `animationSettled` targeted actually landed in
        // `.expanded`. A completion for an animation the reducer had already retargeted to collapse (see
        // `NotchAnimator`'s documentation on retargeting) settles into `.collapsing`/`.collapsed` instead, and
        // must never make a collapsing panel key.
        //
        // This covers only the collapsed-pill click/hotkey that *starts* an expansion. A click on an
        // already-hover-opened panel's own content (for example, the reminders quick-add field) is a
        // separate path — `NotchCommandExecutor`'s pointer monitor promotes the panel to key on that mouse
        // down directly, synchronously, before the click's own event finishes dispatching, so the same click
        // both focuses the window and reaches the control underneath it. See that type's own documentation.
        if case .animationSettled = event, case .expanded = reducer.panels[event.display]?.presentation {
            switch previousPresentation {
            case .expanding(.click):
                displayPanels[event.display]?.panel.makeKey()
            case .expanding(.hotkey):
                // `fn fn` gets everything `.click` gets (key window) plus a bump of
                // `searchActivationToken`, which is what tells the agents hero card to enter search mode
                // and focus its field — see that property's own documentation.
                displayPanels[event.display]?.panel.makeKey()
                displayPanels[event.display]?.viewModel.searchActivationToken += 1
            case .expanding(.hover), .expanding(.fileDrag), .collapsed, .collapsing, .expanded(_), .suspended, nil:
                break
            }
        }
        return commands
    }

    /// The display under the pointer right now, or the main screen if none contains it (for example, the
    /// pointer is on a disconnected display during a reconfigure race).
    ///
    /// Named for its original caller, the debug menu, which has no tracking-area or monitor event of its
    /// own to derive a display from — the `fn fn` global hotkey (`NotchAppDelegate.herdHotKey`) now uses it
    /// for exactly the same reason, and shares the same "whichever display the pointer is over" answer.
    ///
    /// - Returns: The display identity, or `nil` if no screen at all can be resolved.
    func debugTargetDisplay() -> NotchDisplayID? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        return screen.flatMap(NotchScreenAdapter.displayID(for:))
    }

    /// `display`'s current presentation, read straight from the reducer.
    ///
    /// The one seam `NotchAppDelegate`'s fn-fn closure needs to tell whether a just-sent
    /// `hotkeyToggle(_:)` actually opened the panel (result `.expanding`/`.expanded`) or closed it, was
    /// ignored by a lock, or targeted a display with no materialised state at all (`nil`), so that closure
    /// can send its follow-up `route(_:, .herd)` only in the first case — see that closure's own
    /// documentation for the flash/leak bug this exists to fix. `reducer` itself stays `private`; this is
    /// the narrow, read-only slice of it the app delegate is allowed to see.
    ///
    /// - Parameter display: The display to read presentation for.
    /// - Returns: The presentation the reducer holds for `display`, or `nil` if the reducer has not
    ///   materialised state for it yet (equivalent to `NotchPanelState`'s own collapsed default, but `nil`
    ///   here rather than `.collapsed` so a caller can distinguish "never touched" from "touched and
    ///   collapsed" if it ever needs to; today's one caller treats both the same way).
    func presentation(for display: NotchDisplayID) -> NotchPresentation? {
        reducer.panels[display]?.presentation
    }

    /// Copies `presentation`/`pendingRoute` out of the reducer for `display` into that display's published
    /// view model, or leaves the view model at its collapsed/home default if the reducer has not
    /// materialised state for this display yet (or the display has no panel at all, in which case this is
    /// a no-op).
    ///
    /// Only actually assigns a `@Published` field when its value has changed (a perf fix an adversarial
    /// review asked for): `send(_:)` calls this for every event's own display and every returned command's
    /// display, including a plain `hoverExit` while a panel is already expanded — an event that never
    /// touches `presentation` or `pendingRoute` at all, but was still republishing both unconditionally,
    /// invalidating and re-rendering `NotchContentView`'s `@ObservedObject` on every pointer-moved sample
    /// the executor's monitors reported. `NotchPresentation` and `NotchRoute` are both `Equatable`, so the
    /// guard costs nothing beyond the comparison itself.
    private func updateViewModel(for display: NotchDisplayID) {
        guard let viewModel = displayPanels[display]?.viewModel else { return }
        let state = reducer.panels[display]
        let presentation = state?.presentation ?? .collapsed
        let pendingRoute = state?.pendingRoute ?? .home
        if viewModel.presentation != presentation {
            viewModel.presentation = presentation
        }
        if viewModel.pendingRoute != pendingRoute {
            viewModel.pendingRoute = pendingRoute
        }
        updateContainerVisibility(display: display)
    }

    /// Hides ``NotchPanel/containerView``'s translucent material while a notchless (`.pill`) display is
    /// resting `.collapsed`/`.suspended` with ``NotchPreferences/showCollapsedPill`` off, so that setting
    /// actually hides the visible blurred capsule the material renders — not just the SwiftUI content drawn
    /// on top of it. `NotchContentView.collapsedBody` already draws `Color.clear` in this case, but
    /// `containerView` is an `NSVisualEffectView` (see `NotchPanel`'s documentation), and its blur keeps
    /// compositing underneath regardless of what the content layered on top of it draws — that gap between
    /// "the SwiftUI content is invisible" and "the window is invisible" is exactly the bug an adversarial
    /// review found.
    ///
    /// Sets `alphaValue`, never `isHidden`: see ``hiddenMaterialAlpha``'s documentation for why `isHidden`
    /// is the trap this fix must not fall into (it would take ``NotchHoverView``, a subview of
    /// `containerView`, down with it, and silently kill hover-to-expand on a notchless display with the
    /// pill hidden).
    ///
    /// Restored to full opacity for every other presentation — `.expanding`, `.expanded` and `.collapsing`
    /// all keep the surface's material fully visible, so a panel that is animating open or already open
    /// never reads as anything but normal system chrome — and for a real physical notch (`.notched`)
    /// unconditionally, since that pill is the display's own cutout and is never optional (per this fix's
    /// contract, leave that path unchanged).
    ///
    /// - Parameter display: The display whose panel's material visibility to recompute.
    private func updateContainerVisibility(display: NotchDisplayID) {
        guard let displayPanel = displayPanels[display] else { return }
        let hidesMaterial: Bool
        switch displayPanel.viewModel.presentation {
        case .collapsed, .suspended:
            hidesMaterial = displayPanel.viewModel.layoutKind == .pill && !NotchPreferences.shared.showCollapsedPill
        case .expanding, .expanded, .collapsing:
            hidesMaterial = false
        }
        let targetAlpha: CGFloat = hidesMaterial ? Self.hiddenMaterialAlpha : 1.0
        if displayPanel.panel.containerView.alphaValue != targetAlpha {
            displayPanel.panel.containerView.alphaValue = targetAlpha
        }
    }

    /// Recomputes ``updateContainerVisibility(display:)`` for every known display. Called only when
    /// ``NotchPreferences/showCollapsedPill`` itself changes (see ``preferencesCancellable``): every other
    /// path that can affect the outcome — a presentation change, or a reconcile pass's notched↔pill
    /// reclassification — already runs through ``updateViewModel(for:)`` or ``updateGeometry(display:existing:layout:)``
    /// on its own.
    private func refreshAllContainerVisibility() {
        for display in displayPanels.keys {
            updateContainerVisibility(display: display)
        }
    }

    /// Raises ``herdModel``'s poll rate while any display is `expanding`/`expanded`, and lowers it back the
    /// moment none is; also starts/stops ``spotifyService``'s open-only position tick on the same signal.
    /// This is the "hook the same place that already knows expansion state" point the change plan asks for:
    /// `reducer.panels` is the reducer's own presentation state, read fresh after every `reduce(_:)` call, so
    /// this needs no state of its own to duplicate or drift from it. At most one display can be
    /// `expanding`/`expanded` at a time (`NotchInteractionReducer`'s own invariant), but this reads every
    /// display rather than assuming that to stay correct if that invariant is ever relaxed.
    ///
    /// Reusing this one signal for `herdModel`, `spotifyService`, and ``systemNowPlayingService`` rather than
    /// giving each its own "did presentation change" hook: all three exist for the identical reason (poll
    /// something live only while a human is actually looking at it), so one `anyExpanded` computation
    /// answering all three is simpler than three copies of the same reducer scan.
    private func updateHerdModelActivity() {
        let anyExpanded = reducer.panels.values.contains { state in
            switch state.presentation {
            case .expanding, .expanded: true
            case .collapsed, .collapsing, .suspended: false
            }
        }
        herdModel.setActive(anyExpanded)
        if anyExpanded {
            spotifyService.startPositionTicking()
            systemNowPlayingService.startPositionTicking()
            // A toast left showing over an already-open notch would be redundant chrome sitting on top of
            // a surface that already lists the very agent it is announcing — dismiss it the instant any
            // display actually expands, regardless of which gesture (hover, click, `fn fn`, or the toast's
            // own click-to-open) got it there.
            toast.dismiss()
        } else {
            spotifyService.stopPositionTicking()
            systemNowPlayingService.stopPositionTicking()
        }
    }

    /// The first collapsed/suspended display, with its screen-coordinate toast anchor — the common
    /// "which display, and where over it" lookup shared by ``handleAlert(_:)``,
    /// ``showCaffeineToast(active:)`` and ``presentBatteryToast(symbolName:tier:title:)``: an already
    /// `expanding`/`expanded` display already shows its own state in its own content, so a toast on top of
    /// it would be redundant.
    ///
    /// - Returns: The display and its anchor rect, or `nil` if every known display is currently
    ///   expanding/expanded, or this controller has no display at all yet.
    private func collapsedToastTarget() -> (display: NotchDisplayID, anchor: CGRect)? {
        guard let target = displayPanels.first(where: { Self.isCollapsedOrSuspended($0.value.viewModel.presentation) })
        else { return nil }
        let anchor = collapsedScreenFrames[target.key] ?? target.value.panel.frame
        return (target.key, anchor)
    }

    /// The palette for the app's current effective appearance, resolved fresh on every call so a toast
    /// always matches whichever light/dark mode is active the moment it is shown.
    private func currentPalette() -> HerdPalette {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return HerdPalette.resolving(isDark ? ColorScheme.dark : ColorScheme.light)
    }

    /// Shows ``toast`` for `alert`, on whichever collapsed/suspended display is found first — an already
    /// `expanding`/`expanded` display is skipped entirely, since it already shows the transitioning agent
    /// in its own agents hero card and a toast on top of it would be redundant (per the design spec's "if
    /// the notch is already open/expanded, don't toast" rule).
    ///
    /// A no-op if every known display is currently expanding/expanded, or if this controller has no
    /// display at all yet.
    ///
    /// - Parameter alert: The coalesced batch `NotchHerdModel` just published.
    private func handleAlert(_ alert: NotchAlert) {
        guard let target = collapsedToastTarget() else { return }
        toast.present(alert, anchor: target.anchor, dismissDelay: preferences.popupDuration) { [weak self] in
            // Hovering or clicking the toast opens the real notch on the same display it was anchored to,
            // through the same `click` path the collapsed pill's own hover view uses — see
            // `NotchInteractionReducer.handleClick(display:panel:)`.
            self?.send(.click(target.display))
        }

        // Mirrors `NotchToast.content(for:)`'s own precedence: any waiting agent wins the colour over a
        // finished one, since that is the state that most needs the user's attention.
        let dominant: AgentStatus = alert.entries.contains { $0.status == .blocked } ? .blocked : .done
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: target.anchor.midX, y: target.anchor.midY)) }) {
            edgeGlow.flash(status: dominant, on: screen, duration: preferences.popupDuration)
        }
    }

    /// Shows an on-screen "Caffeinate on/off" toast when the toggle happens while the notch is collapsed, so
    /// the Control+Shift+C hotkey (or the status-item menu) gives the same feedback the top-bar cup glyph
    /// already gives while the notch is open. Skipped when every display's panel is expanded — the cup in the
    /// open notch already shows the state, so a toast over it would be redundant (mirrors ``handleAlert(_:)``'s
    /// own "anchor on a collapsed display, else do nothing" rule). Driven by
    /// `KeepAwakeService.manualChanges`, so it covers manual toggles and an auto-off release, never a condition.
    ///
    /// - Parameter active: The new caffeinate state to announce.
    func showCaffeineToast(active: Bool) {
        guard let target = collapsedToastTarget() else { return }
        let palette = currentPalette()
        toast.presentMessage(
            symbolName: active ? "cup.and.saucer.fill" : "cup.and.saucer",
            tint: active ? palette.working : palette.textTertiary,
            title: active ? "Caffeinate on" : "Caffeinate off",
            anchor: target.anchor,
            dismissDelay: preferences.popupDuration
        ) { [weak self] in self?.send(.click(target.display)) }
    }

    /// Ends a drag on `display`, reporting whether the pointer is still over its panel so the exit grace
    /// starts only when the drag really left.
    private func sendDragEnded(_ display: NotchDisplayID) {
        let inside = displayPanels[display]?.panel.frame.contains(NSEvent.mouseLocation) ?? false
        send(.dragEnded(display, pointerInside: inside))
    }

    /// Shows a shelf failure message. Unlike the other toasts this one is not skipped over an open notch:
    /// the shelf is only ever used with the panel open, so the message is the point.
    private func showShelfToast(_ message: String) {
        guard let (display, panelValue) = displayPanels.first.map({ ($0.key, $0.value) }) else { return }
        let anchor = collapsedScreenFrames[display] ?? panelValue.panel.frame
        toast.presentMessage(
            symbolName: "exclamationmark.triangle.fill",
            tint: currentPalette().blocked,
            title: message,
            anchor: anchor,
            dismissDelay: preferences.popupDuration
        ) {}
    }

    /// Announces a battery-threshold crossing or a full charge, mirroring ``showCaffeineToast(active:)``'s
    /// own "toast only while a display is collapsed/suspended" rule.
    ///
    /// **Retains an unannounced crossing.** While charging, ``lastBatteryPercent`` always advances (a
    /// charging battery is climbing, so no downward crossing is pending). While discharging, it advances
    /// only when ``presentBatteryToast(symbolName:tier:title:)`` actually showed a toast — every display
    /// expanded is the one case it returns `false` — so a crossing that could not be announced (every
    /// display was expanded) stays pending and re-fires on the next reading, even after the notch later
    /// collapses, instead of being silently dropped. When nothing crossed, it advances normally.
    ///
    /// One known, accepted gap: a single poll tick that misreports `charging == true` exactly on a crossing
    /// suppresses that crossing (the `charging` branch never checks `crossedTier` at all). Low-probability
    /// and intentional — no code change for it.
    ///
    /// - Parameter percent: The new reading from ``batteryService``, or `nil` on a Mac with no battery.
    private func handleBatteryChange(_ percent: Int?) {
        guard let percent else { return }
        let prefs = NotchPreferences.shared
        guard prefs.batteryAlertsEnabled else {
            lastBatteryPercent = percent
            return
        }
        let charging = batteryService.isCharging
        if charging {
            if BatteryAlert.justReachedFull(previous: lastBatteryPercent, current: percent, charging: charging) {
                presentBatteryToast(symbolName: "battery.100.bolt", tier: .healthy, title: "Fully charged")
            }
            lastBatteryPercent = percent
        } else if let tier = BatteryAlert.crossedTier(
            previous: lastBatteryPercent, current: percent, charging: charging, thresholds: prefs.batteryThresholds
        ) {
            let presented: Bool
            switch tier {
            case .low:
                presented = presentBatteryToast(symbolName: "battery.50", tier: tier, title: "Battery low · \(percent)%")
            case .warning:
                presented = presentBatteryToast(symbolName: "battery.25", tier: tier, title: "Battery at \(percent)%")
            case .critical:
                presented = presentBatteryToast(symbolName: "battery.0", tier: tier, title: "Battery critical · \(percent)%")
            case .healthy:
                // `crossedTier` never returns `.healthy` (see its own documentation); unreachable in
                // practice, kept only for the switch's exhaustiveness.
                presented = false
            }
            if presented {
                lastBatteryPercent = percent
            }
        } else {
            lastBatteryPercent = percent
        }
    }

    /// Presents a battery toast via ``toast``, tinted by `tier` through ``HerdPalette/color(for:)`` (the
    /// one home for the tier→colour mapping, shared with the utility band's own battery ring), on the same
    /// collapsed/suspended-display anchor ``showCaffeineToast(active:)`` uses.
    ///
    /// - Parameters:
    ///   - symbolName: The SF Symbol to show.
    ///   - tier: The tier to tint by.
    ///   - title: The one-line message.
    /// - Returns: `true` if a collapsed/suspended display existed and the toast was actually shown; `false`
    ///   if every display was expanding/expanded and this was a no-op.
    @discardableResult
    private func presentBatteryToast(symbolName: String, tier: BatteryTier, title: String) -> Bool {
        guard let target = collapsedToastTarget() else { return false }
        let palette = currentPalette()
        toast.presentMessage(
            symbolName: symbolName,
            tint: palette.color(for: tier),
            title: title,
            anchor: target.anchor,
            dismissDelay: preferences.popupDuration
        ) { [weak self] in self?.send(.click(target.display)) }
        return true
    }

    /// Whether `presentation` is one this controller considers "closed enough to toast over".
    ///
    /// - Parameter presentation: The presentation to classify.
    /// - Returns: `true` for `.collapsed`/`.suspended`, `false` for every in-flight or open state.
    private static func isCollapsedOrSuspended(_ presentation: NotchPresentation) -> Bool {
        switch presentation {
        case .collapsed, .suspended: return true
        case .expanding, .expanded, .collapsing: return false
        }
    }

    // MARK: - System services

    /// Wires usage, power, keep-awake and system alerts. Every input arrives by notification or publisher;
    /// nothing here polls apps or screens.
    private func startSystemServices() {
        let prefs = NotchPreferences.shared
        inputRunningBundleIds = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        inputExternalDisplay = Self.hasExternalDisplay()
        inputOnCharger = powerInfoService.snapshot.onCharger
        inputBatteryPercent = batteryService.percent
        inputAgentWorking = herdModel.counts.working > 0

        herdModel.$snapshot.map { $0.counts.working > 0 }.removeDuplicates().sink { [weak self] working in
            Task { @MainActor in
                self?.inputAgentWorking = working
                self?.pushKeepAwakeInputs()
            }
        }.store(in: &systemCancellables)
        powerInfoService.$snapshot.map(\.onCharger).removeDuplicates().sink { [weak self] charger in
            Task { @MainActor in
                self?.inputOnCharger = charger
                self?.pushKeepAwakeInputs()
            }
        }.store(in: &systemCancellables)
        batteryService.$percent.removeDuplicates().sink { [weak self] percent in
            Task { @MainActor in
                self?.inputBatteryPercent = percent
                self?.pushKeepAwakeInputs()
            }
        }.store(in: &systemCancellables)
        keepAwakeService.manualChanges.sink { [weak self] active in
            Task { @MainActor in self?.showCaffeineToast(active: active) }
        }.store(in: &systemCancellables)
        keepAwakeService.$lidModeEnabled.dropFirst().removeDuplicates().sink { value in
            // The service turns lid mode off when `sudo` refuses; mirror that into the preference.
            Task { @MainActor in
                if !value, prefs.keepAwakeLidMode { prefs.keepAwakeLidMode = false }
            }
        }.store(in: &systemCancellables)
        lidSleepController.$isSetUp.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.keepAwakeService.reevaluate() }
        }.store(in: &systemCancellables)
        prefs.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.applySystemPreferences() }
        }.store(in: &systemCancellables)
        usageService.events.sink { [weak self] event in
            Task { @MainActor in self?.handleUsageEvent(event) }
        }.store(in: &systemCancellables)
        systemAlertMonitor.events.sink { [weak self] alert in
            Task { @MainActor in self?.handleSystemAlert(alert) }
        }.store(in: &systemCancellables)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self, selector: #selector(appLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        workspace.addObserver(
            self, selector: #selector(appTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChangedForKeepAwake),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        applySystemPreferences()
        pushKeepAwakeInputs()
    }

    /// Applies every preference the System services read. Idempotent: each callee ignores an unchanged value.
    private func applySystemPreferences() {
        let prefs = NotchPreferences.shared
        keepAwakeService.setConditions(prefs.keepAwakeConditions)
        keepAwakeService.setLidMode(prefs.keepAwakeLidMode)
        pushKeepAwakeInputs()
        usageService.configure(
            enabled: prefs.enabledUsageProviders, warnPercent: prefs.usageWarnPercent,
            criticalPercent: prefs.usageCriticalPercent)
        systemAlertMonitor.setEnabled(
            memory: prefs.systemAlertMemoryEnabled, disk: prefs.systemAlertDiskEnabled, cpu: prefs.systemAlertCpuEnabled)
    }

    private func pushKeepAwakeInputs() {
        keepAwakeService.setInputs(
            KeepAwakeInputs(
                anyAgentWorking: inputAgentWorking, runningBundleIds: inputRunningBundleIds,
                onCharger: inputOnCharger, externalDisplay: inputExternalDisplay),
            batteryPercent: inputBatteryPercent, lidCutoff: NotchPreferences.shared.lidBatteryCutoffPercent)
    }

    @objc private func appLaunched(_ note: Notification) {
        guard let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
        else { return }
        inputRunningBundleIds.insert(id)
        pushKeepAwakeInputs()
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
        else { return }
        inputRunningBundleIds.remove(id)
        pushKeepAwakeInputs()
    }

    @objc private func screensChangedForKeepAwake() {
        inputExternalDisplay = Self.hasExternalDisplay()
        pushKeepAwakeInputs()
    }

    private static func hasExternalDisplay() -> Bool {
        NSScreen.screens.contains { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return false }
            return CGDisplayIsBuiltin(id) == 0
        }
    }

    // MARK: - System toasts

    /// Toasts a usage threshold or reset, while a display is collapsed and usage alerts are enabled.
    private func handleUsageEvent(_ event: UsageEvent) {
        guard NotchPreferences.shared.usageAlertsEnabled, let target = collapsedToastTarget() else { return }
        let palette = currentPalette()
        let window = event.label == "Weekly" ? "weekly" : "session"
        let name = "\(event.provider.displayName) \(window)"
        let title: String
        let tint: Color
        switch event.kind {
        case .warning, .critical:
            title = "\(name) at \(event.percent)%"
                + (event.resetsAt.map { " · resets in \(UsageFormat.timeToReset($0, now: Date()))" } ?? "")
            tint = event.kind == .critical ? palette.blocked : palette.working
        case .reset:
            title = "\(name) reset"
            tint = palette.done
        }
        presentSystemToast(symbolName: "gauge.with.dots.needle.67percent", tint: tint, title: title, target: target)
    }

    private func handleSystemAlert(_ alert: SystemAlert) {
        guard let target = collapsedToastTarget() else { return }
        let title: String
        switch alert {
        case .memoryPressureCritical: title = "Memory pressure critical"
        case .diskLow(let percent): title = "Disk \(percent)% free"
        case .cpuSustained: title = "CPU above 90% for 2 min"
        }
        presentSystemToast(
            symbolName: "exclamationmark.triangle.fill", tint: currentPalette().blocked, title: title, target: target)
    }

    private func presentSystemToast(
        symbolName: String, tint: Color, title: String, target: (display: NotchDisplayID, anchor: CGRect)
    ) {
        toast.presentMessage(
            symbolName: symbolName, tint: tint, title: title, anchor: target.anchor,
            dismissDelay: preferences.popupDuration
        ) { [weak self] in self?.send(.click(target.display)) }
    }

    // MARK: - Reconcile

    @objc private func screenParametersChanged() {
        reconcileWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.reconcileScreens() }
        reconcileWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reconcileDebounce, execute: workItem)
    }

    /// Rebuilds or updates every display's panel from the current `NSScreen.screens`, and retires panels
    /// for displays that vanished. See this type's documentation for the full contract.
    private func reconcileScreens() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        var liveDisplays: Set<NotchDisplayID> = []
        for screen in screens {
            guard let display = NotchScreenAdapter.displayID(for: screen) else { continue }
            liveDisplays.insert(display)
            let metrics = NotchScreenAdapter.metrics(for: screen)
            let layout = NotchGeometry.layout(for: metrics, expandedSize: Self.expandedSize)
            if let existing = displayPanels[display] {
                updateGeometry(display: display, existing: existing, layout: layout)
            } else {
                displayPanels[display] = makePanel(for: display, layout: layout)
            }
            // Recomputed here, after `displayPanels[display]` is guaranteed to exist for both branches
            // above: `makePanel(for:layout:)`'s own call to `updateViewModel(for:)` runs before its caller
            // (this loop) has actually stored the new `DisplayPanel` back into `displayPanels`, so that
            // call's `updateContainerVisibility(display:)` is a silent no-op on a brand-new panel — leaving
            // its container at AppKit's default `alphaValue` of `1.0` instead of already-hidden if this
            // display defaults to a notchless, pill-hidden collapsed panel. `updateGeometry`'s layoutKind
            // reassignment (a notched↔pill reclassification) needs the same recompute on every reconcile
            // pass regardless, since that can flip which branch of ``updateContainerVisibility(display:)``
            // applies with no `NotchEvent` of its own to trigger it.
            updateContainerVisibility(display: display)
            // A display that is live again after having been suspended (screen unplugged, then replugged;
            // or the whole machine slept and woke while this display briefly dropped out of
            // `NSScreen.screens`) must be told to `resume` here: `handleSuspend` leaves the reducer's entry
            // parked in `.suspended` forever, and that state ignores every event but `resume` (see
            // `NotchInteractionReducer.reduce(_:)`), so nothing else would ever revive it.
            if case .suspended = reducer.panels[display]?.presentation {
                send(.resume(display))
            }
        }

        for display in displayPanels.keys where !liveDisplays.contains(display) {
            send(.suspend(display))
            executor.teardownDisplay(display)
            displayPanels[display]?.panel.orderOut(nil)
            displayPanels.removeValue(forKey: display)
            collapsedScreenFrames.removeValue(forKey: display)
        }
    }

    /// Builds a brand-new panel, hover view and view model for `display`, and registers it with the
    /// executor.
    private func makePanel(for display: NotchDisplayID, layout: NotchLayout) -> DisplayPanel {
        let viewModel = NotchDisplayViewModel()
        viewModel.layoutKind = layout.kind
        viewModel.notchRect = notchRect(for: layout)
        viewModel.expandedSize = layout.expandedFrame.size
        collapsedScreenFrames[display] = layout.collapsedFrame
        let hostingView = NSHostingView(
            rootView: NotchContentView(
                viewModel: viewModel,
                herdModel: herdModel,
                caffeinateService: caffeinateService,
                keepAwakeService: keepAwakeService,
                lidSleepController: lidSleepController,
                powerInfoService: powerInfoService,
                usageService: usageService,
                remindersService: remindersService,
                spotifyService: spotifyService,
                systemNowPlayingService: systemNowPlayingService,
                batteryService: batteryService,
                shelfService: shelfService,
                searchKeyNav: searchKeyNav,
                onEscape: { [weak self] in self?.send(.escape(display)) },
                onOpenSettings: { [weak self] in self?.onOpenSettings?() },
                onDragBegan: { [weak self] in self?.send(.dragBegan(display)) },
                onDragEnded: { [weak self] in self?.sendDragEnded(display) },
                onSelectAgent: { [weak self] session, agent in
                    self?.onSelectAgent?(session, agent)
                    self?.send(.escape(display))
                }
            )
        )

        let panel = NotchPanel(expandedFrame: layout.expandedFrame, content: hostingView)
        panel.searchKeyNav = searchKeyNav
        panel.onScrollMomentumBegan = { [weak self] in self?.send(.scrollMomentumBegan(display)) }
        panel.onScrollMomentumEnded = { [weak self, weak panel] in
            guard let panel else { return }
            self?.send(.scrollMomentumEnded(display, pointerInside: panel.frame.contains(NSEvent.mouseLocation)))
        }

        let hoverView = NotchHoverView(frame: localRect(layout.collapsedFrame, in: layout.expandedFrame))
        hoverView.onMouseEntered = { [weak self] in self?.send(.hoverIntent(display)) }
        hoverView.onClick = { [weak self] in self?.send(.click(display)) }
        hoverView.onFileDragEntered = { [weak self] in self?.send(.fileDragEntered(display)) }
        hoverView.onFileDragEnded = { [weak self] in self?.sendDragEnded(display) }
        hoverView.onFileDrop = { [weak self] urls in self?.shelfService.add(urls) }
        panel.containerView.addSubview(hoverView)

        executor.configureDisplay(
            display,
            panel: panel,
            collapsedFrame: localRect(layout.collapsedFrame, in: layout.expandedFrame),
            collapsedCornerRadius: collapsedCornerRadius(for: layout),
            expandedFrameScreen: layout.expandedFrame,
            expandedCornerRadius: layout.cornerRadius,
            presentation: reducer.panels[display]?.presentation ?? .collapsed
        )

        panel.orderFrontRegardless()
        updateViewModel(for: display)
        return DisplayPanel(panel: panel, hoverView: hoverView, viewModel: viewModel)
    }

    /// Applies a freshly computed `layout` to an already-existing panel: repositions the fixed window
    /// frame if the display's geometry actually changed, repositions the hover view, and re-registers the
    /// geometry with the executor (which snaps the mask to the correct resting frame with no animation —
    /// see `NotchCommandExecutor.configureDisplay`).
    private func updateGeometry(display: NotchDisplayID, existing: DisplayPanel, layout: NotchLayout) {
        if existing.panel.frame != layout.expandedFrame {
            existing.panel.setFrame(layout.expandedFrame, display: true)
        }
        existing.viewModel.layoutKind = layout.kind
        existing.viewModel.notchRect = notchRect(for: layout)
        existing.viewModel.expandedSize = layout.expandedFrame.size
        collapsedScreenFrames[display] = layout.collapsedFrame
        existing.hoverView.frame = localRect(layout.collapsedFrame, in: layout.expandedFrame)
        executor.configureDisplay(
            display,
            panel: existing.panel,
            collapsedFrame: localRect(layout.collapsedFrame, in: layout.expandedFrame),
            collapsedCornerRadius: collapsedCornerRadius(for: layout),
            expandedFrameScreen: layout.expandedFrame,
            expandedCornerRadius: layout.cornerRadius,
            presentation: reducer.panels[display]?.presentation ?? .collapsed
        )
    }

    /// Translates a screen-coordinate rect into the panel's local (bottom-left-origin) coordinate space,
    /// given the window's own screen-coordinate frame.
    private func localRect(_ rect: CGRect, in windowFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.minX - windowFrame.minX,
            y: rect.minY - windowFrame.minY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Derives ``NotchDisplayViewModel/notchRect`` from a freshly computed `layout`, in the SwiftUI
    /// content view's own top-left-origin coordinate space.
    ///
    /// For ``NotchKind/notched``, this is the real camera-housing cutout `NotchGeometry` already computed
    /// as `layout.collapsedFrame` (screen coordinates), converted the same first step
    /// ``makePanel(for:layout:)``/``updateGeometry(display:existing:layout:)`` already apply to build
    /// `NotchHoverView`'s own frame — ``localRect(_:in:)``, into the window's bottom-left-origin local
    /// space — then flipped to SwiftUI's top-left origin by measuring from the panel's own height, since
    /// both frames share the same physical top edge (`NotchGeometry.layout(for:expandedSize:)` pins both
    /// `collapsedFrame` and `expandedFrame` to `metrics.frame.maxY`).
    ///
    /// For ``NotchKind/pill``, the "collapsed frame" is a synthesized capsule sized to the menu bar, not a
    /// real cutout — the design spec is explicit that the dead zone should fall back to
    /// ``NotchDisplayViewModel/fallbackRect(panelWidth:)`` in that case rather than reserve space shaped like a UI
    /// element that is not actually there.
    ///
    /// - Parameter layout: The layout just computed for this display.
    /// - Returns: The rect in SwiftUI top-left coordinates.
    private func notchRect(for layout: NotchLayout) -> CGRect {
        guard layout.kind == .notched else {
            return NotchDisplayViewModel.fallbackRect(panelWidth: layout.expandedFrame.width)
        }
        let local = localRect(layout.collapsedFrame, in: layout.expandedFrame)
        return CGRect(
            x: local.minX,
            y: layout.expandedFrame.height - local.maxY,
            width: local.width,
            height: local.height
        )
    }

    /// The collapsed pill's corner radius for a given layout: sharp corners (`0`) for a real notch cutout,
    /// since it has to exactly match a physical rectangle with no rounding of its own; a capsule (half the
    /// pill's own height) for a synthesized pill. `NotchGeometry.NotchLayout` does not carry this value
    /// itself — see that type's documentation for why — so it is derived here from `layout.kind` instead.
    private func collapsedCornerRadius(for layout: NotchLayout) -> CGFloat {
        switch layout.kind {
        case .notched: return 0
        case .pill: return layout.collapsedFrame.height / 2
        }
    }

    // MARK: - Lifecycle notifications

    @objc private func workspaceWillSleep() {
        for display in displayPanels.keys {
            send(.suspend(display))
        }
    }

    @objc private func workspaceDidWake() {
        for display in displayPanels.keys {
            send(.resume(display))
        }
    }

    @objc private func activeSpaceChanged() {
        for display in displayPanels.keys {
            send(.escape(display))
        }
    }
}
