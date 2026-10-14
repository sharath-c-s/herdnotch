import Carbon.HIToolbox
import Foundation
import Testing

@testable import HerdShortcut

/// Tests for the configurable global shortcut.
///
/// Persistence is the whole reason these exist. A shortcut that stores and reads back as a *different*
/// shortcut is the failure mode a user would experience as "settings do not stick", and it is a failure the
/// previous encoding genuinely had: it treated `code > 0 && modifiers > 0` as "the user changed it", which
/// silently made `kVK_ANSI_A` (which is literally `0`) and every modifier-free binding unstorable. The
/// default is now itself modifier-free, so that bug would have made the default unstorable too.
@Suite struct HerdShortcutTests {

    // MARK: - The shipped default

    /// The default has to be bare `F19`, because that is the key the shipped Karabiner rule synthesises from
    /// a double tap of `fn`. If these two ever disagree, pressing `fn` twice does nothing and there is no
    /// error anywhere to explain why.
    @Test func shippedDefaultIsBareF19() {
        #expect(HerdShortcut.fnDoubleTap.keyCode == UInt32(kVK_F19))
        #expect(HerdShortcut.fnDoubleTap.modifiers == 0)
        #expect(HerdShortcut.fnDoubleTap.isFunctionKey)
        // A bare key is normally refused, and a function key is the documented exemption. The default has to
        // clear the app's own validity rule, or the recorder would reject the value the app ships with.
        #expect(HerdShortcut.fnDoubleTap.isSafeToRegister)
    }

    /// An unset store yields the default rather than `kVK_ANSI_A` with no modifiers, which is what a
    /// zero-means-unset encoding would produce.
    @Test func unsetStoreReadsAsTheDefault() throws {
        let defaults = try scratchDefaults()
        #expect(HerdShortcutStore.read(from: defaults) == .fnDoubleTap)
    }

    // MARK: - Round trip

