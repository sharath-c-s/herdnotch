import AppKit
import HerdHotKey
import SwiftUI

/// Presents the settings window.
///
/// A real titled `NSWindow` rather than a second popover, and that is the one thing worth arguing about
/// here, because the previous build's stated reason for having no settings window was that a window "would
/// mean a second `NSHostingController`, a title bar, and an activation policy fight with `LSUIElement`".
/// Two of those three turned out to be free and the third is a single call:
///
/// - The hosting controller is one line, and this app already builds two of them.
/// - The title bar is what the user closes the window with, so it is the feature rather than the cost. An
///   accessory app has no application menu, so there is no ⌘W to fall back on.
/// - The activation policy needs `NSApp.activate()` before `makeKeyAndOrderFront`, exactly as the search
///   window already does. An `.accessory` app's windows can hold key status; they just cannot get it while
///   the app is inactive.
///
/// What a popover could not do is hold a text field and a shortcut recorder: a `.transient` popover dismisses
/// on the first click outside itself, which includes the click that moves focus between controls.
///
/// The window is created once and reused, and is not released when closed, so reopening it does not rebuild
/// the SwiftUI tree or lose a half-typed path.
///
/// Thread-safety: main-actor isolated, as all AppKit work must be.
@MainActor
public final class HerdSettingsWindow: NSObject, NSWindowDelegate {
    /// The window, built on first use.
    private var window: NSWindow?

    /// Every setting, bound into the form.
    private let preferences: HerdPreferences

    /// Live registration state of the global shortcut.
    private let hotKeyStatus: HerdHotKeyStatus

    /// Every discovered session name, for the filter list.
    private let roster: HerdSessionRoster

    /// The window's title bar text, so two host apps sharing this type do not both claim to be
    /// "Boring Herd Bar".
    private let title: String

    /// Creates the presenter without building any AppKit objects.
    ///
    /// - Parameters:
    ///   - preferences: The settings the form edits.
    ///   - hotKeyStatus: Whether the chosen shortcut is actually registered.
    ///   - roster: Every discovered session name, so the filter can offer sessions it is hiding.
    ///   - title: The window's title bar text. Defaults to the shipped `BoringHerdBar` title so that
    ///     app's own call site needs no change; `HerdNotch` passes its own name.
    public init(
        preferences: HerdPreferences,
        hotKeyStatus: HerdHotKeyStatus,
        roster: HerdSessionRoster,
        title: String = "Boring Herd Bar Settings"
    ) {
        self.preferences = preferences
        self.hotKeyStatus = hotKeyStatus
        self.roster = roster
        self.title = title
    }

    /// Shows the window, bringing it forward if it is already open.
    public func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        // Activation first, then key. Only the active application's windows can hold key status, so an
        // accessory app that skips this gets a window that becomes key and immediately resigns, which looks
        // like the window flashing. Measured the same way for the search window.
        NSApp.activate()
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        recordShortcutIfRequested(window)
        captureIfRequested(window)
    }

    /// Drives the shortcut recorder with a scripted key press, for the harness.
    ///
    /// This exists to check one thing no assertion can reach: that recording a shortcut **re-registers it
    /// while the app is running**. The chain being exercised is the production one end to end, a mouse event
    /// into the real recorder view, a key event with real modifier flags, the preference write, the
    /// `objectWillChange` the app delegate observes, and the Carbon re-registration. Nothing is stubbed.
    ///
    /// The recorder is located by walking the view tree rather than by a hard-coded point, so the script
    /// cannot silently start clicking somewhere else the first time the form's layout changes.
    ///
    /// `HERDBAR_SETTINGS_RECORD` is `<virtualKeyCode>[:cmd][:opt][:shift][:ctrl]`, for example `38:cmd:opt`
    /// for `⌥⌘J`.
    ///
    /// - Parameter window: The settings window, already on screen.
    private func recordShortcutIfRequested(_ window: NSWindow) {
        guard let spec = ProcessInfo.processInfo.environment["HERDBAR_SETTINGS_RECORD"] else { return }
        let parts = spec.split(separator: ":").map(String.init)
        guard let first = parts.first, let code = UInt16(first) else {
            FileHandle.standardError.write(Data("herd: bad HERDBAR_SETTINGS_RECORD \(spec)\n".utf8))
            return
        }
        var modifiers: NSEvent.ModifierFlags = []
        for name in parts.dropFirst() {
            switch name {
            case "cmd": modifiers.insert(.command)
            case "opt": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            case "ctrl": modifiers.insert(.control)
            default: break
            }
        }
        // Delayed so SwiftUI has committed the hosting view's layout; a view found before that has a zero
        // frame and the click would land at the window's corner.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard let recorder = Self.firstKeyCaptureView(in: window.contentView) else {
                FileHandle.standardError.write(Data("herd: recorder view not found\n".utf8))
                return
            }
            let centre = recorder.convert(
                NSPoint(x: recorder.bounds.midX, y: recorder.bounds.midY), to: nil
            )
            HerdDebugCapture.click(at: centre, in: window)
            HerdDebugCapture.press(code: code, characters: "", modifiers: modifiers, in: window)
            FileHandle.standardError.write(
                Data("herd: recorded key \(code) modifiers \(modifiers.rawValue)\n".utf8)
            )
        }
    }

    /// Depth-first search for the recorder's event sink.
    ///
    /// - Parameter view: Root of the subtree to search.
    /// - Returns: The first capture view found, or `nil`.
    private static func firstKeyCaptureView(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view is HerdKeyCaptureView.CaptureView { return view }
        for subview in view.subviews {
            if let found = firstKeyCaptureView(in: subview) { return found }
        }
        return nil
    }

    /// Renders the form to a PNG when asked, on the same terms as the panel and the search window.
    ///
    /// Screen Recording is denied to this process, so nothing outside it can photograph its interface; the
    /// only way to look at a layout is to render it from inside. For a settings form that matters more than
    /// for the other two surfaces, because the thing most worth checking is whether the session list is
    /// showing sessions the filter is currently *hiding*, and that is invisible to any assertion: the list
    /// would look correct to a test either way.
    ///
    /// Delayed so the first poll has landed, because before it the roster is empty and the capture would
    /// photograph "No sessions discovered yet."
    ///
    /// - Parameter window: The window whose content view to render.
    private func captureIfRequested(_ window: NSWindow) {
        guard let path = ProcessInfo.processInfo.environment["HERDBAR_SETTINGS_DUMP"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard let view = window.contentView else { return }
            view.setFrameSize(view.fittingSize)
            window.setContentSize(view.fittingSize)
            FileHandle.standardError.write(
                Data("herd: settings window visible: \(window.isVisible) size \(view.bounds.size)\n".utf8)
            )
            HerdDebugCapture.write(view, to: path)
        }
    }

    /// Builds the window and its content.
    ///
    /// The content size is taken from the hosting view's fitting size, so the form decides the height and
    /// this code decides nothing about layout. `.miniaturizable` is left off: a utility window nobody keeps
    /// open has no use for the Dock, and an accessory app has no Dock tile to minimise into.
    private func makeWindow() -> NSWindow {
        let hosting = NSHostingView(
            rootView: HerdSettingsView(
                preferences: preferences,
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
        window.title = title
        // Closing must hide rather than destroy, or the second open rebuilds the form and the recorder's and
        // text editor's transient state goes with it.
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        window.delegate = self
        window.collectionBehavior = [.moveToActiveSpace]
        return window
    }
}
