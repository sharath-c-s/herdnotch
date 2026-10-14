import AppKit
import Combine
import HerdHotKey
import HerdHost
import HerdKit
import HerdPanelUI
import SwiftUI

/// The menu bar roll-up: coloured dots with counts.
///
/// This is feature 4 relocated from the collapsed notch to the status item, which is arguably the
/// better home: it is always visible and never has to fight the music player for the slot.
///
/// Rendered in SwiftUI and hosted in the status item's button so the dots use exactly the same
/// ``AgentStatus/tint`` as the list rows. Two surfaces drawing the same colour from the same source
/// cannot drift apart.
private struct HerdRollUpView: View {
    /// Pre-aggregated counts from the snapshot. Never recomputed here.
    let counts: StatusCounts

    /// Whether to replace the counts with a warning glyph, used when herdr is unreachable and the
    /// numbers would be a lie.
    let isDegraded: Bool

    /// Whether polling is switched off, which shows a paused glyph rather than zeroes.
    let isPaused: Bool

    /// Drives the palette from the menu bar's own appearance.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = HerdPalette.resolving(colorScheme)
        return HStack(spacing: 5) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 11, weight: .medium))
            if isPaused {
                Image(systemName: "pause.fill").font(.system(size: 9))
            } else if isDegraded {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(palette.blocked)
            } else {
                // The red and green dots appear only when they have something to say, so the common case
                // (nothing waiting on you, nothing just finished) stays visually quiet and the alarm
                // colours are never ambient. Working and idle are always shown, because their counts are
                // the ambient reading this item exists to give.
                if counts.blocked > 0 { dot(.blocked, counts.blocked, palette) }
                if counts.done > 0 { dot(.done, counts.done, palette) }
                dot(.working, counts.working, palette)
                dot(.idle, counts.idle, palette)
                if counts.unknown > 0 { dot(.unknown, counts.unknown, palette) }
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 5)
    }

    /// One dot and its count.
    ///
    /// Uses the panel's own tokens so the menu bar and the popover agree about what each hue means.
    /// `unknown`, the one status with no accent, draws a hollow ring rather than borrowing a colour, which
    /// is the same rule the rows follow.
    ///
    /// The count reserves the width of two digits and uses `monospacedDigit`, so going from 9 to 10
    /// agents neither reflows the row nor nudges the neighbouring menu bar items.
    ///
    /// - Parameters:
    ///   - status: Status to draw.
    ///   - value: Number of agents in that status.
    ///   - palette: Tokens for the menu bar's current appearance.
    private func dot(_ status: AgentStatus, _ value: Int, _ palette: HerdPalette) -> some View {
        HStack(spacing: 3) {
            Group {
                if let accent = palette.accent(for: status) {
                    Circle().fill(accent)
                } else {
                    // `.secondary` rather than a fixed hairline: the menu bar's backdrop is the
                    // desktop, so an idle ring has to stay legible over an arbitrary wallpaper.
                    Circle().strokeBorder(Color.secondary, lineWidth: 1)
                }
            }
            .frame(width: 6, height: 6)
            Text("\(value)")
                .monospacedDigit()
                .frame(minWidth: 13, alignment: .leading)
        }
    }
}

/// Owns the `NSStatusItem`: its content, its click behaviour and its right-click menu.
///
/// Placement is the whole reason this app exists in this shape. An `NSStatusItem` is positioned by
/// the OS, so it cannot collide with boringNotch's notch panel; two independent apps trying to share
/// the notch strip would contend for the same rectangle at the same window level.
///
/// Thread-safety: main-actor isolated, as all AppKit view work must be. Subclasses `NSObject` so the
/// menu items can target its `@objc` actions.
@MainActor
final class HerdStatusItem: NSObject {
    /// The status item itself. Held strongly for the process lifetime; releasing it removes the item.
    private let statusItem: NSStatusItem

    /// SwiftUI content of the button.
    private let hostingView: NSHostingView<HerdRollUpView>

    /// A width computed while the popover was open, waiting to be applied once it closes.
    ///
    /// `nil` when there is nothing pending. See ``refresh()`` for why the write has to wait.
    private var deferredLength: CGFloat?

    /// Data source, observed for redraws.
    private let model: HerdBarModel

    /// Settings, mutated by the menu toggles.
    private let preferences: HerdPreferences

    /// Invoked on a left click, to toggle the popover.
    private let onPrimaryClick: () -> Void

    /// Invoked by the menu's search entry.
    private let onOpenSearch: () -> Void

    /// Invoked by the menu's settings entry.
    private let onOpenSettings: () -> Void

    /// Live registration state of the global shortcut.
    ///
    /// Read at menu-build time rather than captured as a string, because the shortcut is now rebindable at
    /// runtime and a captured label would go stale the moment the user changed it. It also carries the
    /// failure case, which is the only thing in this menu that is ever an alarm.
    private let hotKeyStatus: HerdHotKeyStatus

    /// Keeps the redraw subscription alive.
    private var cancellable: AnyCancellable?

