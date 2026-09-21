import Foundation

/// Zero-latency app candidates for a spoken clause ("open up the notes app",
/// "switch to chrome"), so Jev can pick one and Navi can launch it without any
/// text model in the loop.
///
/// Speech has no capital letters or quotes and comes wrapped in filler ("open
/// up the", "can you", "app"), so every 1–3-word window of the clause, minus
/// fillers, is scored against the installed-app index with the same fuzzy
/// matcher the panel uses. Pure given an `AppIndex`; unit-tested with a fake one.
enum VoiceAppMatcher {
    struct Candidate: Equatable, Sendable {
        var id: String          // "a1", "a2", … (Jev choice ids)
        var entry: AppEntry
        var score: Double
        var phrase: String      // the words that matched
    }

    static let maxCandidates = 5
    static let minScore = 0.8
    /// Words that never name an app.
    static let stopWords: Set<String> = [
        "open", "up", "the", "a", "an", "my", "app", "application", "please", "can", "could", "you", "would", "navi",
        "launch", "start", "switch", "to", "go", "into", "in", "on", "bring", "show", "me", "get", "let's", "lets",
        "quickly", "now", "then", "and", "also", "just", "again", "back", "over", "window", "program", "for", "it",
        "search", "type", "make", "write", "click", "new", "create", "send", "text", "email", "message", "note", "notes",
    ]
    /// Words that are apps *and* common words: only accepted after an opening verb.
    static let ambiguousNames: Set<String> = ["notes", "mail", "messages", "music", "photos", "calendar", "maps",
                                              "contacts", "reminders", "books", "news", "home", "clock", "weather",
                                              "stocks", "terminal", "finder", "preview", "pages", "numbers", "keynote"]
    static let openingVerbs: Set<String> = ["open", "launch", "start", "switch", "go", "bring", "show", "in", "into", "use"]

    /// The words of a clause that could be an app name ("open the foo app" → "foo").
    static func nameGuess(in text: String) -> String? {
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "'" })
            .map(String.init)
            .filter { !stopWords.contains($0) || ambiguousNames.contains($0) }
        let guess = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return guess.isEmpty ? nil : guess
    }

    static func candidates(in text: String, index: AppIndex, running: Set<String> = []) -> [Candidate] {
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "'" })
            .map(String.init)
        guard !words.isEmpty else { return [] }
        let hasOpeningVerb = words.contains { openingVerbs.contains($0) }
        var best: [String: (AppEntry, Double, String)] = [:]   // app key → best match
        for n in stride(from: min(3, words.count), through: 1, by: -1) {
            for i in 0...(words.count - n) {
                let window = Array(words[i..<(i + n)])
                // A window made only of stop words can't be an app name.
                let meaningful = window.filter { !stopWords.contains($0) || (ambiguousNames.contains($0) && hasOpeningVerb) }
                guard !meaningful.isEmpty else { continue }
                let phrase = meaningful.joined(separator: " ")
                var matches = index.search(phrase, limit: 3, running: running)
                // Volatile speech text sometimes glues a fragment onto a word
                // ("calculatorcul"): a word that *starts with* a full app name still names it.
                if n == 1, matches.isEmpty, phrase.count >= 6 {
                    matches = index.entries.filter { $0.lowerName.count >= 5 && phrase.hasPrefix($0.lowerName) }
                        .map { AppMatch(entry: $0, score: 0.85) }
                }
                for m in matches where m.score >= minScore {
                    // Single common words ("notes", "mail") need an opening verb to count.
                    if n == 1 || meaningful.count == 1, ambiguousNames.contains(phrase), !hasOpeningVerb { continue }
                    // Prefer the longer, more specific phrase for the same app.
                    let score = m.score + Double(meaningful.count) * 0.01
                    if let cur = best[m.entry.key], cur.1 >= score { continue }
                    best[m.entry.key] = (m.entry, score, phrase)
                }
            }
        }
        return best.values
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name < $1.0.name }
            .prefix(maxCandidates)
            .enumerated()
            .map { i, v in Candidate(id: "a\(i + 1)", entry: v.0, score: min(1, v.1), phrase: v.2) }
    }
}
