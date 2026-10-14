import AppKit
import Carbon.HIToolbox
import HerdPanelUI
import HerdShortcut
import SwiftUI

/// The settings window's shortcut recorder: click it, press a combination, and that becomes the shortcut.
///
/// Built as SwiftUI chrome with a transparent AppKit view on top purely to catch the key event, rather than
/// as one AppKit control that draws itself. The reason is that the only thing AppKit is needed for here is
/// the *virtual key code*: SwiftUI's `onKeyPress` reports a `KeyEquivalent`, which has no representation for
/// `F19` at all, and `F19` is the app's default shortcut. `NSEvent.keyCode` is already the Carbon virtual key
/// code, so the capture view is about ten lines and everything visible stays in SwiftUI, where it can use the
/// same palette as the rest of the app.
///
/// Three keys are reserved rather than recordable, and each for a reason the user would otherwise have to
/// discover by getting stuck:
///
/// - **Escape** cancels, because a recorder with no way out traps the keyboard.
/// - **Delete** resets to the shipped default, which is the only route back to `fn fn` once it is changed.
/// - **Return and Tab** are ignored while recording, because they are how a user leaves a control and
///   binding them here would make the settings window unnavigable.
struct HerdShortcutField: View {
    /// The shortcut being edited. Written on a successful capture.
    @Binding var shortcut: HerdShortcut

    /// Called when the user presses Delete, so the caller can remove the stored keys rather than write
    /// today's default into them.
    let onReset: () -> Void

    /// Whether the field currently owns the keyboard.
    @State private var isRecording = false

    /// Why the last capture was refused, or `nil` when nothing was refused.
    @State private var rejection: String?

    /// Drives the palette.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = HerdPalette.resolving(colorScheme)
        return VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(palette.hoverFill)
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(
                        isRecording ? palette.blocked : palette.hairline,
                        lineWidth: isRecording ? 1.5 : 1
                    )
                // The shortcut is a key name, so it is set in the identifier face like every other
                // identifier in this app rather than in the chrome face.
                Text(isRecording ? "press a shortcut" : shortcut.summary)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(isRecording ? palette.textTertiary : palette.textPrimary)
                    .lineLimit(1)
                HerdKeyCaptureView(
                    isRecording: $isRecording,
                    onCapture: capture(keyCode:modifiers:),
                    onReset: {
                        rejection = nil
                        onReset()
                    }
                )
            }
            .frame(width: 132, height: 24)
            .help("Click, then press the combination you want. Delete resets, Escape cancels.")

            if let rejection {
                Text(rejection)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.blocked)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Validates and stores one captured combination.
    ///
    /// The validation that matters is refusing a bare printable key. Registering one claims it system-wide,
    /// so binding `H` alone would mean the letter `h` opened a search window instead of typing, in every
    /// application. Function keys are exempt because they are not text.
    ///
    /// - Parameters:
    ///   - keyCode: Carbon virtual key code from `NSEvent.keyCode`.
    ///   - modifiers: Carbon modifier mask, already converted from the Cocoa flags.
    private func capture(keyCode: UInt32, modifiers: UInt32) {
        let candidate = HerdShortcut(keyCode: keyCode, modifiers: modifiers)
        guard candidate.isSafeToRegister else {
            rejection = "Add a modifier, or use a function key. A bare key would be claimed system-wide."
            return
        }
        rejection = nil
        shortcut = candidate
    }
}

/// A transparent first-responder view whose only job is to report one key press in Carbon's units.
///
/// It draws nothing, so the SwiftUI content underneath shows through and this stays purely an event sink.
/// Being on top in the `ZStack` is what gets it the click.
struct HerdKeyCaptureView: NSViewRepresentable {
    /// Whether the view currently owns the keyboard. Written from AppKit, read by SwiftUI for the ring.
    @Binding var isRecording: Bool

    /// Receives a captured combination.
    let onCapture: (UInt32, UInt32) -> Void

