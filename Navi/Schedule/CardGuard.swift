import Foundation

/// What keeps the ⌘Space cards (scheduler, reminder) to the requests that are really theirs. A card
/// drops down on a keystroke and ⏎ books or adds at once, so a query the card only half reads becomes
/// a junk event on the user's real calendar. Overnight bench 2026-11-01:
///   - "read this assignment, make a google doc with its title and the questions, and block time friday
///     morning to do it" → "Meeting with Its" booked (multi-030);
///   - "set up a study session: check what's due this week on canvas, block 2 hours before each on my
///     calendar, and put on a focus playlist on spotify" → a 2 h "Meeting" today (multi-018);
///   - "add a google calendar event for the hackathon nov 14-15 all day" → a card that read none of it
///     (calendar-023);
///   - "set a timer for 10 minutes" → a reminder (native-025); "in notion add a todo under school…" → a
///     reminder titled with the whole sentence (schoolwork-026).
/// Such a query is a computer task (or a Clock task), never a card. Pure: unit-tested; the parsers
/// return nil for a vetoed query, which keeps every card path (typed opener or Jev's
/// `wants_to_schedule` / `wants_reminder`) closed.
enum CardGuard {
    enum Veto: Equatable, Sendable {
        /// Several instructions ("read…, make…, and block…"): the agent plans them.
        case compound
        /// Another app or site to do it in ("in notion", "a google calendar event", "on canvas").
        case otherPlace(String)
        /// A timer, alarm or stopwatch: the Clock app, not a reminder or an event.
        case timer
        /// Something else to make ("make a note called groceries…", "add a checklist…"): a note, a
        /// document, a list — the Notes app or the app in front, not a reminder or an event.
        case otherThing
        /// An all-day or multi-day event ("nov 14-15 all day"): the card books timed events only.
        case allDayOrMultiDay
    }

    enum Card { case schedule, reminder }

    /// Why `query` is not for `card` (nil: it may be). `explicitOpener`: the query opened with
    /// "remind me (to)", "todo", "don't forget"… — everything after is the reminder's own text, so it
    /// may hold several verbs ("remind me to buy milk and call mom") or a timer ("remind me to reset the
    /// alarm"); a place it is to be done *in* still sends it elsewhere ("add a todo in notion") unless
    /// `placeIsContent` ("remind me to submit it on canvas": the place is part of what to remember).
    static func veto(_ query: String, card: Card, explicitOpener: Bool = false, placeIsContent: Bool = false) -> Veto? {
        if !placeIsContent, let place = otherPlace(in: query) { return .otherPlace(place) }
        if !explicitOpener, mentionsTimer(query) { return .timer }
        if !explicitOpener, makesOtherThing(query) { return .otherThing }
        if !explicitOpener, isCompound(query) { return .compound }
        if card == .schedule, isAllDayOrMultiDay(query) { return .allDayOrMultiDay }
        return nil
    }

    // MARK: Several instructions

    /// Verbs that start an instruction of their own: the voice segmenter's, plus the ones a calendar or
    /// study task chains ("block 2 hours…", "export…", "book a room").
    static let instructionVerbs: Set<String> = UtteranceSegmenter.imperativeVerbs.union([
        "block", "book", "schedule", "plan", "export", "download", "upload", "order", "buy", "listen", "watch",
        "summarize", "summarise", "draft", "share", "submit", "print", "invite", "review",
    ]).subtracting(["call"])   // "lunch with ana and a call after" — an event word as often as a verb
    static let clauseFillers: Set<String> = UtteranceSegmenter.leadingFillers.union(["can", "could", "would", "you", "i", "want", "to", "let's", "lets"])

