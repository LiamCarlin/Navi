import Foundation

/// A string Jev can pick (or the executor can use without an LLM), with where it came from.
struct TextCandidate: Equatable, Sendable {
    let id: String        // "t1", "t2", …
    let text: String
    let source: String    // "quoted", "verb", "segment", "url", "app", "email", "number", "clipboard", "window", "domain"
}

/// Zero-latency extraction of strings from the task and its context. Jev cannot
/// generate text, so the Jev-first driver uses these for OPEN_APP / OPEN_URL
/// targets and as a pre-check that skips the text helper when the task
/// contains exactly one obvious quoted string.
enum TextCandidates {
    static let cap = 20

    static func extract(task: String, clipboard: String? = nil, windowTitle: String? = nil,
                        url: String? = nil, focusedValue: String? = nil) -> [TextCandidate] {
        var out: [(String, String)] = []
        func add(_ text: String, _ source: String) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            guard !t.isEmpty, t.count <= 300 else { return }
            if out.contains(where: { $0.0 == t }) { return }
            out.append((t, source))
        }

        for q in quotedStrings(in: task) { add(q, "quoted") }
        for v in verbPhrases(in: task) { add(v, "verb") }
        for u in urls(in: task) { add(u, "url") }
        for a in appNames(in: task) { add(a, "app") }
        for e in matches(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z0-9.-]+"#, in: task) { add(e, "email") }
        for n in matches(#"(?<![\w.])\d[\d,.]*(?![\w.])"#, in: task) { add(n, "number") }
        for s in segments(in: task) { add(s, "segment") }
        for u in urls(in: task) {
            if let d = domain(of: u), d != u { add(d, "domain") }
        }
        if let c = clipboard?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty, c.count <= 2000 {
            add(String(c.prefix(300)), "clipboard")
        }
        if let w = windowTitle, !w.isEmpty { add(w, "window") }
        if let url, !url.isEmpty { add(url, "url") }
        if let f = focusedValue, !f.isEmpty { add(f, "focused") }

        return out.prefix(cap).enumerated().map { i, p in TextCandidate(id: "t\(i + 1)", text: p.0, source: p.1) }
    }

    /// The single quoted string in the task, when there is exactly one — the
    /// only case where typing needs no LLM.
    static func obviousText(in task: String) -> String? {
        let q = quotedStrings(in: task).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return q.count == 1 ? q[0] : nil
    }

    // MARK: Pieces

