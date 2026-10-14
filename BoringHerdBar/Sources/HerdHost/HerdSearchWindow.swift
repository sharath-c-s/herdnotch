import AppKit
import Foundation
import HerdKit
import SwiftUI

/// A borderless panel that can take keyboard focus.
///
/// `NSPanel` refuses key status for a borderless style mask, which for an ordinary panel is the right
/// default and here is exactly wrong: the whole point of this window is that the user types into it the
/// instant it appears. Overriding ``canBecomeKey`` is the documented way to opt back in.
private final class HerdKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Supplies the panes ``HerdSearchWindow`` searches, and learns when the window opens or closes.
///
/// A protocol rather than a concrete dependency on either host app's poller, which is what lets this
/// library build the search window with no import back to `BoringHerdBar` or `HerdNotch` (SwiftPM
/// cannot import an executable target anyway). Each host's own model conforms instead: `HerdBarModel` in
/// `BoringHerdBar`, `NotchHerdModel` in `HerdNotch`. The window only ever sees the four members below.
///
/// Thread-safety: `@MainActor`, matching every other object involved in presenting this window.
@MainActor
public protocol HerdSearchSnapshotSource: AnyObject {
    /// The most recent snapshot to search.
    var snapshot: HerdSnapshot { get }

    /// Keys of agents that finished inside the host's own recency window, from
    /// ``HerdUrgencyOrder/key(sessionName:paneId:)``. A host with no recency memory returns an empty set,
    /// which simply ranks by status alone.
    var recentlyCompleted: Set<String> { get }

    /// Called just before the window is shown, so the host can refresh live data or lift its own poll out
    /// of an idle back-off. A host that already polls continuously (never fully idling) may make this a
    /// no-op.
    func panelDidOpen()

    /// Called when the window is dismissed, the counterpart to ``panelDidOpen()``.
    func panelDidClose()
}

/// The pane search window, opened by the global hotkey.
///
/// A separate window rather than a mode inside the status item's popover, for two reasons that both
/// come from the hotkey. A popover has to be anchored to its status item, so it cannot appear when the
/// menu bar is hidden by a full-screen app; and it would put a search field in the surface whose whole
/// design is that it is quiet, which is the opposite of what a Spotlight-shaped thing should feel like.
///
/// The window is created once and reused. Rebuilding it per invocation would rebuild the SwiftUI
/// hosting view too, which is measurable on a hotkey the user is expected to hit reflexively.
///
/// Thread-safety: main-actor isolated, as all AppKit work must be.
@MainActor
public final class HerdSearchWindow: NSObject, NSWindowDelegate {
    /// Fraction of the screen height the window's top edge sits at.
    ///
    /// Above centre, where Spotlight and every launcher puts itself, because the eye is already there
    /// and because a window centred vertically covers whatever the user is trying to search against.
    private static let verticalPlacement: CGFloat = 0.28

    /// The panel, built on first use.
    private var panel: HerdKeyablePanel?

    /// Supplies the snapshot to search.
    private let model: any HerdSearchSnapshotSource

    /// Invoked with the chosen pane.
    private let onSelect: (HerdSession, HerdAgent) -> Void

    /// Creates the presenter without building any AppKit objects.
    ///
    /// - Parameters:
    ///   - model: Read at open time for the current snapshot.
    ///   - onSelect: Invoked with the owning session and the agent when the user picks a result.
    public init(model: any HerdSearchSnapshotSource, onSelect: @escaping (HerdSession, HerdAgent) -> Void) {
        self.model = model
        self.onSelect = onSelect
    }

    /// Shows the window, or closes it if it is already up.
    ///
    /// Toggling rather than always showing, so the same hotkey that summons it dismisses it. A second
    /// press when the window is already key is much more likely to mean "never mind" than "show me the
    /// thing I am looking at".
    ///
    /// The panes are re-flattened from the model on every open rather than observed, because the window
    /// is short-lived by design: a snapshot arriving mid-search would reorder the list under the user's
    /// selection, which is worse than the list being slightly out of date.
    ///
    /// How far out of date is worth stating, since the ordering now depends on it. ``present()`` asks the
    /// model to refresh and then reads the snapshot synchronously on the next line, so this list is built
    /// from the poll *before* that refresh: up to the closed-panel back-off, five seconds, not the one
    /// second the panel polls at while open. Bounded and self-correcting, because the refresh lands for the
    /// next press, and it costs at most a status glyph and a row position being a few seconds behind, never
    /// a result that focuses the wrong pane. Making the window observe the model instead would fix the
    /// staleness and reintroduce exactly the mid-search reorder this design rejects.
    public func toggle() {
        if let panel, panel.isVisible {
            close()
            return
        }
        present()
    }

