import Foundation

/// The second echo layer: words the Mac itself just said are not instructions.
///
/// Echo cancellation (`SpeechListener.echoCancellation`) subtracts what the
/// speakers play from the microphone, but a loud video can still leak through.
/// So Navi also transcribes the Mac's own audio (`SpeechListener` with
/// `capturesSystemAudio`) and keeps the last few seconds of those words here.
/// Before a clause is decided, runs of its words that the Mac said too are
/// cut out; a clause that is mostly the Mac's words is dropped.
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
    /// A clause at least this much echo is dropped whole.
    static let dropFraction = 0.7
    /// While the Mac has said something this recently, it is "talking".
    static let activeSeconds: TimeInterval = 3

    enum Verdict: Equatable {
        /// Nothing the Mac said: decide as usual.
        case clean
        /// The clause is the Mac's audio: drop it.
        case echo
        /// The user's words with the Mac's cut out.
        case trimmed(String)
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
        let tokens = head.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let cores = tokens.map(UtteranceSegmenter.core)
        let mask = Self.echoedMask(cores, in: echo)
        let echoed = mask.filter { $0 }.count
        guard echoed > 0 else { return .clean }
        let kept = zip(tokens, mask).filter { !$0.1 }.map(\.0)
        let meaningful = kept.map(UtteranceSegmenter.core).filter { !$0.isEmpty && !Self.fillers.contains($0) }
        if meaningful.isEmpty || Double(echoed) / Double(max(1, cores.count)) >= Self.dropFraction { return .echo }
        return .trimmed(UtteranceSegmenter.clean(kept))
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

    /// Words that don't make what is left of a clause an instruction.
    static let fillers: Set<String> = VoiceDecider.fragmentWords.union(UtteranceSegmenter.leadingFillers)
}
