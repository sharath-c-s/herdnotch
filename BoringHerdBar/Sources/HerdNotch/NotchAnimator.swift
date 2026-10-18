import AppKit
import Foundation
import QuartzCore

/// Grows and shrinks a layer mask on a fixed-size window's container view, so the notch appears to open
/// and close without the window's own frame ever changing.
///
/// ## Why a mask, and why not the window frame
///
/// `NotchPanel` is created once at its display's expanded (maximum) size and never resized again for an
/// animation (see that type's documentation). What actually moves is a plain `CALayer` set as
/// `containerLayer.mask`, whose `bounds`, `position` and `cornerRadius` are animated between the
/// collapsed and expanded geometry `NotchGeometry.layout(for:expandedSize:)` computed. A plain `CALayer`
/// rather than a `CAShapeLayer` with an animated rounded-rect `path`, deliberately: two rounded-rect
/// paths with different corner radii (in particular the sharp-cornered notched collapsed frame, radius
/// `0`, against the rounded expanded frame) do not have the same path-element structure, and Core Animation
/// does not smoothly morph between paths whose element counts differ — it either refuses or snaps. A plain
/// layer's `bounds`/`position`/`cornerRadius` are each independently, smoothly animatable, which is all
/// this shape ever needs since both endpoints are always axis-aligned rounded rectangles.
///
/// ## Interruptible and generation-safe by construction
///
/// `expand(generation:reduceMotion:onSettled:)` and `collapse(generation:reduceMotion:onSettled:)` never
/// disable implicit actions and never remove an in-flight animation before starting a new one. Setting a
/// new target value on a layer that is already mid-animation is standard Core Animation retargeting: the
/// new animation starts from the layer's current *presented* value, not from the old animation's original
/// starting point and not by jump-cutting to the old target first. That is exactly the "retarget from the
/// current presented state, never cancel-then-jump" contract `NotchCommandExecutor` is required to honour,
/// and it falls out of not fighting Core Animation's default behaviour rather than anything this type does
/// explicitly.
///
/// A retarget's completion block can still fire for the animation it interrupted, at an unpredictable time
/// relative to the new one — this is why every completion carries the `generation` it was started with, for
/// `NotchInteractionReducer.reduce(_:)` to recognise and discard as stale on the other side of
/// `NotchEvent.animationSettled(_:generation:)`. This type does not attempt to suppress a stale completion
/// itself; that would just be reimplementing the reducer's own job on the wrong side of the boundary.
///
/// ## Thread safety
///
/// Used only from the main actor, like every other AppKit-touching type in this target. Completion blocks
/// are dispatched back onto the main actor explicitly with `Task { @MainActor in }`, because Core
/// Animation's `CATransaction.setCompletionBlock` contract does not itself guarantee a call on any
/// particular queue.
@MainActor
final class NotchAnimator {

    /// Expand duration: ~180ms ease-out, per the design's stated feel for the panel growing to greet the
    /// user's pointer.
    private static let expandDuration: CFTimeInterval = 0.18

    /// Collapse duration: ~150ms ease-in, slightly quicker than expand because a closing panel should not
    /// linger.
    private static let collapseDuration: CFTimeInterval = 0.15

    /// Duration of the wings widening or shrinking while the mask rests collapsed.
    private static let retargetDuration: CFTimeInterval = 0.22

    /// The mask's resting opacity while collapsed. Fully opaque: the wings sit over the menu bar, where
    /// anything less reads as a see-through grey bar beside the black cutout.
    private static let collapsedOpacity: Float = 1

    /// The mask's resting opacity while expanded.
    private static let expandedOpacity: Float = 1.0

    /// The mask layer applied to the container view's layer. A plain `CALayer`, not a `CAShapeLayer`; see
    /// this type's documentation for why.
    private let maskLayer = CALayer()

    /// The collapsed pill's frame, in the container's own local (bottom-left-origin) coordinate space.
    /// Updated by ``updateGeometry(collapsedFrame:collapsedCornerRadius:expandedFrame:expandedCornerRadius:)``
    /// on every reconcile pass, never during an animation.
    private var collapsedFrame: CGRect = .zero

    /// The collapsed pill's corner radius: `0` for a real notch cutout's sharp corners, or half the
    /// pill's height for a synthesized capsule. See ``NotchWindowController`` for which one a given
    /// display currently uses.
    private var collapsedCornerRadius: CGFloat = 0

    /// The expanded surface's frame, in the container's own local coordinate space. This is always the
    /// container's full bounds, since the window itself is sized to the expanded frame, but is stored
    /// rather than read from the layer every time so `resetToExpanded()` and `expand(...)` share one
    /// source of truth with ``collapsedFrame``.
    private var expandedFrame: CGRect = .zero