    /// Creates and installs the status item.
    ///
    /// - Parameters:
    ///   - model: Publishes the snapshot and state that the roll-up renders.
    ///   - preferences: Backs the menu's one toggle and the paused marker.
    ///   - hotKeyStatus: Supplies the shortcut label and whether it registered.
    ///   - onOpenSearch: Called by the menu's search entry.
    ///   - onOpenSettings: Called by the menu's settings entry.
    ///   - onPrimaryClick: Called on left click. The popover is not owned here, so that this type has
    ///     no opinion about what the click opens.
    init(
        model: HerdBarModel,
        preferences: HerdPreferences,
        hotKeyStatus: HerdHotKeyStatus,
        onOpenSearch: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onPrimaryClick: @escaping () -> Void
    ) {
        self.model = model
        self.preferences = preferences
        self.hotKeyStatus = hotKeyStatus
        self.onOpenSearch = onOpenSearch
        self.onOpenSettings = onOpenSettings
        self.onPrimaryClick = onPrimaryClick
        statusItem = NSStatusBar.system.statusItem(withLength: 60)
        hostingView = NSHostingView(
            rootView: HerdRollUpView(counts: StatusCounts(), isDegraded: false, isPaused: false)
        )
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(buttonClicked(_:))
            // Both mouse-ups, so a right click reaches the same handler and can open the menu
            // instead. Setting `statusItem.menu` would make a left click open the menu too, which
            // would leave no gesture for the popover.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            hostingView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: button.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: button.bottomAnchor)
            ])
        }

        // Observing `objectWillChange` rather than passing the model into the SwiftUI view: the view
        // would redraw itself either way, but the item's width also has to be recomputed, and doing
        // both in one place keeps content and width from ever being a frame apart.
        cancellable = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    /// Removes the status item from the menu bar.
    func remove() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// The button, so the popover can anchor to it.
    var anchorView: NSStatusBarButton? { statusItem.button }

    /// Re-renders the roll-up and resizes the item to fit it.
    ///
    /// Callable from outside now, because the paused marker follows a preference the settings window can
    /// change while the popover is closed, and the roll-up would otherwise keep the old glyph until the next
    /// poll published something.
    ///
    /// The width is set explicitly rather than using `NSStatusItem.variableLength`, because the button
    /// has no title or image of its own and so no intrinsic content size for the system to measure.
    /// The width only changes when a dot appears or disappears, which is a real change; digit-count
    /// changes are absorbed by the reserved width inside ``HerdRollUpView``.
    func refresh() {
        let isDegraded: Bool = if case .error = model.state { true } else { false }
        hostingView.rootView = HerdRollUpView(
            counts: model.snapshot.counts,
            isDegraded: isDegraded,
            isPaused: !preferences.isEnabled
        )
        hostingView.layoutSubtreeIfNeeded()
        statusItem.button?.toolTip = tooltip

        let wanted = max(hostingView.fittingSize.width, 40)

        // Two guards on the width, and both matter for the same reason: writing `NSStatusItem.length`
        // relayouts the status bar and *moves this item*, and the popover is anchored to this item's
        // button.
        //
        // Only on a real change. The old code assigned on every publish, so a 1 Hz poll relayouted the
        // menu bar once a second while the panel was open, for a value that had not changed.
        //
        // And never while the panel is open. `HerdPanel.toggle` calls `model.panelDidOpen()` immediately
        // after showing the popover, which polls at once, which publishes, which lands here: so *every*
        // open was followed by a resize of the very view the popover had just anchored to, a frame or two
        // later. That is the mechanism behind the panel occasionally appearing far to the left instead of
        // under the item, and it got likelier when the `done` dot arrived, because a dot appearing or
        // disappearing is exactly what changes the width. Deferring costs nothing: the roll-up's contents
        // above are already up to date, only the item's own width waits, and `HerdPanel` calls back on
        // close so the deferred width applies then rather than on the next tick.
        guard !model.isPanelOpen else {
            deferredLength = wanted
            return
        }
        deferredLength = nil
        if statusItem.length != wanted { statusItem.length = wanted }
    }

    /// Full status summary for the item's tooltip, so hovering answers the obvious question without
    /// opening anything.
    private var tooltip: String {
        switch model.state {
        case .ok:
            let counts = model.snapshot.counts
            let sessions = model.snapshot.sessions.count
            // Same vocabulary as the rows and the popup: an agent is "waiting for you", not blocked.
            // `done` is listed only when there is one, matching the dot it describes.
            var parts = ["\(counts.blocked) waiting for you"]
            if counts.done > 0 { parts.append("\(counts.done) done") }
            parts.append("\(counts.working) working")
            parts.append("\(counts.idle) idle")
            if counts.unknown > 0 { parts.append("\(counts.unknown) unknown") }
            return """
            \(counts.total) agent\(counts.total == 1 ? "" : "s") in \(sessions) session\(sessions == 1 ? "" : "s")
            \(parts.joined(separator: " · "))
            """
        case .noSessions(let reason), .error(let reason):
            return reason
        }
    }

    // MARK: - Clicks

    /// Routes a click: left opens the popover, right opens the menu.
    ///
    /// The event type is read from `NSApp.currentEvent` because `NSStatusBarButton` reports only that
    /// it was clicked, not with which button.
    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isSecondary {
            showMenu(from: sender)
        } else {
            onPrimaryClick()
        }
    }

    /// Pops up the settings menu under the item.
    ///
    /// Built fresh on each open rather than kept around, because every item's state (checkmarks, the
    /// selected interval, the session filter list) depends on current preferences and on the sessions
    /// in the latest snapshot.
    ///
    /// - Parameter sender: The button to position the menu beneath.
    private func showMenu(from sender: NSStatusBarButton) {
        let menu = buildMenu()
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: sender.bounds.height + 4),
            in: sender
        )
    }

    /// Assembles the right-click menu.
    ///
    /// Four entries, down from roughly twenty. Everything configurable now lives in the settings window, and
    /// what stayed had to earn its place by being either an action or a switch worth one click:
    ///
    /// - **Find a pane…** is an action, and it is also the only place the global shortcut is ever announced.
    ///   A system-wide shortcut nobody was told about is a feature that does not exist, so the label carries
    ///   it, and when registration failed the label says so instead of naming a key that does nothing.
    /// - **Pause / Resume watching** is the pause switch. It is here because pausing is something people do
    ///   reactively (a wedged herdr server, a laptop on battery) and making that a two-click trip through a
    ///   window would be worse than the menu it replaced.
    ///
    ///   It states the **action** rather than carrying a checkmark, and that is not a style preference. A
    ///   menu containing any item with a state reserves a leading column for the checkmark across *every*
    ///   item, so "Settings…" and "Quit" each sat behind a permanently empty slot that read as a missing
    ///   icon. Naming the verb removes the state, ``NSMenu/showsStateColumn`` set to `false` removes the
    ///   column for good, and the titles line up at the left edge. Nothing is lost: whether polling is on
    ///   was always readable at a glance from the status item's own pause glyph, so the checkmark was the
    ///   second, more expensive copy of that fact.
    /// - **Settings…** and **Quit** are the two entries the brief asked for.
    ///
    /// Everything else went: the popup and notification toggles, both duration lists, the poll-interval list
    /// and the session list. The session list in particular could not stay, because it was built from the
    /// *filtered* snapshot, so unticking a session removed it from the menu and there was no way back short
    /// of clearing the whole filter.
    ///
    /// Built fresh on each open rather than kept around, because the shortcut label, the checkmark and the
    /// registration state all depend on current state.
    ///
    /// - Returns: A fully configured menu, ready to pop up.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        // No item in this menu carries a state, so the leading checkmark column is dead space on every row.
        // AppKit reserves it for the whole menu the moment one item could use it, which is why turning it
        // off here is what actually removes the empty slot rather than only hiding one checkmark.
        menu.showsStateColumn = false

        let shortcut = hotKeyStatus.isRegistered
            ? "  \(hotKeyStatus.shortcut.summary)"
            : "  (shortcut unavailable)"
        menu.addItem(item(title: "Find a pane…\(shortcut)", action: #selector(openSearch)))

        // Only present when something is wrong, so the common case stays four entries. Actionable rather
        // than a disabled label: the fix is in the settings window, so the item opens it.
        if !hotKeyStatus.isRegistered {
            menu.addItem(item(title: hotKeyStatus.explanation, action: #selector(openSettings)))
        }

        menu.addItem(.separator())
        // The verb, not the state. See the note above about the checkmark column.
        menu.addItem(
            item(
                title: preferences.isEnabled ? "Pause watching the herd" : "Resume watching the herd",
                action: #selector(toggleEnabled)
            )
        )

        menu.addItem(.separator())
        menu.addItem(item(title: "Settings…", action: #selector(openSettings)))
        menu.addItem(item(title: "Quit BoringHerdBar", action: #selector(quit)))
        return menu
    }

    /// Builds one actionable menu item targeting this object.
    ///
    /// There is no `on:` parameter any more. Every entry in this menu is an action, so nothing sets a
    /// state, and leaving the parameter behind would invite the next entry to reintroduce the checkmark
    /// column this menu deliberately does not have.
    ///
    /// - Parameters:
    ///   - title: Visible title.
    ///   - action: Selector on this object.
    /// - Returns: The configured item.
    private func item(title: String, action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    // MARK: - Menu actions

    /// Opens the pane search window, for people who reached the menu before learning the shortcut.
    @objc private func openSearch() {
        onOpenSearch()
    }

    /// Opens the settings window.
    @objc private func openSettings() {
        onOpenSettings()
    }

    /// Toggles polling. Refreshing immediately so the paused glyph appears without waiting for a tick.
    @objc private func toggleEnabled() {
        preferences.isEnabled.toggle()
        refresh()
    }

    /// Quits the app.
    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
