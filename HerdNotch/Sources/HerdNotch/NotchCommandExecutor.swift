import AppKit
import Foundation
import NotchCore

/// A faithful, per-display translator of `NotchCommand` into AppKit side effects.
///
/// "Faithful" is the load-bearing word: this type contains no state-machine logic of its own. Every
/// decision about *whether* to expand, collapse, schedule or cancel a timer, or install or remove a
/// monitor has already been made by `NotchInteractionReducer.reduce(_:)`; this type's only job is running
/// the effect it is handed, for the display it is handed, and reporting completion back through
/// `sendEvent` exactly once per timer fire or animation settle. It never second-guesses a command by
/// checking whether it "looks right" against some AppKit-side notion of current state, because the reducer
/// is the only place that notion is allowed to live.
///
/// ## Why `DispatchSourceTimer`, not `Timer`
///
/// `NotchEffect.scheduleHoverDebounce(generation:)` and `.scheduleExitGrace(generation:)` are scheduled as
/// GCD `DispatchSourceTimer`s on the main queue rather than `Timer`s on the main run loop. A `Timer`
/// scheduled in the default run-loop mode stalls for the entire duration of a menu track, a window drag,
/// or scroll-momentum tracking, because those put the run loop into `.eventTracking` mode where default-mode
/// timers do not fire — which is precisely the single most likely way to reintroduce the headline "stuck
/// open" bug the design review named. A `DispatchSourceTimer` on `DispatchQueue.main` is not tied to run
/// loop modes at all, so it fires on schedule regardless of what AppKit tracking loop happens to be running
/// at the time.
///
/// ## Why both a global and a local monitor, and why both need `acceptsMouseMovedEvents`
///
/// `NSEvent.addGlobalMonitorForEvents` never delivers events for this process's own windows — that is
/// documented AppKit behaviour, and the reason `HerdPanel.swift`'s outside-click monitor works at all
/// (it would be useless if it also fired for clicks on the panel it is watching). For notch hover tracking
/// that silence is exactly backwards: once the panel is expanding or expanded, most of the pointer motion
/// this type needs to see is *over the panel itself*. A local monitor (`NSEvent.addLocalMonitorForEvents`)
/// covers exactly that gap; the global monitor covers everything outside the panel. Both are required
/// together, both are torn down together on `.removePointerMonitors`, and neither is a substitute for the
/// other. The local monitor only ever sees anything, though, because `NotchPanel.acceptsMouseMovedEvents`
/// is `true`; AppKit does not deliver `mouseMoved` (or the drag variants below) to a window that opts out,
/// which is the exact bug this phase's adversarial review found — the panel never saw its own pointer
/// motion, so re-entering it during the exit grace never cancelled anything and the panel collapsed under
/// the cursor.
///
/// Both monitors also watch `.leftMouseDragged`/`.otherMouseDragged`, not only `.mouseMoved`: AppKit
/// suppresses `mouseMoved` delivery for the whole duration of a mouse-button-down drag, so a press-drag
/// that carries the pointer out of the panel (for example, scrubbing the eventual Spotify progress bar)
/// would otherwise report no containment update at all until the button comes up — leaving the panel open
/// with the pointer already gone. A drag event is treated identically to a move for containment purposes;
/// see `reportContainment(display:)`.
///
/// ## Containment is checked against the target frame, not the animating one
///
/// Pointer containment is tested against the display's expanded frame in *screen* coordinates, inflated by
/// a fixed hysteresis margin — never against the mask's live, still-animating frame. Testing against a
/// moving target would make "is the pointer inside" answer differently depending on exactly how far the
/// expand animation had progressed at the instant of the mouse-moved event, which is not a distinction a
/// user's pointer position has any business being sensitive to.
///
/// ## Thread safety
///
/// Used only from the main actor. Every framework callback this type installs (`NSEvent` monitor handlers,
/// `DispatchSourceTimer` event handlers) hops back onto the main actor explicitly with `Task { @MainActor
/// in }` before touching anything, the same idiom `HerdPanel.swift`'s outside-click monitor already uses,
/// because none of those callback contracts guarantee they run there themselves.
@MainActor
final class NotchCommandExecutor {