    /// The expanded surface's corner radius, from `NotchLayout/cornerRadius`.
    private var expandedCornerRadius: CGFloat = 0

    /// Where the mask is at rest or heading to, so a retarget can tell whether anything would change.
    private var maskFrame: CGRect = .zero
    private var maskCornerRadius: CGFloat = 0

    /// What the mask is doing, for ``retargetCollapsed(frame:cornerRadius:)``.
    private enum Phase { case restingCollapsed, collapsing, expandingOrExpanded }
    private var phase: Phase = .restingCollapsed

    /// Bumped on every phase change so a collapse completion that lost a race to a newer expand or reset
    /// recognises itself as stale and does nothing.
    private var phaseToken: UInt64 = 0

    /// Installs the mask on `containerLayer` and leaves it resting at the collapsed geometry until
    /// ``updateGeometry(collapsedFrame:collapsedCornerRadius:expandedFrame:expandedCornerRadius:)`` and
    /// one of ``resetToCollapsed()``/``resetToExpanded()`` are called.
    ///
    /// - Parameter containerLayer: The layer to mask — `NotchPanel.containerView.layer`.
    init(containerLayer: CALayer) {
        maskLayer.backgroundColor = NSColor.black.cgColor
        maskLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        containerLayer.mask = maskLayer
    }

    /// Records the current collapsed and expanded geometry, in the container's local coordinate space.
    ///
    /// Called by `NotchWindowController` once at panel creation and again on every reconcile pass, never
    /// mid-animation: a screen's geometry changing while a panel happens to be expanding is the one edge
    /// case this type does not attempt to animate through smoothly. `NotchWindowController` instead calls
    /// ``resetToCollapsed()``/``resetToExpanded()`` immediately afterwards to snap the mask to whichever
    /// resting state the panel's current `NotchPresentation` implies.
    ///
    /// - Parameters:
    ///   - collapsedFrame: The collapsed pill's frame, local coordinates.
    ///   - collapsedCornerRadius: The collapsed pill's corner radius.
    ///   - expandedFrame: The expanded surface's frame, local coordinates (always the container's bounds).
    ///   - expandedCornerRadius: The expanded surface's corner radius.
    func updateGeometry(
        collapsedFrame: CGRect,
        collapsedCornerRadius: CGFloat,
        expandedFrame: CGRect,
        expandedCornerRadius: CGFloat
    ) {
        self.collapsedFrame = collapsedFrame
        self.collapsedCornerRadius = collapsedCornerRadius
        self.expandedFrame = expandedFrame
        self.expandedCornerRadius = expandedCornerRadius
    }

    /// Snaps the mask to the collapsed geometry instantly, with implicit actions disabled so no animation
    /// is implied. Used at initial panel creation and after a reconcile pass for a panel whose
    /// `NotchPresentation` is currently collapsed, collapsing, or suspended.
    func resetToCollapsed() {
        // A running collapse keeps its phase and token: re-entering would let a later retarget's implicit
        // animation replace it and fire its completion early. `collapseSettled` follows up with the retarget.
        if phase != .collapsing { enter(.restingCollapsed) }
        setMaskInstantly(frame: collapsedFrame, cornerRadius: collapsedCornerRadius, opacity: Self.collapsedOpacity)
    }

    /// Snaps the mask to the expanded geometry instantly. Used after a reconcile pass for a panel whose
    /// `NotchPresentation` is currently expanding or expanded, so a screen-geometry change does not
    /// visibly snap an open panel back to its pill mid-session.
    func resetToExpanded() {
        enter(.expandingOrExpanded)
        setMaskInstantly(frame: expandedFrame, cornerRadius: expandedCornerRadius, opacity: Self.expandedOpacity)
    }

    /// Animates the mask from wherever it currently is to the expanded geometry, honouring Reduce Motion.
    ///
    /// - Parameters:
    ///   - generation: The generation `NotchEffect.startExpand(generation:)` was stamped with, echoed back
    ///     unchanged to `onSettled` so the reducer can recognise a stale completion.
    ///   - reduceMotion: When `true`, the mask snaps to the expanded geometry instantly instead of
    ///     animating, and `onSettled` fires synchronously — Reduce Motion means "finite, not slow", not
    ///     "skip the transition and leave the state machine hanging".
    ///   - onSettled: Invoked once, on the main actor, once the animation has actually run (or, under
    ///     Reduce Motion, immediately).
    func expand(generation: UInt64, reduceMotion: Bool, onSettled: @escaping @Sendable (UInt64) -> Void) {
        enter(.expandingOrExpanded)
        animate(
            to: expandedFrame,
            cornerRadius: expandedCornerRadius,
            opacity: Self.expandedOpacity,
            duration: reduceMotion ? 0 : Self.expandDuration,
            timingFunction: CAMediaTimingFunction(name: .easeOut),
            generation: generation,
            onSettled: onSettled
        )
    }

