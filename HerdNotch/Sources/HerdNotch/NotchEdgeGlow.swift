import AppKit
import HerdKit
import HerdPanelUI
import SwiftUI

/// Content of ``NotchEdgeGlow``: two vertical light bars hugging the screen's leading and trailing edges,
/// each fading from the status colour to fully clear over ``barWidth``. Transparent everywhere else, so
/// the glow never dims or tints the desktop it floats over.
private struct NotchEdgeGlowView: View {
    let color: Color

    private let barWidth: CGFloat = 110

    var body: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [color.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: barWidth)
            Spacer(minLength: 0)
            LinearGradient(colors: [.clear, color.opacity(0.55)], startPoint: .leading, endPoint: .trailing)
                .frame(width: barWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

/// Flashes a status-tinted glow down the left and right edges of a screen when an agent blocks or
/// finishes, so a state that matters is visible even where the user is not currently looking, not only in
/// the toast anchored under one collapsed pill. Purely decorative, click-through, and reused for the whole
/// process lifetime, mirroring ``NotchToast``'s own reused-panel/cancel-and-reschedule dismiss discipline.
///
/// **Deliberately its own panel, not folded into ``NotchToast``.** The toast is a small, hoverable content
/// panel anchored under one pill; this is a full-screen, click-through decoration over a whole display's
/// frame with opposite mouse behaviour. Merging them would mean branching most of `NotchToast.show` on
/// which shape was wanted.
///
/// Thread-safety: main-actor isolated, as all AppKit work must be.
@MainActor
final class NotchEdgeGlow {
    /// The panel, created lazily on first flash so a session with no alerts never builds one.
    private var panel: NSPanel?

    /// The pending auto-hide. Cancelled and replaced on every new ``flash(status:on:duration:)`` call, the
    /// same "a second event re-arms the timer" rule `NotchToast`'s own dismiss timer documents.
    private var dismissWork: DispatchWorkItem?

    /// Flashes the glow for `status`'s colour over `screen`, replacing whatever is currently showing
    /// (re-arming the auto-hide timer rather than leaving the earlier flash's timer to hide the new one
    /// early).
    ///
    /// - Parameters:
    ///   - status: Selects the colour via `HerdPalette.accent(for:)`. `unknown`'s `nil` accent falls back
    ///     to the palette's tertiary text colour, so a flash never silently no-ops.
    ///   - screen: The display to glow, sized to its full frame (not `visibleFrame`) so the bars reach the
    ///     screen's actual edges, under the menu bar and dock.
    ///   - duration: Seconds to hold the glow before hiding. Callers pass `HerdPreferences.popupDuration`.
    func flash(status: AgentStatus, on screen: NSScreen, duration: TimeInterval) {
        let palette = HerdPalette.resolving(currentColorScheme())
        let color = palette.accent(for: status) ?? palette.textTertiary
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        panel.setFrame(screen.frame, display: false)
        panel.contentView = NSHostingView(rootView: NotchEdgeGlowView(color: color))

        dismissWork?.cancel()
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.orderFrontRegardless()
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 1
            }
        }

        let work = DispatchWorkItem { [weak self] in self?.hide(animated: !reduceMotion) }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Hides the glow, fading out first unless Reduce Motion asked for a steady glow with no animation.
    private func hide(animated: Bool) {
        guard let panel else { return }
        dismissWork = nil
        if animated {
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = 0.25
                    panel.animator().alphaValue = 0
                },
                // `completionHandler` is not `@MainActor`-annotated, though AppKit always runs it on the
                // main thread once the animation finishes; `assumeIsolated` documents that rather than
                // hopping through another `Task`.
                completionHandler: { MainActor.assumeIsolated { panel.orderOut(nil) } }
            )
        } else {
            panel.orderOut(nil)
        }
    }

    /// The app's current effective appearance, resolved fresh on every flash — mirrors
    /// `NotchWindowController.currentPalette()`, duplicated here rather than shared since that method is
    /// private to a different type.
    private func currentColorScheme() -> ColorScheme {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    /// Builds the panel with the window flags this pure decoration needs.
    ///
    /// - `ignoresMouseEvents = true`: fully click-through, since this is a side-effect of state and must
    ///   never eat a click meant for whatever is underneath it.
    /// - `.statusBar` level and no shadow: floats above ordinary windows like the notch, but casts none of
    ///   its own since the content is already a soft gradient.
    /// - `.canJoinAllSpaces`/`.stationary`/`.ignoresCycle` so it never drags a Space switch along with it
    ///   and never appears in `⌘`-Tab-adjacent window lists.
    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }
}
