import AppKit
import Combine
import HerdHost
import HerdHotKey
import HerdShortcut
import NotchCore

// Process entry point.
//
// Explicit `NSApplication` setup rather than `@main` on a SwiftUI `App`, for the same reason
// `BoringHerdBar/main.swift` uses one: there is no Xcode on this machine, so this file is the whole launch
// sequence and is worth being readable in one screen. `NSApp.setActivationPolicy(.accessory)` is called
// here directly (belt-and-braces alongside `LSUIElement` in the bundled `Info.plist`) so a bare `swift run`
// during development still behaves like an accessory app with no Dock icon, exactly the same reasoning
// `BoringHerdBar` documents for its own delegate.

/// The composition root's app delegate: owns the one `NotchWindowController` for the process, and a debug
/// menu-bar status item so the shell is testable without the fn-fn hotkey, which does not exist until
/// Phase 2.
///
/// The debug menu maps onto the reducer's own vocabulary rather than inventing a parallel "just show it"
/// code path: "Expand" sends `NotchEvent.click(_:)` (an explicit, decisive gesture the reducer already
/// treats as skipping the hover debounce) and "Collapse" sends `NotchEvent.escape(_:)` (the reducer's own
/// immediate, lock-respecting dismissal), both targeting whichever display currently has the pointer. This
/// keeps the debug affordance itself honest: it cannot do anything a real gesture could not already do
/// through `NotchWindowController.send(_:)`.
@MainActor
private final class NotchAppDelegate: NSObject, NSApplicationDelegate {
    /// Every configurable value `BoringHerdBar` also exposes: the search shortcut, the poll interval, the
    /// watch on/off switch, the session filter, remote paths and the rest of `HerdPreferences` (from
    /// `HerdHost`). One instance, shared by ``windowController`` (via its poller), ``focusService`` and
    /// ``settingsWindow``, the same "one source of truth" shape `BoringHerdBar/AppDelegate.preferences`
    /// documents. `NotchPreferences.shared` is unrelated and untouched: it holds the one notch-specific
    /// setting (``NotchPreferences/showCollapsedPill``) this store has no business knowing about.
    private let preferences = HerdPreferences()

    /// The single controller owning every display's panel and the shared reducer. `lazy` because its
    /// initializer reads ``preferences``, another instance property, which a plain stored property's
    /// initializer cannot do before `self` exists.
    private lazy var windowController = NotchWindowController(preferences: preferences)

    /// Held for the process lifetime; an `NSStatusItem` is removed from the menu bar if its owning object
    /// is deallocated.
    private var statusItem: NSStatusItem?

    /// The "Show Pill (notchless)" menu item, held so its checkmark can be kept in sync with
    /// ``NotchPreferences/showCollapsedPill`` after ``debugToggleShowPill()`` flips it.
    private var showPillMenuItem: NSMenuItem?

    /// Focuses an agent's pane in herdr and raises its terminal, reusing `HerdHost`'s implementation
    /// rather than reimplementing the herdr focus/raise sequence a third time. `lazy` because its default
    /// value references ``preferences``, another instance property, which a plain stored property's
    /// initializer cannot do before `self` exists.
    private lazy var focusService = HerdFocusService(preferences: preferences)

    /// Live registration state of ``preferences``'s search shortcut, the same "what the interface is
    /// allowed to say about it" object `BoringHerdBar/AppDelegate.hotKeyStatus` uses, and shown in the
    /// settings window the same way.
    private let hotKeyStatus = HerdHotKeyStatus()

    /// HerdNotch's merged settings window: the notch's own interaction/appearance/battery knobs
    /// (``NotchPreferences``) as its "HerdNotch" tab, and the shared herd-data form — the shortcut, the
    /// watch switch, the poll interval, the panel text size, the session filter, the terminal override and
    /// the remote paths, every setting `BoringHerdBar`'s own settings window edits, on the same
    /// `HerdPreferences` instance ``windowController``'s poller and ``herdHotKey`` already read — as its
    /// "Herd Data" tab. `lazy` because its default value references several other instance properties.
    /// `windowController.herdModel.roster` (not a roster of its own) so the session list the "Herd Data"
    /// tab offers reflects the notch's own discovery rather than a second, separate one. This is what the
    /// notch's settings gear and the status item's "Settings…" item both open.
    private lazy var notchSettingsWindow = NotchSettingsWindow(
        notchPreferences: NotchPreferences.shared,
        herdPreferences: preferences,
        hotKeyStatus: hotKeyStatus,
        roster: windowController.herdModel.roster
    )