    /// Animates the mask from wherever it currently is to the collapsed geometry, honouring Reduce Motion.
    /// Same contract as ``expand(generation:reduceMotion:onSettled:)``, mirrored for collapse.
    func collapse(generation: UInt64, reduceMotion: Bool, onSettled: @escaping @Sendable (UInt64) -> Void) {
        let token = enter(.collapsing)
        animate(
            to: collapsedFrame,
            cornerRadius: collapsedCornerRadius,
            opacity: Self.collapsedOpacity,
            duration: reduceMotion ? 0 : Self.collapseDuration,
            timingFunction: CAMediaTimingFunction(name: .easeIn),
            generation: generation,
            onSettled: onSettled,
            afterSettle: { [weak self] in self?.collapseSettled(token: token) }
        )
    }

    /// Moves the resting collapsed shape (the notch's wings) to `frame`, without touching the reducer.
    ///
    /// At rest collapsed it animates with no `onSettled`: no interaction state changed, so there is no
    /// generation to echo. While expanding or expanded it only stores the target for the next `collapse`.
    /// While collapsing it stores it too, and that collapse's completion follows up with one retarget.
    func retargetCollapsed(frame: CGRect, cornerRadius: CGFloat) {
        collapsedFrame = frame
        collapsedCornerRadius = cornerRadius
        guard phase == .restingCollapsed, maskDiffersFromCollapsed else { return }
        animate(
            to: frame,
            cornerRadius: cornerRadius,
            opacity: Self.collapsedOpacity,
            duration: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Self.retargetDuration,
            timingFunction: CAMediaTimingFunction(name: .easeInEaseOut),
            generation: 0,
            onSettled: nil
        )
    }

    private var maskDiffersFromCollapsed: Bool {
        maskFrame != collapsedFrame || maskCornerRadius != collapsedCornerRadius
    }

    @discardableResult
    private func enter(_ newPhase: Phase) -> UInt64 {
        phase = newPhase
        phaseToken &+= 1
        return phaseToken
    }

    private func collapseSettled(token: UInt64) {
        guard token == phaseToken, phase == .collapsing else { return }
        phase = .restingCollapsed
        if maskDiffersFromCollapsed {
            retargetCollapsed(frame: collapsedFrame, cornerRadius: collapsedCornerRadius)
        }
    }

    /// Shared animate-or-snap implementation for ``expand(generation:reduceMotion:onSettled:)`` and
    /// ``collapse(generation:reduceMotion:onSettled:)``.
    private func animate(
        to frame: CGRect,
        cornerRadius: CGFloat,
        opacity: Float,
        duration: CFTimeInterval,
        timingFunction: CAMediaTimingFunction,
        generation: UInt64,
        onSettled: (@Sendable (UInt64) -> Void)?,
        afterSettle: (@MainActor @Sendable () -> Void)? = nil
    ) {
        guard duration > 0 else {
            setMaskInstantly(frame: frame, cornerRadius: cornerRadius, opacity: opacity)
            afterSettle?()
            onSettled?(generation)
            return
        }
        maskFrame = frame
        maskCornerRadius = cornerRadius
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(timingFunction)
        CATransaction.setCompletionBlock {
            Task { @MainActor in
                afterSettle?()
                onSettled?(generation)
            }
        }
        // Implicit actions are left enabled here on purpose: this is what lets a retarget mid-flight pick
        // up from the layer's current presented value instead of jumping. See this type's documentation.
        maskLayer.bounds = CGRect(origin: .zero, size: frame.size)
        maskLayer.position = CGPoint(x: frame.midX, y: frame.midY)
        maskLayer.cornerRadius = cornerRadius
        maskLayer.opacity = opacity
        CATransaction.commit()
    }

    /// Sets the mask's geometry and opacity with implicit actions disabled, so the change is instantaneous
    /// rather than picking up whatever animation duration happens to be ambient on the current run loop
    /// turn.
    private func setMaskInstantly(frame: CGRect, cornerRadius: CGFloat, opacity: Float) {
        maskFrame = frame
        maskCornerRadius = cornerRadius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.bounds = CGRect(origin: .zero, size: frame.size)
        maskLayer.position = CGPoint(x: frame.midX, y: frame.midY)
        maskLayer.cornerRadius = cornerRadius
        maskLayer.opacity = opacity
        CATransaction.commit()
    }
}
