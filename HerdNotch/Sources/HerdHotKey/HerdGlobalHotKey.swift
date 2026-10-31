import AppKit
import Carbon.HIToolbox
import Combine
import Foundation
import HerdShortcut

/// A single system-wide keyboard shortcut, registered with Carbon's `RegisterEventHotKey`.
///
/// Carbon rather than a SwiftPM dependency such as `KeyboardShortcuts`, and the reason is narrow: this
/// app needs one shortcut and a recorder small enough to fit in a settings form, which is about sixty
/// lines here against a package to fetch, vendor and keep current. `RegisterEventHotKey` is also the API
/// those packages call underneath, so nothing is given up in reliability, and it needs no Accessibility
/// permission, unlike a `CGEventTap`.
///
/// The shortcut itself is ``HerdShortcut``, which lives in its own target so its persistence and display
/// can be tested without a running app.
///
/// Thread-safety: main-actor isolated. Carbon delivers hot-key events on the main run loop, and the
/// handler hops nowhere, so the callback runs where AppKit expects it.
@MainActor
public final class HerdGlobalHotKey {
    /// Four-character signature Carbon uses to namespace hot-key ids. Any value works as long as it is
    /// stable within the process.
    private static let signature: OSType = 0x68_65_72_64 // 'herd'

    /// Hands out a unique ``EventHotKeyID/id`` to each instance.
    ///
    /// This is the fix for the real bug: `GetApplicationEventTarget()` is one target shared by every
    /// `HerdGlobalHotKey` in the process, and Carbon calls each installed handler on it, starting from the
    /// most recently installed, until one returns `noErr`. Every instance used to register with the same
    /// hard-coded `id: 1`, and the handler only ever checked ``signature`` (identical for every instance)
    /// before calling its own `onFire` and returning `noErr`. With one hot key registered that was
    /// harmless; with two — `HerdNotch`'s search shortcut and its Ctrl-Ctrl caffeinate toggle — the
    /// most-recently-installed instance's handler claimed *every* `'herd'`-signed hot-key event on the
    /// shared target, on either shortcut, and always said "handled", so the earlier-installed instance's
    /// handler was never reached. That is the actual reason fn-fn opened nothing: the key fired, Carbon
    /// delivered it, and the caffeinate toggle silently swallowed it. A per-instance id closes this,
    /// because it lets each handler tell "my hot key fired" from "a different instance's hot key fired"
    /// and answer `eventNotHandledErr` for the latter, letting Carbon keep walking the chain.
    @MainActor
    private static var nextHotKeyID: UInt32 = 1

    /// This instance's unique id within ``signature``'s namespace, assigned once so a settings-window
    /// rebind (which tears down and re-registers ``hotKeyRef`` via ``register(_:)``) keeps identifying the
    /// same instance's events. A plain `UInt32` constant, readable from the non-capturing Carbon callback
    /// with no actor hop, for the same reason ``signature`` already is: it is `Sendable` and, being a
    /// `let`, cannot change after `init` sets it.
    ///
    /// `internal`, not `private`: `HerdGlobalHotKeyTests` reads it back (via `@testable import`) to build a
    /// synthetic Carbon event addressed at one specific instance, which is how that suite proves the
    /// cross-instance routing bug this property fixes without needing a real key press.
    let hotKeyID: UInt32

    /// The registered hot key, or `nil` when registration failed or has been torn down.
    private var hotKeyRef: EventHotKeyRef?

    /// The installed Carbon event handler, removed on ``unregister()``.
    private var handlerRef: EventHandlerRef?

    /// Invoked on the main actor each time the shortcut fires.
    private let onFire: () -> Void

    /// Creates the object without registering anything.
    ///
    /// - Parameter onFire: Called on every press of the registered shortcut.
    public init(onFire: @escaping () -> Void) {
        self.onFire = onFire
        hotKeyID = Self.nextHotKeyID
        Self.nextHotKeyID += 1
    }

    // No `deinit` cleanup on purpose. Both the hot key and the handler are registered against
    // `GetApplicationEventTarget()`, so the kernel of the registration is this process and it goes away
    // when the process does. A `deinit` would also have to reach non-`Sendable` Carbon references from
    // a nonisolated context, which is a Swift 6 concurrency violation for no gain. Teardown while the
    // app is alive is what ``unregister()`` is for, and the app delegate calls it on termination.

