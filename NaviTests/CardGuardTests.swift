import Foundation
import Testing
@testable import Navi

// The overnight bench of 2026-11-01 (build/taskbench/overnight-20261101-hotkey): the scheduler and
// reminder cards grabbed queries that were not theirs, and ⏎ on the scheduler booked a real event.

@Suite struct CardGuardTests {
    // MARK: The bench queries never open a card

    @Test func benchQueriesAreComputerTasks() {
        let multi030 = "read this assignment, make a google doc with its title and the questions, and block time friday morning to do it"
        let multi018 = "set up a study session: check what's due this week on canvas, block 2 hours before each on my calendar, and put on a focus playlist on spotify"
        let calendar023 = "add a google calendar event for the hackathon nov 14-15 all day"
        let native025 = "set a timer for 10 minutes"
        let schoolwork026 = "in notion add a todo under school that says finish hci reading"
        for q in [multi030, multi018, calendar023, native025, schoolwork026] {
            #expect(ScheduleParser.parse(q) == nil, Comment(rawValue: q))
            #expect(ReminderParser.parse(q) == nil, Comment(rawValue: q))
        }
        #expect(CardGuard.veto(multi030, card: .schedule) == .otherPlace("Google Docs"))   // "make a google doc"
        #expect(CardGuard.isCompound(multi030))
        #expect(CardGuard.veto(multi018, card: .schedule) == .otherPlace("Canvas"))
        #expect(CardGuard.veto(calendar023, card: .schedule) == .otherPlace("Google Calendar"))
        #expect(CardGuard.veto(native025, card: .reminder) == .timer)
        #expect(CardGuard.veto(schoolwork026, card: .reminder) == .otherPlace("Notion"))
    }

    // MARK: Several instructions

    @Test func compoundInstructions() {
        #expect(CardGuard.isCompound("read this assignment, make a google doc with its title and the questions, and block time friday morning to do it"))
        #expect(CardGuard.isCompound("set up a study session: check what's due this week, block 2 hours before each, and put on a focus playlist"))
        #expect(CardGuard.isCompound("schedule a meeting with ana tomorrow and book a room"))
        // Names joined by "and", one instruction, dictated text: one clause of work.
        #expect(!CardGuard.isCompound("meeting with jilles and harshil tomorrow afternoon for 45 min"))
        #expect(!CardGuard.isCompound("set up a meeting with ana, bob and carl next friday at 3"))
        #expect(!CardGuard.isCompound("go ahead and schedule lunch with ana tomorrow"))
        #expect(!CardGuard.isCompound("block 2 to 4 on wednesday for focus time"))
        #expect(!CardGuard.isCompound("text ana that I'll book it and call her later"))
    }

    @Test func aReminderOpenerKeepsItsOwnText() {
        // After "remind me to…" the verbs, a timer and a place are what to remember.
        #expect(ReminderParser.parse("remind me to buy milk and call mom tomorrow")?.isExplicit == true)
        #expect(ReminderParser.parse("remind me to reset the alarm tonight")?.isExplicit == true)
        #expect(ReminderParser.parse("remind me to submit the lab report on canvas friday")?.isExplicit == true)
        #expect(ReminderParser.parse("don't forget to put the playlist on spotify")?.isExplicit == true)
        // "add a todo" names where it goes when it says "in notion".
        #expect(ReminderParser.parse("add a todo in notion to finish the hci reading") == nil)
        #expect(ReminderParser.parse("add a todo to finish the hci reading")?.isExplicit == true)
    }

    // MARK: Another app or site

    @Test func anotherPlaceToDoItIn() {
        #expect(CardGuard.otherPlace(in: "in notion add a todo under school") == "Notion")
        #expect(CardGuard.otherPlace(in: "add a google calendar event for the hackathon") == "Google Calendar")
        #expect(CardGuard.otherPlace(in: "add lunch with ana to google calendar") == "Google Calendar")
        #expect(CardGuard.otherPlace(in: "check what's due this week on canvas") == "Canvas")
        #expect(CardGuard.otherPlace(in: "put on a focus playlist on spotify") == "Spotify")
        // The cards' own apps and meeting links; a mere mention.
        #expect(CardGuard.otherPlace(in: "block 2 hours on my calendar tomorrow") == nil)
        #expect(CardGuard.otherPlace(in: "meeting with ana on zoom tomorrow at 3") == nil)
        #expect(CardGuard.otherPlace(in: "meeting with ana about the canvas assignment tomorrow") == nil)
        #expect(CardGuard.otherPlace(in: "remind me to email the notion team") == nil)
        #expect(CardGuard.otherPlace(in: "remind me to mail the package") == nil)
    }

    // MARK: Timers

    @Test func timersAreTheClocks() {
        for q in ["set a timer for 10 minutes", "start a 25 minute timer", "set an alarm for 7am tomorrow", "start the stopwatch"] {
            #expect(ReminderParser.parse(q) == nil, Comment(rawValue: q))
            #expect(ScheduleParser.parse(q) == nil, Comment(rawValue: q))
        }
        // A reminder in some minutes is still a reminder.
        #expect(ReminderParser.parse("remind me in 10 minutes to check the oven")?.relativeMinutes == 10)
    }

    // MARK: All-day and multi-day events wait for a card that books them

    @Test func allDayAndMultiDayDefer() {
        for q in ["hackathon nov 14-15 all day", "block friday all day for the retreat", "conference november 14 to 16",
                  "trip 14th-16th of december", "offsite friday to sunday", "camping for 3 days next week"] {
            #expect(CardGuard.isAllDayOrMultiDay(q), Comment(rawValue: q))
            #expect(ScheduleParser.parse(q) == nil, Comment(rawValue: q))
        }
        for q in ["block 2 to 4 on wednesday for focus time", "meeting with ana 2-3pm tomorrow", "lunch with ana nov 14 at noon",
                  "coffee with jo march 3", "sync with the team today 10-11"] {
            #expect(!CardGuard.isAllDayOrMultiDay(q), Comment(rawValue: q))
        }
    }
}