    /// Hysteresis margin added around a display's expanded frame before testing pointer containment, so a
    /// pointer that is nominally outside the panel by a pixel or two does not immediately start the exit
    /// grace.
    private static let hysteresisMargin: CGFloat = 12

    /// Everything this type owns for one display: the panel and animator `NotchWindowController` built for
    /// it, the two AppKit-native timers, the monitor pair, and the screen-space frame pointer containment
    /// is tested against.
    private struct DisplayState {
        let panel: NotchPanel
        let animator: NotchAnimator
        var expandedFrameScreen: CGRect
        var hoverDebounceTimer: DispatchSourceTimer?
        var exitGraceTimer: DispatchSourceTimer?
        var globalMonitor: Any?
        var localMonitor: Any?
    }

    /// Per-display AppKit-side state, keyed the same way `NotchInteractionReducer.panels` is.
    private var displays: [NotchDisplayID: DisplayState] = [:]

    /// Feeds a completed timer fire or animation settle back into `NotchWindowController`'s central event
    /// pump. Never called with anything this type invented itself — only the exact echo-back events
    /// `NotchEffect`'s documentation requires (`hoverDebounceFired`, `exitGraceFired`, `animationSettled`)
    /// plus the pointer-containment-derived `hoverExit` events the monitors exist to produce.
    private let sendEvent: (NotchEvent) -> Void

    /// - Parameter sendEvent: `NotchWindowController.send(_:)`, captured as a closure so this type never
    ///   needs a reference to the controller itself.
    init(sendEvent: @escaping (NotchEvent) -> Void) {
        self.sendEvent = sendEvent
    }

    /// Registers a newly built (or geometrically updated) panel for `display`, and instantly snaps its
    /// mask to whichever resting geometry `presentation` implies.
    ///
    /// Called by `NotchWindowController` both when a display's panel is first created and again on every
    /// reconcile pass. A reconcile never animates this snap: a screen's geometry changing (a resolution
    /// switch, a notch reclassification) is not a user interaction, so there is no expand/collapse motion
    /// to play, only a possibly-different resting frame to snap to immediately.
    ///
    /// - Parameters:
    ///   - display: The display this configuration is for.
    ///   - panel: The window, already sized to `expandedFrameScreen`.
    ///   - collapsedFrame: The collapsed pill's frame, in the panel's local coordinate space.
    ///   - collapsedCornerRadius: The collapsed pill's corner radius.
    ///   - expandedFrameScreen: The expanded frame in global screen coordinates, the target pointer
    ///     containment is tested against.
    ///   - expandedCornerRadius: The expanded surface's corner radius.
    ///   - presentation: The panel's current lifecycle state, read from `NotchInteractionReducer.panels`,
    ///     used only to decide whether the instant snap lands on the collapsed or expanded resting frame.
    func configureDisplay(
        _ display: NotchDisplayID,
        panel: NotchPanel,
        collapsedFrame: CGRect,
        collapsedCornerRadius: CGFloat,
        expandedFrameScreen: CGRect,
        expandedCornerRadius: CGFloat,
        presentation: NotchPresentation
    ) {
        let animator = displays[display]?.animator ?? NotchAnimator(containerLayer: panel.containerView.layer!)
        animator.updateGeometry(
            collapsedFrame: collapsedFrame,
            collapsedCornerRadius: collapsedCornerRadius,
            expandedFrame: CGRect(origin: .zero, size: expandedFrameScreen.size),
            expandedCornerRadius: expandedCornerRadius
        )
        switch presentation {
        case .expanding, .expanded:
            animator.resetToExpanded()
        case .collapsed, .collapsing, .suspended:
            animator.resetToCollapsed()
        }
        if var state = displays[display] {
            state.expandedFrameScreen = expandedFrameScreen
            displays[display] = state
        } else {
            displays[display] = DisplayState(
                panel: panel,
                animator: animator,
                expandedFrameScreen: expandedFrameScreen
            )
        }
    }

    /// Retargets `display`'s resting collapsed shape (the notch's wings) without involving the reducer.
    /// See ``NotchAnimator/retargetCollapsed(frame:cornerRadius:)`` for what each phase does with it.
    func setCollapsedWings(_ display: NotchDisplayID, frame: CGRect, cornerRadius: CGFloat) {
        displays[display]?.animator.retargetCollapsed(frame: frame, cornerRadius: cornerRadius)
    }

