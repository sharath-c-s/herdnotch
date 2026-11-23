import Foundation

/// A reminder title and optional due date pulled out of one line of typed text.
public struct ReminderDraft: Equatable, Sendable {
    public let title: String
    public let due: Date?
    /// False when the text named only a day: the reminder is date-only, with no time and no alarm.
    public let hasTime: Bool

    public init(title: String, due: Date?, hasTime: Bool = false) {
        self.title = title
        self.due = due
        self.hasTime = hasTime
    }

    // Built once: construction is costly and the compose view parses on every keystroke.
    private static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.date.rawValue)

    private static let timeWords =
        #"\d{1,2}:\d{2}|\d\s*[ap]\.?m\b|\bnoon\b|\bmidnight\b|\bat\s+\d|\b(tonight|morning|afternoon|evening|night|hours?|hrs?|minutes?|mins?)\b"#
    private static let dayWords =
        #"\b(today|tonight|tomorrow|tmrw|yesterday|week|weekend|month|next|days?|mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun|monday|tuesday|wednesday|thursday|friday|saturday|sunday|jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec|january|february|march|april|june|july|august|september|october|november|december)\b|\d[/-]\d"#

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Parses the last date phrase in `text` into `due` and strips it from the title.
    ///
    /// NSDataDetector has no reference date and resolves relative words against the real clock, so `now`
    /// must fall on the current calendar day. It only drives the time-of-day roll-forward below.
    public static func parse(_ text: String, now: Date, calendar: Calendar = .current) -> ReminderDraft {
        let trimmed = collapse(text)
        guard
            let detector,
            let match = detector.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)).last,
            let detected = match.date,
            let range = Range(match.range, in: trimmed)
        else { return bareHour(trimmed, now: now, calendar: calendar) }

        var title = String(trimmed[..<range.lowerBound])
        if let preposition = title.range(of: #"\b(at|by|on)\s*$"#, options: [.regularExpression, .caseInsensitive]) {
            title.removeSubrange(preposition)
        }
        title = collapse(title + " " + trimmed[range.upperBound...])
        if title.isEmpty { return ReminderDraft(title: trimmed, due: nil) }

        let matched = String(trimmed[range])
        let hasTime = matches(timeWords, matched)
        if !hasTime {
            return ReminderDraft(title: title, due: calendar.startOfDay(for: detected), hasTime: false)
        }
        var due = detected
        if !matches(dayWords, matched) {
            let time = calendar.dateComponents([.hour, .minute], from: detected)
            due = calendar.date(
                bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: now) ?? detected
            if due <= now { due = calendar.date(byAdding: .day, value: 1, to: due) ?? due }
        }
        return ReminderDraft(title: title, due: due, hasTime: true)
    }

    /// "call bank at 5": NSDataDetector ignores it. Hours 1-12 only; picks the soonest of h and h+12.
    private static func bareHour(_ text: String, now: Date, calendar: Calendar) -> ReminderDraft {
        let plain = ReminderDraft(title: text, due: nil)
        guard
            let regex = try? NSRegularExpression(pattern: #"\bat\s+(\d{1,2})(?::(\d{2}))?\b"#, options: .caseInsensitive),
            let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
            let hourRange = Range(match.range(at: 1), in: text), let hour = Int(text[hourRange]),
            (1...12).contains(hour),
            let whole = Range(match.range, in: text)
        else { return plain }
        var minute = 0
        if let minuteRange = Range(match.range(at: 2), in: text) {
            guard let parsed = Int(text[minuteRange]), parsed < 60 else { return plain }
            minute = parsed
        }
        let title = collapse(String(text[..<whole.lowerBound]) + " " + text[whole.upperBound...])
        if title.isEmpty { return plain }
        let candidates = [hour % 24, (hour + 12) % 24].compactMap { hour -> Date? in
            guard let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
            return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
        }
        guard let due = candidates.min() else { return plain }
        return ReminderDraft(title: title, due: due, hasTime: true)
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