    /// Every shortcut the recorder can produce must survive a write and a read unchanged, including the two
    /// values the previous encoding could not represent: key code zero, and a zero modifier mask.
    @Test func everyShortcutRoundTrips() throws {
        let defaults = try scratchDefaults()
        let cases: [HerdShortcut] = [
            HerdShortcut(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(controlKey | optionKey | cmdKey)),
            // Key code 0. Indistinguishable from "unset" under the old rule.
            HerdShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey | shiftKey)),
            // No modifiers. Also indistinguishable from "unset" under the old rule.
            HerdShortcut(keyCode: UInt32(kVK_F13), modifiers: 0),
            HerdShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)),
            .fnDoubleTap
        ]
        for shortcut in cases {
            HerdShortcutStore.write(shortcut, to: defaults)
            #expect(HerdShortcutStore.read(from: defaults) == shortcut, "\(shortcut.displayName)")
        }
    }

    /// A stored shortcut has to survive the store object being thrown away and rebuilt, which is what
    /// relaunching the app amounts to. Reading through a second `UserDefaults` handle on the same suite is
    /// the closest a unit test gets to that.
    @Test func aStoredShortcutSurvivesANewStore() throws {
        let suite = "com.boringherd.tests.\(UUID().uuidString)"
        let first = try #require(UserDefaults(suiteName: suite))
        defer { first.removePersistentDomain(forName: suite) }
        first.register(defaults: HerdShortcutStore.registrationDefaults)

        let chosen = HerdShortcut(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(cmdKey | controlKey))
        HerdShortcutStore.write(chosen, to: first)

        let second = try #require(UserDefaults(suiteName: suite))
        second.register(defaults: HerdShortcutStore.registrationDefaults)
        #expect(HerdShortcutStore.read(from: second) == chosen)
    }

    /// Resetting has to remove the keys rather than write today's default into them, so a user who resets
    /// follows the default if it ever changes instead of being frozen on the current answer.
    @Test func resetForgetsRatherThanRewrites() throws {
        let defaults = try scratchDefaults()
        HerdShortcutStore.write(
            HerdShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey)),
            to: defaults
        )
        #expect(HerdShortcutStore.read(from: defaults) != .fnDoubleTap)

        HerdShortcutStore.reset(in: defaults)

        #expect(HerdShortcutStore.read(from: defaults) == .fnDoubleTap)
        #expect(defaults.object(forKey: HerdShortcutStore.keyCodeKey) as? Int == HerdShortcutStore.unsetKeyCode)
    }

    /// A hand-edited plist is the one input this code cannot validate in advance, so a negative key code
    /// must fall back to the default rather than wrap into an enormous `UInt32`.
    @Test func aNegativeStoredKeyCodeFallsBackRatherThanWrapping() throws {
        let defaults = try scratchDefaults()
        defaults.set(-7, forKey: HerdShortcutStore.keyCodeKey)
        defaults.set(-3, forKey: HerdShortcutStore.modifiersKey)
        #expect(HerdShortcutStore.read(from: defaults) == .fnDoubleTap)
    }

    // MARK: - Validity

    /// A bare printable key must be refused. Registering one claims it system-wide, so binding `H` alone
    /// would make the letter `h` open a search window in every application instead of typing.
    @Test func aBarePrintableKeyIsRefusedAndAFunctionKeyIsNot() {
        #expect(!HerdShortcut(keyCode: UInt32(kVK_ANSI_H), modifiers: 0).isSafeToRegister)
        #expect(!HerdShortcut(keyCode: UInt32(kVK_Space), modifiers: 0).isSafeToRegister)
        #expect(HerdShortcut(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey)).isSafeToRegister)
        #expect(HerdShortcut(keyCode: UInt32(kVK_F5), modifiers: 0).isSafeToRegister)
    }

    // MARK: - Display

    /// Modifier glyphs must come out in Apple's menu order, which is not the bit order of the mask and so
    /// has to be written out rather than derived.
    @Test func modifiersAreOrderedTheWayMenusOrderThem() {
        let all = HerdShortcut(
            keyCode: UInt32(kVK_ANSI_H),
            modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey)
        )
        #expect(all.displayName == "⌃⌥⇧⌘H")
        // Built in the opposite order, to prove the label is derived from the mask rather than from the order
        // the bits were combined in.
        let reversed = HerdShortcut(
            keyCode: UInt32(kVK_ANSI_H),
            modifiers: UInt32(shiftKey | controlKey | optionKey | cmdKey)
        )
        #expect(reversed.displayName == all.displayName)
    }

    /// Function keys need names, because the shipped default is one and a label reading `key 80` would be
    /// useless.
    @Test func functionKeysAreNamed() {
        #expect(HerdShortcut(keyCode: UInt32(kVK_F19), modifiers: 0).displayName == "F19")
        #expect(HerdShortcut(keyCode: UInt32(kVK_F1), modifiers: 0).displayName == "F1")
        #expect(
            HerdShortcut(keyCode: UInt32(kVK_F12), modifiers: UInt32(cmdKey)).displayName == "⌘F12"
        )
    }

    /// An unnamed key must still produce something a human can act on, since a hand-edited plist can hold
    /// one and the alternative is a blank label.
    @Test func anUnnamedKeyFallsBackToItsCode() {
        // kVK_ANSI_KeypadPlus is deliberately outside both name tables.
        let shortcut = HerdShortcut(keyCode: UInt32(kVK_ANSI_KeypadPlus), modifiers: UInt32(cmdKey))
        #expect(shortcut.displayName == "⌘key \(kVK_ANSI_KeypadPlus)")
    }

    /// `F19` alone is a lie by omission on a Mac, because no Apple keyboard has that key. The default's
    /// summary therefore has to name what the user actually presses, and only the default: once rebound, the
    /// Karabiner rule no longer applies and the annotation would be wrong.
    @Test func onlyTheDefaultSummarisesAsFnFn() {
        #expect(HerdShortcut.fnDoubleTap.summary == "fn fn")
        let rebound = HerdShortcut(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey | optionKey))
        #expect(rebound.summary == rebound.displayName)
        #expect(rebound.summary == "⌥⌘H")
        // A different function key must not inherit the annotation either.
        let otherFunctionKey = HerdShortcut(keyCode: UInt32(kVK_F18), modifiers: 0)
        #expect(otherFunctionKey.summary == "F18")
    }

    // MARK: - Helpers

    /// A `UserDefaults` in a throwaway suite, with the shipped registrations applied.
    ///
    /// A scratch suite rather than `.standard`, so a test run cannot leave a shortcut behind in the real
    /// app's preferences. The domain is removed when the test finishes, which `UserDefaults` only does
    /// reliably for a named suite.
    private func scratchDefaults() throws -> UserDefaults {
        let suite = "com.boringherd.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.register(defaults: HerdShortcutStore.registrationDefaults)
        return defaults
    }
}
