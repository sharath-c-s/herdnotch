import AppKit
import Foundation
import HerdHost
import HerdKit
import HerdPanelUI
import SwiftUI

/// SwiftUI wrapper that feeds the model's published values into the host-agnostic ledger.
///
/// It exists so ``HerdLedgerView`` never has to know about ``HerdBarModel``: this view is the only place
/// the two meet, and it is the piece Track B replaces with its own `HerdView`.
private struct HerdPanelRoot: View {
    /// The polling model, observed for redraws.
    @ObservedObject var model: HerdBarModel

    /// Settings, observed so a type-size change repaints the panel without waiting for a poll or a reopen.
    ///
    /// This view is the only place the host's preferences and the host-agnostic ledger meet, which is the
    /// same job it already did for the model. ``HerdLedgerView`` still receives a plain ``HerdLedgerScale``
    /// and knows nothing about where it came from.
    @ObservedObject var preferences: HerdPreferences

    /// Forwarded to ``HerdLedgerView/onSelectAgent``.
    let onSelectAgent: (HerdSession, HerdAgent) -> Void

    /// Forwarded to ``HerdLedgerView/onSelectSession``.
    let onSelectSession: (HerdSession) -> Void

    /// Forwarded to ``HerdLedgerView/onSelectWorkspace``.
    let onSelectWorkspace: (HerdSession, HerdWorkspace) -> Void

    /// Forwarded to ``HerdLedgerView/onDismiss``.
    let onDismiss: () -> Void

    var body: some View {
        HerdLedgerView(
            snapshot: model.snapshot,
            recentlyCompleted: model.recentlyCompleted,
            detachedSessions: model.detachedSessions,
            scale: preferences.ledgerScale,
            banner: banner,
            bannerIsError: isError,
            onSelectAgent: onSelectAgent,
            onSelectSession: onSelectSession,
            onSelectWorkspace: onSelectWorkspace,
            onDismiss: onDismiss
        )
    }

    /// The banner sentence for the current state, or `nil` when the rows are the whole truth.
    ///
    /// Mapped here rather than passing ``HerdBarState`` into the view. That enum belongs to this app, and
    /// the ledger lives in a module the boringNotch fork also consumes; two scalars are a smaller contract
    /// than a shared enum and cannot drift out of sync.
    private var banner: String? {
        switch model.state {
        case .ok: nil
        case .noSessions(let reason): reason
        case .error(let reason): reason
        }
    }

    /// Whether the banner describes a fault rather than a state.
    private var isError: Bool {
        if case .error = model.state { return true }
        return false
    }
}

/// The popover anchored to the status item.
///
/// An `NSPopover` rather than a hand-placed borderless `NSPanel`, and that choice is worth stating:
/// the popover gives click-outside dismissal, correct screen-edge and multi-display placement, and
/// Escape-to-close for free. Those are features 7 and 8 solved by the OS instead of by us, and a
/// hand-placed panel would mean re-implementing all three and getting the third-display case wrong.
///
/// Thread-safety: main-actor isolated. `NSPopoverDelegate` callbacks arrive on the main thread.
@MainActor
final class HerdPanel: NSObject, NSPopoverDelegate {
    /// The popover. Held for the process lifetime and reused, so its content view is built once.
    private let popover = NSPopover()

    /// The model, notified when the panel opens and closes so it can change poll interval.
    private let model: HerdBarModel

    /// Invoked after the popover closes, so the status item can apply a width change it deferred while
    /// the popover was anchored to it. See ``HerdStatusItem/refresh()``.
    private let onDidClose: () -> Void

    /// Watches for clicks that land in *other* applications while the popover is open.
    ///
    /// `NSPopover.Behavior.transient` dismisses on a click inside this app and on ordinary deactivation,
    /// and that is genuinely not enough for a menu bar popover: clicking another app's status item does
    /// not reliably activate that app, so this app never resigns active and never sees a mouse event, and
    /// the panel sat open on top of whatever the other item had just opened.
    ///
    /// It costs no TCC permission. `addGlobalMonitorForEvents` needs Input Monitoring for *keyboard*
    /// events; mouse events need nothing, so this stays inside the project's rule of asking for no extra
    /// permission.
    ///
    /// Global monitors never fire for events delivered to this process, which is what makes this safe
    /// rather than a way to dismiss the panel out from under the user: a click on the panel itself, or on
    /// our own status item, cannot reach here. Installed on show, removed on close, so nothing is
    /// watching while the panel is shut.
    private var outsideClickMonitor: Any?

