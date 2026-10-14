import AppKit
import HerdHost
import HerdHotKey
import SwiftUI

/// Presents ``NotchSettingsView``, HerdNotch's merged two-tab settings window (the notch's own knobs, plus
/// the shared herd-data form as its second tab).
///
/// Mirrors `HerdHost/HerdSettingsWindow`'s own presenter exactly — a real titled `NSWindow` built once and
/// reused, not released when closed (so reopening it never rebuilds the SwiftUI tree, and any in-flight
/// slider drag is not lost), and the same activate-then-key sequence that window documents: an `.accessory`
/// app's windows can hold key status, they just cannot acquire it while the app itself is inactive.
///
/// Kept as a separate type from `HerdSettingsWindow` rather than a second initializer on it, because that
/// type's own `makeWindow()` hard-codes `HerdSettingsView` as its sole root content, and this window's root
/// is the two-tab ``NotchSettingsView`` instead.
///
/// Thread-safety: main-actor isolated, as all AppKit work must be.
@MainActor
final class NotchSettingsWindow: NSObject, NSWindowDelegate {
    /// The window, built on first use.
    private var window: NSWindow?

    /// The notch-only knobs the "HerdNotch" tab edits.
    private let notchPreferences: NotchPreferences

    /// The shared herd-data settings, forwarded to the "Herd Data" tab.
    private let herdPreferences: HerdPreferences

    /// Live registration state of the shared search shortcut, forwarded to the "Herd Data" tab.
    private let hotKeyStatus: HerdHotKeyStatus

    /// Every discovered session name, forwarded to the "Herd Data" tab.
    private let roster: HerdSessionRoster

    /// Creates the presenter without building any AppKit objects.
    ///
    /// - Parameters:
    ///   - notchPreferences: The notch-only settings the "HerdNotch" tab edits. Defaults to
    ///     ``NotchPreferences/shared``, the one instance every other consumer in this target reads.
    ///   - herdPreferences: The shared herd-data settings, for the "Herd Data" tab.
    ///   - hotKeyStatus: Live registration state of the shared search shortcut, for the "Herd Data" tab.
    ///   - roster: Every discovered session name, for the "Herd Data" tab's session filter.
    init(
        notchPreferences: NotchPreferences = .shared,
        herdPreferences: HerdPreferences,
        hotKeyStatus: HerdHotKeyStatus,
        roster: HerdSessionRoster
    ) {
        self.notchPreferences = notchPreferences
        self.herdPreferences = herdPreferences
        self.hotKeyStatus = hotKeyStatus
        self.roster = roster
    }

    /// Shows the window, bringing it forward if it is already open.
    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        // Activation first, then key — see `HerdSettingsWindow.show()`'s own documentation for why an
        // accessory app must do these in this order.
        NSApp.activate()
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    /// Builds the window and its content.
    ///
    /// The content size is taken from the hosting view's fitting size, so the form decides the height and
    /// this code decides nothing about layout.
    private func makeWindow() -> NSWindow {
        let hosting = NSHostingView(
            rootView: NotchSettingsView(
                notchPreferences: notchPreferences,
                herdPreferences: herdPreferences,
                hotKeyStatus: hotKeyStatus,
                roster: roster
            )
        )
        hosting.setFrameSize(hosting.fittingSize)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "HerdNotch Settings"
        // Closing must hide rather than destroy, or the second open rebuilds the form and any in-flight
        // slider drag's transient state goes with it — the same reason `HerdSettingsWindow` does this.
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        window.delegate = self
        window.collectionBehavior = [.moveToActiveSpace]
        return window
    }
}
