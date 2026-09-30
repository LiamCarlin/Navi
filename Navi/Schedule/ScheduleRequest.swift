import Foundation

/// What a typed request asks to put on the calendar: "meeting with jilles and
/// harshil tomorrow afternoon for 45 min". Parsed locally on every keystroke —
/// before Jev has answered — so the scheduler card can drop down instantly.
struct ScheduleRequest: Equatable, Sendable {
    enum TokenKind: String, Equatable, Sendable { case activity, person, day, partOfDay, time, duration, recurrence, priority }

    /// A recognised stretch of the query, in `Character` offsets (for highlighting).
    struct Token: Equatable, Sendable {
        var kind: TokenKind
        var start: Int
        var length: Int
    }

    enum Day: Equatable, Sendable {
        case today, tomorrow
        /// Monday of next week.
        case nextWeek
        /// `Calendar` weekday (1 = Sunday … 7 = Saturday); `nextWeek` for "next friday".
        case weekday(Int, nextWeek: Bool)
        case date(month: Int, day: Int)
    }

    enum PartOfDay: String, Equatable, Sendable {
        case morning, afternoon, evening

        /// Minutes from midnight.
        var range: (start: Int, end: Int) {
            switch self {
            case .morning: return (9 * 60, 12 * 60)
            case .afternoon: return (12 * 60, 17 * 60)
            case .evening: return (17 * 60, 20 * 60)
            }
        }
    }

    struct ClockTime: Equatable, Sendable {
        var hour: Int
        var minute: Int
        var minutes: Int { hour * 60 + minute }
    }

    /// "Meeting", "Coffee", "Focus time"…
    var activity: String
    /// Names (or emails) as typed after "with".
    var people: [String] = []
    var day: Day?
    var partOfDay: PartOfDay?
    var time: ClockTime?
    var durationMinutes: Int?
    var tokens: [Token] = []
    /// The query plainly asks to put something on the calendar ("schedule…",
    /// or an event word with people or a time). Otherwise only Jev's
    /// `wants_to_schedule` can open the card.
    var isExplicit = false

    /// Anything beyond the event word: without it the card shows examples.
    var hasDetails: Bool {
        !people.isEmpty || day != nil || partOfDay != nil || time != nil || durationMinutes != nil
    }

    var defaultDuration: Int {
        switch activity {
        case "Lunch", "Dinner", "Breakfast", "Focus time", "Deep work", "Workshop", "Brainstorm": return 60
        default: return 30
        }
    }

    /// "Meeting with Jilles & Harshil"; just the activity with nobody.
    static func title(activity: String, names: [String]) -> String {
        guard let last = names.last else { return activity }
        let list = names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " & " + last
        return "\(activity) with \(list)"
    }

    /// The calendar day this request is for (start of day). With no day typed:
    /// today while there is still time left in the working day, else the next
    /// weekday; a typed time already past today means tomorrow.
    func resolvedDay(now: Date, calendar cal: Calendar) -> Date {
        let today = cal.startOfDay(for: now)
        func add(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: today) ?? today }
        let weekday = cal.component(.weekday, from: today)
        let toNextMonday: Int = { let n = (2 - weekday + 7) % 7; return n == 0 ? 7 : n }()
        switch day {
        case .today:
            return today
        case .tomorrow:
            return add(1)
        case .nextWeek:
            return add(toNextMonday)
        case .weekday(let target, let nextWeek):
            if nextWeek { return add(toNextMonday + (target - 2 + 7) % 7) }
            return add((target - weekday + 7) % 7)
        case .date(let month, let dayOfMonth):
            var comps = cal.dateComponents([.year], from: today)
            comps.month = month
            comps.day = dayOfMonth
            if let date = cal.date(from: comps), date >= today { return date }
            comps.year = (comps.year ?? 2000) + 1
            return cal.date(from: comps) ?? today
        case nil:
            let nowMinutes = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
            if let time { return time.minutes > nowMinutes ? today : add(1) }
            let latestStart = (partOfDay?.range.end ?? SchedulePlanner.dayEndHour * 60) - (durationMinutes ?? defaultDuration)
            if nowMinutes < latestStart { return today }
            var n = 1
            while cal.isDateInWeekend(add(n)) { n += 1 }
            return add(n)
        }
    }
}

// MARK: - Parser

enum ScheduleParser {
    struct Word: Equatable {
        var text: String
        var lower: String
        var start: Int
        var length: Int
        /// A comma followed the word ("with jilles, harshil").
        var comma = false
    }

