import Foundation
import Testing
@testable import Navi

private typealias Clock = ScheduleRequest.ClockTime

@Suite struct ReminderParserTests {
    private func parse(_ q: String) -> ReminderRequest {
        guard let r = ReminderParser.parse(q) else {
            Issue.record("expected a parse for “\(q)”")
            return ReminderRequest(title: "")
        }
        return r
    }

    @Test func remindMeToWithDayAndTime() {
        let r = parse("remind me to call mom tomorrow at 5")
        #expect(r.isExplicit)
        #expect(r.title == "Call mom")
        #expect(r.day == .tomorrow)
        #expect(r.time == Clock(hour: 17, minute: 0))
        #expect(r.tokens.map(\.kind) == [.day, .time])
    }

    @Test func timeBeforeTheTask() {
        let r = parse("remind me at 5 to call mom")
        #expect(r.title == "Call mom")
        #expect(r.time == Clock(hour: 17, minute: 0))
    }

    @Test func relativeTimes() {
        #expect(parse("remind me to stretch in 45 min").relativeMinutes == 45)
        #expect(parse("remind me to stretch in 45 min").title == "Stretch")
        let r = parse("remind me in an hour to check the oven")
        #expect(r.relativeMinutes == 60)
        #expect(r.title == "Check the oven")
        #expect(parse("remind me to follow up in 2 days").relativeMinutes == 2 * 24 * 60)
        #expect(parse("remind me to call back in half an hour").relativeMinutes == 30)
    }

    @Test func repeats() {
        let plants = parse("remind me to water the plants every sunday morning")
        #expect(plants.title == "Water the plants")
        #expect(plants.repeatRule == .weekly(weekday: 1))
        #expect(plants.day == .weekday(1, nextWeek: false))
        #expect(plants.partOfDay == .morning)
        let trash = parse("remind me to take out the trash every tuesday night")
        #expect(trash.title == "Take out the trash")
        #expect(trash.repeatRule == .weekly(weekday: 3))
        #expect(trash.partOfDay == .evening)
        let email = parse("remind me to email ana daily at 9am")
        #expect(email.title == "Email ana")
        #expect(email.repeatRule == .daily)
        #expect(email.time == Clock(hour: 9, minute: 0))
        #expect(parse("remind me to stand up every weekday").repeatRule == .weekdays)
        #expect(parse("remind me to pay rent every month").repeatRule == .monthly)
    }

    @Test func otherOpeners() {
        let todo = parse("todo: renew passport next week")
        #expect(todo.isExplicit)
        #expect(todo.title == "Renew passport")
        #expect(todo.day == .nextWeek)
        let forget = parse("don't forget to pay rent friday")
        #expect(forget.isExplicit)
        #expect(forget.title == "Pay rent")
        #expect(forget.day == .weekday(6, nextWeek: false))
        let bank = parse("set a reminder for tomorrow morning to call the bank")
        #expect(bank.isExplicit)
        #expect(bank.title == "Call the bank")
        #expect(bank.day == .tomorrow)
        #expect(bank.partOfDay == .morning)
    }

    @Test func lengthsStayInTheTitle() {
        let r = parse("remind me to walk for 30 min")
        #expect(r.title == "Walk for 30 min")
        #expect(!r.hasWhen)
    }

    @Test func priority() {
        let r = parse("remind me to submit the report urgent")
        #expect(r.highPriority)
        #expect(r.title == "Submit the report")
    }

    @Test func openersAloneAndLookalikes() {
        #expect(parse("remind me").isExplicit)
        #expect(parse("remind me").title.isEmpty)
        #expect(!parse("reminder").isExplicit)       // on the way to "reminders" (the app)
        #expect(!parse("reminders").isExplicit)
        #expect(ReminderParser.parse("what reminders do I have") == nil)
        #expect(ReminderParser.parse("delete the reminder") == nil)
        let loose = parse("buy milk tomorrow")          // only Jev can open the card for this
        #expect(!loose.isExplicit)
        #expect(loose.title == "Buy milk")
        #expect(loose.day == .tomorrow)
    }