    /// Keeps the preferences subscription alive.
    private var preferencesObserver: AnyCancellable?

    /// The system-wide shortcut that opens the notch's own in-card agent search.
    ///
    /// **No longer opens a separate `HerdSearchWindow`** — a floating window duplicated the notch's own
    /// agents hero card for no reason once that card could hold a search mode of its own, and it could
    /// never be reached by `Tab`-cycling out of the notch panel the way an in-panel field can. `HerdSearchWindow`
    /// itself is untouched and still what `BoringHerdBar`'s own fn-fn opens; this app's copy of the type is
    /// simply unused now.
    ///
    /// Sends `NotchEvent.hotkeyToggle(_:)` for whichever display is under the pointer (the same lookup the
    /// debug menu already uses — see ``NotchWindowController/debugTargetDisplay()``), for the reducer to
    /// expand, collapse or retarget exactly as a click on that display's own pill would (see
    /// `NotchInteractionReducer.handleHotkeyToggle(display:panel:)`). `NotchWindowController.send(_:)`'s own
    /// key-window contract is what turns a `.hotkey`-triggered expand into a keyed, search-mode-entering
    /// open; this closure only has to name the display and the trigger.
    ///
    /// `lazy` (rather than a plain `let`) because its closure captures `self`, which is unavailable to a
    /// stored property's default-value expression before `self` exists — the same reason
    /// `BoringHerdBar/AppDelegate.searchHotKey` is `lazy`. Held for the process lifetime, since Carbon
    /// holds the registration only as long as this object is alive.
    private lazy var herdHotKey = HerdGlobalHotKey { [weak self] in
        FileHandle.standardError.write(Data("herdnotch: search shortcut fired\n".utf8))
        guard let self, let display = self.windowController.debugTargetDisplay() else { return }
        self.windowController.send(.hotkeyToggle(display))
    }

    /// The caffeinate toggle, bound to **Control+Shift+C** (see `HerdShortcut.caffeinateToggle`), an ordinary
    /// chord Carbon claims directly with no Karabiner relay. Replaced the old double-tap-Control relay, which
    /// collided with macOS 26 Apple Intelligence voice typing. No settings-window override. `lazy`, same
    /// reason as ``herdHotKey``: its closure captures `self`.
    private lazy var caffeinateHotKey = HerdGlobalHotKey { [weak self] in
        self?.windowController.toggleKeepAwake()
    }

    /// The "Caffeinate" status-item menu item, held so its checkmark can be kept in sync with
    /// `NotchWindowController.caffeinateService.isActive` after every toggle, the same "held for live
    /// updates" reason ``showPillMenuItem`` is held.
    private var caffeinateMenuItem: NSMenuItem?

    /// Keeps ``caffeinateMenuItem``'s checkmark in step with `windowController.caffeinateService.isActive`,
    /// including toggles that did not originate from this menu item at all (the Control+Shift+C hotkey, or the
    /// notch's own home-surface toggle).
    private var caffeinateObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMinimalAppMenu()
        // Wired before `start()`, though no panel exists yet to use it either way: this is the one place
        // `windowController.onOpenSettings` is ever assigned, and doing it here rather than scattered near
        // `settingsWindow`'s own declaration keeps every one-time launch wiring step in this one method.
        windowController.onOpenSettings = { [weak self] in self?.notchSettingsWindow.show() }
        // Wired for the same reason and at the same point as `onOpenSettings` just above: this is the one
        // place `windowController.onSelectAgent` is ever assigned. Collapsing the panel afterward is
        // `windowController`'s own job, not this closure's — see its `onSelectAgent` documentation.
        windowController.onSelectAgent = { [weak self] session, agent in
            self?.focusService.focus(agent: agent, in: session)
        }
        // A click that finds no host must not look ignored.
        focusService.onJumpOutcome = { _, outcome in
            if outcome == .cannotLocate { NSSound.beep() }
        }
        windowController.start()
        installDebugStatusItem()
        applySearchShortcut()
        applyCaffeinateShortcut()