    /// Creates the popover and its content.
    ///
    /// - Parameters:
    ///   - model: Supplies the snapshot and receives open and close notifications.
    ///   - preferences: Supplies the panel's type scale, observed so a change applies live.
    ///   - onSelectAgent: Invoked when an agent row is clicked or activated with Return.
    ///   - onSelectSession: Invoked when a session header is clicked.
    ///   - onSelectWorkspace: Invoked when a workspace header is clicked.
    ///   - onDidClose: Invoked once the popover has closed, however it closed.
    init(
        model: HerdBarModel,
        preferences: HerdPreferences,
        onSelectAgent: @escaping (HerdSession, HerdAgent) -> Void,
        onSelectSession: @escaping (HerdSession) -> Void,
        onSelectWorkspace: @escaping (HerdSession, HerdWorkspace) -> Void,
        onDidClose: @escaping () -> Void = {}
    ) {
        self.model = model
        self.onDidClose = onDidClose
        super.init()

        // The list can no longer rely on the popover's own Escape handling, because it now holds
        // keyboard focus in order to receive arrow keys. Closing is therefore wired explicitly, and
        // this closure is the only thing in the chain that knows a popover is what is being closed.
        //
        // Captured weakly because the ownership runs popover → content controller → root view →
        // closure, so a strong capture would close the loop and leak the whole panel.
        let target = popover
        let controller = NSHostingController(
            rootView: HerdPanelRoot(
                model: model,
                preferences: preferences,
                onSelectAgent: onSelectAgent,
                onSelectSession: onSelectSession,
                onSelectWorkspace: onSelectWorkspace,
                onDismiss: { [weak target] in target?.performClose(nil) }
            )
        )
        // Lets SwiftUI drive the popover's size, so the popover shrinks to fit two sessions and grows
        // to the list's own 420 pt scroll cap rather than being told a fixed height here.
        controller.sizingOptions = [.preferredContentSize]

        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    /// Whether the popover is currently on screen.
    var isShown: Bool { popover.isShown }

    /// Closes the popover if it is open.
    ///
    /// Called when a row is acted on: choosing an agent means "take me there", so the panel has done
    /// its job. It closed on its own anyway once raising the terminal deactivated the app, but not
    /// until the herdr calls had returned, which left the focus confirmation overlapping the rows it
    /// was confirming.
    func close() {
        popover.performClose(nil)
    }

    /// Opens the popover if closed, closes it if open.
    ///
    /// - Parameter anchor: The status item button to anchor to.
    func toggle(relativeTo anchor: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            // Activating and making the popover key has to happen after `show`, because before it
            // there is no popover window to make key. Verified: with the activation before `show`,
            // the first click on an agent row was swallowed as a window-activating click and the user
            // had to click twice. This is also what gives the popover keyboard focus, and therefore
            // Escape-to-close.
            NSApp.activate()
            popover.contentViewController?.view.window?.makeKey()
            installOutsideClickMonitor()
            model.panelDidOpen()
            if let path = ProcessInfo.processInfo.environment["HERDBAR_DUMP"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                    guard let view = self?.popover.contentViewController?.view else { return }
                    // Keys are replayed immediately before the capture rather than on open, so the
                    // first poll has already populated the rows the keys are meant to walk.
                    if let script = ProcessInfo.processInfo.environment["HERDBAR_DUMP_KEYS"] {
                        HerdDebugCapture.replay(script, into: view.window)
                    }
                    // Given as x,y from the content view's top-left, because that is how the capture
                    // PNG reads, and converted here so the caller never has to know whether the
                    // hosting view is flipped or where the popover's chrome puts it in its window.
                    if let spec = ProcessInfo.processInfo.environment["HERDBAR_DUMP_CLICK"] {
                        let parts = spec.split(separator: ",").compactMap { Double($0) }
                        if parts.count == 2 {
                            let local = NSPoint(
                                x: view.bounds.minX + parts[0],
                                y: view.isFlipped ? view.bounds.minY + parts[1] : view.bounds.maxY - parts[1]
                            )
                            HerdDebugCapture.click(at: view.convert(local, to: nil), in: view.window)
                        }
                    }
                    // Reported because the capture renders the view whether or not the popover is on
                    // screen, so a PNG alone cannot say whether Escape dismissed anything. The frame
                    // goes with it so a click script can be aimed without guessing the height.
                    let shown = self?.popover.isShown == true
                    let frame = view.window?.frame ?? .zero
                    // Content bounds reported alongside the popover's own content size. If those two
                    // disagree the rows are being drawn outside the panel, which is what the
                    // oscillating layout looked like on screen, so this is the cheap standing check.
                    let bounds = view.bounds.size
                    let fitting = view.fittingSize
                    let content = self?.popover.contentSize ?? .zero
                    let report = "herd: panel shown: \(shown) window: \(frame)\n"
                        + "herd: content bounds \(bounds) fitting \(fitting) popover \(content)\n"
                    FileHandle.standardError.write(Data(report.utf8))
                    HerdDebugCapture.write(view, to: path)
                }
            }
        }
    }

    /// Tells the model the panel is gone, whichever way it closed: the button, a click outside, or
    /// Escape. The model uses this to fall back to its idle poll interval.
    ///
    /// - Parameter notification: Unused; required by the delegate protocol.
    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
        model.panelDidClose()
        // After the model, so the status item's deferred width is applied against an `isPanelOpen` that
        // is already false. The other order would defer it again and leave the item at its old width
        // until the next poll.
        onDidClose()
    }

    /// Starts watching for a click in another application, and closes the popover on the first one.
    ///
    /// Idempotent: a monitor already installed is left alone rather than stacked, so a second `show`
    /// without an intervening close cannot leak one.
    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            // Hopped to the main actor because the monitor's handler is not main-actor isolated, and
            // everything it touches is AppKit.
            Task { @MainActor in
                guard let self, self.popover.isShown else { return }
                self.popover.performClose(nil)
            }
        }
    }

    /// Stops watching. Safe to call when nothing is installed.
    private func removeOutsideClickMonitor() {
        guard let monitor = outsideClickMonitor else { return }
        NSEvent.removeMonitor(monitor)
        outsideClickMonitor = nil
    }
}