    @Test func schedulerStepsAsideForReminders() {
        #expect(ScheduleParser.parse("remind me to book lunch with ana tomorrow") == nil)
        #expect(parse("remind me to book lunch with ana tomorrow").title == "Book lunch with ana")
    }
}

@Suite struct ReminderDueTests {
    /// Tuesday 29 September 2026, 18:00 UTC.
    let now = Date(timeIntervalSince1970: 1_790_704_800)
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func due(_ q: String, at now: Date? = nil) -> String? {
        let r = ReminderParser.parse(q) ?? ReminderRequest(title: "")
        guard let d = r.resolvedDue(now: now ?? self.now, calendar: cal) else { return nil }
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        return String(format: "%04d-%02d-%02d %02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!)
    }

    @Test func dayAndTime() {
        #expect(due("remind me to x tomorrow at 5") == "2026-09-30 17:00")
        #expect(due("remind me to x tomorrow") == "2026-09-30 09:00")
        #expect(due("remind me to x at 5") == "2026-09-30 17:00")      // 5 PM has passed today
        #expect(due("remind me to x at 8pm") == "2026-09-29 20:00")
        #expect(due("remind me to x friday afternoon") == "2026-10-02 14:00")
    }

    @Test func relative() {
        #expect(due("remind me to x in 45 min") == "2026-09-29 18:45")
    }

    @Test func repeatsStartAtTheNextOccurrence() {
        #expect(due("remind me to x every sunday morning") == "2026-10-04 09:00")
        #expect(due("remind me to x daily") == "2026-09-30 09:00")
        let fridayNoon = now.addingTimeInterval(3 * 86400 - 6 * 3600)   // Fri 2 Oct 12:00
        #expect(due("remind me to x every friday at 9", at: fridayNoon) == "2026-10-09 09:00")
    }

    @Test func noWhenNoDate() {
        #expect(due("remind me to x") == nil)
    }

    @Test func quickPicksInTheEvening() {
        let options = ReminderPlanner.options(now: now, calendar: cal)
        #expect(options.map(\.label) == ["In 1 hour", "Tonight", "Tomorrow", "This weekend", "Next week", "No date"])
        #expect(options[0].date == now.addingTimeInterval(3600))
        #expect(options[1].date == now.addingTimeInterval(3 * 3600))                 // 21:00
        #expect(options[2].date == now.addingTimeInterval(15 * 3600))                // Wed 09:00
        #expect(options[3].date == now.addingTimeInterval(3 * 86400 + 16 * 3600))    // Sat 10:00
        #expect(options[4].date == now.addingTimeInterval(5 * 86400 + 15 * 3600))    // Mon 09:00
        #expect(options[5].date == nil)
    }

    @Test func quickPicksOnAFridayMorning() {
        let fridayMorning = now.addingTimeInterval(3 * 86400 - 8 * 3600)   // Fri 2 Oct 10:00
        let labels = ReminderPlanner.options(now: fridayMorning, calendar: cal).map(\.label)
        #expect(labels == ["In 1 hour", "This evening", "Tomorrow", "Next week", "No date"])
    }

    @Test func dueLabels() {
        let tomorrow5 = now.addingTimeInterval(23 * 3600)
        #expect(ReminderPlanner.dueLabel(tomorrow5, now: now, calendar: cal).hasPrefix("Tomorrow at "))
        #expect(ReminderPlanner.dueLabel(now.addingTimeInterval(3600), now: now, calendar: cal).hasPrefix("Today at "))
    }

    @Test func repeatLabels() {
        #expect(ReminderRequest.Repeat.weekly(weekday: 1).label == "Every Sunday")
        #expect(ReminderRequest.Repeat.weekly(weekday: nil).label == "Every week")
        #expect(ReminderRequest.Repeat.weekdays.label == "Weekdays")
    }

    @Test func jevIsAskedAboutReminders() {
        guard case .noul? = QueryRouter.jevQuestions["wants_reminder"] else {
            Issue.record("wants_reminder must be a noul on the routing call"); return
        }
    }
}