    static func quotedStrings(in s: String) -> [String] {
        var out: [String] = []
        out += matches(#""([^"\n]{1,200})""#, in: s, group: 1)
        out += matches(#"“([^”\n]{1,200})”"#, in: s, group: 1)
        out += matches(#"‘([^’\n]{1,200})’"#, in: s, group: 1)
        out += matches(#"(?<![A-Za-z0-9])'([^'\n]{1,200})'(?![A-Za-z0-9])"#, in: s, group: 1)
        return out
    }

    static let verbs = "search for|search|google|look up|type|enter|write|paste|name it|titled|called|rename to|reply with|say|send"
    static let stops = #"(?=\s*(?:,|\.|;|\band\b|\bthen\b|\binto\b|\bin\b|\bon\b|\bfor\b|\bat\b|\bto\b|$))"#

    static func verbPhrases(in s: String) -> [String] {
        matches(#"(?i)\b(?:"# + verbs + #")\s+(.+?)"# + stops, in: s, group: 1)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’ ")) }
            .filter { !$0.isEmpty }
    }

    static func urls(in s: String) -> [String] {
        matches(#"(?i)\b(?:https?://)?(?:[a-z0-9-]+\.)+(?:com|org|net|io|ai|dev|app|co|edu|gov|me|sh|xyz|uk|de|fr|jp|ca|us|info|tv)\b(?:/[^\s,;"'”’]*)?"#, in: s)
    }

    static func domain(of url: String) -> String? {
        var s = url
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        return s.isEmpty ? nil : s
    }

    static func appNames(in s: String) -> [String] {
        matches(#"(?i)\b(?:open|launch|switch to|go to|start|in)\s+(?:the\s+)?([A-Za-z][A-Za-z0-9 .+-]{1,30}?)"# + stops, in: s, group: 1)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("http") && !$0.contains("/") }
    }

    static func segments(in s: String) -> [String] {
        let parts = s.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .flatMap { $0.components(separatedBy: " and ") }
            .flatMap { $0.components(separatedBy: " then ") }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 2 && $0.count <= 80 }
    }

    static func matches(_ pattern: String, in s: String, group: Int = 0) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard group < m.numberOfRanges, m.range(at: group).location != NSNotFound else { return nil }
            return ns.substring(with: m.range(at: group))
        }
    }
}

// MARK: - Field text, locally

/// What the native driver can say about a field without a model. The writer (`CUWriter`)
/// composes field text; these two only pick the field it starts on while Jev decides, and
/// type what the goal spells out when no writer is configured.
enum FieldText {
    /// The one field a TYPE_TEXT step would obviously target, if the screen has
    /// exactly one: the focused empty text field, else the only empty text field.
    /// Secure fields never qualify. Drives the speculative helper call that runs
    /// in parallel with Jev's decision; nil ⇒ don't speculate.
    static func obviousField(in snapshot: AXSnapshot) -> AXElement? {
        let empty = snapshot.elements.filter { e in
            e.isTextInput && !e.isSecure && (e.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let focused = empty.filter(\.isFocused)
        if focused.count == 1 { return focused[0] }
        return empty.count == 1 ? empty[0] : nil
    }

    /// What the goal itself says to type, when it spells it out — no model
    /// needed and nothing to invent: "type good night in the message box" →
    /// "good night", "look up Matt Armstrong" into a search field → "Matt
    /// Armstrong", "tell her I'm running late" → "I'm running late". nil when
    /// the goal only *describes* the text ("write a love message"), when the
    /// phrase was already typed, or when nothing in the goal reads as literal text.
    static func localGuess(goal: String, field: AXElement, typed alreadyTyped: [String] = []) -> String? {
        let typed = Set(alreadyTyped.map { $0.lowercased() })
        func fresh(_ t: String) -> String? {
            let v = t.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".,;:!?")))
            guard v.count >= 1, !typed.contains(v.lowercased()) else { return nil }
            // "write a love message", "type the address": a description, not the text.
            let first = v.lowercased().split(separator: " ").first.map(String.init) ?? ""
            if ["a", "an", "the", "some", "my", "your", "his", "her", "their", "this", "that", "it", "something"].contains(first) { return nil }
            return v
        }
        if let q = TextCandidates.obviousText(in: goal), let v = fresh(q) { return v }
        // "tell mom I'm late", "text her good night", "reply thanks", "message Sam see you at 5".
        let addressed = TextCandidates.matches(#"(?i)\b(?:tell|text|message|reply(?: to)?|respond(?: to)?|answer|dm|say to|ask)\s+(?:[A-Z][\w']*|mom|mum|dad|her|him|them|me|us|everyone|the group|my \w+)\s*(?:that|to say|saying|:|,)?\s+(.+)$"#,
                                              in: goal, group: 1)
        for a in addressed { if let v = fresh(a) { return v } }
        for phrase in TextCandidates.verbPhrases(in: goal) { if let v = fresh(phrase) { return v } }
        // A search / address / query field with a lookup goal: the query is the goal minus its launcher words.
        let hint = (field.label + " " + field.role + " " + (field.path)).lowercased()
        let searchy = ["search", "query", "find", "address", "url", "omnibox", "look up", "ask", "prompt", "message"].contains { hint.contains($0) }
        if searchy, AgentRun.isLookup(goal) || goal.lowercased().range(of: #"\b(search|look up|google|find|type|enter)\b"#, options: .regularExpression) != nil {
            let q = UltrafastBridge.searchQuery(for: goal)
            if q.lowercased() != goal.lowercased().trimmingCharacters(in: .whitespaces), let v = fresh(q) { return v }
        }
        return nil
    }
}
