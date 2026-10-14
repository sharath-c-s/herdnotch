import Carbon.HIToolbox
import Foundation

/// One system-wide keyboard shortcut, in the units Carbon's `RegisterEventHotKey` takes.
///
/// A value type in its own target rather than a nested type on the hot-key registrar, and the reason is
/// testability. Persistence and display are the two parts of a configurable shortcut that can actually be
/// wrong (a stored value that reads back as a different shortcut, a label that says `⌃⌥⌘H` for something
/// else), and both are pure functions over integers. They can therefore be tested without a window server,
/// a status item or an app, which a type living inside the executable target could not be: SwiftPM cannot
/// import an executable module whose entry point is top-level code in `main.swift`.
///
/// Carbon's own units, deliberately: virtual key codes and `cmdKey`-style modifier masks. Storing Cocoa
/// values and converting at registration would mean two representations of one fact plus a conversion table
/// to keep honest, and `NSEvent.keyCode` is already the same virtual key code, so the recorder needs no
/// translation for the key half either.
public struct HerdShortcut: Equatable, Sendable {
    /// Virtual key code, for example `kVK_ANSI_H` or `kVK_F19`.
    public let keyCode: UInt32

    /// Carbon modifier mask, an OR of `cmdKey`, `optionKey`, `controlKey` and `shiftKey`.
    ///
    /// Zero is legitimate, and that is not an oversight. The shipped default is `F19` with no modifiers,
    /// because `F19` is a key no Apple keyboard has and therefore nothing competes for.
    public let modifiers: UInt32

    /// Creates a shortcut.
    ///
    /// - Parameters:
    ///   - keyCode: Carbon virtual key code.
    ///   - modifiers: Carbon modifier mask, possibly zero.
    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    // MARK: - The shipped default

    /// The shipped default: bare `F19`, which the user reaches by pressing `fn` twice.
    ///
    /// Two facts force this shape. The first is that **Carbon cannot register `fn`**: `RegisterEventHotKey`
    /// takes a virtual key code plus a modifier mask, and `fn` is neither. It is not in Carbon's modifier
    /// vocabulary (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`), and although a raw `fn` key event does
    /// exist, it arrives as a `flagsChanged` event that the hot-key mechanism never sees. The only in-process
    /// way to observe it is a `CGEventTap` on `flagsChanged`, which needs Input Monitoring, a TCC permission
    /// this app otherwise does not want and cannot obtain without another consent prompt.
    ///
    /// The second is that **`F19` does not exist on any Apple keyboard**. Apple's own layouts stop at `F12`
    /// on laptops and `F19` is the last key on the discontinued full-size aluminium keyboard, so on this
    /// machine nothing can generate it and, more to the point, nothing else is listening for it. A bare
    /// key with no modifiers would be a terrible default for any key a user can actually type; for this one
    /// it is the safest binding available.
    ///
    /// The bridge between the two is a Karabiner-Elements complex modification that turns a double tap of
    /// `fn` into `F19`, shipped in `karabiner/herd-fn-double-tap.json`. That keeps the app itself
    /// dependency-free and needing no extra permission: it registers an ordinary hot key and never learns
    /// that `fn` was involved.
    public static let fnDoubleTap = HerdShortcut(keyCode: UInt32(kVK_F19), modifiers: 0)

    /// The key the Karabiner rule synthesises, exposed so the settings interface can say whether the user
    /// is still on the shortcut that rule targets.
    public static var fnDoubleTapKeyCode: UInt32 { fnDoubleTap.keyCode }

    /// The caffeinate toggle's shortcut: **Control+Shift+C**, an ordinary chord `RegisterEventHotKey`
    /// claims directly — no Karabiner relay, no relayed function key, unlike ``fnDoubleTap``.
    ///
    /// This replaced an earlier bare-`Control`-double-tap (relayed through a Karabiner complex modification
    /// into a bare `F18`, the same fn-relay trick ``fnDoubleTap`` still uses) after it started colliding
    /// with macOS 26's Apple Intelligence voice-typing shortcut, which also listens for a double-tap of
    /// Control: pressing Control twice to toggle caffeinate would instead (or also) start dictation. A
    /// normal modifier chord has no such collision and needs no Karabiner rule at all, so
    /// `karabiner/herd-ctrl-double-tap.json` was retired alongside it.
    ///
    /// Unlike ``fnDoubleTap``, this is not read from ``HerdShortcutStore`` or exposed in the settings
    /// window's recorder: the caffeinate toggle has no configurable-shortcut UI in this phase, so it is
    /// registered with this fixed value every launch, with no override path.
    public static let caffeinateToggle = HerdShortcut(
        keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(controlKey | shiftKey)
    )

