import Foundation
import Testing
@testable import Navi

private typealias Clock = ScheduleRequest.ClockTime

// MARK: - Parser

@Suite struct ScheduleParserTests {
    private func parse(_ q: String) -> ScheduleRequest {
        guard let r = ScheduleParser.parse(q) else {
            Issue.record("expected a parse for “\(q)”")
            return ScheduleRequest(activity: "")
        }
        return r
    }

    @Test func meetingWithTwoPeople() {
        let r = parse("meeting with jilles and harshil")
        #expect(r.activity == "Meeting")
        #expect(r.people == ["jilles", "harshil"])
        #expect(r.isExplicit)
        #expect(r.tokens == [
            ScheduleRequest.Token(kind: .activity, start: 0, length: 7),
            ScheduleRequest.Token(kind: .person, start: 13, length: 6),
            ScheduleRequest.Token(kind: .person, start: 24, length: 7),
        ])
    }

    @Test func ampersandAndCommasSplitPeople() {
        #expect(parse("meeting with jilles & harshil").people == ["jilles", "harshil"])
        #expect(parse("schedule a call with ana, ben and cleo").people == ["ana", "ben", "cleo"])
        #expect(parse("sync with jilles, harshil").people == ["jilles", "harshil"])
    }

    @Test func aFullNameIsOnePerson() {
        let r = parse("lunch with sam jones on oct 3rd at noon")
        #expect(r.activity == "Lunch")
        #expect(r.people == ["sam jones"])
        #expect(r.day == .date(month: 10, day: 3))
        #expect(r.time == Clock(hour: 12, minute: 0))
    }

    @Test func shortMonthBeforeADayIsTheDateNotASurname() {
        let r = parse("meeting with ana oct 3")
        #expect(r.people == ["ana"])
        #expect(r.day == .date(month: 10, day: 3))
    }

    @Test func coffeeFridayAtTenForHalfAnHour() {
        let r = parse("Coffee with Developer Friday at 10am for 30 min")
        #expect(r.activity == "Coffee")
        #expect(r.people == ["Developer"])
        #expect(r.day == .weekday(6, nextWeek: false))
        #expect(r.time == Clock(hour: 10, minute: 0))
        #expect(r.durationMinutes == 30)
        #expect(r.isExplicit)
        #expect(r.tokens.map(\.kind) == [.activity, .person, .day, .time, .duration])
    }

    @Test func syncTomorrowAfternoon() {
        let r = parse("Sync with Developer and Bengaluru tomorrow afternoon")
        #expect(r.people == ["Developer", "Bengaluru"])
        #expect(r.day == .tomorrow)
        #expect(r.partOfDay == .afternoon)
    }

    @Test func focusTimeWithNobody() {
        let r = parse("Focus time tomorrow morning for 2h")
        #expect(r.activity == "Focus time")
        #expect(r.people.isEmpty)
        #expect(r.day == .tomorrow)
        #expect(r.partOfDay == .morning)
        #expect(r.durationMinutes == 120)
        #expect(r.isExplicit)
    }

    @Test func nextWeekdayAndBareHour() {
        let r = parse("schedule a call with ana next friday at 3")
        #expect(r.activity == "Call")
        #expect(r.day == .weekday(6, nextWeek: true))
        #expect(r.time == Clock(hour: 15, minute: 0))
    }

    @Test func politeLeadInIsSkipped() {
        let r = parse("can you schedule a meeting with jilles")
        #expect(r.isExplicit)
        #expect(r.people == ["jilles"])
    }

    @Test func partialNameWhileTyping() {
        #expect(parse("meeting with jil").people == ["jil"])
        let empty = parse("meeting with")
        #expect(empty.people.isEmpty)
        #expect(empty.isExplicit)
        #expect(!empty.hasDetails)
    }

    @Test func eventWordAloneShowsExamplesOnlyWhenUnambiguous() {
        #expect(parse("meeting").isExplicit)
        #expect(!parse("meeting").hasDetails)
        #expect(parse("focus time").isExplicit)
        #expect(!parse("coffee").isExplicit)
        #expect(!parse("sync").isExplicit)
        #expect(!parse("meeting notes").isExplicit)
    }

    @Test func notSchedulingRequests() {
        #expect(ScheduleParser.parse("what meetings do I have tomorrow") == nil)
        #expect(ScheduleParser.parse("cancel my meeting with jilles") == nil)
        #expect(ScheduleParser.parse("open calendar") == nil)
        #expect(ScheduleParser.parse("") == nil)
        #expect(!parse("call mom").isExplicit)
        #expect(!parse("book a flight to paris").isExplicit)
        #expect(!parse("set a timer for 10 minutes").isExplicit)
    }

    @Test func eventWordWithATimeIsExplicit() {
        #expect(parse("lunch tomorrow").isExplicit)
        #expect(parse("call with mom at 5").isExplicit)
        #expect(parse("block tomorrow morning").isExplicit)
        #expect(parse("block tomorrow morning").activity == "Hold")
    }

    @Test func durations() {
        #expect(ScheduleParser.compactDuration("1h30") == 90)
        #expect(ScheduleParser.compactDuration("1h30m") == 90)
        #expect(ScheduleParser.compactDuration("90min") == 90)
        #expect(ScheduleParser.compactDuration("1.5h") == 90)
        #expect(ScheduleParser.compactDuration("45m") == 45)
        #expect(ScheduleParser.compactDuration("2hrs") == 120)
        #expect(ScheduleParser.compactDuration("10am") == nil)
        #expect(ScheduleParser.compactDuration("30") == nil)
        #expect(parse("meeting with ana for half an hour").durationMinutes == 30)
        #expect(parse("meeting with ana for an hour").durationMinutes == 60)
        #expect(parse("meeting with ana for 45").durationMinutes == 45)
        #expect(parse("meeting with ana 1 hour").durationMinutes == 60)
    }

    @Test func clockTimes() {
        func time(_ q: String) -> ScheduleRequest.ClockTime? { parse("meeting with ana \(q)").time }
        #expect(time("at 9") == Clock(hour: 9, minute: 0))
        #expect(time("at 3") == Clock(hour: 15, minute: 0))
        #expect(time("3pm") == Clock(hour: 15, minute: 0))
        #expect(time("3 pm") == Clock(hour: 15, minute: 0))
        #expect(time("10:30") == Clock(hour: 10, minute: 30))
        #expect(time("10.30pm") == Clock(hour: 22, minute: 30))
        #expect(time("15:45") == Clock(hour: 15, minute: 45))
        #expect(time("12pm") == Clock(hour: 12, minute: 0))
        #expect(time("12am") == Clock(hour: 0, minute: 0))
        #expect(time("friday") == nil)
        #expect(ScheduleParser.parseClock("1:1") == nil)
    }

    @Test func titles() {
        #expect(ScheduleRequest.title(activity: "Focus time", names: []) == "Focus time")
        #expect(ScheduleRequest.title(activity: "Meeting", names: ["Jilles"]) == "Meeting with Jilles")
        #expect(ScheduleRequest.title(activity: "Meeting", names: ["Jilles", "Harshil"]) == "Meeting with Jilles & Harshil")
        #expect(ScheduleRequest.title(activity: "Sync", names: ["A", "B", "C"]) == "Sync with A, B & C")
    }

    @Test func wordsKeepCharacterOffsets() {
        let ws = ScheduleParser.words(in: "coffee with ana, ben & cleo.")
        #expect(ws.map(\.text) == ["coffee", "with", "ana", "ben", "&", "cleo"])
        #expect(ws.map(\.start) == [0, 7, 12, 17, 21, 23])
        #expect(ws[2].comma && !ws[3].comma)
    }
}

