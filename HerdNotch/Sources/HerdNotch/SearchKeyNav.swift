import AppKit
import Foundation

/// Owns the keyboard-highlighted index into the agents card's search results, and the "is search mode
/// live right now" flag `NotchPanel.sendEvent(_:)` checks before it consumes an arrow keyDown.
///
/// A focused SwiftUI `TextField`'s AppKit field editor is the key responder, and it consumes arrow keys
/// as caret motion before they ever reach SwiftUI's own `.onKeyPress`/`.onMoveCommand` — on either the
/// field itself or any ancestor. Two earlier attempts at this feature failed for two different reasons:
///
/// 1. `.onKeyPress(.upArrow)`/`.onKeyPress(.downArrow)` attached directly to `NotchContentView`'s search
///    field never fired, for exactly the field-editor-eats-it-first reason above.
/// 2. A local `NSEvent.addLocalMonitorForEvents(matching:handler:)` keyDown monitor — this type's own
///    former implementation — is *app*-scoped, not window-scoped: it only runs while `NSApp` itself is
///    active, and this panel is a `.nonactivatingPanel` that can hold key status *without* activating the
///    app (see `NotchPanel`'s own documentation for why that combination is the whole point of this
///    feature — typing over a full-screen app must not stop that app from being the active one). On
///    device, activating over a full-screen app or another app's window left this app inactive, and an
///    inactive app's local monitors are never invoked at all, so the handler silently never ran.
///
/// The fix that actually works is a **window-level `sendEvent(_:)` override** on `NotchPanel` itself (see
/// that type). `NSWindow.sendEvent(_:)` runs for *every* event AppKit routes to that window once it is the
/// key window, independent of whether the owning app is active — a nonactivating panel can be key without
/// activating, and its own `sendEvent(_:)` still fires — and it runs before the window dispatches the
/// event on to whichever view is first responder (the field editor). That is strictly more reliable than
/// either prior approach: no app-active ambiguity (window-scoped, not app-scoped) and no field-editor race
/// (dispatched before first-responder routing, not after).
///
/// Selection lives here, in a reference type owned by the view rather than in a SwiftUI `@State`, because
/// `NotchPanel.sendEvent(_:)` needs a stable object to call into from AppKit's own event loop — a `struct`
/// `NotchContentView` gives it no stable `self` to hold onto, and an `ObservableObject` here gives both
/// `NotchPanel` a stable target to mutate and the view a `@Published` property to read back out and
/// re-render from.
///
/// Only ``isActive`` while the agents card is actually in search mode — flipped by
/// `NotchContentView.enterSearchMode()` and the panel's own collapse/exit paths — so `NotchPanel` only ever
/// consumes Up/Down while the search field is genuinely showing; ordinary typing (including the reminders
/// quick-add field, which never touches this object) and every other keyDown pass through untouched.
@MainActor
final class SearchKeyNav: ObservableObject {
    /// The keyboard-highlighted row index into the current search results. Written by
    /// ``handleKeyCode(_:)`` (arrows), and reset to `0` by `NotchContentView` itself on every query edit
    /// and on entering search mode fresh — the same "the query changed, the old index may not even be in
    /// the new results" reasoning `HerdSearchView.selection` documents.
    @Published var selection = 0

    /// The current search result count. `NotchContentView` refreshes this on every render (from
    /// `searchResults.count`), so ``handleKeyCode(_:)``'s own clamping below never selects past the end of
    /// a list that just got shorter mid-keystroke — this object has no way to read a SwiftUI computed
    /// property itself, so the view has to push the count in rather than this object pulling it.
    var resultCount = 0

    /// Whether the agents card's search mode is currently live. `NotchPanel.sendEvent(_:)` only consumes
    /// an arrow keyDown while this is `true`, so Up/Down behave normally everywhere else the panel is key
    /// (for example the reminders quick-add field). Set by `NotchContentView.enterSearchMode()` and every
    /// place search mode ends — see that view's own documentation for the full list of exit paths.
    var isActive = false

    /// Handles one raw keyDown's key code, moving ``selection`` for Up/Down.
    ///
    /// Return (key code 36) is deliberately not handled here — it stays owned solely by the search
    /// field's own `.onSubmit(activateSearchSelection)`; consuming it here too would activate the
    /// selection twice for one keystroke, once from this method and once from `onSubmit`.
    ///
    /// - Parameter keyCode: `NSEvent.keyCode` of the keyDown being dispatched.
    /// - Returns: `true` if this call moved ``selection`` and the event should be consumed (not passed on
    ///   to the field editor); `false` for every other key code, which the caller must still dispatch
    ///   normally.
    func handleKeyCode(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 126: // Up arrow
            selection = max(0, selection - 1)
            return true
        case 125: // Down arrow
            selection = min(max(0, resultCount - 1), selection + 1)
            return true
        default:
            return false
        }
    }
}
