import AppKit
import Foundation

/// Renders a live view to a PNG so the design can be inspected without Screen Recording permission.
///
/// Only ever invoked when the `HERDBAR_DUMP` or `HERDBAR_POPUP_DUMP` environment variable is set, so
/// it costs a branch in normal use.
///
/// Two details make the output trustworthy, both learned the hard way. The view's appearance is
/// forced to `darkAqua` explicitly, because a captured view inherits nothing from a window that is
/// not on screen yet. And the render is composited over an **opaque** dark fill, because
/// `cacheDisplay` draws onto transparency: an earlier version captured against nothing, so every
/// `textPrimary` glyph came out white on white and appeared to be missing. Forcing light appearance
/// worked around that, but dark mode is what this interface is tuned for, so the capture has to show
/// dark mode truthfully.
///
/// Moved out of `BoringHerdBar` into this library alongside ``HerdSearchWindow`` and
/// ``HerdSettingsWindow``, its two callers, so both host apps can drive the same capture harness. The
/// one caller that stayed behind, `BoringHerdBar/AppDelegate.writeFixtures(into:recentlyCompleted:)`,
/// is an extension declared back in that target (see `BoringHerdBar/HerdDebugCapture+Fixtures.swift`),
/// because it renders `HerdFixtureSnapshot`, a fixture fabricated for that app's own design review and
/// not something either host's model layer needs.
@MainActor
public enum HerdDebugCapture {
    /// Panel base colour from `docs/herd/DESIGN.md`, used as the opaque backing.
    private static let surface = NSColor(
        srgbRed: 0x16 / 255, green: 0x17 / 255, blue: 0x1A / 255, alpha: 1
    )

    /// Stand-in for the popover's light-mode material, used only by the light capture.
    private static let lightSurface = NSColor(
        srgbRed: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF4 / 255, alpha: 1
    )

    /// Captures a view and writes it as a PNG.
    ///
    /// - Parameters:
    ///   - view: The view to render. Its appearance is mutated to `darkAqua`.
    ///   - path: Absolute destination path.
    public static func write(_ view: NSView, to path: String) {
        // Dark is the tuned target, so it is the default. `HERDBAR_DUMP_LIGHT` captures the other
        // appearance without touching the user's system setting, which is how the light-mode
        // legibility floor gets checked.
        let wantsLight = ProcessInfo.processInfo.environment["HERDBAR_DUMP_LIGHT"] != nil
        view.appearance = NSAppearance(named: wantsLight ? .aqua : .darkAqua)
        // Painting the surface into the view's own layer, rather than compositing it underneath
        // afterwards, is what actually produces an opaque capture: `cacheDisplay` renders the layer
        // tree, and anything the tree does not paint stays transparent no matter what is drawn behind
        // it later.
        // Normally the capture paints the surface itself, because a view rendered off-screen composites
        // onto transparency. `HERDBAR_DUMP_NOFILL` skips that, which is the only way to check whether
        // the *content* is opaque on its own rather than relying on the harness to make it look so.
        view.wantsLayer = true
        if ProcessInfo.processInfo.environment["HERDBAR_DUMP_NOFILL"] == nil {
            view.layer?.backgroundColor = (wantsLight ? lightSurface : surface).cgColor
        }
        view.layoutSubtreeIfNeeded()
        view.display()

        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let layer = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: layer)

