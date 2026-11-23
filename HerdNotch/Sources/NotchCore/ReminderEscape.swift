import Foundation

/// What Escape does inside the reminders view, in priority order.
public enum ReminderEscape: Sendable, Equatable {
    case clearText
    case backToPage
    case collapse

    /// A non-empty draft is cleared first; then Escape goes back to the page it came from, else collapses.
    public static func action(text: String, returnsToPage: Bool) -> ReminderEscape {
        if !text.isEmpty { return .clearText }
        return returnsToPage ? .backToPage : .collapse
    }
}
