import Foundation

/// The user's own words — the apps and sites they use, the people they talk to,
/// their projects and documents — for a recognizer that has never heard them.
///
/// Live (2026-10-29): "go to my most recent Canvas assignment" arrived as "to my
/// most recent *cannabis* assignment". Apple's recognizer knows English, not that
/// this user lives in Canvas. Two layers fix that generally, with no word map:
///   1. the session hands the recognizer these words as contextual strings, so it
///      leans towards them in the first place (`recognizerHints`);
///   2. what still comes through misheard is caught here: a word (or two) of HEAD
///      that *sounds like* one of the user's terms — a consonant-skeleton key with
///      near sounds (b/p/f/v, m/n, s/z, k/g…) costing little — is proposed, and Jev
///      confirms it in the same decision call (`misheard_i` noul) before the goal is
///      rewritten. Nothing is replaced on sound alone.
enum VoiceVocabulary {
    struct Term: Equatable, Sendable {
        var text: String
        /// How Jev reads it: "apps and sites", "people", "projects and documents".
        var kind: String
        var key: String

        init(_ text: String, kind: String) {
            self.text = text
            self.kind = kind
            self.key = VoiceVocabulary.phoneticKey(text)
        }
    }

    struct SoundAlike: Equatable, Sendable {
        /// The words as heard ("cannabis").
        var heard: String
        /// The user's term it sounds like ("Canvas").
        var meant: String
        var kind: String
    }

    /// Sound-alikes asked about per clause.
    static let maxAsked = 2
    /// P(misheard) at which the goal is rewritten.
    static let acceptP = 0.6
    /// Similarity of the sound keys needed to propose a term.
    static let minSimilarity = 0.8

    static let stopWords: Set<String> = [
        "the", "and", "then", "open", "close", "with", "from", "into", "that", "this", "what", "when", "where", "which",
        "there", "their", "them", "they", "your", "mine", "about", "please", "could", "would", "should", "make", "take",
        "send", "search", "find", "look", "show", "tell", "give", "have", "just", "like", "some", "most", "recent", "last",
        "first", "next", "back", "page", "file", "note", "notes", "new", "order", "click", "type", "write", "message", "text",
        "email", "call", "play", "song", "assignment", "class", "course", "document", "doc", "tab", "window", "app",
    ]

    /// Common verbs that are never one of the user's names.
    static let verbLike: Set<String> = ["continue", "resume", "finish", "start", "keep", "pick", "bring", "pull", "help", "make", "let", "want", "need"]

    // MARK: Proposals

