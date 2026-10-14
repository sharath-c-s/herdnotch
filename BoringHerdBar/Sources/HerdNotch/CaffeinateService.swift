import Foundation
import IOKit.pwr_mgt

/// Toggles a single `IOPMAssertionCreateWithName` assertion that prevents idle system sleep.
///
/// A concrete type, not a protocol: IOKit power-management assertions have exactly one implementation
/// worth having, there is no boundary here that unit testing needs stubbed (the assertion lifecycle is
/// exercised end to end with `pmset -g assertions`, not with a mock), and the team rule is no interface for
/// one product.
///
/// The assertion is `kIOPMAssertPreventUserIdleSystemSleep`, the same one `caffeinate(8)` itself creates —
/// no subprocess is spawned; this calls the IOKit API `caffeinate` wraps directly, which is both cheaper
/// and lets ``isActive`` reflect the assertion's true lifetime rather than a child process's.
///
/// An assertion held forever by an app a user forgot they toggled is worse than the sleep it prevents, so
/// every activation schedules an automatic release out, cancelled and re-armed by every ``toggle()``. How
/// far out is ``NotchPreferences/caffeinateAutoOffMinutes``, read live at schedule time; `0` means never
/// auto-off, so the assertion is held until the user (or the hotkey, or the notch's own toggle) turns it
/// off by hand.
///
/// Thread-safety: `@MainActor`, like every other type in this target. `IOPMAssertionCreateWithName` and
/// `IOPMAssertionRelease` are cheap, synchronous IOKit calls with no blocking I/O of their own, so unlike
/// `RemindersService` or `SpotifyNowPlayingService` this needs no background queue.
@MainActor
final class CaffeinateService: ObservableObject {
    /// Whether the sleep-prevention assertion is currently held. Mirrors the assertion's own lifetime
    /// exactly: it flips to `true` only after `IOPMAssertionCreateWithName` actually succeeds, and back to
    /// `false` on every release, whether user-initiated, timed, or at shutdown.
    @Published private(set) var isActive = false

    /// When the pending auto-release fires, or `nil` when none is scheduled (not held, or held with no timer).
    @Published private(set) var autoOffDate: Date?

    /// The live assertion's id, or `0` when none is held. `IOPMAssertionID` has no sentinel "invalid" value
    /// of its own; `0` is used the same way `assertionID` is documented to behave when uninitialised.
    private var assertionID: IOPMAssertionID = 0

    /// The pending auto-release, rescheduled on every ``activate()`` and torn down on every ``deactivate()``.
    /// A `DispatchSourceTimer`, matching `NotchCommandExecutor`'s own discipline (never a run-loop `Timer`),
    /// though the reason differs here: this timer only ever needs to fire once, well after any interactive
    /// gesture, so run-loop mode starvation is not the risk a `Timer` would carry elsewhere in this app —
    /// `DispatchSourceTimer` is used anyway for one consistent timer idiom across the target.
    private var autoReleaseTimer: DispatchSourceTimer?

    /// Asked when the auto-off timer fires; `true` keeps the assertion held (a condition still wants it), so
    /// ending the manual layer never passes through a released state.
    var keepHeldOnAutoOff: (() -> Bool)?

    /// Creates the service with no assertion held.
    init() {}

    /// Releases the assertion synchronously if one is held, bypassing the actor-isolated ``deactivate()``
    /// since a `deinit` cannot call an isolated method without an `await` this synchronous context cannot
    /// provide. Safe: at `deinit` this instance has exactly zero remaining references, so no concurrent
    /// access can race a direct read of its own stored properties.
    ///
    /// This is a last-resort net, not the primary teardown path — `deinit` on an object this app holds for
    /// its entire process lifetime may never run before the process itself exits, which is why
    /// ``releaseForShutdown()`` also exists and is called explicitly from `applicationWillTerminate(_:)`.
    deinit {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
        }
        autoReleaseTimer?.cancel()
    }

    /// Activates if inactive, or releases if active. A manual toggle: activation uses the auto-off preference.
    func toggle() {
        isActive ? deactivate() : activate(autoOffMinutes: Self.preferredAutoOffMinutes)
    }

    /// Holds the assertion for an automatic reason. `autoOffMinutes == nil` skips the auto-off timer, so a
    /// condition hold (agents busy, on charger) is never cut short by the manual timer. A no-op when already held.
    func acquire(autoOffMinutes: Int?) {
        activate(autoOffMinutes: autoOffMinutes)
    }

    /// Re-arms (or, with `nil`, cancels) the auto-off timer of a held assertion. A no-op when not held.
    func setAutoOff(minutes: Int?) {
        guard isActive else { return }
        scheduleAutoRelease(minutes: minutes)
    }

    /// Releases the assertion. A no-op when not held.
    func release() {
        deactivate()
    }

    /// The auto-off preference as a timer length, with `0` ("never") mapped to `nil`.
    static var preferredAutoOffMinutes: Int? {
        let minutes = NotchPreferences.shared.caffeinateAutoOffMinutes
        return minutes > 0 ? minutes : nil
    }

    /// Explicit shutdown hook for `NotchAppDelegate.applicationWillTerminate(_:)`. Idempotent: a no-op if
    /// nothing is held.
    func releaseForShutdown() {
        deactivate()
    }

    /// Creates the assertion and starts the auto-release clock. A no-op if already active.
    private func activate(autoOffMinutes: Int?) {
        guard !isActive else { return }
        var newID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "HerdNotch caffeinate toggle" as CFString,
            &newID
        )
        guard result == kIOReturnSuccess else {
            FileHandle.standardError.write(
                Data("herdnotch: caffeinate assertion failed with IOReturn \(result)\n".utf8)
            )
            return
        }
        assertionID = newID
        isActive = true
        scheduleAutoRelease(minutes: autoOffMinutes)
    }

    /// Releases the assertion and cancels the auto-release clock. A no-op if already inactive.
    private func deactivate() {
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isActive = false
        cancelAutoRelease()
    }

    /// (Re)schedules the timed release `minutes` out, cancelling any previous one first so repeated toggles
    /// (off, then on again) restart the clock rather than stacking timers. A no-op, with no timer scheduled
    /// at all, when `minutes` is `nil`: the assertion simply stays held with nothing pending to release it.
    private func scheduleAutoRelease(minutes: Int?) {
        cancelAutoRelease()
        guard let minutes, minutes > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + TimeInterval(minutes * 60))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.keepHeldOnAutoOff?() == true { self.cancelAutoRelease() } else { self.deactivate() }
            }
        }
        autoReleaseTimer = timer
        autoOffDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        timer.resume()
    }

    /// Cancels and forgets the pending auto-release timer, if any.
    private func cancelAutoRelease() {
        autoReleaseTimer?.cancel()
        autoReleaseTimer = nil
        autoOffDate = nil
    }
}