    /// Splits on whitespace and commas; "&" is its own word ("and"); trailing
    /// sentence marks are dropped.
    static func words(in query: String) -> [Word] {
        var out: [Word] = []
        var buffer = ""
        var bufferStart = 0
        func flush() {
            var text = buffer
            while text.count > 1, let last = text.last, ".!?;:".contains(last) { text.removeLast() }
            if !text.isEmpty, text != "." {
                out.append(Word(text: text, lower: text.lowercased(), start: bufferStart, length: text.count))
            }
            buffer = ""
        }
        for (i, ch) in query.enumerated() {
            if ch.isWhitespace || ch == "," {
                flush()
                if ch == ",", !out.isEmpty { out[out.count - 1].comma = true }
            } else if ch == "&" {
                flush()
                out.append(Word(text: "&", lower: "and", start: i, length: 1))
            } else {
                if buffer.isEmpty { bufferStart = i }
                buffer.append(ch)
            }
        }
        flush()
        return out
    }

    // MARK: Lexicon

    /// Polite lead-ins skipped at the start ("can you schedule…").
    static let fillers: Set<String> = ["please", "pls", "hey", "navi", "can", "could", "would", "will", "you",
                                        "i", "want", "need", "to", "let's", "lets", "let", "us", "go", "ahead"]
    /// First words that make it something else: a question, a search, an edit.
    static let rejects: Set<String> = ["what", "what's", "whats", "when", "when's", "where", "who", "who's", "how", "why",
                                        "is", "are", "am", "do", "does", "did", "show", "list", "find", "open", "cancel",
                                        "delete", "remove", "move", "reschedule", "search", "google", "email", "text",
                                        "message", "send", "tell", "remind", "reply", "join", "decline", "accept"]
    static let verbs: Set<String> = ["schedule", "book", "arrange", "plan", "add", "create", "put", "set", "setup",
                                      "organize", "organise", "grab", "have", "hold", "block"]
    /// Verbs that mean "calendar" on their own ("schedule a call").
    static let strongVerbs: Set<String> = ["schedule", "book", "arrange", "plan", "set", "setup", "organize", "organise"]
    /// Skipped between the verb and the event word: "schedule a quick sync", "set up time with".
    static let skippable: Set<String> = ["a", "an", "the", "some", "my", "our", "quick", "short", "brief", "new",
                                          "long", "little", "time", "up", "in"]

    struct Activity {
        var words: [String]
        var name: String
        /// Clear enough on its own ("meeting") to show the card with examples.
        var standalone: Bool
    }

    /// Longest phrases first.
    static let activities: [Activity] = [
        Activity(words: ["one", "on", "one"], name: "1:1", standalone: true),
        Activity(words: ["focus", "time"], name: "Focus time", standalone: true),
        Activity(words: ["deep", "work"], name: "Deep work", standalone: true),
        Activity(words: ["catch", "up"], name: "Catch-up", standalone: false),
        Activity(words: ["check", "in"], name: "Check-in", standalone: false),
        Activity(words: ["meeting"], name: "Meeting", standalone: true),
        Activity(words: ["meet"], name: "Meeting", standalone: false),
        Activity(words: ["sync"], name: "Sync", standalone: false),
        Activity(words: ["call"], name: "Call", standalone: false),
        Activity(words: ["coffee"], name: "Coffee", standalone: false),
        Activity(words: ["lunch"], name: "Lunch", standalone: false),
        Activity(words: ["dinner"], name: "Dinner", standalone: false),
        Activity(words: ["breakfast"], name: "Breakfast", standalone: false),
        Activity(words: ["drinks"], name: "Drinks", standalone: false),
        Activity(words: ["chat"], name: "Chat", standalone: false),
        Activity(words: ["standup"], name: "Standup", standalone: true),
        Activity(words: ["stand-up"], name: "Standup", standalone: true),
        Activity(words: ["interview"], name: "Interview", standalone: false),
        Activity(words: ["review"], name: "Review", standalone: false),
        Activity(words: ["demo"], name: "Demo", standalone: false),
        Activity(words: ["1:1"], name: "1:1", standalone: true),
        Activity(words: ["1-1"], name: "1:1", standalone: true),
        Activity(words: ["1on1"], name: "1:1", standalone: true),
        Activity(words: ["one-on-one"], name: "1:1", standalone: true),
        Activity(words: ["catchup"], name: "Catch-up", standalone: false),
        Activity(words: ["catch-up"], name: "Catch-up", standalone: false),
        Activity(words: ["check-in"], name: "Check-in", standalone: false),
        Activity(words: ["focus"], name: "Focus time", standalone: false),
        Activity(words: ["brainstorm"], name: "Brainstorm", standalone: false),
        Activity(words: ["workshop"], name: "Workshop", standalone: false),
        Activity(words: ["huddle"], name: "Huddle", standalone: false),
        Activity(words: ["appointment"], name: "Appointment", standalone: false),
        Activity(words: ["session"], name: "Session", standalone: false),
        Activity(words: ["meetup"], name: "Meetup", standalone: false),
        Activity(words: ["hangout"], name: "Hangout", standalone: false),
        Activity(words: ["walk"], name: "Walk", standalone: false),
    ]