        // Composited into a bitmap declared `hasAlpha: false`, so unpainted regions cannot come back
        // as transparency. That matters: the view itself is not opaque, so its own capture is mostly
        // transparent, and a PNG carrying that alpha renders as white in most viewers, which is
        // exactly what made an earlier dark capture look like a light one.
        guard let png = layer.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        FileHandle.standardError.write(Data("herd: captured \(path)\n".utf8))
    }

    /// Virtual key codes for the keys the capture scripts drive, keyed by the name used in the
    /// environment variable.
    ///
    /// Only the keys the panel and the search window actually bind. Anything else is a literal
    /// character and is typed as itself.
    private static let namedKeys: [String: (code: UInt16, character: Character)] = [
        "down": (125, Character(UnicodeScalar(NSDownArrowFunctionKey)!)),
        "up": (126, Character(UnicodeScalar(NSUpArrowFunctionKey)!)),
        "return": (36, "\r"),
        "escape": (53, "\u{1B}")
    ]

    /// Replays a comma-separated script of key presses into a window, synchronously.
    ///
    /// Exists because this process is denied Screen Recording, so the only way to see what the
    /// keyboard does to the interface is to drive it from inside and capture the result. The events go
    /// through `NSWindow.sendEvent`, which is the same path a real key press takes once AppKit has
    /// dequeued it, so SwiftUI's `onKeyPress` sees exactly what it would see from the user. No
    /// Accessibility permission is involved: these are this application's own events, not synthesised
    /// system input.
    ///
    /// - Parameters:
    ///   - script: Comma-separated steps. A step is either a name from ``namedKeys`` or a literal
    ///     string, each character of which is typed in turn.
    ///   - window: The window to deliver to. Nothing happens when it is `nil`.
    public static func replay(_ script: String, into window: NSWindow?) {
        guard let window else { return }
        for step in script.split(separator: ",") {
            let token = String(step)
            if let key = namedKeys[token] {
                send(code: key.code, characters: String(key.character), to: window)
            } else {
                for character in token {
                    send(code: 0, characters: String(character), to: window)
                }
            }
        }
    }

    /// Clicks once at a point in window coordinates.
    ///
    /// The counterpart to ``replay(_:into:)`` for the parts of the interface that only respond to the
    /// mouse, which is how the session and workspace headers are reached. Same reasoning: these are
    /// this application's own events delivered through `NSWindow.sendEvent`, not synthesised system
    /// input, so no Accessibility permission is involved and nothing outside the process sees them.
    ///
    /// - Parameters:
    ///   - point: Location in the window's own coordinate space, origin bottom-left.
    ///   - window: The window to deliver to. Nothing happens when it is `nil`.
    public static func click(at point: NSPoint, in window: NSWindow?) {
        guard let window else { return }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            window.sendEvent(event)
        }
    }

    /// Delivers one key press that carries modifiers.
    ///
    /// The shortcut recorder is the only part of the interface whose behaviour depends on the modifier flags
    /// rather than on the characters, and ``replay(_:into:)`` sends none: a shortcut is a key *plus*
    /// modifiers, so a recorder driven without them could only ever be shown rejecting a bare key. This is
    /// what lets the harness record `⌥⌘J` through the real control and then check that the global hot key
    /// actually rebound, which is the one claim about the settings window that cannot be checked from
    /// outside the process.
    ///
    /// - Parameters:
    ///   - code: Virtual key code, which is what the recorder reads.
    ///   - characters: The characters the press produces. Unused by the recorder, but part of a well-formed
    ///     event.
    ///   - modifiers: Cocoa modifier flags held during the press.
    ///   - window: The window to deliver to. Nothing happens when it is `nil`.
    public static func press(
        code: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags,
        in window: NSWindow?
    ) {
        guard let window else { return }
        send(code: code, characters: characters, modifiers: modifiers, to: window)
    }

    /// Delivers one key down and its matching key up.
    ///
    /// Both halves are sent because a text field that only ever saw key-downs would still work, but a
    /// view watching for the release would not, and the point of the harness is to be indistinguishable
    /// from a real press.
    ///
    /// - Parameters:
    ///   - code: Virtual key code. Zero for a literal character, whose identity comes from
    ///     `characters` rather than from the code.
    ///   - characters: The characters the press produces.
    ///   - modifiers: Cocoa modifier flags held during the press. Empty for ordinary typing.
    ///   - window: The window to deliver to.
    private static func send(
        code: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = [],
        to window: NSWindow
    ) {
        for isDown in [true, false] {
            guard let event = NSEvent.keyEvent(
                with: isDown ? .keyDown : .keyUp,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: code
            ) else { continue }
            window.sendEvent(event)
        }
    }
}
