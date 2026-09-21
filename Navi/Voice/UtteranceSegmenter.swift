import Foundation

/// Turns a growing live transcript into clauses Navi can act on, one at a time.
///
/// The recognizer hands us the whole utterance so far ("open up the notes app
/// and make hello the title of the note"); the user never stops talking to
/// mark where one instruction ends and the next begins. This type keeps a
/// cursor (`dispatched`) into the word stream and proposes the next *clause*:
/// the words after the cursor up to the first boundary (a connector such as
/// "and"/"then" or sentence punctuation), plus whatever follows the boundary.
/// Jev decides whether the head really is a complete instruction; the session
/// then `commit`s it (advance the cursor, act), `drop`s it (advance, ignore) or
/// `acceptContinuation`s it (the boundary was false — "search for cats *and*
/// dogs" — so that split is never proposed again).
///
/// Pure value type; no timing and no network. Fully unit-tested.
struct UtteranceSegmenter: Equatable {
    /// One proposed instruction.
    struct Clause: Equatable {
        /// The candidate instruction (fillers stripped, trailing punctuation removed).
        var head: String
        /// Words after the boundary, if any ("" when the head is everything so far).
        var following: String
        /// The connector between head and following ("and", "then", "," …); "" when none.
        var connector: String
        /// Absolute word indexes: the head starts here (after skipped fillers)…
        var start: Int
        /// …and ends before this index (exclusive).
        var end: Int
        /// Index just past the connector — where `following` starts. Equals `end` without a connector.
        var resume: Int
        /// True when a boundary split head from following.
        var hasBoundary: Bool { resume > end || !connector.isEmpty }
        var headWordCount: Int { end - start }
    }

    private(set) var words: [String] = []
    /// Words before this index have been acted on or discarded.
    private(set) var dispatched = 0
    /// Absolute indexes where Jev said "this connector does not end the clause".
    private var ignoredBoundaries: Set<Int> = []
    /// The last few words before the cursor, so the cursor can be re-found
    /// when the recognizer revises earlier words (see `realign`).
    private var anchor: [String] = []
    /// Heads that were committed (most recent last), for Jev's context.
    private(set) var history: [String] = []
    /// The pending text as of the last `update`, to detect changes.
    private var lastPendingText = ""
    /// When the pending text last changed.
    private(set) var lastChangeAt = Date.distantPast

    static let maxHistory = 6

    // MARK: Vocabulary

    /// Words that begin a new instruction. Two-word connectors are matched first.
    static let connectors: [[String]] = [
        ["and", "then"], ["after", "that"], ["and", "also"], ["and", "now"],
        ["and"], ["then"], ["next"], ["afterwards"], ["also"], ["plus"],
    ]
    /// How the recognizer tends to spell the wake word.
    static let wakeWords: Set<String> = ["navi", "navy", "nabi", "naby", "novi", "noavi", "navvy", "nav"]
    /// Ignored at the start of a clause (and never a head on their own).
    static let leadingFillers: Set<String> = wakeWords.union([
        "um", "uh", "hmm", "mm", "so", "okay", "ok", "alright", "well", "hey", "please",
        "and", "then", "also", "now", "yeah", "just",
    ])
    /// Dropped from the end of a head before it becomes a task.
    static let trailingFillers: Set<String> = wakeWords.union(["please", "now", "okay", "ok", "thanks", "thank"])
    static let sentenceEnders: Set<Character> = [".", "?", "!", ";"]

    // MARK: Update

    /// Replaces the transcript. Returns true when the pending text changed.
    @discardableResult
    mutating func update(finalized: String, volatile: String = "", at now: Date = Date()) -> Bool {
        let joined = finalized.trimmingCharacters(in: .whitespaces) + " " + volatile.trimmingCharacters(in: .whitespaces)
        words = Self.tokenize(joined)
        realign()
        let pendingText = words[dispatched...].joined(separator: " ")
        guard pendingText != lastPendingText else { return false }
        lastPendingText = pendingText
        lastChangeAt = now
        return true
    }

    /// Volatile results are revised as the recognizer hears more: a word may
    /// split, merge or change, moving everything after it. The cursor is kept
    /// as a word count, so after each update it is re-found by matching the
    /// words that preceded it (nearest match within a few words); if they are
    /// gone it is clamped to the transcript.
    private mutating func realign() {
        guard dispatched > 0 else { return }
        let k = anchor.count
        if k > 0, words.count >= k {
            let lo = max(0, dispatched - k - 4), hi = min(words.count - k, dispatched + 4)
            if lo <= hi {
                var best: Int?
                for q in lo...hi where Array(words[q..<(q + k)].map(Self.core)) == anchor {
                    if best == nil || abs(q + k - dispatched) < abs(best! + k - dispatched) { best = q }
                }
                if let best { dispatched = best + k; return }
            }
        }
        if dispatched > words.count { dispatched = words.count }
    }

