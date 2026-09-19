import Foundation

/// Query side of screen memory: natural-language question → time window +
/// FTS terms → ranked `MemoryHit`s (frames and sessions), plus a formatter
/// that turns hits into LLM context.
///
/// `MemoryHit.id` is the frame id for frame hits and the *negative* session id
/// for session hits, so the panel can tell them apart without a new field.
final class Recall: @unchecked Sendable {
    let store: MemoryStore
    private let calendar: Calendar

    init(store: MemoryStore, calendar: Calendar = .current) {
        self.store = store
        self.calendar = calendar
    }

    func search(query: String, limit: Int = 20, now: Date = Date()) async -> [MemoryHit] {
        let store = self.store, calendar = self.calendar
        return await Task.detached(priority: .userInitiated) { () -> [MemoryHit] in
            let (window, terms) = Recall.parseTimeWindow(query, now: now, calendar: calendar)
            do {
                if MemoryStore.ftsQuery(terms, requireAll: true) != nil {
                    let hits = try store.search(query: terms, limit: limit, within: window, now: now)
                    return hits.map(Recall.memoryHit(from:))
                }
                // No searchable terms ("what did I do yesterday?"): list sessions in the window.
                let sessions = window != nil
                    ? try store.sessions(in: window!, limit: limit)
                    : try store.recentSessions(limit: limit)
                return sessions.map { s in
                    let thumb = try? store.bestThumbnail(between: s.start, and: s.end)
                    return Recall.memoryHit(from: s, thumbnail: thumb, now: now)
                }
            } catch {
                Log.memory.error("Recall search failed: \(error.localizedDescription)")
                return []
            }
        }.value
    }

    /// Hits formatted as a compact block for an answer prompt.
    func context(for query: String, limit: Int = 8, now: Date = Date()) async -> String {
        let hits = await search(query: query, limit: limit, now: now)
        return Self.format(hits, calendar: calendar)
    }

    static func format(_ hits: [MemoryHit], calendar: Calendar = .current) -> String {
        guard !hits.isEmpty else { return "" }
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"
        var lines = ["[SCREEN_MEMORY]"]
        for h in hits {
            var head = "- \(f.string(from: h.timestamp)) · \(h.appName)"
            if let t = h.windowTitle, !t.isEmpty { head += " · \(t)" }
            if let u = h.url, !u.isEmpty { head += " · \(u)" }
            lines.append(head)
            if !h.snippet.isEmpty { lines.append("  \(h.snippet.prefix(400))") }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Conversion

    static func memoryHit(from h: MemoryStore.Hit) -> MemoryHit {
        MemoryHit(id: h.source == .session ? -h.id : h.id,
                  timestamp: h.timestamp, appName: h.appName, bundleID: h.bundleID,
                  windowTitle: h.windowTitle, url: h.url, snippet: h.snippet,
                  thumbnailPath: h.thumbnailPath, score: h.score)
    }

    static func memoryHit(from s: SessionRecord, thumbnail: String?, now: Date) -> MemoryHit {
        let snippet = s.summary.isEmpty ? s.title : VaultWriter.oneLine(s.summary, max: 240)
        let ageDays = max(0, now.timeIntervalSince(s.end)) / 86_400
        return MemoryHit(id: -s.id, timestamp: s.start, appName: s.appName, bundleID: s.bundleID,
                         windowTitle: s.title, url: s.url, snippet: snippet, thumbnailPath: thumbnail,
                         score: (1 + s.importance) * exp(-ageDays / 7))
    }

    // MARK: Time parsing

    /// Pulls a relative time expression out of the query ("yesterday", "this
    /// morning", "last week", "3 days ago", "on tuesday") and returns the
    /// window plus the query with those words removed.
    static func parseTimeWindow(_ query: String, now: Date, calendar: Calendar) -> (DateInterval?, String) {
        // Punctuation-insensitive: "yesterday?" must still match.
        let normalized = query.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        var q = " " + String(normalized) + " "
        var window: DateInterval?
        let day: TimeInterval = 86_400
        let today = calendar.startOfDay(for: now)
        func strip(_ phrase: String) { q = q.replacingOccurrences(of: " \(phrase) ", with: " ") }
        func dayInterval(_ start: Date) -> DateInterval { DateInterval(start: start, duration: day) }

        let phrases: [(String, () -> DateInterval)] = [
            ("day before yesterday", { dayInterval(today.addingTimeInterval(-2 * day)) }),
            ("yesterday morning", { DateInterval(start: today.addingTimeInterval(-day + 5 * 3600), duration: 7 * 3600) }),
            ("yesterday afternoon", { DateInterval(start: today.addingTimeInterval(-day + 12 * 3600), duration: 6 * 3600) }),
            ("yesterday evening", { DateInterval(start: today.addingTimeInterval(-day + 17 * 3600), duration: 7 * 3600) }),
            ("last night", { DateInterval(start: today.addingTimeInterval(-day + 18 * 3600), duration: 9 * 3600) }),
            ("yesterday", { dayInterval(today.addingTimeInterval(-day)) }),
            ("this morning", { DateInterval(start: today.addingTimeInterval(5 * 3600), end: max(now, today.addingTimeInterval(5 * 3600 + 1))) }),
            ("this afternoon", { DateInterval(start: today.addingTimeInterval(12 * 3600), end: max(now, today.addingTimeInterval(12 * 3600 + 1))) }),
            ("this evening", { DateInterval(start: today.addingTimeInterval(17 * 3600), end: max(now, today.addingTimeInterval(17 * 3600 + 1))) }),
            ("tonight", { DateInterval(start: today.addingTimeInterval(17 * 3600), end: max(now, today.addingTimeInterval(17 * 3600 + 1))) }),
            ("earlier today", { DateInterval(start: today, end: now) }),
            ("today", { DateInterval(start: today, end: now) }),
            ("last week", {
                let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)!
                return DateInterval(start: thisWeek.start.addingTimeInterval(-7 * day), end: thisWeek.start)
            }),
            ("this week", { DateInterval(start: calendar.dateInterval(of: .weekOfYear, for: now)!.start, end: now) }),
            ("last month", {
                let thisMonth = calendar.dateInterval(of: .month, for: now)!
                let prev = calendar.date(byAdding: .month, value: -1, to: thisMonth.start)!
                return DateInterval(start: prev, end: thisMonth.start)
            }),
            ("this month", { DateInterval(start: calendar.dateInterval(of: .month, for: now)!.start, end: now) }),
        ]
        for (phrase, make) in phrases where q.contains(" \(phrase) ") {
            window = make(); strip(phrase); break
        }

        if window == nil, let m = q.range(of: #" (\d{1,2}) days? ago "#, options: .regularExpression) {
            let n = Int(q[m].filter(\.isNumber)) ?? 1
            window = dayInterval(today.addingTimeInterval(-Double(n) * day))
            q.replaceSubrange(m, with: " ")
        }
        if window == nil, let m = q.range(of: #" (last|this|on)? ?(monday|tuesday|wednesday|thursday|friday|saturday|sunday) "#, options: .regularExpression) {
            let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
            if let name = names.first(where: { q[m].contains($0) }), let target = names.firstIndex(of: name) {
                let weekday = calendar.component(.weekday, from: now) - 1
                var back = (weekday - target + 7) % 7
                if back == 0 { back = 7 }
                window = dayInterval(today.addingTimeInterval(-Double(back) * day))
                q.replaceSubrange(m, with: " ")
            }
        }
        let cleaned = q.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (window, cleaned)
    }
}