    /// Registers `shortcut` system-wide, replacing any previous registration.
    ///
    /// Failure is reported rather than thrown because there is exactly one cause in practice, another
    /// application already owns the combination, and there is nothing the app can do about it beyond
    /// telling the user. The rest of the app works without the shortcut, so a failure here must not be
    /// fatal; ``HerdHotKeyStatus`` is what carries the fact into the interface.
    ///
    /// Re-registration is why ``unregister()`` runs first: Carbon holds the previous claim until it is
    /// released, so rebinding without releasing would leave the old shortcut live as well as the new one.
    ///
    /// - Parameter shortcut: The shortcut to claim.
    /// - Returns: `true` when the shortcut is now registered.
    @discardableResult
    public func register(_ shortcut: HerdShortcut) -> Bool {
        unregister()

        // The handler is installed before the key is registered, because Carbon can deliver the first
        // event as soon as registration returns.
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                // Every instance shares one process-wide target (`GetApplicationEventTarget()`), so both
                // halves of the id have to match, not just `signature`: the signature alone cannot tell
                // this instance's hot key from a different `HerdGlobalHotKey`'s, and answering `noErr` for
                // an event that is not actually this instance's own is exactly the bug ``nextHotKeyID``'s
                // documentation names — it swallows the event before the real owner's handler ever runs.
                var identifier = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                let owner = Unmanaged<HerdGlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                guard identifier.signature == HerdGlobalHotKey.signature,
                      identifier.id == owner.hotKeyID else {
                    return OSStatus(eventNotHandledErr)
                }
                // Carbon calls this on the main run loop, but the compiler cannot know that, so the
                // hop is made explicit rather than asserted.
                Task { @MainActor in owner.onFire() }
                return noErr
            },
            1,
            &eventType,
            context,
            &handlerRef
        )
        guard installed == noErr else { return false }

        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            EventHotKeyID(signature: Self.signature, id: hotKeyID),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            FileHandle.standardError.write(
                Data("herd: could not register \(shortcut.displayName); another app may own it\n".utf8)
            )
            unregister()
            return false
        }
        hotKeyRef = reference
        return true
    }

    /// Releases the shortcut and the event handler. Safe to call when nothing is registered.
    public func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }
}

/// What the interface is allowed to say about the global shortcut.
///
/// A separate observable object rather than a property on the preferences, because it is not a preference:
/// it is the *outcome* of trying to honour one. The distinction matters in exactly the case this type
/// exists for. A user picks `⌥Space`, the preference stores `⌥Space`, and Carbon refuses it because
/// something else already owns it. The stored value and the live registration then disagree, and the
/// settings window has to be able to show both, otherwise the shortcut appears to have been accepted and
/// simply never fires. That silence was the previous behaviour: registration failure went to standard
/// error, where a user launching from LaunchServices never sees it.
///
/// Thread-safety: main-actor isolated, since only the app delegate writes it and only SwiftUI reads it.
@MainActor
public final class HerdHotKeyStatus: ObservableObject {
    /// The shortcut the app last tried to register.
    @Published public private(set) var shortcut: HerdShortcut = .fnDoubleTap

    /// Whether that attempt succeeded.
    @Published public private(set) var isRegistered = false

    /// Creates a status with no registration attempt recorded yet.
    public init() {}

    /// Records the outcome of a registration attempt.
    ///
    /// - Parameters:
    ///   - shortcut: The shortcut that was attempted.
    ///   - registered: Whether Carbon accepted it.
    public func record(shortcut: HerdShortcut, registered: Bool) {
        self.shortcut = shortcut
        isRegistered = registered
    }

    /// One sentence describing the current state, for the settings window and the status item menu.
    ///
    /// Names the remedy rather than only the fault, because "unavailable" on its own leaves the user with
    /// nothing to do. There is no way to find out *which* application holds a Carbon hot key, so the copy
    /// does not pretend to know.
    public var explanation: String {
        if isRegistered {
            return shortcut == .fnDoubleTap
                ? "Press fn twice. Needs the Karabiner rule; see the README."
                : "Registered."
        }
        return "\(shortcut.displayName) is already taken by another app. Pick a different one."
    }
}