    /// Words of `head` (one, or two read as one: "on shape" → Onshape) that sound like one of
    /// `terms` without being it, best first, at most `maxAsked`.
    static func soundAlikes(in head: String, terms: [Term]) -> [SoundAlike] {
        let words = head.split(whereSeparator: { $0.isWhitespace }).map { String($0).trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
        guard !words.isEmpty, !terms.isEmpty else { return [] }
        let lowerHead = " " + words.joined(separator: " ").lowercased() + " "
        // A term already said outright needs no help.
        let said = Set(terms.filter { lowerHead.contains(" " + $0.text.lowercased() + " ") }.map(\.text))
        var found: [(SoundAlike, Double)] = []
        for n in [2, 1] where words.count >= n {
            for i in 0...(words.count - n) {
                let phrase = words[i..<(i + n)].joined(separator: " ")
                let lower = phrase.lowercased()
                let letters = lower.filter(\.isLetter)
                guard letters.count >= 4 else { continue }
                if n == 1, stopWords.contains(lower) { continue }
                // The instruction's own verb is not a name: "continue where I left off" once became
                // "content where I left off" (bench school-06). Nor is any verb Navi acts on.
                if i == 0 || words[i..<(i + n)].contains(where: { VoiceDecider.actionVerbs.contains($0.lowercased()) || verbLike.contains($0.lowercased()) }) { continue }
                if n == 2, words[i..<(i + n)].contains(where: { stopWords.contains($0.lowercased()) || $0.count < 2 }) { continue }
                let key = phoneticKey(phrase)
                guard key.count >= 3 else { continue }
                var best: (Term, Double)?
                for t in terms where !said.contains(t.text) && t.text.lowercased() != lower {
                    // Two heard words are only ever one term word ("on shape"); one heard word one term word.
                    guard !t.text.contains(" ") else { continue }
                    let sim = similarity(key, t.key)
                    if sim >= minSimilarity, sim > (best?.1 ?? 0) { best = (t, sim) }
                }
                if let (t, sim) = best, !found.contains(where: { $0.0.heard.lowercased().contains(lower) || lower.contains($0.0.heard.lowercased()) }) {
                    found.append((SoundAlike(heard: phrase, meant: t.text, kind: t.kind), sim))
                }
            }
        }
        return found.sorted { $0.1 > $1.1 }.prefix(maxAsked).map(\.0)
    }

    /// `head` with each confirmed sound-alike replaced by the term (whole words, any case).
    static func apply(_ fixes: [SoundAlike], to head: String) -> String {
        var out = head
        for f in fixes {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: f.heard) + "\\b"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: f.meant))
        }
        return out
    }

    // MARK: Sound keys

    /// A consonant skeleton: letters only, spelling folded to sound (ph → f, ck → k, c → k/s,
    /// q → k, x → ks, z → s, silent h), vowels dropped after the first letter, doubles collapsed.
    /// "Canvas" → "knfs", "cannabis" → "knps".
    static func phoneticKey(_ s: String) -> String {
        let t = s.lowercased().filter(\.isLetter)
        guard !t.isEmpty else { return "" }
        var w = t
        for (a, b) in [("ph", "f"), ("ck", "k"), ("qu", "kw"), ("wh", "w"), ("gh", "g"), ("sch", "sk"), ("tch", "ch"), ("dg", "j")] {
            w = w.replacingOccurrences(of: a, with: b)
        }
        let chars = Array(w)
        var out: [Character] = []
        for (i, c) in chars.enumerated() {
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            var m: Character
            switch c {
            case "c": m = (next == "e" || next == "i" || next == "y") ? "s" : "k"
            case "q": m = "k"
            case "x": out.append("k"); m = "s"
            case "z": m = "s"
            case "v": m = "f"
            case "h": if i == 0 { m = "h" } else { continue }
            case "w", "y": if i == 0 { m = c } else { continue }
            case "a", "e", "i", "o", "u": if i == 0 { m = "a" } else { continue }
            default: m = c
            }
            if out.last != m { out.append(m) }
        }
        return String(out)
    }

    /// Sounds that are easy to confuse cost less than unrelated ones.
    static let nearGroups: [Set<Character>] = [["p", "b", "f"], ["m", "n"], ["s", "j", "c"], ["k", "g"], ["t", "d"], ["l", "r"]]

    static func substitutionCost(_ a: Character, _ b: Character) -> Double {
        if a == b { return 0 }
        return nearGroups.contains { $0.contains(a) && $0.contains(b) } ? 0.3 : 1
    }

    /// 1 − weighted edit distance / longer length; the first sound must be the same or near.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard let fx = x.first, let fy = y.first, substitutionCost(fx, fy) < 1 else { return 0 }
        var d = Array(repeating: Array(repeating: 0.0, count: y.count + 1), count: x.count + 1)
        for i in 0...x.count { d[i][0] = Double(i) }
        for j in 0...y.count { d[0][j] = Double(j) }
        if !x.isEmpty, !y.isEmpty {
            for i in 1...x.count {
                for j in 1...y.count {
                    d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + substitutionCost(x[i - 1], y[j - 1]))
                }
            }
        }
        return 1 - d[x.count][y.count] / Double(max(x.count, y.count))
    }

    // MARK: The user's terms

    /// Terms from what Navi knows about this user: the web apps and apps it has playbooks for,
    /// installed apps, and the people, projects and documents in screen memory.
    static func terms(skills: [AppSkill], appNames: [String], things: [UserKnowledge.Thing]) -> [Term] {
        var seen = Set<String>()
        var out: [Term] = []
        func add(_ text: String, _ kind: String) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 4, t.count <= 40, seen.insert(t.lowercased()).inserted else { return }
            out.append(Term(t, kind: kind))
        }
        for t in things {
            switch t.type {
            case "person": t.name.split(separator: " ").forEach { add(String($0), "people") }
            default: add(t.name, "projects and documents"); t.tokens.filter { $0.count >= 5 && !$0.contains(where: \.isNumber) }.forEach { add($0, "projects and documents") }
            }
            for p in t.places where p.isWeb { if let label = p.key.split(separator: ".").first { add(String(label).capitalized, "apps and sites") } }
        }
        for s in skills { add(s.name, "apps and sites"); s.aliases.forEach { add($0, "apps and sites") } }
        for n in appNames { add(n, "apps and sites") }
        return out
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cached: (terms: [Term], at: Date)?

    /// The live term list (screen memory read at most every 10 minutes).
    @MainActor
    static func liveTerms() -> [Term] {
        cacheLock.lock()
        if let c = cached, Date().timeIntervalSince(c.at) < 600 { cacheLock.unlock(); return c.terms }
        cacheLock.unlock()
        let things = UserKnowledge.current.map { Array($0.things().prefix(150)) } ?? []
        let t = terms(skills: AppSkills.all, appNames: AppIndex.shared.entries.prefix(300).map(\.name), things: things)
        cacheLock.lock(); cached = (t, Date()); cacheLock.unlock()
        return t
    }

    /// Contextual strings for the recognizer: the user's people, projects and sites first.
    @MainActor
    static func recognizerHints(limit: Int = 150) -> [String] {
        let t = liveTerms()
        let mine = t.filter { $0.kind != "apps and sites" }.map(\.text)
        let sites = t.filter { $0.kind == "apps and sites" }.map(\.text)
        return Array((mine + sites).prefix(limit))
    }
}