    /// Splits a transcript into words. The recognizer sometimes finalizes a
    /// stretch of audio as punctuation alone ("....." or ", ." after a flush);
    /// those marks are glued onto the word before them so they keep their
    /// meaning as a sentence end but never sit at the cursor as a "word" with
    /// nothing in it — that jammed the cursor for good.
    static func tokenize(_ text: String) -> [String] {
        var out: [String] = []
        for raw in text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            let w = String(raw)
            if core(w).isEmpty {
                guard let last = out.last else { continue }   // leading marks belong to nobody
                out[out.count - 1] = last + w
            } else {
                out.append(w)
            }
        }
        return out
    }

    /// Forgets everything (new session).
    mutating func reset() {
        words = []; dispatched = 0; ignoredBoundaries = []; anchor = []; history = []; lastPendingText = ""; lastChangeAt = .distantPast
    }

    /// The recognizer was restarted and its transcript begins again at zero:
    /// forget the old words and cursor but keep what was already carried out.
    mutating func restartTranscript() {
        words = []; dispatched = 0; ignoredBoundaries = []; anchor = []; lastPendingText = ""
    }

    /// Keeps only the last `keepLast` pending words (while paused, so the
    /// transcript doesn't pile up behind a "resume" that can't be seen).
    mutating func trimPending(keepLast: Int) {
        let excess = words.count - dispatched - keepLast
        if excess > 0 { advance(to: dispatched + excess) }
    }

    /// The last few words heard, cleaned (for control phrases while paused).
    func tailWords(_ n: Int) -> [String] {
        Array(words.suffix(n).map(Self.core)).filter { !$0.isEmpty }
    }

    // MARK: Pending clause

    /// The next clause to decide on, or nil when nothing actionable is pending.
    func pending() -> Clause? {
        var start = dispatched
        // Skip fillers, stray connectors and bare punctuation at the front.
        while start < words.count, Self.core(words[start]).isEmpty || Self.leadingFillers.contains(Self.core(words[start])) { start += 1 }
        guard start < words.count else { return nil }

        var end = words.count
        var resume = words.count
        var connector = ""
        var i = start
        scan: while i < words.count {
            // Sentence punctuation (or a comma) ends the clause after this word.
            if let last = words[i].last, Self.sentenceEnders.contains(last) || last == "," {
                let boundary = i + 1
                if !ignoredBoundaries.contains(boundary) {
                    end = boundary; resume = boundary; connector = String(last)
                    // "open notes, and make…": the connector after the mark belongs to the boundary too.
                    if let c = Self.connector(at: boundary, in: words) { resume = boundary + c.count; connector = c.joined(separator: " ") }
                    break scan
                }
            }
            if i > start, !ignoredBoundaries.contains(i), let c = Self.connector(at: i, in: words) {
                end = i; resume = i + c.count; connector = c.joined(separator: " "); break scan
            }
            i += 1
        }
        // Trailing fillers ("please", "now") belong to nobody.
        var headEnd = end
        while headEnd > start + 1, Self.trailingFillers.contains(Self.core(words[headEnd - 1])) { headEnd -= 1 }
        let head = Self.clean(words[start..<headEnd])
        guard !head.isEmpty else { return nil }
        let following = Self.clean(words[resume...])
        return Clause(head: head, following: following, connector: connector, start: start, end: end, resume: resume)
    }

    /// Everything after the cursor, as one string (for the UI).
    var pendingText: String { words[dispatched...].joined(separator: " ") }
    var isEmpty: Bool { dispatched >= words.count }

    // MARK: Decisions

    /// The head was acted on: move past it and its connector.
    mutating func commit(_ c: Clause) {
        advance(to: c.resume)
        history.append(c.head)
        if history.count > Self.maxHistory { history.removeFirst(history.count - Self.maxHistory) }
    }

    /// The head was not an instruction: move past it (and its connector).
    mutating func drop(_ c: Clause) { advance(to: c.resume) }

    /// The connector after the head does not end the instruction; never split there again.
    mutating func acceptContinuation(_ c: Clause) {
        guard c.hasBoundary else { return }
        ignoredBoundaries.insert(c.end)
    }

    /// Discards everything said so far that hasn't been acted on ("never mind").
    mutating func discardPending() { advance(to: words.count) }

    private mutating func advance(to index: Int) {
        dispatched = min(max(dispatched, index), words.count)
        anchor = Array(words[max(0, dispatched - 3)..<dispatched].map(Self.core))
        ignoredBoundaries = ignoredBoundaries.filter { $0 > dispatched }
        lastPendingText = words[dispatched...].joined(separator: " ")
    }

    // MARK: Text helpers

    /// Lower-cased word without surrounding punctuation ("And," → "and").
    static func core(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
    }

    /// The connector phrase starting at `index`, longest first, or nil.
    static func connector(at index: Int, in words: [String]) -> [String]? {
        for c in connectors where index + c.count <= words.count {
            if words[index..<(index + c.count)].map(core) == c { return c }
        }
        return nil
    }

    /// Joins words and strips a trailing sentence mark / comma.
    static func clean<S: Sequence>(_ words: S) -> String where S.Element == String {
        var s = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        while let last = s.last, sentenceEnders.contains(last) || last == "," { s.removeLast() }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
