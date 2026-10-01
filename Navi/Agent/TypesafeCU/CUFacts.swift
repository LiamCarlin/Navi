import CoreGraphics
import Foundation

// Facts code decides so Jev does not have to (typesafe_computer_use/dates.py and the
// layout helpers of decide.py / perception.py). Jev does no calendar math, cannot tell
// which of three "Buy" buttons is which, and has no clock: all of that is computed here
// and handed over as state.

enum CUFacts {
    // MARK: Now

    static func nowContext(_ now: Date = Date(), timeZone: TimeZone = .current) -> [String: Any] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm EEEE"
        let d = DateFormatter()
        d.locale = f.locale; d.timeZone = timeZone; d.dateFormat = "yyyy-MM-dd"
        return ["local_time": f.string(from: now), "timezone": timeZone.abbreviation(for: now) ?? timeZone.identifier,
                "today": d.string(from: now)]
    }

    // MARK: Dates (dates.py)

    struct Day: Equatable, Comparable, Sendable {
        var year: Int, month: Int, day: Int
        var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
        static func < (a: Day, b: Day) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }
        var date: Date? {
            var c = DateComponents(); c.year = year; c.month = month; c.day = day
            return Calendar(identifier: .gregorian).date(from: c)
        }
        static func from(_ date: Date, calendar: Calendar = .current) -> Day {
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            return Day(year: c.year!, month: c.month!, day: c.day!)
        }
        func days(to other: Day) -> Int {
            guard let a = date, let b = other.date else { return 0 }
            return Calendar(identifier: .gregorian).dateComponents([.day], from: a, to: b).day ?? 0
        }
    }

    static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let monthPattern = "jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec"
    private static let dashes = "[-\\u2013\\u2014]"
    static let dateRE = try! NSRegularExpression(pattern:
        "\\b(?:(?<mon>\(monthPattern))[a-z]*\\.?\\s+(?<day>\\d{1,2})(?:\\s*\(dashes)\\s*\\d{1,2})?(?:,?\\s+(?<year>\\d{4}))?"
        + "|(?<day2>\\d{1,2})\\s+(?<mon2>\(monthPattern))[a-z]*\\.?(?:,?\\s+(?<year2>\\d{4}))?"
        + "|(?<iso>\\d{4}-\\d{2}-\\d{2})"
        + "|(?<m>\\d{1,2})/(?<d>\\d{1,2})/(?<y>\\d{4}))\\b", options: [.caseInsensitive])

    /// The first date mentioned in the text. A missing year is this year, or next year
    /// when this year's would be more than 60 days gone.
    static func firstDate(in text: String, today: Day) -> Day? {
        let ns = text as NSString
        guard let m = dateRE.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func g(_ name: String) -> String? {
            let r = m.range(withName: name)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        func valid(_ d: Day) -> Day? {
            guard (1...12).contains(d.month), let date = d.date, Day.from(date, calendar: Calendar(identifier: .gregorian)) == d else { return nil }
            return d
        }
        if let iso = g("iso") {
            let p = iso.split(separator: "-").compactMap { Int($0) }
            return p.count == 3 ? valid(Day(year: p[0], month: p[1], day: p[2])) : nil
        }
        if let mm = g("m"), let dd = g("d"), let yy = g("y"), let m = Int(mm), let d = Int(dd), let y = Int(yy) {
            return valid(Day(year: y, month: m, day: d))
        }
        guard let monText = g("mon") ?? g("mon2"), let month = months.firstIndex(of: String(monText.prefix(3)).lowercased()),
              let dayText = g("day") ?? g("day2"), let day = Int(dayText) else { return nil }
        if let y = g("year") ?? g("year2"), let year = Int(y) { return valid(Day(year: year, month: month + 1, day: day)) }
        guard var found = valid(Day(year: today.year, month: month + 1, day: day)) else { return nil }
        if found.days(to: today) > 60 { found.year += 1; return valid(found) }
        return found
    }

    static func describeOffset(_ d: Day, today: Day) -> String {
        let delta = today.days(to: d)
        if delta == 0 { return "\(d.iso) (today)" }
        return delta > 0 ? "\(d.iso) (in \(delta) days)" : "\(d.iso) (\(-delta) days ago)"
    }

    static let nearRowsPt: CGFloat = 60

    /// Item index → "dated …" for items containing a date, or "near a line dated …" for close
    /// neighbours. Menu-bar items take no part: the clock is a date, and it would date every
    /// control under it as "near a line dated today".
    static func dateHints(_ items: [CUItem], today: Day) -> [Int: String] {
        let items = items.filter { $0.role != "menu" }
        var dated: [Int: Day] = [:]
        for it in items { if let d = firstDate(in: it.text, today: today) { dated[it.index] = d } }
        var hints = dated.mapValues { "dated \(describeOffset($0, today: today))" }
        guard !dated.isEmpty else { return hints }
        let byIndex = Dictionary(uniqueKeysWithValues: items.map { ($0.index, $0) })
        for it in items where hints[it.index] == nil {
            let cy = it.center.y
            guard let nearest = dated.keys.min(by: { abs(byIndex[$0]!.center.y - cy) < abs(byIndex[$1]!.center.y - cy) }),
                  abs(byIndex[nearest]!.center.y - cy) < nearRowsPt else { continue }
            hints[it.index] = "near a line dated \(describeOffset(dated[nearest]!, today: today))"
        }
        return hints
    }

    // MARK: Layout (decide.py `row_mates`, models.py `Screen.region`)

    static let rowMatesInCriteria = 3

    /// Item index → the texts sharing its row, left to right, for every item whose text another
    /// item repeats. Three rows of events each end in a "Buy": the label says nothing about
    /// which, and the row does. `limit` keeps a criterion short; nil takes the whole row.
    static func rowMates(_ items: [CUItem], limit: Int? = rowMatesInCriteria) -> [Int: [String]] {
        var counts: [String: Int] = [:]
        for it in items { counts[it.text, default: 0] += 1 }
        var out: [Int: [String]] = [:]
        for it in items where (counts[it.text] ?? 0) >= 2 {
            let cy = it.center.y, half = max(1, it.box.height) / 2
            let mates = items.filter { $0.index != it.index && abs($0.center.y - cy) < half }.sorted { $0.box.minX < $1.box.minX }
            if !mates.isEmpty { out[it.index] = (limit.map { Array(mates.prefix($0)) } ?? mates).map(\.text) }
        }
        return out
    }

    /// A coarse cell for the item within `frame` (the window), clamped both ways: frames lie,
    /// and the cell is only ever a hint.
    static func region(_ item: CUItem, in frame: CGRect) -> String {
        guard frame.width > 0, frame.height > 0 else { return "middle-center" }
        let cx = item.center.x - frame.minX, cy = item.center.y - frame.minY
        let col = ["left", "center", "right"][max(0, min(2, Int(3 * cx / frame.width)))]
        let row = ["top", "middle", "bottom"][max(0, min(2, Int(3 * cy / frame.height)))]
        return "\(row)-\(col)"
    }

    /// Text of items within a radius of the focused field (models.py `Screen.near_field`).
    static func nearField(_ field: CUField?, items: [CUItem], radius: CGFloat = 160) -> [String] {
        guard let f = field?.frame else { return [] }
        return items.filter { abs($0.center.x - f.midX) < radius + f.width / 2 && abs($0.center.y - f.midY) < radius }.map(\.text)
    }

    // MARK: Goal echo (perception.py)

    static let echoChars = 24

    /// Substrings that identify a screen line as the command that launched this run (Navi's
    /// own panel, the overlay pill, a terminal the goal was typed into).
    static func goalEchoes(_ goal: String) -> Set<String> {
        let norm = goal.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return norm.count >= echoChars ? [String(norm.prefix(echoChars)), String(norm.suffix(echoChars))] : [norm]
    }

    static func isEcho(_ text: String, echoes: Set<String>) -> Bool {
        let norm = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return echoes.contains { !$0.isEmpty && norm.contains($0) }
    }

    /// A string as Python's repr would quote it, which is how the upstream criteria read ('Buy').
    static func quoted(_ s: String) -> String {
        s.contains("'") && !s.contains("\"") ? "\"\(s)\"" : "'\(s.replacingOccurrences(of: "'", with: "\\'"))'"
    }

    // MARK: Literal goals (Navi)

    /// "• Local" → "local", "Send…" → "send": a label without the marks apps and OCR put around it.
    static func plainLabel(_ s: String) -> String {
        let marks = CharacterSet(charactersIn: "•·◦‣▪︎▸▶︎►✓✔︎☑︎☐*>-–—…:").union(.whitespacesAndNewlines).union(.punctuationCharacters)
        return s.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: marks)
    }

    static let literalVerbs = ["click on the", "click on", "click the", "click", "tap on the", "tap on", "tap the", "tap", "press the", "press",
                               "hit the", "hit", "select the", "select", "choose the", "choose", "pick the", "pick", "toggle the", "toggle",
                               "check the", "uncheck the", "check", "uncheck"]
    static let literalSuffixes = [" button", " tab", " link", " option", " checkbox", " check box", " menu item", " item", " icon",
                                  " toggle", " switch", " please", " now", " for me"]
    static let notLabels: Set<String> = ["it", "that", "this", "them", "one", "the first one", "the second one", "the last one", "all",
                                         "everything", "something", "anything", "here", "there"]

    /// The label a one-action goal names — "click on interviewing", "select local", "press the
    /// send button" → "interviewing", "local", "send" — or nil for anything more: a second
    /// instruction, a value to change something to, a pronoun. One click on that label *is*
    /// the goal, so code can tell when it is done (Navi deviation, docs/TYPESAFE_CU.md).
    static func literalTarget(_ goal: String) -> String? {
        var g = VoiceDecider.normalizedGoal(goal).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = g.last, ".!".contains(last) { g.removeLast() }
        guard g.count <= 60, g.range(of: #"[,;?]|\b(and|then|to|into|from|with|if|until|after|before|so)\b"#, options: .regularExpression) == nil
        else { return nil }
        guard let verb = literalVerbs.first(where: { g.hasPrefix($0 + " ") }) else { return nil }
        var label = String(g.dropFirst(verb.count + 1)).trimmingCharacters(in: .whitespaces)
        var trimmed = true
        while trimmed {
            trimmed = false
            for s in literalSuffixes where label.hasSuffix(s) && label.count > s.count {
                label = String(label.dropLast(s.count)).trimmingCharacters(in: .whitespaces); trimmed = true
            }
        }
        if label.hasPrefix("on ") { label = String(label.dropFirst(3)) }
        label = plainLabel(label)
        guard !label.isEmpty, !notLabels.contains(label), label.split(separator: " ").count <= 5 else { return nil }
        if verb.hasPrefix("select") && label.hasPrefix("all") { return nil }
        return label
    }

    static func matchesLiteral(_ text: String, _ label: String) -> Bool { plainLabel(text) == label }

    /// The one item on screen the literal label names: copies in one row (a control and the OCR
    /// line over it) count once, the control preferred; two in different rows is ambiguous → nil.
    static func literalItem(_ label: String, in items: [CUItem]) -> CUItem? {
        let hits = items.filter { matchesLiteral($0.text, label) }
        guard let first = hits.first else { return nil }
        let oneRow = hits.allSatisfy { abs($0.center.y - first.center.y) <= max($0.box.height, first.box.height, 8) / 2 + 4 }
        guard oneRow else { return nil }
        return hits.first(where: \.fromAX) ?? first
    }
}