    static let weekdays: [String: Int] = [
        "sunday": 1, "sun": 1, "monday": 2, "mon": 2, "tuesday": 3, "tue": 3, "tues": 3,
        "wednesday": 4, "wed": 4, "weds": 4, "thursday": 5, "thu": 5, "thur": 5, "thurs": 5,
        "friday": 6, "fri": 6, "saturday": 7, "sat": 7,
    ]
    static let months: [String: Int] = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3, "april": 4, "apr": 4,
        "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7, "august": 8, "aug": 8,
        "september": 9, "sep": 9, "sept": 9, "october": 10, "oct": 10, "november": 11, "nov": 11,
        "december": 12, "dec": 12,
    ]
    static let minuteUnits: Set<String> = ["m", "min", "mins", "minute", "minutes"]
    static let hourUnits: Set<String> = ["h", "hr", "hrs", "hour", "hours"]
    /// Words that end a name: "with jilles tomorrow", "with ana about the roadmap".
    static let nameStops: Set<String> = [
        "and", "or", "with", "at", "on", "for", "to", "about", "re", "regarding", "in", "from", "this", "next",
        "today", "tonight", "tomorrow", "tmrw", "tmr", "tomorow", "tommorow", "morning", "afternoon", "evening",
        "noon", "midday", "around", "by", "before", "after", "via", "over", "during", "the", "every", "a", "an",
        "january", "february", "march", "april", "june", "july", "august", "september", "october", "november", "december",
    ]
    /// Glue between recognised parts: consumed without counting as unknown.
    static let glue: Set<String> = ["at", "on", "for", "this", "around", "and", "by", "from", "of", "@", "the", "a", "an"]

    // MARK: Parse

    /// nil when the query can't be a scheduling request at all (a question, a
    /// search, an edit). Otherwise the parse, with `isExplicit` saying whether
    /// it plainly is one.
    static func parse(_ query: String) -> ScheduleRequest? {
        let ws = words(in: query)
        var i = 0
        while i < ws.count, fillers.contains(ws[i].lower) { i += 1 }
        guard i < ws.count, !rejects.contains(ws[i].lower) else { return nil }

        var req = ScheduleRequest(activity: "Meeting")
        var verb: String?
        if verbs.contains(ws[i].lower) {
            verb = ws[i].lower
            i += 1
        }
        while i < ws.count, skippable.contains(ws[i].lower) { i += 1 }

        var activity: Activity?
        if let match = matchActivity(ws, at: i) {
            activity = match
            req.activity = match.name
            req.tokens.append(token(.activity, ws, i, i + match.words.count - 1))
            i += match.words.count
        } else if verb == "block" || verb == "hold" {
            req.activity = "Hold"
        }

        var unknown = 0
        var j = i
        while j < ws.count {
            if ws[j].lower == "with" {
                j = parsePeople(ws, from: j + 1, into: &req)
            } else if let next = parseWhen(ws, at: j, into: &req) {
                j = next
            } else {
                if !glue.contains(ws[j].lower) { unknown += 1 }
                j += 1
            }
        }

        let hasPeople = !req.people.isEmpty
        let hasWhen = req.day != nil || req.partOfDay != nil || req.time != nil || req.durationMinutes != nil
        let v = verb ?? ""
        if let activity {
            req.isExplicit = hasPeople || hasWhen || strongVerbs.contains(v) || (activity.standalone && unknown == 0)
        } else {
            req.isExplicit = ((v == "schedule" || v == "arrange") && (hasPeople || hasWhen || unknown == 0))
                || (verb != nil && hasPeople)
                || ((v == "block" || v == "hold") && hasWhen)
        }
        return req
    }

    static func matchActivity(_ ws: [Word], at i: Int) -> Activity? {
        activities.first { a in
            i + a.words.count <= ws.count && zip(a.words, ws[i...]).allSatisfy { $0 == $1.lower }
        }
    }

    static func token(_ kind: ScheduleRequest.TokenKind, _ ws: [Word], _ first: Int, _ last: Int) -> ScheduleRequest.Token {
        ScheduleRequest.Token(kind: kind, start: ws[first].start, length: ws[last].start + ws[last].length - ws[first].start)
    }

    /// Names after "with": up to three words each, split by "and", "&", "or" or commas.
    static func parsePeople(_ ws: [Word], from start: Int, into req: inout ScheduleRequest) -> Int {
        var j = start
        while j < ws.count {
            var end = j
            while end < ws.count, end - j < 3, isNameWord(ws, at: end) {
                end += 1
                if ws[end - 1].comma { break }
            }
            guard end > j else { break }
            req.people.append(ws[j..<end].map(\.text).joined(separator: " "))
            req.tokens.append(token(.person, ws, j, end - 1))
            let comma = ws[end - 1].comma
            j = end
            if j < ws.count, ws[j].lower == "and" || ws[j].lower == "or" { j += 1; continue }
            if comma { continue }
            break
        }
        return j
    }

    static func isNameWord(_ ws: [Word], at k: Int) -> Bool {
        let w = ws[k].lower
        if nameStops.contains(w) || weekdays[w] != nil { return false }
        // "with ana oct 3": a short month before a day number is the date, not a surname.
        if months[w] != nil, k + 1 < ws.count, dayNumber(ws[k + 1].lower) != nil { return false }
        if w.first?.isNumber == true { return false }
        return w.contains { $0.isLetter }
    }

    /// Days, parts of the day, times and durations. Returns the index after
    /// what it consumed, or nil when `ws[j]` is none of them.
    static func parseWhen(_ ws: [Word], at j: Int, into req: inout ScheduleRequest) -> Int? {
        let w = ws[j].lower
        let next = j + 1 < ws.count ? ws[j + 1].lower : nil
        let prev = j > 0 ? ws[j - 1].lower : nil
        func take(_ kind: ScheduleRequest.TokenKind, through last: Int) -> Int {
            req.tokens.append(token(kind, ws, j, last))
            return last + 1
        }

        // Days
        switch w {
        case "today":
            req.day = .today
            return take(.day, through: j)
        case "tonight":
            req.day = .today
            req.partOfDay = .evening
            return take(.day, through: j)
        case "tomorrow", "tmrw", "tmr", "tomorow", "tommorow":
            req.day = .tomorrow
            return take(.day, through: j)
        default:
            break
        }
        if w == "next", next == "week" {
            req.day = .nextWeek
            return take(.day, through: j + 1)
        }
        if w == "next" || w == "this", let n = next, let target = weekdays[n] {
            req.day = .weekday(target, nextWeek: w == "next")
            return take(.day, through: j + 1)
        }
        if w == "this", let n = next, let part = ScheduleRequest.PartOfDay(rawValue: n) {
            if req.day == nil { req.day = .today }
            req.partOfDay = part
            return take(.partOfDay, through: j + 1)
        }
        if let target = weekdays[w] {
            req.day = .weekday(target, nextWeek: false)
            return take(.day, through: j)
        }
        if let month = months[w], let n = next, let d = dayNumber(n) {
            req.day = .date(month: month, day: d)
            return take(.day, through: j + 1)
        }
        if let d = dayNumber(w), let n = next {
            if let month = months[n] {
                req.day = .date(month: month, day: d)
                return take(.day, through: j + 1)
            }
            if n == "of", j + 2 < ws.count, let month = months[ws[j + 2].lower] {
                req.day = .date(month: month, day: d)
                return take(.day, through: j + 2)
            }
        }

        // Parts of the day
        if let part = ScheduleRequest.PartOfDay(rawValue: w) {
            req.partOfDay = part
            return take(.partOfDay, through: j)
        }
        if w == "noon" || w == "midday" {
            req.time = ScheduleRequest.ClockTime(hour: 12, minute: 0)
            return take(.time, through: j)
        }

        // Durations: "30min", "2h", "30 min", "an hour", "half an hour"
        if let minutes = compactDuration(w) {
            req.durationMinutes = minutes
            return take(.duration, through: j)
        }
        if let num = splitNumber(w), num.rest.isEmpty, num.value > 0, let unit = next {
            if minuteUnits.contains(unit), num.value <= 720 {
                req.durationMinutes = Int(num.value.rounded())
                return take(.duration, through: j + 1)
            }
            if hourUnits.contains(unit), num.value <= 12 {
                req.durationMinutes = Int((num.value * 60).rounded())
                return take(.duration, through: j + 1)
            }
        }
        if w == "an" || w == "a" || w == "one", next == "hour" {
            req.durationMinutes = 60
            return take(.duration, through: j + 1)
        }
        if w == "half", next == "hour" {
            req.durationMinutes = 30
            return take(.duration, through: j + 1)
        }
        if w == "half", next == "an", j + 2 < ws.count, ws[j + 2].lower == "hour" {
            req.durationMinutes = 30
            return take(.duration, through: j + 2)
        }

        // Times: "10am", "3 pm", "10:30", "at 3"
        let meridiemNext = next.map { ["am", "pm", "a.m", "p.m"].contains($0) } ?? false
        let clockText = meridiemNext ? w + (next ?? "") : w
        if let clock = parseClock(clockText) {
            let cued = clock.meridiem != nil || clock.hasColon || ["at", "@", "around", "by", "from"].contains(prev ?? "")
            if cued, let hour = resolveHour(clock.hour, meridiem: clock.meridiem) {
                req.time = ScheduleRequest.ClockTime(hour: hour, minute: clock.minute)
                return take(.time, through: meridiemNext ? j + 1 : j)
            }
        }

        // "for 45" means minutes
        if prev == "for", let num = splitNumber(w), num.rest.isEmpty, num.value >= 5, num.value <= 480 {
            req.durationMinutes = Int(num.value)
            return take(.duration, through: j)
        }
        return nil
    }

    /// "3", "3rd", "21st" → 3, 3, 21.
    static func dayNumber(_ w: String) -> Int? {
        var s = w
        for suffix in ["st", "nd", "rd", "th"] where s.hasSuffix(suffix) {
            s = String(s.dropLast(2))
            break
        }
        guard let n = Int(s), (1...31).contains(n) else { return nil }
        return n
    }

    /// Leading number and the rest: "30min" → (30, "min"), "1.5h" → (1.5, "h").
    static func splitNumber(_ s: String) -> (value: Double, rest: String)? {
        let end = s.firstIndex { !($0.isNumber || $0 == ".") } ?? s.endIndex
        guard end > s.startIndex, let n = Double(s[..<end]) else { return nil }
        return (value: n, rest: String(s[end...]))
    }

    /// One-word durations: "30min", "45m", "2h", "1.5hrs", "1h30", "1h30m".
    static func compactDuration(_ s: String) -> Int? {
        guard let num = splitNumber(s), num.value > 0, !num.rest.isEmpty else { return nil }
        let n = num.value, unit = num.rest
        if minuteUnits.contains(unit) { return n <= 720 ? Int(n.rounded()) : nil }
        if hourUnits.contains(unit) { return n <= 12 ? Int((n * 60).rounded()) : nil }
        for h in ["h", "hr"] where unit.hasPrefix(h) {
            var rest = String(unit.dropFirst(h.count))
            for m in ["mins", "min", "m"] where rest.hasSuffix(m) {
                rest = String(rest.dropLast(m.count))
                break
            }
            if let extra = Int(rest), (0...59).contains(extra), n <= 12, n == n.rounded() {
                return Int(n) * 60 + extra
            }
        }
        return nil
    }

    struct Clock: Equatable {
        var hour: Int
        var minute: Int
        /// "a" or "p" when am/pm was given.
        var meridiem: Character?
        var hasColon: Bool
    }

    /// "10am", "10:30", "10.30pm", "3p.m", "15:00" → hour/minute as written.
    static func parseClock(_ raw: String) -> Clock? {
        var s = raw.lowercased()
            .replacingOccurrences(of: "a.m", with: "am")
            .replacingOccurrences(of: "p.m", with: "pm")
        var meridiem: Character?
        if s.hasSuffix("am") || s.hasSuffix("pm") {
            meridiem = s.dropLast().last
            s = String(s.dropLast(2))
        }
        s = s.replacingOccurrences(of: ".", with: ":")
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, let hour = Int(parts[0]), (0...23).contains(hour) else { return nil }
        var minute = 0
        if parts.count == 2 {
            guard parts[1].count == 2, let m = Int(parts[1]), (0...59).contains(m) else { return nil }
            minute = m
        }
        return Clock(hour: hour, minute: minute, meridiem: meridiem, hasColon: parts.count == 2)
    }

    /// 24-hour clock hour. Without am/pm, 1–7 read as afternoon ("at 3") and
    /// 8–11 as morning, the way people book meetings.
    static func resolveHour(_ hour: Int, meridiem: Character?) -> Int? {
        switch meridiem {
        case "a"?:
            guard (1...12).contains(hour) else { return nil }
            return hour == 12 ? 0 : hour
        case "p"?:
            guard (1...12).contains(hour) else { return nil }
            return hour == 12 ? 12 : hour + 12
        default:
            if hour == 0 || hour >= 12 { return hour }
            return hour <= 7 ? hour + 12 : hour
        }
    }
}
