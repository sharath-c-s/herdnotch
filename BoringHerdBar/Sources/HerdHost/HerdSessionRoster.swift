import Foundation

/// The names of every session discovery found, whether or not the filter lets them through.
///
/// A tiny observable of its own rather than another `@Published` on the host's poller model, and the
/// reason is the settings window. SwiftUI invalidates a view when *any* published property of an
/// observed object changes, so a form observing the model would re-evaluate its body at the poll rate,
/// on a window that changes about once a minute; that is wasted work at best and, with a text field
/// mid-edit, a way to lose what the user was typing. This object changes only when the set of session
/// names actually changes.
///
/// It exists at all because the session filter needs a list of candidates that is *not* the filtered
/// snapshot. A menu built from the filtered snapshot cannot do this: deselecting a session removes it
/// from the menu and there is no way to select it again short of clearing the whole filter.
///
/// Extracted out of `BoringHerdBar/HerdBarModel.swift` into this library alongside ``HerdSettingsView``
/// and ``HerdSettingsWindow``, its two consumers, so both host apps' poller models (`HerdBarModel` in
/// `BoringHerdBar`, `NotchHerdModel` in `HerdNotch`) can feed the same settings window a live roster.
///
/// Thread-safety: main-actor isolated, written only by the owning model's poll.
@MainActor
public final class HerdSessionRoster: ObservableObject {
    /// Every discovered session name, in discovery's display order.
    @Published public private(set) var names: [String] = []

    /// Creates an empty roster.
    public init() {}

    /// Records the current names, publishing only when they differ.
    ///
    /// - Parameter names: Names from the unfiltered snapshot.
    public func update(_ names: [String]) {
        guard names != self.names else { return }
        self.names = names
    }
}
