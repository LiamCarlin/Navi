import Foundation

/// What a typed request asks to be reminded of: "remind me to call mom
/// tomorrow at 5", "todo: renew passport next week", "stretch in 45 min",
/// "water the plants every sunday". Parsed locally on every keystroke, like
/// `ScheduleRequest`, whose day/time reading it reuses.
struct ReminderRequest: Equatable, Sendable {
    enum Repeat: Equatable, Sendable {
        case never, daily, weekdays, monthly
        /// Weekly; on a given `Calendar` weekday (1 = Sunday … 7 = Saturday) when one was said.
        case weekly(weekday: Int?)

        var label: String {
            switch self {
            case .never: return "Never"
            case .daily: return "Every day"
            case .weekdays: return "Weekdays"
            case .monthly: return "Every month"
            case .weekly(let day?):
                var cal = Calendar(identifier: .gregorian)
                cal.locale = Locale(identifier: "en_US")
                return "Every \(cal.weekdaySymbols[(day - 1 + 7) % 7])"
            case .weekly(nil): return "Every week"
            }
        }
    }

    /// "Call mom" — what to remember, with the when-words taken out.
    var title: String
    var day: ScheduleRequest.Day?
    var partOfDay: ScheduleRequest.PartOfDay?
    var time: ScheduleRequest.ClockTime?
    /// "in 45 min" → 45.
    var relativeMinutes: Int?
    var repeatRule: Repeat = .never
    var highPriority = false
    var tokens: [ScheduleRequest.Token] = []
    /// Started with "remind me", "todo", "don't forget"… Otherwise only Jev's
    /// `wants_reminder` can open the card.
    var isExplicit = false

    var hasWhen: Bool { day != nil || partOfDay != nil || time != nil || relativeMinutes != nil }

    /// When it's due. A day without a time is 9 AM; a part of the day is its
    /// usual hour (morning 9, afternoon 2, evening 6); a time already past
    /// today means tomorrow. A repeat with no when starts at the next 9 AM.
    /// No when at all → no due date.
    func resolvedDue(now: Date, calendar cal: Calendar) -> Date? {
        if let relativeMinutes { return now.addingTimeInterval(TimeInterval(relativeMinutes * 60)) }
        var day = self.day
        if day == nil, case .weekly(let weekday?) = repeatRule { day = .weekday(weekday, nextWeek: false) }
        guard day != nil || partOfDay != nil || time != nil || repeatRule != .never else { return nil }

        let minutes = time?.minutes ?? partOfDay.map(Self.usualMinutes) ?? 9 * 60
        let today = cal.startOfDay(for: now)
        func at(_ d: Date) -> Date { cal.date(byAdding: .minute, value: minutes, to: d) ?? d }
        if let day {
            let base = ScheduleRequest(activity: "", day: day).resolvedDay(now: now, calendar: cal)
            let due = at(base)
            // "every friday at 9" said on a Friday at noon: the first one is next week.
            if due <= now, case .weekday = day, let next = cal.date(byAdding: .day, value: 7, to: base) { return at(next) }
            return due
        }
        let dueToday = at(today)
        if dueToday > now { return dueToday }
        return at(cal.date(byAdding: .day, value: 1, to: today) ?? today)
    }

    static func usualMinutes(_ part: ScheduleRequest.PartOfDay) -> Int {
        switch part {
        case .morning: return 9 * 60
        case .afternoon: return 14 * 60
        case .evening: return 18 * 60
        }
    }
}

// MARK: - Parser

enum ReminderParser {
    typealias Word = ScheduleParser.Word

