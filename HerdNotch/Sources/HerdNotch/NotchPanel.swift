import AppKit
import Foundation

/// The window a notch panel lives in, one per display.
///
/// Everything about this class's configuration exists to make the panel behave like part of the system
/// chrome rather than an ordinary app window:
///
/// - `.nonactivatingPanel` so a click on the panel while a full-screen app is active does not activate
///   this app and eject the user from full screen. `canBecomeKey` is overridden to `true` regardless,
///   because AppKit's default for a borderless panel is `false`, and this phase's whole certification goal
///   is a text field the user can type into — a nonactivating panel *can* become key without the app
///   becoming active, which is exactly what lets typing work over a full-screen app without stealing focus
///   from it. See `HerdSearchWindow.swift`'s `HerdKeyablePanel` for the same override used for a different
///   reason (there, the panel wants activation; here it deliberately does not).
/// - `level = .statusBar` so it draws above ordinary windows and full-screen Spaces' menu-bar-hidden
///   chrome, the same level the real notch cutout visually occupies.
/// - `isMovable = false`, because a notch has one fixed position per display; there is no drag handle and
///   there must never appear to be one.
/// - `hidesOnDeactivate = false`, because the panel's visibility is owned entirely by
///   `NotchInteractionReducer`'s `hidePanel`/`showCollapsed` commands (suspend/resume), not by whether this
///   app happens to be the active one — a nonactivating panel can be visible while some other app is
///   active, which is the normal case.
/// - `collectionBehavior` joins every Space and survives full-screen transitions, so the collapsed pill
///   is present no matter which Space or full-screen app the user is looking at.
/// - `acceptsMouseMovedEvents = true`, because AppKit does not deliver `mouseMoved` to a window at all
///   unless it opts in, and `NotchCommandExecutor`'s local `mouseMoved`/drag monitor (see that type's
///   documentation) is the only thing that reports pointer containment while the panel is expanding or
///   expanded. Without this flag that local monitor is installed but silently starves once the pointer is
///   over this panel's own content, which reads as the panel eventually collapsing under a cursor that
///   never actually left — the exit grace fires because no "still inside" event ever arrives to cancel it.
///
/// The window is created once, at the display's **expanded** (maximum) size, and never resized to animate
/// open or closed: ``NotchAnimator`` grows and shrinks a mask on ``containerView``'s layer instead.
/// Animating `setFrame` would resize the window's backing store and re-lay-out the SwiftUI content on
/// every frame of the animation, which is the shimmer-and-CPU cost the design review measured and this
/// whole fixed-window approach exists to avoid. The window's frame only ever changes at reconcile time (a
/// screen actually changed geometry), never as part of an expand/collapse.
final class NotchPanel: NSPanel {

    /// The layer-backed container `NotchAnimator` masks and that hosts the SwiftUI content.
    ///
    /// `NSVisualEffectView` rather than a plain `NSView`, so the panel reads as translucent system chrome
    /// rather than a flat SwiftUI card — the same material family the rest of macOS's own status-bar-level
    /// surfaces use.
    let containerView: NSVisualEffectView

    /// The agents card's search-navigation object, or `nil` before `NotchWindowController.makePanel(for:layout:)`
    /// wires it in. `weak`: `NotchWindowController` owns the one shared `SearchKeyNav` instance for the
    /// whole process (see that type's own documentation for why one instance, not one per display, is
    /// correct), and this panel only ever borrows a reference to it for ``sendEvent(_:)`` to consult —
    /// nothing about this window's own lifetime should keep that object alive.
    weak var searchKeyNav: SearchKeyNav?

    /// Reported around a trackpad scroll gesture plus its momentum tail, so the reducer's
    /// `.scrollMomentum` lock keeps the panel open for the whole fling. `NotchWindowController` wires both
    /// to `NotchEvent.scrollMomentumBegan`/`scrollMomentumEnded`.
    var onScrollMomentumBegan: (() -> Void)?
    var onScrollMomentumEnded: (() -> Void)?

    private var isScrollLocked = false
    private var scrollSettleWork: DispatchWorkItem?

    /// Always `true`: the one override that makes a borderless, nonactivating panel able to hold keyboard
    /// focus at all. See this type's documentation for why that combination, and not activation, is the
    /// mechanism that lets the throwaway text field type over a full-screen app.
    override var canBecomeKey: Bool { true }

