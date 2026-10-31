import Foundation

/// The content shown inside an expanded notch panel.
///
/// A route is orthogonal to ``NotchPresentation``: the presentation says whether the panel is open, this
/// says what it is open *to*. Kept as a flat enum rather than a stack, because the notch is a single-level
/// surface, switching routes is a content swap, not a push/pop navigation, and the reducer never needs to
/// remember where a route was switched from.
public enum NotchRoute: Sendable, Equatable {
    /// The compact status row shown by default whenever a panel expands with no route requested yet.
    case home

    /// The herd agent ledger pane, wrapping `HerdLedgerView` from `HerdPanelUI` in a later phase.
    case herd

    /// The macOS Reminders list-and-add pane.
    case reminders

    /// The Spotify now-playing and playlist pane.
    case spotify

    /// Account and preferences.
    case settings
}