// MARK: - Days

@Suite struct ScheduleDayTests {
    /// Tuesday 29 September 2026, 18:00 UTC.
    let now = Date(timeIntervalSince1970: 1_790_704_800)
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func day(_ q: String, at now: Date? = nil) -> String {
        let r = ScheduleParser.parse(q) ?? ScheduleRequest(activity: "Meeting")
        let d = r.resolvedDay(now: now ?? self.now, calendar: cal)
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    @Test func fixtureIsTuesdayEvening() {
        #expect(cal.component(.weekday, from: now) == 3)
        #expect(cal.component(.hour, from: now) == 18)
    }

    @Test func namedDays() {
        #expect(day("meeting with ana today") == "2026-09-29")
        #expect(day("meeting with ana tomorrow") == "2026-09-30")
        #expect(day("meeting with ana friday") == "2026-10-02")
        #expect(day("meeting with ana tuesday") == "2026-09-29")
        #expect(day("meeting with ana monday") == "2026-10-05")
        #expect(day("meeting with ana next friday") == "2026-10-09")
        #expect(day("meeting with ana next week") == "2026-10-05")
        #expect(day("meeting with ana oct 3") == "2026-10-03")
        #expect(day("meeting with ana 3rd of october") == "2026-10-03")
        #expect(day("meeting with ana sep 1") == "2027-09-01")
    }

    @Test func noDayAfterHoursMeansNextWeekday() {
        #expect(day("meeting with ana") == "2026-09-30")
        let morning = now.addingTimeInterval(-9 * 3600)   // 09:00
        #expect(day("meeting with ana", at: morning) == "2026-09-29")
        #expect(day("meeting with ana at 10am") == "2026-09-30")
        #expect(day("meeting with ana at 8pm") == "2026-09-29")
        let friday = now.addingTimeInterval(3 * 86400)     // Friday 18:00 → Monday
        #expect(day("meeting with ana", at: friday) == "2026-10-05")
    }
}

// MARK: - Slots

@Suite struct SchedulePlannerTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// Wednesday 30 September 2026, 00:00 UTC.
    let day = Date(timeIntervalSince1970: 1_790_726_400)

