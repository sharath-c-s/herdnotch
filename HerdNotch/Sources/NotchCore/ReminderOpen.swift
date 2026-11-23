import Foundation

/// Which full-panel reminders view is showing.
public enum ReminderMode: Equatable, Sendable {
    case compose, list
}

/// What a cmd-cmd or cmd-cmd-cmd request does given the panel's current state.
public enum ReminderOpen: Sendable, Equatable {
    case open
    case switchMode
    case close
    case ignore

    /// The same request twice closes the panel; a different one swaps the view; a mid-animation or
    /// suspended panel ignores it.
    public static func action(
        presentation: NotchPresentation?, current: ReminderMode?, requested: ReminderMode
    ) -> ReminderOpen {
        switch presentation {
        case .expanded:
            return current == requested ? .close : .switchMode
        case .collapsed, .collapsing, nil:
            return .open
        case .expanding, .suspended:
            return .ignore
        }
    }
}