    /// Openers that make it a reminder, longest first.
    static let leadIns: [[String]] = [
        ["set", "a", "reminder", "to"], ["set", "a", "reminder", "for"], ["set", "a", "reminder"],
        ["add", "a", "reminder", "to"], ["add", "a", "reminder", "for"], ["add", "a", "reminder"],
        ["create", "a", "reminder", "to"], ["create", "a", "reminder"],
        ["set", "reminder", "to"], ["set", "reminder"], ["add", "reminder", "to"], ["add", "reminder"],
        ["remind", "me", "to"], ["remind", "me", "about"], ["remind", "me", "that"], ["remind", "me"],
        ["new", "reminder"], ["reminder", "to"], ["reminder"],
        ["don't", "forget", "to"], ["dont", "forget", "to"], ["don't", "forget"], ["dont", "forget"],
        ["add", "a", "todo"], ["add", "todo"], ["add", "a", "task"], ["add", "task"], ["new", "task"],
        ["todo"], ["to-do"], ["to", "do"],
    ]
    /// Openers that are a reminder even with nothing after them ("remind me" → examples).
    static let standaloneLeadIns: Set<String> = ["remind me", "set a reminder", "add a reminder", "new reminder",
                                                  "set reminder", "add reminder", "create a reminder", "todo", "add todo",
                                                  "add a todo", "add task", "add a task", "new task"]
    static let fillers: Set<String> = ["please", "pls", "hey", "navi", "can", "could", "would", "you"]
    /// Little words that belonged to a date ("at 5", "on friday") and leave the title with it.
    static let glue: Set<String> = ["at", "on", "by", "around", "for", "from", "before"]
    static let priorityWords: Set<String> = ["urgent", "asap", "important", "!!", "!!!", "high-priority"]

    /// nil for a question or an edit ("what reminders…", "delete…"). Otherwise
    /// the parse; `isExplicit` when it opened with "remind me" and the like.
    static func parse(_ query: String) -> ReminderRequest? {
        let ws = ScheduleParser.words(in: query)
        var i = 0
        while i < ws.count, fillers.contains(ws[i].lower) { i += 1 }
        guard i < ws.count, !ScheduleParser.rejects.subtracting(["remind"]).contains(ws[i].lower) else { return nil }

        var request = ReminderRequest(title: "")
        if let lead = leadIns.first(where: { phrase in
            i + phrase.count <= ws.count && zip(phrase, ws[i...]).allSatisfy { $0 == $1.lower }
        }) {
            i += lead.count
            let hasRest = i < ws.count
            request.isExplicit = hasRest || standaloneLeadIns.contains(lead.joined(separator: " "))
        }

        var title: [Word] = []
        var j = i
        while j < ws.count {
            let w = ws[j].lower
            let next = j + 1 < ws.count ? ws[j + 1].lower : nil

            // Repeats: "every monday", "every day", "daily", "weekdays"
            if w == "every" || w == "each", let n = next, let rule = repeatRule(for: n) {
                request.repeatRule = rule
                if case .weekly(let d?) = rule, request.day == nil { request.day = .weekday(d, nextWeek: false) }
                request.tokens.append(ScheduleParser.token(.recurrence, ws, j, j + 1))
                dropTrailingGlue(&title)
                j += 2
                continue
            }
            if let rule = ["daily": ReminderRequest.Repeat.daily, "weekdays": .weekdays, "weekly": .weekly(weekday: nil),
                           "monthly": .monthly][w] {
                request.repeatRule = rule
                request.tokens.append(ScheduleParser.token(.recurrence, ws, j, j))
                j += 1
                continue
            }
            // Relative: "in 45 min", "in 2 hours", "in an hour", "in half an hour"
            if w == "in", let rel = relative(ws, from: j + 1) {
                request.relativeMinutes = rel.minutes
                request.tokens.append(ScheduleParser.token(.duration, ws, j, rel.last))
                j = rel.last + 1
                continue
            }
            // "every tuesday night": evening, once a day or a repeat is known.
            if w == "night" || w == "nights", request.day != nil || request.repeatRule != .never {
                request.partOfDay = .evening
                request.tokens.append(ScheduleParser.token(.partOfDay, ws, j, j))
                j += 1
                continue
            }
            if priorityWords.contains(w) {
                request.highPriority = true
                request.tokens.append(ScheduleParser.token(.priority, ws, j, j))
                j += 1
                continue
            }
            // Days and times, read the way the scheduler reads them (lengths are title words here:
            // "walk for 30 min" is the task).
            var scratch = ScheduleRequest(activity: "")
            if let end = ScheduleParser.parseWhen(ws, at: j, into: &scratch), scratch.durationMinutes == nil {
                if let d = scratch.day { request.day = d }
                if let p = scratch.partOfDay { request.partOfDay = p }
                if let t = scratch.time { request.time = t }
                request.tokens += scratch.tokens
                dropTrailingGlue(&title)
                j = end
                continue
            }
            // "remind me at 5 to call mom": the "to" after a leading date isn't part of the task.
            if title.isEmpty, ["to", "that", "about"].contains(w) { j += 1; continue }
            title.append(ws[j])
            j += 1
        }
        request.title = Self.title(from: title)
        return request
    }