    /// Two or more clauses that each start with an instruction verb ("read this assignment, make a
    /// google doc…, and block time friday"). Names joined by "and" ("with jilles and harshil") are no
    /// clauses of their own; text being dictated ("text ana that…") swallows the rest.
    static func isCompound(_ query: String) -> Bool {
        let lower = " " + query.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        let clauses = lower.replacingOccurrences(of: #"\s+(and then|and also|after that|then|and|&)\s+|[,;:]"#, with: "|", options: .regularExpression)
            .split(separator: "|")
            .map { $0.split(separator: " ").map { String($0).trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty } }
            .filter { !$0.isEmpty && $0 != ["go", "ahead"] }
        var instructions = 0
        for words in clauses {
            guard let first = words.drop(while: { clauseFillers.contains($0) }).first, instructionVerbs.contains(first) else { continue }
            instructions += 1
            if instructions >= 2 { return true }
            if UtteranceSegmenter.dictationVerbs.contains(first) { break }
        }
        return false
    }

    // MARK: Another app or site

    /// Apps the cards themselves stand for, or whose meeting link the scheduler adds.
    static let cardPlaces: Set<String> = ["Calendar", "Reminders", "FaceTime", "Microsoft Teams", "Teams Web", "zoom.us", "Zoom Web", "Google Meet"]
    /// Skill aliases that are ordinary words in a calendar request ("the review on edge cases").
    static let ordinaryAliases: Set<String> = ["edge", "brave", "opera", "warp", "tweet", "wiki", "realtor", "google", "gpt",
                                               "messenger", "preferences", "ig", "yt", "fb"]
    /// Things a named app holds: "a google calendar event", "a notion page", "my spotify playlist".
    static let placeObjects = "event|events|calendar|invite|invitation|todo|todos|to do|task|tasks|reminder|reminders|doc|docs|document|page|note|notes|list|board|playlist|assignment|assignments"

    /// The app or site (an `AppSkills` skill other than the cards' own) the query asks for the work to be
    /// done in — the first one it names that way: after "in/on/into/using/via" ("in notion", "on canvas",
    /// "on spotify"); for a name that is no common word also "to <it>" ("add it to google calendar"), as
    /// the query's first word ("notion: add…"), made or opened ("make a google doc"), or naming what it
    /// holds ("a google calendar event"). A mere mention ("remind me to email the notion team") does not
    /// count; a common word ("notes", "music", "mail") only counts after "in/on/…".
    static func otherPlace(in query: String) -> String? {
        let lower = " " + query.lowercased().replacingOccurrences(of: #"[^a-z0-9.+' ]"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ") + " "
        var best: (name: String, at: String.Index, length: Int)?
        for skill in AppSkills.all where !cardPlaces.contains(skill.name) {
            for alias in Set(([skill.name] + skill.aliases).map { $0.lowercased() })
            where !ordinaryAliases.contains(alias) && lower.contains(" \(alias) ") {
                let name = NSRegularExpression.escapedPattern(for: alias)
                var shapes = [#"\b(in|on|into|using|via|inside|within|through) (the |my |our |a |an )?\#(name)\b"#]
                if !AppSkills.commonWordNames.contains(alias) {
                    shapes += [#"\bto (the |my |our |a |an )?\#(name)\b"#,
                               #"^ \#(name)\b"#,
                               #"\b(make|create|start|open|new) (the |my |our |a |an )?(new )?\#(name)\b"#,
                               #"\b\#(name) (\#(placeObjects))\b"#]
                }
                for shape in shapes {
                    guard let r = lower.range(of: shape, options: .regularExpression) else { continue }
                    // The first place named; at the same spot the longer name ("google calendar" over "google").
                    if best == nil || r.lowerBound < best!.at || (r.lowerBound == best!.at && alias.count > best!.length) {
                        best = (skill.name, r.lowerBound, alias.count)
                    }
                }
            }
        }
        return best?.name
    }

    // MARK: Timers

    static func mentionsTimer(_ query: String) -> Bool {
        query.lowercased().range(of: #"\b(timer|timers|stopwatch|alarm|alarms|countdown)\b"#, options: .regularExpression) != nil
    }

    // MARK: Something else to make

    /// "make a note …", "make a new note in my school folder", "create a doc", "add a checklist under it",
    /// "write an email", "start a new spreadsheet" (bench native-040/071/080/041: the reminder or the
    /// scheduler card took them). A note is not a reminder.
    static func makesOtherThing(_ query: String) -> Bool {
        query.lowercased().range(of: #"\b(make|create|write|start|take|jot|jot down|add|new|draft|open)\s+(a |an |the |my |me a |up a )?(new |quick |blank |short )?(note|notes|checklist|check list|list|document|doc|spreadsheet|sheet|presentation|slide|slides|email|e-mail|message|text|file|folder|page)\b"#,
                                     options: .regularExpression) != nil
    }

    // MARK: All-day and multi-day events

    private static let month = #"(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec)\.?"#
    private static let dayNum = #"\d{1,2}(st|nd|rd|th)?"#
    private static let weekday = #"(monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tues|tue|wed|thurs|thur|thu|fri|sat|sun)"#
    private static let through = #"\s*(-|–|to|through|thru|until|till)\s*"#

    /// "all day", "nov 14-15", "november 14 to 16", "14th-15th of nov", "friday to sunday", "for 3 days".
    static func isAllDayOrMultiDay(_ query: String) -> Bool {
        let lower = query.lowercased()
        let patterns = [
            #"\ball[- ]?day\b"#,
            #"\b\#(month)\s+\#(dayNum)\#(through)(\#(month)\s+)?\#(dayNum)\b"#,
            #"\b\#(dayNum)\#(through)\#(dayNum)\s+(of\s+)?\#(month)"#,
            #"\b\#(weekday)\#(through)\#(weekday)\b"#,
            #"\bfor\s+(\d+|two|three|four|five|six|seven|a few|several)\s+days\b"#,
            #"\b(multi-?day|overnight trip)\b"#,
        ]
        return patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }
}
