import AppKit
import Combine
import HerdHotKey
import HerdHost
import HerdKit
import HerdShortcut

/// Wires the four long-lived objects together and owns them for the process lifetime.
///
/// Deliberately the only place that knows about all of them: the model does not know there is a
/// status item, the status item does not know there is a popover, and ``HerdListView`` does not know
/// there is an app. That is what lets the list view lift into the boringNotch fork unchanged.
///
/// Thread-safety: `NSApplicationDelegate` is main-actor isolated by the SDK, and everything held here
/// is main-actor isolated too.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Settings, shared by the model, the menu and the focus service.
    private let preferences = HerdPreferences()

    /// Notification sender, owned by the model but created here because it needs authorization at
    /// launch, before the first poll.
    private let notifier = HerdBlockedNotifier()

    /// The polling model.
    private lazy var model = HerdBarModel(preferences: preferences, notifier: notifier)

    /// Focuses agents in response to row clicks.
    private lazy var focusService = HerdFocusService(preferences: preferences)

    /// The popover.
    private lazy var panel = HerdPanel(
        model: model,
        preferences: preferences,
        onSelectAgent: { [weak self] session, agent in
            self?.focusAgent(agent, in: session)
        },
        onSelectSession: { [weak self] session in
            self?.focusService.focus(session: session)
        },
        onSelectWorkspace: { [weak self] session, workspace in
            self?.focusService.focus(workspace: workspace, in: session)
        },
        // The status item defers its own width changes while the panel is anchored to it, because
        // relayouting the menu bar under an open popover is what made the panel sometimes appear far to
        // the left. This is the nudge that applies the deferred width the moment the panel is gone.
        onDidClose: { [weak self] in self?.statusItem?.refresh() }
    )

    /// The pane search window, opened by the global hotkey and by the status item menu.
    private lazy var searchWindow = HerdSearchWindow(model: model) { [weak self] session, agent in
        self?.focusAgent(agent, in: session)
    }

    /// The system-wide shortcut that opens ``searchWindow``.
    ///
    /// The log line is not decoration. This process cannot be screenshotted from outside and the shortcut is
    /// delivered by the window server, so the only evidence available that a key press reached the app at
    /// all is a line on standard error. It is what made verifying the `F19` binding possible without a
    /// finger on a keyboard.
    private lazy var searchHotKey = HerdGlobalHotKey { [weak self] in
        FileHandle.standardError.write(Data("herd: search shortcut fired\n".utf8))
        self?.searchWindow.toggle()
    }

    /// What the interface is allowed to say about that shortcut: which one, and whether it took.
    private let hotKeyStatus = HerdHotKeyStatus()

    /// The settings window.
    private lazy var settingsWindow = HerdSettingsWindow(
        preferences: preferences,
        hotKeyStatus: hotKeyStatus,
        roster: model.roster
    )

    /// Keeps the preferences subscription alive.
    private var preferencesObserver: AnyCancellable?

    /// The self-dismissing panel shown on notable transitions.
    private let transientPopup = HerdTransientPopup()

    /// The menu bar item. Created in `applicationDidFinishLaunching` so it appears only once the app
    /// is genuinely up.
    private var statusItem: HerdStatusItem?

    /// Installs the status item and starts polling.
    ///
    /// The activation policy is set in code as well as via `LSUIElement` in the Info.plist. Belt and
    /// braces: the plist is what LaunchServices reads when the bundle is opened normally, and the code
    /// path is what keeps a Dock icon away during a bare `swift run` from the terminal.
    ///
    /// - Parameter notification: Unused; required by the delegate protocol.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = HerdStatusItem(
            model: model,
            preferences: preferences,
            hotKeyStatus: hotKeyStatus,
            onOpenSearch: { [weak self] in self?.searchWindow.toggle() },
            onOpenSettings: { [weak self] in self?.settingsWindow.show() }
        ) { [weak self] in
            guard let self, let anchor = self.statusItem?.anchorView else { return }
            // Opening the real panel supersedes any transient hint, so retire it rather than leave
            // the two overlapping under the same status item.
            self.transientPopup.dismiss()
            self.panel.toggle(relativeTo: anchor)
        }

        applySearchShortcut()

        // One subscription covers every live-apply. Most settings need nothing beyond having been stored,
        // because the model re-reads preferences on each tick and the views are bound straight through; the
        // three that need more are the shortcut (Carbon has to be told), the paused glyph (published only
        // by a poll, which does not happen while polling is off) and anything that changes *what is
        // discovered*, which has to re-poll rather than wait out the idle back-off.
        //
        // `objectWillChange` fires before the value is written, so the work hops to the next main-actor turn
        // and reads the new value. The same pattern the status item already uses for the model.
        preferencesObserver = preferences.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.preferencesDidChange() }
        }

        model.onTransitions = { [weak self] transitions in
            guard let self, self.preferences.showsPopup else { return }
            // Suppressed while the real panel is open: the user is already looking at the rows the
            // popup would be summarising.
            guard !self.panel.isShown else { return }
            self.transientPopup.present(
                transitions,
                anchor: self.statusItem?.anchorView,
                duration: self.preferences.popupDuration
            )
        }

        notifier.requestAuthorization()
        model.start()
        openForCaptureIfRequested()
    }

    /// Claims the configured shortcut and records whether Carbon accepted it.
    ///
    /// Called at launch and again whenever the preference changes, which is what makes a rebind take effect
    /// without a relaunch. Carbon holds the previous claim until it is released, and ``HerdGlobalHotKey``
    /// releases it inside `register`, so there is no window in which both the old and new shortcut are live.
    ///
    /// The outcome goes into ``hotKeyStatus`` rather than only to standard error. That is the whole of the
    /// "failures must be visible" requirement: a user who launches the bundle from the Finder never sees
    /// stderr, so the previous build's response to a shortcut another app already owned was silence.
    private func applySearchShortcut() {
        let shortcut = preferences.searchShortcut
        let registered = searchHotKey.register(shortcut)
        hotKeyStatus.record(shortcut: shortcut, registered: registered)
        statusItem?.refresh()
        // Logged on success as well as failure. Which shortcut is live is the one piece of this app's state
        // that has no on-screen home while the settings window is shut, and the log line is what made a
        // rebind verifiable without a finger on a keyboard.
        FileHandle.standardError.write(
            Data("herd: shortcut \(shortcut.displayName) registered: \(registered)\n".utf8)
        )
    }

    /// Applies the parts of a settings change that need more than a stored value.
    ///
    /// Deliberately cheap and idempotent, because it runs on every single preference write, including each
    /// keystroke in the remote-paths editor. The shortcut is only re-registered when it actually differs,
    /// since re-registering unconditionally would drop and reclaim the hot key on every keystroke.
    private func preferencesDidChange() {
        if preferences.searchShortcut != hotKeyStatus.shortcut {
            applySearchShortcut()
        }
        // The paused marker is the one piece of the roll-up a poll cannot refresh, because turning polling
        // off is exactly what stops the polls.
        statusItem?.refresh()
        // Adding a forwarded socket path or widening the session filter changes what is discovered, and
        // waiting out the five-second idle back-off to find out whether a path was right is the difference
        // between a setting that feels live and one that feels broken.
        model.refreshNow()
    }

    /// Opens a surface on its own so the capture harness can photograph it.
    ///
    /// Screen Recording is denied to this process, so nothing outside it can see the interface; the
    /// only way to look at the work is to render a view to a PNG from inside, and the panel and the
    /// search window both need to be open before there is anything to render. A real user opens them by
    /// clicking or by the global shortcut, neither of which a script can do, hence this.
    ///
    /// Costs two environment lookups at launch and nothing else.
    private func openForCaptureIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        // Delayed so the first poll has landed: capturing an empty snapshot would photograph the
        // "looking for herdr sessions" banner rather than the rows.
        if environment["HERDBAR_DUMP"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, let anchor = self.statusItem?.anchorView else { return }
                self.panel.toggle(relativeTo: anchor)
            }
        }
        // Separate from `HERDBAR_SEARCH_DUMP`, which only says where to write: leaving them as one
        // variable made it impossible to test the global shortcut, because the only way to get a
        // capture was to have already opened the window some other way.
        // Fixture captures need no herdr at all and no popover, so they run immediately and the process
        // exits: there is nothing to wait for and leaving a status item behind would be confusing.
        if let directory = environment["HERDBAR_FIXTURE_DUMP"] {
            HerdDebugCapture.writeFixtures(
                into: directory,
                recentlyCompleted: [
                    HerdUrgencyOrder.key(sessionName: "hail_mary", paneId: "w1:p4")
                ]
            )
            exit(0)
        }
        if environment["HERDBAR_SEARCH_OPEN"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.searchWindow.toggle()
            }
        }
        // Either variable opens the window: one asks for a capture of it, the other asks to drive its
        // shortcut recorder, and both are useless without it on screen.
        if environment["HERDBAR_SETTINGS_DUMP"] != nil || environment["HERDBAR_SETTINGS_RECORD"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.settingsWindow.show()
            }
        }
    }

    /// Focuses a pane and says so, whichever surface asked for it.
    ///
    /// The confirmation is not decoration. A herdr session is a headless server, so a session can be
    /// running with agents working while no terminal is attached to it; the three focus calls all
    /// succeed, the terminal comes forward showing a different session, and the click looks like it did
    /// nothing. Attachment is not detectable from outside herdr, so naming the session the focus landed
    /// in is the honest substitute: it turns silence into a fact the user can act on. The remedy,
    /// `herdr session attach <name>`, is in the row's tooltip.
    ///
    /// Gated on the same preference as the transition popup, since it is the same surface and a user
    /// who turned that off has said they do not want panels appearing under the menu bar.
    ///
    /// - Parameters:
    ///   - agent: The agent to focus.
    ///   - session: Its owning session.
    private func focusAgent(_ agent: HerdAgent, in session: HerdSession) {
        panel.close()
        focusService.focus(agent: agent, in: session)
        guard preferences.showsPopup, session.running else { return }
        transientPopup.confirmFocus(
            identifier: agent.displayIdentifier,
            sessionName: session.name,
            anchor: statusItem?.anchorView,
            duration: preferences.popupDuration
        )
    }

    /// Stops the poll loop so the process does not exit from inside a socket read.
    ///
    /// - Parameter notification: Unused; required by the delegate protocol.
    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        searchHotKey.unregister()
        statusItem?.remove()
    }
}