    /// Builds or reuses the panel, fills it with the current panes, and makes it key.
    private func present() {
        // Tells the model a surface is open, which both refreshes immediately and lifts it out of its
        // five-second idle back-off. The refresh lands too late for this open, since the panes below
        // are read synchronously, but it bounds how stale a second press a moment later can be. The
        // pane *set* changes rarely, so what a stale snapshot actually costs is a status dot that is a
        // few seconds behind, never a result that focuses the wrong pane.
        model.panelDidOpen()
        // The recency set is passed, not omitted, so this list ranks a just-finished agent where the panel
        // ranks it. It is the same input the ledger's ordering gets, from the same published value, which is
        // what stops the two surfaces from having different ideas of "just finished".
        let panes = HerdPane.flatten(
            model.snapshot,
            recentlyCompleted: model.recentlyCompleted
        )
        let view = NSHostingView(
            rootView: HerdSearchView(
                panes: panes,
                onSelect: { [weak self] pane in
                    guard let self else { return }
                    // Closing first, then acting. The focus call raises the terminal, and leaving a
                    // key window floating over the app the user just asked to look at is the single
                    // most annoying thing a launcher can do.
                    self.close()
                    self.onSelect(pane.session, pane.agent)
                },
                onDismiss: { [weak self] in self?.close() }
            )
        )
        view.setFrameSize(view.fittingSize)

        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        panel.delegate = self
        panel.contentView = view
        panel.setContentSize(view.fittingSize)
        panel.setFrameOrigin(Self.origin(for: view.fittingSize))

        // Activation has to come first and it has to be real: only the active application's windows
        // can hold key status, so a panel made key while the app is inactive becomes key and then
        // resigns a moment later, which looks exactly like the window flashing and vanishing. Measured
        // both ways with the shortcut fired from another frontmost application.
        //
        // One caveat for anyone reproducing that measurement: an accessory app started by running its
        // binary directly from a shell is denied activation, and the panel does flash and vanish.
        // Launched through LaunchServices, which is how a user starts it, activation succeeds and the
        // panel holds the keyboard. The bug was in the harness, not here, and it is worth knowing
        // before changing this code in response to it.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)

        // The capture harness, on the same terms as the panel's: this process cannot be screenshotted
        // from outside, so the only way to check the search layout and the match highlighting is to
        // type into it from within and render the result.
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["HERDBAR_SEARCH_DUMP"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let view = self?.panel?.contentView else { return }
                if let script = environment["HERDBAR_SEARCH_KEYS"] {
                    HerdDebugCapture.replay(script, into: view.window)
                }
                // Re-sized after typing, because the result count changes the window's fitting height
                // and a capture of the old bounds would clip the rows the query just produced.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    // Reported because the capture renders the view whether or not its window is on
                    // screen, so a PNG alone cannot say whether Escape dismissed anything.
                    let visible = self?.panel?.isVisible == true
                    FileHandle.standardError.write(Data("herd: search window visible: \(visible)\n".utf8))
                    self?.panel?.setContentSize(view.fittingSize)
                    HerdDebugCapture.write(view, to: path)
                }
            }
        }
    }

    /// Hides the window. Safe to call when it is not showing.
    func close() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        model.panelDidClose()
    }

    /// Dismisses the window when it stops being key.
    ///
    /// Clicking away from a launcher means dismissing it, and a stale search window left behind on
    /// another Space is the failure mode this avoids.
    ///
    /// - Parameter notification: Unused; required by the delegate protocol.
    public func windowDidResignKey(_ notification: Notification) {
        close()
    }

    /// Builds the panel with the flags a launcher window needs.
    ///
    /// `.nonactivatingPanel` is deliberately *not* set. It was tried, on the theory that a launcher
    /// should not steal activation, and it is the wrong tool: only the active application's windows
    /// hold key status, so a non-activating panel gains the keyboard and loses it again. This window
    /// wants the app active while the user is typing into it, and gives activation straight back when a
    /// result raises the terminal.
    ///
    /// `.hidesOnDeactivate` is left off because ``windowDidResignKey(_:)`` already handles dismissal
    /// and doing both makes the ordering hard to reason about.
    private static func makePanel() -> HerdKeyablePanel {
        let panel = HerdKeyablePanel(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    /// Bottom-left origin that centres the window horizontally and places it above centre.
    ///
    /// - Parameter size: The window's content size.
    /// - Returns: An origin in screen coordinates, on whichever screen has the mouse, so the window
    ///   appears on the display the user is actually working on rather than always on the main one.
    private static func origin(for size: CGSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return .zero }
        return NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - visible.height * verticalPlacement - size.height
        )
    }
}
