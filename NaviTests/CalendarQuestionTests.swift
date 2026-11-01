import Foundation
import Testing
@testable import Navi

/// Taskbench calendar-001 / memory-029 (morning rerun, 2026-11-01).
struct CalendarQuestionTests {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!; return c }
    private var sunday: Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9))! }

    @Test func asksAboutADay() {
        let monday = cal.date(from: DateComponents(year: 2026, month: 11, day: 2))!
        #expect(CalendarQuestion.day(asked: "what's on my calendar tomorrow", now: sunday, calendar: cal) == monday)
        #expect(CalendarQuestion.day(asked: "what meetings do I have today", now: sunday, calendar: cal) == cal.startOfDay(for: sunday))
        #expect(CalendarQuestion.day(asked: "my schedule for monday", now: sunday, calendar: cal) == monday)
        let friday = cal.date(from: DateComponents(year: 2026, month: 11, day: 6))!
        #expect(CalendarQuestion.day(asked: "anything on my calendar friday?", now: sunday, calendar: cal) == friday)
    }

    @Test func editsAndOtherQueriesAreNotQuestions() {
        #expect(CalendarQuestion.day(asked: "put lunch with ana on my calendar tomorrow", now: sunday, calendar: cal) == nil)
        #expect(CalendarQuestion.day(asked: "cancel what's on my calendar tomorrow", now: sunday, calendar: cal) == nil)
        #expect(CalendarQuestion.day(asked: "open my calendar", now: sunday, calendar: cal) == nil)
        #expect(CalendarQuestion.day(asked: "meeting with jilles tomorrow at 3", now: sunday, calendar: cal) == nil)
    }

    @Test func answerListsTheDay() {
        let monday = cal.date(from: DateComponents(year: 2026, month: 11, day: 2))!
        let at = { (h: Int, m: Int) in self.cal.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: h, minute: m))! }
        let text = CalendarQuestion.answer(day: monday, items: [
            .init(start: at(13, 30), end: at(15, 0), title: "HCI", allDay: false),
            .init(start: at(10, 0), end: at(11, 40), title: "Spec Topics", allDay: false),
            .init(start: monday, end: monday.addingTimeInterval(86_400), title: "Holiday", allDay: true),
        ], now: sunday, calendar: cal)
        #expect(text.hasPrefix("Tomorrow (Monday, November 2), 3 events:"))
        #expect(text.contains("- All day — Holiday\n- 10:00 AM–11:40 AM — Spec Topics\n- 1:30 PM–3:00 PM — HCI"))
        #expect(CalendarQuestion.answer(day: monday, items: [], now: sunday, calendar: cal) == "Tomorrow (Monday, November 2): nothing on your calendar.")
    }

    @Test func pausedMemoryIsNeverGrounded() {
        let q = "open the doc I was working on yesterday while memory was paused"
        #expect(TaskGrounding.memoryWasOff(q))
        #expect(!TaskGrounding.reopensOwnWork(q))
        #expect(!TaskGrounding.memoryWasOff("open the doc I was working on yesterday"))
        #expect(TaskGrounding.reopensOwnWork("open the doc I was working on yesterday"))
    }
}
