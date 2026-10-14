import Carbon.HIToolbox
import Foundation
import Testing

@testable import HerdHotKey
@testable import HerdShortcut

/// Tests for ``HerdGlobalHotKey``'s Carbon event routing.
///
/// This is the regression suite for the real bug behind "fn-fn does nothing in HerdNotch": every
/// `HerdGlobalHotKey` instance in a process shares one target, `GetApplicationEventTarget()`, and Carbon
/// calls each instance's installed handler on it, starting from the most recently installed, until one
/// returns `noErr`. The handler used to identify "is this my hot key?" by checking only ``signature``,
/// which is a `private static let` identical for every instance. With one hot key registered (the shape
/// `BoringHerdBar/AppDelegate` has always used) that check is vacuously true and harmless. With two —
/// `HerdNotch`'s fn-fn search shortcut and its Ctrl-Ctrl caffeinate toggle — the most-recently-installed
/// instance's handler claimed *every* `'herd'`-signed hot-key event, on either shortcut, and always
/// answered `noErr`, so the earlier-installed instance's own handler, and its `onFire`, were never reached.
/// Nothing in ``HerdShortcutTests`` or a manual keypress could have caught this: it only reproduces with
/// two live instances in the same process, which is exactly what a physical fn-fn press exercises in
/// `HerdNotch` and what no existing test constructed.
///
/// A physical key press cannot be driven from an automated test (there is no hardware to press, and
/// synthesizing one via `CGEventPost` needs Accessibility permission this suite cannot assume a CI runner
/// has granted). Carbon's hot-key delivery does not need one either: `RegisterEventHotKey` only claims a
/// combination with the OS, and the event it later delivers to `GetApplicationEventTarget()` is an
/// ordinary `EventRef` this suite can construct and post itself with the same public Carbon APIs
/// `HerdGlobalHotKey` uses to receive it. That is what ``postSyntheticHotKeyEvent(id:)`` does, addressed at
/// one instance's own ``HerdGlobalHotKey/hotKeyID`` (exposed `internal` for exactly this), which is a
/// faithful, deterministic stand-in for "the OS decided this hot key fired" with no keyboard involved.
/// `.serialized`: every test in this suite that calls ``HerdGlobalHotKey/register(_:)`` claims one of two
/// fixed function keys with the real OS via `RegisterEventHotKey`, and Swift Testing otherwise runs a
/// suite's `async` tests concurrently. Two tests registering the same key at once is a genuine collision at
/// the OS level, not a bug in either test, and `RegisterEventHotKey` correctly refuses the second — this
/// just avoids the two ever overlapping instead of making the suite race-dependent on which one wins.
@MainActor
@Suite(.serialized) struct HerdGlobalHotKeyTests {

    /// Function keys nothing else on a development machine plausibly binds, mirroring why ``HerdShortcut``
    /// itself ships `F18`/`F19` as its two defaults. Deliberately different from both of those, so this
    /// suite cannot collide with a `BoringHerdBar` or `HerdNotch` instance that happens to be running
    /// alongside the test process on the same machine.
    private static let shortcutA = HerdShortcut(keyCode: UInt32(kVK_F16), modifiers: 0)
    private static let shortcutB = HerdShortcut(keyCode: UInt32(kVK_F17), modifiers: 0)

    /// Posts a synthetic `kEventHotKeyPressed` event carrying `id`, addressed at
    /// `GetApplicationEventTarget()` exactly the way Carbon itself would after a real key press, and the
    /// exact event every installed `HerdGlobalHotKey` handler in this process receives and has to decide
    /// whether to claim.
    ///
    /// - Parameter id: The ``HerdGlobalHotKey/hotKeyID`` this event claims to belong to.
    private func postSyntheticHotKeyEvent(id: UInt32) {
        var eventRef: EventRef?
        let created = CreateEvent(
            nil,
            OSType(kEventClassKeyboard),
            UInt32(kEventHotKeyPressed),
            0,
            EventAttributes(kEventAttributeNone),
            &eventRef
        )
        #expect(created == noErr)
        guard let eventRef else { return }
        defer { ReleaseEvent(eventRef) }

        // 0x68_65_72_64 is 'herd', the same namespace `HerdGlobalHotKey.signature` uses. Duplicated here
        // rather than exposed from the library: it is a fixed, documented implementation constant
        // (`HerdGlobalHotKey`'s own doc comment states it), not a value this suite needs the library to
        // hand over to build a faithful synthetic event.
        var hotKeyID = EventHotKeyID(signature: 0x68_65_72_64, id: id)
        let setStatus = SetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size,
            &hotKeyID
        )
        #expect(setStatus == noErr)