    /// Tears down every timer and monitor this type owns for `display` and forgets it, because
    /// `NotchWindowController` determined the underlying screen has vanished.
    ///
    /// - Parameter display: The display to forget.
    func teardownDisplay(_ display: NotchDisplayID) {
        cancelHoverDebounceTimer(display: display)
        cancelExitGraceTimer(display: display)
        removeMonitors(display: display)
        displays[display] = nil
    }

    /// Runs `command.effect` against the panel keyed by `command.display`. A no-op, by design, if that
    /// display is not currently registered (it can vanish between a command being produced and a queued
    /// callback trying to act on it — see ``teardownDisplay(_:)``).
    ///
    /// - Parameter command: The command to execute.
    func execute(_ command: NotchCommand) {
        guard displays[command.display] != nil else { return }
        let display = command.display
        switch command.effect {
        case .startExpand(let generation):
            startExpand(display: display, generation: generation)
        case .startCollapse(let generation):
            startCollapse(display: display, generation: generation)
        case .scheduleHoverDebounce(let generation):
            scheduleHoverDebounce(display: display, generation: generation)
        case .cancelHoverDebounce:
            cancelHoverDebounceTimer(display: display)
        case .scheduleExitGrace(let generation):
            scheduleExitGrace(display: display, generation: generation)
        case .cancelExitGrace:
            cancelExitGraceTimer(display: display)
        case .installPointerMonitors:
            installPointerMonitors(display: display)
        case .removePointerMonitors:
            removeMonitors(display: display)
        case .hidePanel:
            displays[display]?.panel.orderOut(nil)
        case .showCollapsed:
            showCollapsed(display: display)
        }
    }

    // MARK: - Animation

    private func startExpand(display: NotchDisplayID, generation: UInt64) {
        guard let state = displays[display] else { return }
        state.panel.orderFrontRegardless()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        state.animator.expand(generation: generation, reduceMotion: reduceMotion) { [weak self] settled in
            Task { @MainActor in
                guard let self, self.displays[display] != nil else { return }
                // `makeKey()` is deliberately not called here. This completion can fire for an animation
                // that has already been retargeted to collapse (see `NotchAnimator`'s documentation on
                // retargeting): a raw expand completion by itself says nothing about whether the reducer
                // still considers this display expanding once `animationSettled` is actually applied. Only
                // `NotchWindowController.send(_:)` knows the answer, after `reduce(_:)` has run, so it is
                // the one that calls `makeKey()` — and only when the reducer landed this display in
                // `.expanded`, never on a stale completion for a panel that is now collapsing.
                self.sendEvent(.animationSettled(display, generation: settled))
            }
        }
    }

    private func startCollapse(display: NotchDisplayID, generation: UInt64) {
        guard let state = displays[display] else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        state.animator.collapse(generation: generation, reduceMotion: reduceMotion) { [weak self] settled in
            Task { @MainActor in
                guard let self, self.displays[display] != nil else { return }
                self.sendEvent(.animationSettled(display, generation: settled))
            }
        }
    }

    // MARK: - Timers