    private func at(_ h: Int, _ m: Int = 0) -> Date { day.addingTimeInterval(TimeInterval(h * 3600 + m * 60)) }
    private func block(_ h1: Int, _ m1: Int, _ h2: Int, _ m2: Int) -> ScheduleInterval {
        ScheduleInterval(start: at(h1, m1), end: at(h2, m2))
    }

    @Test func windowStretchesToATypedTime() {
        #expect(SchedulePlanner.window(for: day, time: nil, duration: 30, calendar: cal) == block(9, 0, 18, 0))
        #expect(SchedulePlanner.window(for: day, time: Clock(hour: 8, minute: 0), duration: 30, calendar: cal) == block(8, 0, 18, 0))
        #expect(SchedulePlanner.window(for: day, time: Clock(hour: 17, minute: 30), duration: 60, calendar: cal) == block(9, 0, 19, 0))
    }

    @Test func freeStartsSkipBusyAndPast() {
        let window = block(9, 0, 12, 0)
        let free = SchedulePlanner.freeStarts(in: window, busy: [block(10, 0, 10, 30)], duration: 30, notBefore: at(9))
        #expect(free == [at(9), at(9, 30), at(10, 30), at(11), at(11, 30)])
        let later = SchedulePlanner.freeStarts(in: window, busy: [], duration: 60, notBefore: at(10, 15))
        #expect(later == [at(10, 30), at(11)])
    }

    @Test func suggestionsAreSpreadOut() {
        let window = block(9, 0, 18, 0)
        let free = SchedulePlanner.freeStarts(in: window, busy: [], duration: 30, notBefore: at(0))
        #expect(SchedulePlanner.suggestions(from: free, duration: 30, preferred: nil) == [at(9), at(10), at(11)])
        #expect(SchedulePlanner.suggestions(from: free, duration: 90, preferred: nil) == [at(9), at(10, 30), at(12)])
        let afternoon = SchedulePlanner.preferredWindow(for: day, partOfDay: .afternoon, activity: "Meeting", calendar: cal)
        #expect(SchedulePlanner.suggestions(from: free, duration: 30, preferred: afternoon) == [at(12), at(13), at(14)])
    }