        let sendStatus = SendEventToEventTarget(eventRef, GetApplicationEventTarget())
        // Delivered means at least one handler answered `noErr`. Both this suite's own instances and any
        // other `HerdGlobalHotKey` already live in this same test process (there should be none) would
        // answer here, so this only confirms the event reached the target, not which handler claimed it.
        #expect(sendStatus == noErr || sendStatus == OSStatus(eventNotHandledErr))
    }

    /// Two instances registered in the same process must never receive each other's ids: that uniqueness
    /// is the whole fix, and a collision here would silently reopen the routing bug even though every other
    /// assertion in this suite passed.
    @Test func instancesGetDistinctIDs() {
        let first = HerdGlobalHotKey {}
        let second = HerdGlobalHotKey {}
        #expect(first.hotKeyID != second.hotKeyID)
    }

    /// Gives a just-posted synthetic event's `Task { @MainActor in owner.onFire() }` hop (see
    /// ``HerdGlobalHotKey``'s Carbon callback) a chance to actually run before the next assertion reads the
    /// flag it sets. `postSyntheticHotKeyEvent(id:)` only *enqueues* that hop; this suite's own test body is
    /// itself main-actor-isolated, so nothing hands the executor back to run it without an explicit await.
    private func drainMainActor() async throws {
        try await Task.sleep(for: .milliseconds(50))
    }

    /// The regression case: with two `HerdGlobalHotKey` instances alive at once — the exact shape
    /// `HerdNotch` has and `BoringHerdBar` never did — firing the second-registered instance's hot key
    /// must not also fire the first's, and firing the first's must not fire the second's. Before the fix,
    /// the most-recently-installed handler (``second``, registered after ``first``) claimed both events,
    /// so ``firstFired`` would spuriously become `true` on ``shortcutB``'s event and ``secondFired`` would
    /// never become `true` at all.
    @Test func eachInstanceOnlyFiresForItsOwnHotKey() async throws {
        var firstFired = false
        var secondFired = false

        let first = HerdGlobalHotKey { firstFired = true }
        #expect(first.register(Self.shortcutA))

        let second = HerdGlobalHotKey { secondFired = true }
        #expect(second.register(Self.shortcutB))

        defer {
            first.unregister()
            second.unregister()
        }

        // second's hot key fires. Only secondFired should flip.
        postSyntheticHotKeyEvent(id: second.hotKeyID)
        try await drainMainActor()
        #expect(secondFired)
        #expect(!firstFired)

        // first's hot key fires. Only firstFired should flip from here.
        postSyntheticHotKeyEvent(id: first.hotKeyID)
        try await drainMainActor()
        #expect(firstFired)
    }

    /// An event whose id matches neither live instance is nobody's hot key and must be left unhandled
    /// (`eventNotHandledErr`), the same answer a real, unrelated application's own hot key would need
    /// Carbon to keep walking its handler chain past this process's handlers.
    @Test func unrecognisedIDFiresNothing() async throws {
        var fired = false
        let hotKey = HerdGlobalHotKey { fired = true }
        #expect(hotKey.register(Self.shortcutA))
        defer { hotKey.unregister() }

        postSyntheticHotKeyEvent(id: hotKey.hotKeyID &+ 1000)
        try await drainMainActor()
        #expect(!fired)
    }
}
