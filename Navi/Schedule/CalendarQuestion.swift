import Foundation

/// "what's on my calendar tomorrow", "what meetings do I have today", "my schedule for friday":
/// answered from EventKit — every account the Mac's Calendar has — instead of driving Outlook
/// (taskbench calendar-001: the agent read Outlook's week view as "no events" for a day with four).
enum CalendarQuestion {
    struct Item: Equatable, Sendable {
        var start: Date
        var end: Date
        var title: String
        var allDay: Bool
    }

    private static let asks = #"\b(what'?s|whats|what is|what do i have|what have i got|anything|show me|read me|tell me)\b.*\b(on|in)\s+my\s+(calendar|schedule|agenda)\b"#
        + #"|\bwhat\s+(meetings|events|classes|appointments)\b.*\b(do i have|have i got|are there|today|tomorrow)\b"#
        + #"|^(?:what'?s\s+)?my\s+(calendar|schedule|agenda)\s+(?:for\s+|on\s+)?(today|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#
    private static let edits = #"\b(add|put|book|move|reschedule|cancel|delete|remove|create|set up|invite|block)\b|(?<!my )(?<!the )\bschedule\b"#
    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    /// The start of the day a calendar question asks about, or nil when the query is not one
    /// (an edit — "put lunch on my calendar" — belongs to the scheduler card).
    static func day(asked query: String, now: Date = Date(), calendar cal: Calendar = .current) -> Date? {
        let t = query.lowercased()
        guard t.range(of: asks, options: .regularExpression) != nil,
              t.range(of: edits, options: .regularExpression) == nil else { return nil }
        let today = cal.startOfDay(for: now)
        if t.contains("tomorrow") { return cal.date(byAdding: .day, value: 1, to: today) }
        if t.contains("yesterday") { return cal.date(byAdding: .day, value: -1, to: today) }
        for (i, name) in weekdays.enumerated() where t.range(of: "\\b\(name)\\b", options: .regularExpression) != nil {
            var ahead = (i + 1 - cal.component(.weekday, from: today) + 7) % 7
            if ahead == 0, t.contains("next") { ahead = 7 }
            return cal.date(byAdding: .day, value: ahead, to: today)
        }
        return today
    }

    /// "Tomorrow (Monday, November 2), 3 events:" then one line per event, all-day first, in time order.
    static func answer(day: Date, items: [Item], now: Date = Date(), calendar cal: Calendar = .current) -> String {
        let dayName = DateFormatter()
        dayName.locale = Locale(identifier: "en_US_POSIX"); dayName.calendar = cal; dayName.timeZone = cal.timeZone
        dayName.dateFormat = "EEEE, MMMM d"
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now
        let when = cal.isDate(day, inSameDayAs: now) ? "Today (\(dayName.string(from: day)))"
            : cal.isDate(day, inSameDayAs: tomorrow) ? "Tomorrow (\(dayName.string(from: day)))"
            : dayName.string(from: day)
        guard !items.isEmpty else { return "\(when): nothing on your calendar." }
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX"); time.calendar = cal; time.timeZone = cal.timeZone
        time.dateFormat = "h:mm a"
        let sorted = items.sorted { ($0.allDay ? 0 : 1, $0.start) < ($1.allDay ? 0 : 1, $1.start) }
        let lines = sorted.map { i in
            i.allDay ? "- All day — \(i.title)" : "- \(time.string(from: i.start))–\(time.string(from: i.end)) — \(i.title)"
        }
        return "\(when), \(items.count) event\(items.count == 1 ? "" : "s"):\n" + lines.joined(separator: "\n")
    }
}
