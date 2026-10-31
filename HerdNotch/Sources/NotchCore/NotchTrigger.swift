import Foundation

/// What caused an expansion, carried on ``NotchPresentation/expanding(_:)`` so the AppKit layer can pick
/// the right animation curve or telemetry label without the reducer needing to know about either.
///
/// Recorded at the moment expansion begins rather than derived later, because by the time the panel has
/// settled into ``NotchPresentation/expanded(_:)`` the triggering event is long gone and there is nothing
/// left to reconstruct it from.
public enum NotchTrigger: Sendable, Equatable {
    /// The pointer dwelled over the collapsed pill long enough to clear the hover debounce.
    case hover

    /// The global hot key (fn-fn) toggled the panel open.
    case hotkey

    /// The user clicked the collapsed pill.
    case click

    /// A file drag entered the collapsed pill. Never makes the panel key: the drag session owns input.
    case fileDrag
}
