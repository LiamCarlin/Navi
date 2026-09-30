import Foundation

/// The second echo layer: words the Mac itself just said are not instructions.
///
/// Echo cancellation (`SpeechListener.echoCancellation`) subtracts what the
/// speakers play from the microphone, but a loud video can still leak through.
/// So Navi also transcribes the Mac's own audio (`SpeechListener` with
/// `capturesSystemAudio`) and keeps the last few seconds of those words here.
/// Before a clause is decided, a clause containing a run of words the Mac
/// said too is dropped — whole: the words around the run are almost always
/// the Mac's as well, just misheard or not transcribed yet (a live test kept
/// "today we are talking about what the tallest" and ran it as a task).
///
/// Only runs of `minRun`+ consecutive words count (with one misheard word
/// allowed inside a run): the two recognizers hear different audio — one
/// clean, one through the room — and a single shared word ("open", "the") is
/// no evidence of anything.
///
/// Pure value type, fully unit-tested; `VoiceSession` owns timing.
struct EchoFilter: Equatable {
    /// Seconds the Mac's words are remembered.
    static let windowSeconds: TimeInterval = 10
    /// Consecutive shared words that make a run echo.
    static let minRun = 3
    /// While the Mac has said something this recently, it is "talking".
    static let activeSeconds: TimeInterval = 3
    /// A short clause this soon after a dropped echo clause is its tail.
    static let trailingSeconds: TimeInterval = 2.5
    static let trailingMaxWords = 2

    enum Verdict: Equatable {
        /// Nothing the Mac said: decide as usual.
        case clean
        /// The clause is the Mac's audio: drop it.
        case echo
    }

    private var finals: [(core: String, at: Date)] = []
    private var volatile: [String] = []
    private var lastFinalized = ""
    /// When the Mac's transcript last changed.
    private(set) var lastUpdateAt = Date.distantPast

    static func == (a: EchoFilter, b: EchoFilter) -> Bool {
        a.finals.map(\.core) == b.finals.map(\.core) && a.volatile == b.volatile && a.lastUpdateAt == b.lastUpdateAt
    }

    // MARK: Update

    /// Takes the Mac-audio recognizer's transcript (finalized is append-only,
    /// volatile is the tail it may still revise).
    mutating func update(finalized: String, volatile newVolatile: String, at now: Date = Date()) {
        if finalized != lastFinalized {
            if finalized.hasPrefix(lastFinalized) {
                let added = Self.cores(String(finalized.dropFirst(lastFinalized.count)))
                finals.append(contentsOf: added.map { ($0, now) })
            }
            // Otherwise the listener trimmed its history: the new words are lost, nothing else is.
            lastFinalized = finalized
        }
        volatile = Self.cores(newVolatile)
        lastUpdateAt = now
        prune(now)
    }

    mutating func reset() { finals = []; volatile = []; lastFinalized = ""; lastUpdateAt = .distantPast }

    private mutating func prune(_ now: Date) {
        finals.removeAll { now.timeIntervalSince($0.at) > Self.windowSeconds }
    }

    /// The Mac has said something in the last few seconds.
    func isActive(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastUpdateAt) <= Self.activeSeconds && !(finals.isEmpty && volatile.isEmpty)
    }

    /// The Mac's recent words, oldest first.
    func recentWords(at now: Date = Date()) -> [String] {
        finals.filter { now.timeIntervalSince($0.at) <= Self.windowSeconds }.map(\.core) + volatile
    }

    // MARK: Classify

    func classify(_ head: String, at now: Date = Date()) -> Verdict {
        let echo = recentWords(at: now)
        guard !echo.isEmpty else { return .clean }
        let cores = Self.cores(head)
        return Self.echoedMask(cores, in: echo).contains(true) ? .echo : .clean
    }

    /// The last word or two of what the Mac was saying, split off after a
    /// connector — "…make sure to like | and subscribe": the recognizer heard
    /// "liken. be", so nothing matches, but it came straight after a dropped
    /// echo clause while the Mac was still talking. Control words ("stop",
    /// "wait") are always the user's.
    static func isTrailingEcho(_ head: String, secondsSinceEchoDrop: TimeInterval, macTalking: Bool) -> Bool {
        guard macTalking, secondsSinceEchoDrop <= trailingSeconds else { return false }
        let words = cores(head)
        guard !words.isEmpty, words.count <= trailingMaxWords else { return false }
        return VoiceDecider.heuristicControl(words.joined(separator: " ")) == nil
    }

    /// Which head words belong to a run the Mac also said. A two- or
    /// three-word head counts when all of it appears in order; a single word
    /// never does ("stop" is the user's even if the video just said it).
    static func echoedMask(_ head: [String], in echo: [String]) -> [Bool] {
        var mask = Array(repeating: false, count: head.count)
        guard head.count >= 2, !echo.isEmpty else { return mask }
        let need = min(minRun, head.count)
        for i in head.indices where !head[i].isEmpty {
            for j in echo.indices where sameWord(head[i], echo[j]) {
                // Extend the run; one mismatch may sit inside it, never at its end.
                var k = 0, matched = 0, misses = 0, lastMatch = -1
                while i + k < head.count, j + k < echo.count {
                    if sameWord(head[i + k], echo[j + k]) { matched += 1; lastMatch = k }
                    else if misses == 0, matched >= 2 { misses = 1 }
                    else { break }
                    k += 1
                }
                if matched >= need { for m in i...(i + lastMatch) { mask[m] = true } }
            }
        }
        return mask
    }

    /// Same word, allowing the small spelling drift of two recognizers
    /// ("colour"/"color", "videos"/"video").
    static func sameWord(_ a: String, _ b: String) -> Bool {
        if a == b { return !a.isEmpty }
        guard a.count >= 4, b.count >= 4 else { return false }
        if a.hasPrefix(b) || b.hasPrefix(a) { return abs(a.count - b.count) <= 2 }
        return editDistance(a, b) <= 1
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > 1 { return 2 }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[y.count]
    }

    static func cores(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map { UtteranceSegmenter.core(String($0)) }.filter { !$0.isEmpty }
    }
}