    // MARK: - Validity

    /// Whether this combination is safe to claim system-wide.
    ///
    /// A bare printable key is rejected because registering one steals it from every application on the
    /// machine, including the text field the user is typing into: binding `H` alone would make the letter
    /// `h` open a search window instead. Function keys are exempt because they are not text, and a bare
    /// function key is the normal way to bind one.
    ///
    /// This is a UI-level guard rather than a precondition. ``HerdShortcut`` will happily hold an invalid
    /// combination, because a hand-edited plist can contain one and the reader has to be able to describe
    /// what it found before deciding to reject it.
    public var isSafeToRegister: Bool {
        modifiers != 0 || Self.functionKeyNames[keyCode] != nil
    }

    /// Whether this is a function key, which is what makes a modifier-free binding acceptable.
    public var isFunctionKey: Bool { Self.functionKeyNames[keyCode] != nil }

    // MARK: - Display

    /// The shortcut written the way a menu shows it, for example `⌃⌥⌘H` or `F19`.
    ///
    /// Derived rather than stored, so an overridden shortcut still labels itself correctly. Modifier glyphs
    /// are emitted in the order Apple's own menus use, control, option, shift, command, which is not the bit
    /// order of the mask and has to be written out explicitly.
    ///
    /// Falls back to the raw key code for a key with no name in the tables below, which is legible enough to
    /// diagnose a hand-edited plist and cannot be reached by the recorder.
    public var displayName: String {
        var name = ""
        if modifiers & UInt32(controlKey) != 0 { name += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { name += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { name += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { name += "⌘" }
        return name + (Self.keyName(keyCode) ?? "key \(keyCode)")
    }

    /// ``displayName`` plus, when the shortcut is still the shipped default, how the user actually reaches
    /// it.
    ///
    /// The annotation exists because `F19` alone is a lie by omission on this machine: no keyboard here has
    /// that key, so a menu that offered `F19` and nothing else would be advertising a shortcut the user
    /// cannot press. What they press is `fn` twice, and the Karabiner rule in between is the only reason
    /// those are the same thing. Once the shortcut is changed to anything else the annotation disappears,
    /// because the rule no longer applies.
    public var summary: String {
        self == Self.fnDoubleTap ? "fn fn" : displayName
    }

    // MARK: - Key names

    /// Printable name for a virtual key code, or `nil` when there is none.
    ///
    /// - Parameter code: Carbon virtual key code.
    /// - Returns: The name to print, or `nil`.
    public static func keyName(_ code: UInt32) -> String? {
        functionKeyNames[code] ?? printableKeyNames[code]
    }

    /// `F1` through `F20`, kept separate from the printable keys because membership of this table is also
    /// what makes a modifier-free binding legal.
    private static let functionKeyNames: [UInt32: String] = {
        let keys: [(Int, String)] = [
            (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F3, "F3"), (kVK_F4, "F4"),
            (kVK_F5, "F5"), (kVK_F6, "F6"), (kVK_F7, "F7"), (kVK_F8, "F8"),
            (kVK_F9, "F9"), (kVK_F10, "F10"), (kVK_F11, "F11"), (kVK_F12, "F12"),
            (kVK_F13, "F13"), (kVK_F14, "F14"), (kVK_F15, "F15"), (kVK_F16, "F16"),
            (kVK_F17, "F17"), (kVK_F18, "F18"), (kVK_F19, "F19"), (kVK_F20, "F20")
        ]
        return Dictionary(uniqueKeysWithValues: keys.map { (UInt32($0.0), $0.1) })
    }()

    /// The letters, digits, punctuation and named keys a user might plausibly bind with modifiers.
    ///
    /// Not exhaustive, on purpose: the keypad and the international keys are absent because nothing shows
    /// them here and ``displayName``'s fallback describes them legibly enough for a hand-edited plist.
    private static let printableKeyNames: [UInt32: String] = {
        let keys: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"),
            (kVK_ANSI_E, "E"), (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"),
            (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"),
            (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"), (kVK_ANSI_P, "P"),
            (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"),
            (kVK_ANSI_Y, "Y"), (kVK_ANSI_Z, "Z"),
            (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
            (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"),
            (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
            (kVK_ANSI_Minus, "-"), (kVK_ANSI_Equal, "="), (kVK_ANSI_LeftBracket, "["),
            (kVK_ANSI_RightBracket, "]"), (kVK_ANSI_Backslash, "\\"), (kVK_ANSI_Semicolon, ";"),
            (kVK_ANSI_Quote, "'"), (kVK_ANSI_Comma, ","), (kVK_ANSI_Period, "."),
            (kVK_ANSI_Slash, "/"), (kVK_ANSI_Grave, "`"),
            (kVK_Space, "Space"), (kVK_Return, "Return"), (kVK_Tab, "Tab"),
            (kVK_LeftArrow, "←"), (kVK_RightArrow, "→"), (kVK_UpArrow, "↑"), (kVK_DownArrow, "↓")
        ]
        return Dictionary(uniqueKeysWithValues: keys.map { (UInt32($0.0), $0.1) })
    }()
}

// MARK: - Persistence

/// Reads and writes ``HerdShortcut`` in `UserDefaults`.
///
/// Separate from the app's preferences object so the round trip is testable on its own, and because the
/// storage rule has one subtlety worth isolating: **an unset shortcut is `-1`, not `0`.** Zero cannot mean
/// "unset", because `kVK_ANSI_A` is literally `0` and a modifier mask of `0` is legitimate now that the
/// default is a bare function key. The earlier design used `code > 0 && modifiers > 0` as the "was it
/// overridden" test, which silently made both `A` and any modifier-free binding unstorable.
public enum HerdShortcutStore {
    /// Defaults key holding the virtual key code, or `-1` when the shortcut has never been changed.
    public static let keyCodeKey = "herdSearchHotKeyCode"

    /// Defaults key holding the Carbon modifier mask.
    public static let modifiersKey = "herdSearchHotKeyModifiers"

    /// Value stored in ``keyCodeKey`` when no shortcut has been chosen, so the shipped default applies.
    public static let unsetKeyCode = -1

    /// The defaults this store expects to be registered, so `defaults read` from a shell and
    /// `objectIsForced` both report the effective value.
    ///
    /// Computed rather than stored: `[String: Any]` is not `Sendable`, so a static constant of that type is a
    /// shared-mutable-state error under Swift 6. Building the dictionary per call costs two insertions and
    /// happens once at launch.
    public static var registrationDefaults: [String: Any] {
        [keyCodeKey: unsetKeyCode, modifiersKey: 0]
    }

    /// The stored shortcut, or the shipped default when none has been stored.
    ///
    /// - Parameter defaults: Backing store.
    /// - Returns: The user's shortcut, or ``HerdShortcut/fnDoubleTap``.
    public static func read(from defaults: UserDefaults) -> HerdShortcut {
        let code = defaults.integer(forKey: keyCodeKey)
        guard code >= 0 else { return .fnDoubleTap }
        let modifiers = max(0, defaults.integer(forKey: modifiersKey))
        return HerdShortcut(keyCode: UInt32(code), modifiers: UInt32(modifiers))
    }

    /// Stores a shortcut.
    ///
    /// - Parameters:
    ///   - shortcut: The shortcut to persist.
    ///   - defaults: Backing store.
    public static func write(_ shortcut: HerdShortcut, to defaults: UserDefaults) {
        defaults.set(Int(shortcut.keyCode), forKey: keyCodeKey)
        defaults.set(Int(shortcut.modifiers), forKey: modifiersKey)
    }

    /// Forgets any stored shortcut, so ``read(from:)`` returns the shipped default again.
    ///
    /// Removing the keys rather than writing the default's values into them, so that a future change to
    /// what the default *is* reaches a user who reset rather than freezing them on today's answer.
    ///
    /// - Parameter defaults: Backing store.
    public static func reset(in defaults: UserDefaults) {
        defaults.removeObject(forKey: keyCodeKey)
        defaults.removeObject(forKey: modifiersKey)
    }
}