    @Test func preferredWindowFallsBackWhenFull() {
        let morning = SchedulePlanner.preferredWindow(for: day, partOfDay: .morning, activity: "Meeting", calendar: cal)
        let free = [at(13), at(15)]
        #expect(SchedulePlanner.suggestions(from: free, duration: 30, preferred: morning) == [at(13), at(15)])
        #expect(SchedulePlanner.preferredWindow(for: day, partOfDay: nil, activity: "Lunch", calendar: cal) == block(12, 0, 14, 0))
        #expect(SchedulePlanner.preferredWindow(for: day, partOfDay: nil, activity: "Meeting", calendar: cal) == nil)
    }

    @Test func typedTimeWinsOverSuggestions() {
        let start = SchedulePlanner.initialStart(time: Clock(hour: 12, minute: 30), day: day, suggestions: [at(11)], calendar: cal)
        #expect(start == at(12, 30))
        #expect(SchedulePlanner.initialStart(time: nil, day: day, suggestions: [at(11)], calendar: cal) == at(11))
        #expect(SchedulePlanner.initialStart(time: nil, day: day, suggestions: [], calendar: cal) == nil)
    }

    @Test func conflicts() {
        let busy = [block(13, 0, 14, 0)]
        #expect(SchedulePlanner.conflicts(start: at(12, 30), duration: 45, busy: busy))
        #expect(!SchedulePlanner.conflicts(start: at(12, 15), duration: 45, busy: busy))   // ends exactly at 13:00
        #expect(!SchedulePlanner.conflicts(start: at(14), duration: 30, busy: busy))
    }

    @Test func snapping() {
        let window = block(9, 0, 18, 0)
        #expect(SchedulePlanner.snap(at(10, 7), in: window, duration: 30) == at(10))
        #expect(SchedulePlanner.snap(at(10, 8), in: window, duration: 30) == at(10, 15))
        #expect(SchedulePlanner.snap(at(8), in: window, duration: 30) == at(9))
        #expect(SchedulePlanner.snap(at(17, 50), in: window, duration: 30) == at(17, 30))
        #expect(SchedulePlanner.notBefore(at(10, 7)) == at(10, 15))
        #expect(SchedulePlanner.notBefore(at(10, 15)) == at(10, 15))
    }

    @Test func durationsAndSteps() {
        #expect(SchedulePlanner.durationLabel(30) == "30 min")
        #expect(SchedulePlanner.durationLabel(60) == "1 h")
        #expect(SchedulePlanner.durationLabel(75) == "1 h 15 min")
        #expect(SchedulePlanner.adjustedDuration(30, by: 1) == 45)
        #expect(SchedulePlanner.adjustedDuration(45, by: 1) == 60)
        #expect(SchedulePlanner.adjustedDuration(60, by: 1) == 90)
        #expect(SchedulePlanner.adjustedDuration(90, by: -1) == 60)
        #expect(SchedulePlanner.adjustedDuration(60, by: -1) == 45)
        #expect(SchedulePlanner.adjustedDuration(15, by: -1) == 15)
        #expect(SchedulePlanner.adjustedDuration(480, by: 1) == 480)
    }
}

// MARK: - People, calendars, invites