    static func repeatRule(for word: String) -> ReminderRequest.Repeat? {
        switch word {
        case "day", "morning", "evening", "night": return .daily
        case "weekday": return .weekdays
        case "week": return .weekly(weekday: nil)
        case "month": return .monthly
        default: return ScheduleParser.weekdays[word].map { .weekly(weekday: $0) }
        }
    }

    /// Minutes and the index of the last word used, for the words after "in".
    static func relative(_ ws: [Word], from k: Int) -> (minutes: Int, last: Int)? {
        guard k < ws.count else { return nil }
        let w = ws[k].lower
        let next = k + 1 < ws.count ? ws[k + 1].lower : nil
        if let m = ScheduleParser.compactDuration(w) { return (m, k) }
        if let num = ScheduleParser.splitNumber(w), num.rest.isEmpty, num.value > 0, let unit = next {
            if ScheduleParser.minuteUnits.contains(unit) { return (Int(num.value.rounded()), k + 1) }
            if ScheduleParser.hourUnits.contains(unit) { return (Int((num.value * 60).rounded()), k + 1) }
            if unit == "day" || unit == "days" { return (Int(num.value.rounded()) * 24 * 60, k + 1) }
            if unit == "week" || unit == "weeks" { return (Int(num.value.rounded()) * 7 * 24 * 60, k + 1) }
        }
        if (w == "an" || w == "a"), next == "hour" { return (60, k + 1) }
        if (w == "a"), next == "day" { return (24 * 60, k + 1) }
        if (w == "a"), next == "week" { return (7 * 24 * 60, k + 1) }
        if w == "half", next == "an", k + 2 < ws.count, ws[k + 2].lower == "hour" { return (30, k + 2) }
        if w == "half", next == "hour" { return (30, k + 1) }
        return nil
    }

    static func dropTrailingGlue(_ title: inout [Word]) {
        while let last = title.last, glue.contains(last.lower) { title.removeLast() }
    }

    /// "call mom" → "Call mom".
    static func title(from words: [Word]) -> String {
        let text = words.map(\.text).joined(separator: " ")
        guard let first = text.first else { return "" }
        return first.uppercased() + text.dropFirst()
    }
}

// MARK: - Quick picks

/// The due-date chips on the card: "In 1 hour", "This evening", "Tomorrow",
/// "This weekend", "Next week".
enum ReminderPlanner {
    struct Option: Equatable, Sendable {
        var label: String
        var date: Date?
    }

    static func options(now: Date, calendar cal: Calendar) -> [Option] {
        let today = cal.startOfDay(for: now)
        func at(_ dayOffset: Int, _ hour: Int) -> Date {
            let d = cal.date(byAdding: .day, value: dayOffset, to: today) ?? today
            return cal.date(byAdding: .hour, value: hour, to: d) ?? d
        }
        let fiveMinutes: TimeInterval = 300
        let inAnHour = Date(timeIntervalSinceReferenceDate:
            (now.addingTimeInterval(3600).timeIntervalSinceReferenceDate / fiveMinutes).rounded(.up) * fiveMinutes)
        var out = [Option(label: "In 1 hour", date: inAnHour)]
        let hour = cal.component(.hour, from: now)
        if hour < 17 { out.append(Option(label: "This evening", date: at(0, 18))) }
        else if hour < 20 { out.append(Option(label: "Tonight", date: at(0, 21))) }
        out.append(Option(label: "Tomorrow", date: at(1, 9)))
        let weekday = cal.component(.weekday, from: now)   // 1 = Sunday … 7 = Saturday
        if (2...5).contains(weekday) { out.append(Option(label: "This weekend", date: at(7 - weekday, 10))) }
        let toMonday = { let n = (2 - weekday + 7) % 7; return n == 0 ? 7 : n }()
        out.append(Option(label: "Next week", date: at(toMonday, 9)))
        out.append(Option(label: "No date", date: nil))
        return out
    }

    /// "Tomorrow at 5:00 PM", "Today at 6:00 PM", "Fri 2 Oct at 9:00 AM".
    static func dueLabel(_ date: Date, now: Date, calendar cal: Calendar) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDate(date, inSameDayAs: now) { return "Today at \(time)" }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow at \(time)"
        }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 99
        if (2..<7).contains(days) { return "\(date.formatted(.dateTime.weekday(.wide))) at \(time)" }
        return "\(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) at \(time)"
    }
}