    /// Receives a Delete press, meaning "back to the default".
    let onReset: () -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onStateChange = { isRecording = $0 }
        view.onCapture = onCapture
        view.onReset = onReset
        return view
    }

    /// Re-points the callbacks at the current closures, which capture the current `Binding`.
    ///
    /// SwiftUI hands out a fresh struct with fresh closures on every update, and an `NSView` that kept the
    /// first set would be writing through a stale binding.
    func updateNSView(_ view: CaptureView, context: Context) {
        view.onStateChange = { isRecording = $0 }
        view.onCapture = onCapture
        view.onReset = onReset
    }

    /// The event sink.
    final class CaptureView: NSView {
        /// Reports entering and leaving recording state.
        var onStateChange: ((Bool) -> Void)?

        /// Reports a captured combination as `(keyCode, carbonModifiers)`.
        var onCapture: ((UInt32, UInt32) -> Void)?

        /// Reports a Delete press.
        var onReset: (() -> Void)?

        /// Whether a key press should be captured rather than passed on.
        private var isRecording = false {
            didSet { onStateChange?(isRecording) }
        }

        override var acceptsFirstResponder: Bool { true }

        /// Accepts the click that activates the window, rather than spending it on activation.
        ///
        /// This is a real defect fixed, not harness scaffolding, and it is the same one the popover already
        /// hit: by default AppKit swallows the first click into an inactive window, so the user has to click
        /// once to bring the window forward and again to arm the recorder, with nothing on screen explaining
        /// why the first click did nothing. That is worse here than almost anywhere else in the app, because
        /// this app is an accessory with no Dock icon, so its settings window is *usually* not the active one
        /// when the user reaches for it.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// Clicking arms the recorder.
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            isRecording = true
        }

        /// Losing focus disarms it, so clicking elsewhere in the window cancels rather than leaving a field
        /// that looks armed and is not.
        override func resignFirstResponder() -> Bool {
            isRecording = false
            return true
        }

        /// Captures one combination, or handles the three reserved keys.
        ///
        /// - Parameter event: The key event. `event.keyCode` is already a Carbon virtual key code, which is
        ///   why no key translation happens here; only the modifier flags need converting.
        override func keyDown(with event: NSEvent) {
            guard isRecording else {
                super.keyDown(with: event)
                return
            }
            switch Int(event.keyCode) {
            case kVK_Escape:
                isRecording = false
            case kVK_Delete, kVK_ForwardDelete:
                isRecording = false
                onReset?()
            case kVK_Return, kVK_Tab, kVK_ANSI_KeypadEnter:
                // Left for the window to handle: these are how the keyboard leaves a control, and binding
                // one would make the settings window impossible to navigate without a mouse.
                super.keyDown(with: event)
            default:
                isRecording = false
                onCapture?(UInt32(event.keyCode), Self.carbonModifiers(from: event.modifierFlags))
            }
        }

        /// Translates Cocoa modifier flags into the Carbon mask `RegisterEventHotKey` takes.
        ///
        /// `.deviceIndependentFlagsMask` first, because the raw flags carry left/right and device bits that
        /// would make an otherwise identical combination compare unequal depending on which shift was held.
        ///
        /// `fn` is deliberately not translated, and cannot be: Carbon has no `fn` modifier bit, which is the
        /// whole reason the shipped default goes through a Karabiner rule and `F19` instead. A user holding
        /// `fn` while pressing a key records the key and the other modifiers, which is also what the key
        /// event itself reports.
        ///
        /// - Parameter flags: Cocoa modifier flags from the event.
        /// - Returns: An OR of `controlKey`, `optionKey`, `shiftKey` and `cmdKey`.
        static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
            let relevant = flags.intersection(.deviceIndependentFlagsMask)
            var mask: UInt32 = 0
            if relevant.contains(.control) { mask |= UInt32(controlKey) }
            if relevant.contains(.option) { mask |= UInt32(optionKey) }
            if relevant.contains(.shift) { mask |= UInt32(shiftKey) }
            if relevant.contains(.command) { mask |= UInt32(cmdKey) }
            return mask
        }
    }
}