@Suite struct ScheduleDataTests {
    @Test func contactRanking() {
        let exact = ScheduleDirectory.matchScore(typed: "jilles", given: "Jilles", family: "van Gurp", nickname: "", hasEmail: true)
        let prefix = ScheduleDirectory.matchScore(typed: "jil", given: "Jillian", family: "Moss", nickname: "", hasEmail: true)
        let family = ScheduleDirectory.matchScore(typed: "gurp", given: "Jilles", family: "Gurp", nickname: "", hasEmail: false)
        #expect(exact > prefix && prefix > family && family > 0)
        #expect(ScheduleDirectory.matchScore(typed: "ana", given: "Ben", family: "Stone", nickname: "", hasEmail: true) == 0)
        let withEmail = ScheduleDirectory.matchScore(typed: "sam", given: "Sam", family: "A", nickname: "", hasEmail: true)
        let without = ScheduleDirectory.matchScore(typed: "sam", given: "Sam", family: "B", nickname: "", hasEmail: false)
        #expect(withEmail > without)
    }

    @Test func workEmailIsPreferred() {
        let emails = ["jilles@gmail.com", "jilles@cloudflare.com"]
        #expect(ScheduleDirectory.preferredEmail(emails, domain: "cloudflare.com") == "jilles@cloudflare.com")
        #expect(ScheduleDirectory.preferredEmail(emails, domain: nil) == "jilles@gmail.com")
        #expect(ScheduleDirectory.preferredEmail([], domain: "x.com") == nil)
    }

    @Test func typedPeople() {
        let name = SchedulePerson.typedOnly("jilles van gurp")
        #expect(name.name == "Jilles Van Gurp")
        #expect(name.firstName == "Jilles")
        #expect(name.email == nil)
        let email = SchedulePerson.typedOnly("ana@example.com")
        #expect(email.email == "ana@example.com")
        #expect(email.firstName == "Ana")
    }

    @Test func colleagueCalendarsAreRecognised() {
        let jilles = SchedulePerson(id: "1", typed: "jilles", name: "Jilles van Gurp", firstName: "Jilles",
                                    email: "jilles@cloudflare.com", imageData: nil, isContact: true)
        #expect(ScheduleCalendar.calendarTitle("jilles@cloudflare.com", belongsTo: jilles))
        #expect(ScheduleCalendar.calendarTitle("Jilles van Gurp", belongsTo: jilles))
        #expect(!ScheduleCalendar.calendarTitle("Work", belongsTo: jilles))
        #expect(!ScheduleCalendar.calendarTitle("Jilles", belongsTo: jilles))   // too loose on a first name
    }

    @Test func attendeeScriptEscapesQuotes() {
        let script = ScheduleCalendar.attendeeScript(uid: "ABC-1", calendarTitle: "Liam's \"Work\"", emails: ["a@b.com", "c@d.com"])
        #expect(script.contains("every calendar whose name is \"Liam's \\\"Work\\\"\""))
        #expect(script.contains("whose uid is \"ABC-1\""))
        #expect(script.contains("make new attendee at end of attendees with properties {email:\"a@b.com\"}"))
        #expect(script.contains("{email:\"c@d.com\"}"))
        #expect(script.hasPrefix("tell application \"Calendar\""))
    }

    @Test func highlightRunsKeepTheText() {
        let text = "meeting with jilles and harshil"
        let tokens = ScheduleParser.parse(text)?.tokens ?? []
        let attributed = ScheduleTokenStyle.attributed(text, tokens: tokens) { _, _ in }
        #expect(String(attributed.characters) == text)
        #expect(String(ScheduleTokenStyle.colored("Focus time tomorrow morning for 2h").characters) == "Focus time tomorrow morning for 2h")
    }

    @Test func jevIsAskedWhetherToSchedule() {
        guard case .noul? = QueryRouter.jevQuestions["wants_to_schedule"] else {
            Issue.record("wants_to_schedule must be a noul on the routing call"); return
        }
    }

    @Test func busyListsAreJoinedForTheStatusLine() {
        #expect(SchedulerModel.list(["Jilles"]) == "Jilles")
        #expect(SchedulerModel.list(["Jilles", "Harshil"]) == "Jilles and Harshil")
        #expect(SchedulerModel.list(["A", "B", "C"]) == "A, B and C")
    }
}