    /// Intercepts Up/Down arrow keyDowns for the agents card's search mode before AppKit ever dispatches
    /// them to the key window's first responder (the search field's own field editor).
    ///
    /// `NSWindow.sendEvent(_:)` runs for every event this window receives once it is key, ahead of
    /// first-responder dispatch — see ``SearchKeyNav``'s own documentation for why that beats both of this
    /// feature's two prior, failed approaches (a SwiftUI `.onKeyPress`, which the field editor's own caret
    /// motion always wins; and a local `NSEvent` monitor, which is app-active-scoped and silently never
    /// fires while this nonactivating panel is key but the app itself is not active). Only consumes the
    /// event — returning without calling `super` — when ``SearchKeyNav/isActive`` is `true` and the key
    /// code is actually Up or Down; every other keyDown (typed characters, Return, Escape, and all of this
    /// while search mode is not active — for example the reminders quick-add field) falls through to
    /// `super.sendEvent(_:)` and reaches the first responder exactly as it would with no override at all.
    ///
    /// - Parameter event: The event AppKit is dispatching to this key window.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let nav = searchKeyNav, nav.isActive, nav.handleKeyCode(event.keyCode) {
            return
        }
        if event.type == .scrollWheel { trackScroll(event) }
        super.sendEvent(event)
    }

    /// Locks from the gesture's first event; releases when momentum ends, or shortly after the fingers
    /// lift if no momentum phase follows (a gesture with no fling never reports a momentum end).
    private func trackScroll(_ event: NSEvent) {
        guard !event.phase.isEmpty || !event.momentumPhase.isEmpty else { return }
        scrollSettleWork?.cancel()
        if !isScrollLocked {
            isScrollLocked = true
            onScrollMomentumBegan?()
        }
        let fingersDown = event.phase.contains(.began) || event.phase.contains(.changed)
            || event.phase.contains(.stationary) || event.phase.contains(.mayBegin)
        if fingersDown || event.momentumPhase.contains(.began) || event.momentumPhase.contains(.changed) {
            return
        }
        // Fingers lifted (or momentum ended): release after a short quiet period that outlasts the gap
        // before a fling's first momentum event.
        let work = DispatchWorkItem { [weak self] in
            guard let self, isScrollLocked else { return }
            isScrollLocked = false
            onScrollMomentumEnded?()
        }
        scrollSettleWork = work
        let delay: TimeInterval = event.momentumPhase.isEmpty ? 0.2 : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Builds the window at its fixed, maximum size and installs `content` as the container's sole
    /// subview.
    ///
    /// - Parameters:
    ///   - expandedFrame: The display's expanded frame in global screen coordinates
    ///     (`NotchLayout/expandedFrame`). This becomes the window's permanent frame; only a reconcile pass
    ///     reacting to an actual screen-geometry change ever calls `setFrame` again.
    ///   - content: The SwiftUI hosting view to fill the container. Callers add further furniture (for
    ///     example the collapsed-pill hover view) as additional subviews afterwards, so it draws on top.
    init(expandedFrame: NSRect, content: NSView) {
        containerView = NSVisualEffectView(frame: NSRect(origin: .zero, size: expandedFrame.size))
        super.init(
            contentRect: expandedFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        level = .statusBar
        isMovable = false
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        acceptsMouseMovedEvents = true

        containerView.wantsLayer = true
        containerView.material = .hudWindow
        containerView.state = .active
        containerView.blendingMode = .behindWindow
        containerView.autoresizingMask = [.width, .height]

        content.frame = containerView.bounds
        content.autoresizingMask = [.width, .height]
        containerView.addSubview(content)

        contentView = containerView
    }
}

/// A small, otherwise-invisible view sized to exactly the collapsed pill's rect, existing solely to give
/// `NotchWindowController` a tracking area for hover-in intent and a target for the collapsed pill's
/// click.
///
/// It deliberately overrides `mouseEntered(with:)` and nothing else — no `mouseExited`. Once a panel is
/// expanding or expanded, dismissal is the pointer monitors' job (see `NotchCommandExecutor`), not this
/// tracking area's: a window growing under a stationary cursor can emit a phantom exited/entered pair for
/// a tracking area that no longer corresponds to where the pointer visually is, and the fix is not to
/// filter that noise here but to never wire `mouseExited` to anything at all.
final class NotchHoverView: NSView {

    /// Invoked when the pointer enters this view's bounds. `NotchWindowController` wires this to
    /// `NotchEvent.hoverIntent(_:)` for the owning display.
    var onMouseEntered: (() -> Void)?

    /// Invoked on a primary click inside this view. `NotchWindowController` wires this to
    /// `NotchEvent.click(_:)` for the owning display.
    var onClick: (() -> Void)?

    /// File-drag callbacks for the shelf. Entered/ended bracket the drag so the reducer's `.drag` lock
    /// holds; `onFileDrop` receives the dropped file URLs.
    var onFileDragEntered: (() -> Void)?
    var onFileDragEnded: (() -> Void)?
    var onFileDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onFileDragEntered?()
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onFileDragEnded?()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onFileDrop?(urls)
        return true
    }

    /// Sent for every drag end (drop, Esc-cancel, drop elsewhere); `concludeDragOperation` is not. The
    /// reducer's `dragEnded` is idempotent, so also firing from `draggingExited` is harmless.
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onFileDragEnded?()
    }

    /// The one tracking area this view ever owns, replaced (never stacked) whenever the view's bounds
    /// change, since the collapsed pill's frame can itself change on a reconcile pass.
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEntered?()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
