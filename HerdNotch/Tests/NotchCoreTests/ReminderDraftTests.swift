import Foundation
import Testing

@testable import NotchCore

@Suite struct ReminderDraftTests {
    private let calendar = Calendar.current

    /// Today at `hour`:00, the only kind of `now` the parser supports.
    private func today(_ hour: Int) -> Date {
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
    }

    private func parts(_ date: Date?) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date!)
    }

    @Test func noDateKeepsTitle() {
        let draft = ReminderDraft.parse("  buy   milk ", now: today(10))
        #expect(draft.title == "buy milk")
        #expect(draft.due == nil)
    }

    @Test func timeOnlyLaterTodayStaysToday() {
        let now = today(10)
        let draft = ReminderDraft.parse("call bank 5pm", now: now)
        #expect(draft.title == "call bank")
        #expect(draft.due == today(17))
    }

    @Test func danglingAtIsRemoved() {
        let draft = ReminderDraft.parse("call bank at 5pm", now: today(10))
        #expect(draft.title == "call bank")
        #expect(draft.due == today(17))
    }

    @Test func tomorrowMorningWithLeadingPhrase() {
        let draft = ReminderDraft.parse("tomorrow 9am standup", now: today(10))
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date())!
        #expect(draft.title == "standup")
        #expect(parts(draft.due).day == calendar.component(.day, from: tomorrow))
        #expect(parts(draft.due).hour == 9)
        #expect(parts(draft.due).minute == 0)
    }

    @Test func pastTimeRollsToTomorrow() {
        let draft = ReminderDraft.parse("pay rent at 8am", now: today(10))
        let expected = calendar.date(byAdding: .day, value: 1, to: today(8))!
        #expect(draft.title == "pay rent")
        #expect(draft.due == expected)
    }

    @Test func explicitDate() {
        let draft = ReminderDraft.parse("meet on Sep 4", now: today(10))
        #expect(draft.title == "meet")
        #expect(parts(draft.due).month == 9)
        #expect(parts(draft.due).day == 4)
    }

    @Test func dateOnlyTextKeepsOriginalTitle() {
        let draft = ReminderDraft.parse("5pm", now: today(10))
        #expect(draft.title == "5pm")
        #expect(draft.due == nil)
    }

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date())!
    }

    @Test(arguments: ["dentist tomorrow", "send report by friday", "flight on dec 5"])
    func dateOnlyTextHasNoTime(_ text: String) {
        let draft = ReminderDraft.parse(text, now: today(10))
        #expect(draft.due != nil)
        #expect(draft.hasTime == false)
        #expect(parts(draft.due).hour == 0)
    }

    @Test func typedTimeHasTime() {
        #expect(ReminderDraft.parse("call bank 5pm", now: today(10)).hasTime)
        #expect(ReminderDraft.parse("tomorrow 9am standup", now: today(10)).hasTime)
        #expect(ReminderDraft.parse("lunch at noon", now: today(10)).hasTime)
    }

    @Test func noonAtLateEveningRollsToTomorrow() {
        let now = at(23, 59)
        let draft = ReminderDraft.parse("lunch at noon", now: now)
        let expected = calendar.date(byAdding: .day, value: 1, to: at(12))!
        #expect(draft.title == "lunch")
        #expect(draft.due == expected)
    }

    @Test func bareHourPicksSoonestOccurrence() {
        let morning = ReminderDraft.parse("call bank at 5", now: at(10))
        #expect(morning.title == "call bank")
        #expect(morning.due == at(17))
        #expect(morning.hasTime)

        let evening = ReminderDraft.parse("call bank at 5", now: at(18))
        #expect(evening.due == calendar.date(byAdding: .day, value: 1, to: at(5)))
    }

    @Test func bareHourAbove12IsIgnored() {
        let draft = ReminderDraft.parse("call bank at 25", now: at(10))
        #expect(draft.due == nil)
        #expect(draft.title == "call bank at 25")
    }
}