    private func scheduleHoverDebounce(display: NotchDisplayID, generation: UInt64) {
        cancelHoverDebounceTimer(display: display)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Read at the moment the timer is scheduled, not cached at init, so a settings change
        // (``NotchPreferences/hoverInDelayMs``) applies to the very next hover without a relaunch.
        let interval = TimeInterval(NotchPreferences.shared.hoverInDelayMs) / 1000
        timer.schedule(deadline: .now() + interval)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.sendEvent(.hoverDebounceFired(display, generation: generation))
            }
        }
        displays[display]?.hoverDebounceTimer = timer
        timer.resume()
    }

    private func cancelHoverDebounceTimer(display: NotchDisplayID) {
        displays[display]?.hoverDebounceTimer?.cancel()
        displays[display]?.hoverDebounceTimer = nil
    }

    private func scheduleExitGrace(display: NotchDisplayID, generation: UInt64) {
        cancelExitGraceTimer(display: display)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Read at the moment the timer is scheduled, not cached at init, so a settings change
        // (``NotchPreferences/exitGraceMs``) applies to the very next collapse without a relaunch.
        let interval = TimeInterval(NotchPreferences.shared.exitGraceMs) / 1000
        timer.schedule(deadline: .now() + interval)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.sendEvent(.exitGraceFired(display, generation: generation))
            }
        }
        displays[display]?.exitGraceTimer = timer
        timer.resume()
    }

    private func cancelExitGraceTimer(display: NotchDisplayID) {
        displays[display]?.exitGraceTimer?.cancel()
        displays[display]?.exitGraceTimer = nil
    }

    // MARK: - Pointer monitors

    private func installPointerMonitors(display: NotchDisplayID) {
        guard let state = displays[display], state.globalMonitor == nil, state.localMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .otherMouseDragged, .leftMouseDown]
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            Task { @MainActor in
                self?.reportContainment(display: display)
            }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            // The key-window half of the contract `NotchWindowController.send(_:)` documents: a click on the
            // collapsed pill is handled there (by the time this monitor even exists, that click has already
            // been dispatched — see that method's own documentation), but a click *inside* an
            // already-hover-opened, still-non-key panel (for example, the reminders quick-add field) has to
            // be caught here instead. `makeKey()` runs synchronously, directly in this handler, deliberately
            // not deferred through `Task { @MainActor in }` the way `reportContainment(display:)` below is:
            // AppKit's own "click-to-activate" rule swallows the very first click's interactive delivery
            // (`mouseDown` never reaches the hit-tested SwiftUI control) for any view in a window that is
            // still non-key *at the moment AppKit dispatches that click* — this handler runs before that
            // dispatch, so promoting the window to key here, before this closure returns the event, is what
            // lets that same first click also focus the text field it landed in, rather than needing a
            // second click once the window catches up.
            if event.type == .leftMouseDown, let panel = self.displays[display]?.panel, !panel.isKeyWindow {
                panel.makeKey()
            }
            Task { @MainActor in
                self.reportContainment(display: display)
            }
            return event
        }
        displays[display]?.globalMonitor = global
        displays[display]?.localMonitor = local
    }

    private func removeMonitors(display: NotchDisplayID) {
        if let monitor = displays[display]?.globalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = displays[display]?.localMonitor {
            NSEvent.removeMonitor(monitor)
        }
        displays[display]?.globalMonitor = nil
        displays[display]?.localMonitor = nil
    }

    /// Tests the current pointer location against `display`'s expanded frame, inflated by the hysteresis
    /// margin, and reports the result as `NotchEvent.hoverExit(_:pointerInside:)`.
    ///
    /// `NSEvent.mouseLocation` (the class property, in global screen coordinates) is read fresh here rather
    /// than derived from the triggering `NSEvent`'s own location, so the global and local monitor handlers
    /// above can share one implementation regardless of which coordinate space each event type natively
    /// reports in.
    private func reportContainment(display: NotchDisplayID) {
        guard let expandedFrame = displays[display]?.expandedFrameScreen else { return }
        let hitTestFrame = expandedFrame.insetBy(dx: -Self.hysteresisMargin, dy: -Self.hysteresisMargin)
        let pointerInside = hitTestFrame.contains(NSEvent.mouseLocation)
        sendEvent(.hoverExit(display, pointerInside: pointerInside))
    }

    // MARK: - Visibility

    /// Snaps `display`'s mask back to the collapsed resting geometry, then orders the panel on screen
    /// showing the collapsed pill.
    ///
    /// The mask is reset unconditionally, before the ordering check below, because a `.resume` can arrive
    /// for a panel whose mask was left sitting at its expanded (or mid-animation) geometry when `.suspend`
    /// forced it closed without running the normal collapse animation (see `NotchInteractionReducer`'s
    /// `handleSuspend`). Ordering the panel front without resetting first would show a one-frame ghost of
    /// the expanded mask over the collapsed pill's content.
    ///
    /// Idempotent: safe to call on a panel that is already visible. `NotchEffect.showCollapsed`'s
    /// documentation requires this, since a resume from a suspend whose prior state was already
    /// `.collapsed` (no paired `hidePanel`) emits it too — the ordering step below is a no-op in that case,
    /// but the mask reset above still runs, which is harmless because it was already at rest there.
    private func showCollapsed(display: NotchDisplayID) {
        guard let state = displays[display] else { return }
        state.animator.resetToCollapsed()
        guard !state.panel.isVisible else { return }
        state.panel.orderFrontRegardless()
    }
}