        // Mirrors `BoringHerdBar/AppDelegate`'s one subscription: `objectWillChange` fires before the
        // value is written, so the work hops to the next main-actor turn and reads the new value.
        preferencesObserver = preferences.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.preferencesDidChange() }
        }
        caffeinateObserver = windowController.caffeinateService.$isActive.sink { [weak self] active in
            Task { @MainActor in self?.caffeinateMenuItem?.state = active ? .on : .off }
        }
    }

    /// Releases the caffeinate assertion before the process exits, so quitting HerdNotch while it is holding
    /// one never leaves the machine unable to idle-sleep. This is the teardown path that actually matters —
    /// see `CaffeinateService.deinit`'s own documentation for why a `deinit` on an object held for the whole
    /// process lifetime is not something to rely on for this.
    func applicationWillTerminate(_ notification: Notification) {
        windowController.shutdown()
    }

    /// Installs a minimal `NSApp.mainMenu` with nothing in it but a "Quit HerdNotch" item bound to Cmd-Q.
    ///
    /// An `LSUIElement`/accessory app has no menu bar of its own, but `NotchPanel` is a `.nonactivatingPanel`
    /// that becomes key on a deliberate click (see `NotchWindowController.send(_:)`'s key-window contract)
    /// **without** activating this app — the whole point of that style is that it can hold keyboard focus
    /// over a full-screen app without ejecting it. `-[NSApplication sendEvent:]` still checks `self.mainMenu`
    /// for a Command-key event's key-equivalent *before* forwarding it to the key window, and it does this
    /// regardless of `NSApp.isActive`, because the event was already delivered to this process's queue by
    /// the window server (which routes keyboard input to whichever window is key, not whichever app is
    /// frontmost). Without a `mainMenu` at all there is nothing for that check to find, so Cmd-Q while the
    /// panel is key would silently do nothing — neither closing the panel nor quitting the app. This one-item
    /// menu is what gives Cmd-Q an actual quit action to hit, matching every other Mac app's ordinary Cmd-Q
    /// behaviour rather than inventing a notch-specific meaning for it (an earlier version of this fix had
    /// Cmd-Q close the panel instead of quitting; that was reverted precisely because it is not what Cmd-Q
    /// means anywhere else).
    private func installMinimalAppMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit HerdNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    /// Claims ``HerdShortcut/caffeinateToggle`` and logs whether Carbon accepted it, mirroring
    /// ``applySearchShortcut()`` — this shortcut has no settings-window override to re-apply on a
    /// preference change, so this is called exactly once, at launch.
    private func applyCaffeinateShortcut() {
        let registered = caffeinateHotKey.register(.caffeinateToggle)
        let shortcutName = HerdShortcut.caffeinateToggle.displayName
        FileHandle.standardError.write(
            Data("herdnotch: caffeinate shortcut \(shortcutName) registered: \(registered)\n".utf8)
        )
    }

    /// Claims the configured shortcut and records whether Carbon accepted it.
    ///
    /// Called at launch and again whenever the preference changes, mirroring
    /// `BoringHerdBar/AppDelegate.applySearchShortcut()` exactly, down to the standard-error log line:
    /// this process cannot be screenshotted either, so a launched-from-Finder rebind has the same "no
    /// on-screen home while the window is shut" problem `BoringHerdBar` already solved by recording the
    /// outcome in ``hotKeyStatus``.
    private func applySearchShortcut() {
        let shortcut = preferences.searchShortcut
        let registered = herdHotKey.register(shortcut)
        hotKeyStatus.record(shortcut: shortcut, registered: registered)
        FileHandle.standardError.write(
            Data("herdnotch: shortcut \(shortcut.displayName) registered: \(registered)\n".utf8)
        )
    }

    /// Applies the parts of a settings change that need more than a stored value: re-registering the
    /// shortcut when it actually differs, and re-polling so a watch-switch flip, a session-filter edit or
    /// a remote-path change is visible immediately rather than up to ``NotchHerdModel``'s idle back-off
    /// later. Mirrors `BoringHerdBar/AppDelegate.preferencesDidChange()`.
    private func preferencesDidChange() {
        if preferences.searchShortcut != hotKeyStatus.shortcut {
            applySearchShortcut()
        }
        windowController.herdModel.refreshNow()
    }

    /// Builds a plain "Expand / Collapse / Quit" menu under an SF Symbol status item, the tiny debug
    /// affordance the change plan calls for so this shell can be exercised without a hotkey.
    private func installDebugStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "menubar.rectangle", accessibilityDescription: "HerdNotch"
        )
        let menu = NSMenu()
        menu.addItem(
            withTitle: "Expand", action: #selector(debugExpand), keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: "Collapse", action: #selector(debugCollapse), keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        // Debug affordance for the Phase 2 pill-visibility preference: a notchless display's collapsed
        // pill is transparent by default (`NotchPreferences.showCollapsedPill == false`), and this is the
        // only way to see it without editing `UserDefaults` by hand. `NotchContentView` already observes
        // `NotchPreferences.shared` as an `ObservedObject`, so flipping it here repaints every open panel
        // live with no separate "refresh" call needed.
        let pillItem = menu.addItem(
            withTitle: "Show Pill (notchless)", action: #selector(debugToggleShowPill), keyEquivalent: ""
        )
        pillItem.target = self
        pillItem.state = NotchPreferences.shared.showCollapsedPill ? .on : .off
        showPillMenuItem = pillItem
        menu.addItem(.separator())
        // The caffeinate toggle, mirrored from the same `caffeinateService` the notch's own home-surface
        // button and the Ctrl-Ctrl hotkey drive, so all three ways of flipping it agree on the current state.
        let caffeinateItem = menu.addItem(
            withTitle: "Caffeinate", action: #selector(debugToggleCaffeinate), keyEquivalent: ""
        )
        caffeinateItem.target = self
        caffeinateItem.state = windowController.caffeinateService.isActive ? .on : .off
        caffeinateMenuItem = caffeinateItem
        menu.addItem(
            withTitle: "Reminders", action: #selector(debugOpenReminders), keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: "Spotify", action: #selector(debugOpenSpotify), keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        // Opens `notchSettingsWindow`: the notch's own interaction/appearance/battery knobs as one tab and
        // the reused `HerdSettingsView` as the other, so every preference this app has (its own and the
        // ones shared with `BoringHerdBar`) is reachable without editing `UserDefaults` by hand.
        menu.addItem(
            withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit HerdNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        )
        item.menu = menu
        statusItem = item
    }

    @objc private func debugExpand() {
        guard let display = windowController.debugTargetDisplay() else { return }
        windowController.send(.click(display))
    }

    @objc private func debugCollapse() {
        guard let display = windowController.debugTargetDisplay() else { return }
        windowController.send(.escape(display))
    }

    /// Toggles the caffeinate assertion. ``caffeinateObserver`` keeps ``caffeinateMenuItem``'s checkmark in
    /// step, so this method itself only needs to forward the click.
    @objc private func debugToggleCaffeinate() {
        windowController.toggleKeepAwake()
    }

    /// Expands the pointer's display, then routes it to `NotchRoute/reminders` — the same two-event sequence
    /// as ``debugExpand()`` followed by a `route(_:)`, since a `route(_:)` sent to a still-collapsed panel
    /// is a documented no-op (see `NotchInteractionReducer.handleRoute(_:panel:)`): the `click` has to land
    /// first so the panel is at least `expanding` by the time the route event arrives.
    @objc private func debugOpenReminders() {
        guard let display = windowController.debugTargetDisplay() else { return }
        windowController.send(.click(display))
        windowController.send(.route(display, .reminders))
    }

    /// Expands the pointer's display, then routes it to `NotchRoute/spotify`. Mirrors
    /// ``debugOpenReminders()`` exactly; see that method's documentation for why the `click` has to be sent
    /// first.
    @objc private func debugOpenSpotify() {
        guard let display = windowController.debugTargetDisplay() else { return }
        windowController.send(.click(display))
        windowController.send(.route(display, .spotify))
    }

    /// Flips ``NotchPreferences/showCollapsedPill`` and keeps the menu's checkmark in step with it.
    @objc private func debugToggleShowPill() {
        NotchPreferences.shared.showCollapsedPill.toggle()
        showPillMenuItem?.state = NotchPreferences.shared.showCollapsedPill ? .on : .off
    }

    /// Shows ``notchSettingsWindow``.
    @objc private func openSettings() {
        notchSettingsWindow.show()
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate: NSApplicationDelegate = NotchAppDelegate()
application.delegate = delegate
application.run()
