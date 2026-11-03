import Foundation

/// What worked before, per app: the episodic half of the agent's knowledge
/// (`AppSkills` is the hand-written half). After a step completes, the goal
/// and the action labels that got there are stored; a later goal in the same
/// app that shares words with it gets those lines as `state.experience`, so
/// Jev starts from "last time this took ⌘N → type → Return" instead of
/// exploring. Mirrors Agent S's episodic memory (subtask → grounded actions,
/// successes only), kept deliberately small and local.
///
/// Runs that did not get there are kept too (`recordFailure`): the actions and a code-made
/// `lesson` (how it ended — never the writer's words), recalled as "✗ went wrong" so the next run
/// in that app does not walk into the same dead end. Detours (a click undone by Esc / Close, the
/// same click twice) are dropped before anything is stored (`condense`).
///
/// Privacy: only action labels are stored (element names, never typed text —
/// callers pass `AgentAction.human(in:text:nil)`), in the user's own
/// Application Support folder. Secure fields never reach the log.
final class AgentExperience: @unchecked Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var bundleID: String
        var appName: String?
        var goal: String
        var actions: [String]
        var at: Date
        /// nil or true: it got there. false: a run that stopped short (`lesson` says how).
        var worked: Bool?
        var lesson: String?

        var succeeded: Bool { worked ?? true }
    }

    static let shared = AgentExperience()

    static let maxEntries = 300
    static let maxActionsPerEntry = 12
    static let maxLabelLength = 60
    static let recallLimit = 3
    /// Minimum share of the goal's words an entry must share to be recalled —
    /// and at least two of them unless the goal is a single word, so "note"
    /// alone does not drag every Notes goal in.
    static let minOverlap = 0.34
    static let minSharedWords = 2
    /// Failures kept per app, and recalled per goal.
    static let maxFailuresPerApp = 20
    static let recallFailures = 1

    private let lock = NSLock()
    private let fileURL: URL?
    private var entries: [Entry]

    /// The app-wide store under Application Support. `fileURL: nil` keeps
    /// everything in memory (tests).
    init(fileURL: URL? = AgentExperience.defaultFileURL) {
        self.fileURL = fileURL
        self.entries = fileURL.flatMap { Self.load($0) } ?? []
    }

    static var defaultFileURL: URL {
        NaviSettings.dataDirectory.appendingPathComponent("agent-experience.json")
    }

    // MARK: Privacy hook (Settings → Privacy & Data)

    /// Forgets everything and deletes the file ("Delete everything Navi has stored").
    func removeAll() {
        lock.lock(); entries = []; lock.unlock()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    // MARK: Record / recall

    /// Stores a completed step. Replaces an earlier entry for the same app and
    /// (normalised) goal so the store keeps the latest way that worked.
    func record(bundleID: String?, appName: String?, goal: String, actions: [String], at: Date = Date()) {
        store(bundleID: bundleID, appName: appName, goal: goal, actions: actions, at: at, worked: true, lesson: nil)
    }

    /// Stores a run that stopped short: its actions and `lesson` (how it ended, from code). Replaces
    /// an earlier failure for the same app and goal; a later success for the goal keeps both.
    func recordFailure(bundleID: String?, appName: String?, goal: String, actions: [String], lesson: String, at: Date = Date()) {
        store(bundleID: bundleID, appName: appName, goal: goal, actions: actions, at: at, worked: false,
              lesson: String(lesson.prefix(Self.maxLabelLength * 2)))
    }

    private func store(bundleID: String?, appName: String?, goal: String, actions: [String], at: Date, worked: Bool, lesson: String?) {
        let actions = Self.condense(actions)
        guard let bundleID, !bundleID.isEmpty, !actions.isEmpty || !worked else { return }
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !g.isEmpty else { return }
        let entry = Entry(bundleID: bundleID, appName: appName, goal: String(g.prefix(200)),
                          actions: actions.suffix(Self.maxActionsPerEntry).map { String($0.prefix(Self.maxLabelLength)) }, at: at,
                          worked: worked ? nil : false, lesson: lesson)
        lock.lock()
        entries.removeAll { $0.bundleID == bundleID && $0.succeeded == worked && Self.words($0.goal) == Self.words(g) }
        entries.append(entry)
        if !worked {
            let failures = entries.indices.filter { entries[$0].bundleID == bundleID && !entries[$0].succeeded }
            if failures.count > Self.maxFailuresPerApp { entries.remove(at: failures[0]) }
        }
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
        let snapshot = entries
        lock.unlock()
        if let fileURL { Self.save(snapshot, to: fileURL) }
    }

    /// Up to `recallLimit` past runs in this app whose goals overlap `goal`, best match first, as
    /// "goal → action · action · …" lines — successes first, then at most `recallFailures` failure
    /// as "✗ goal → … — went wrong: lesson". Goals are compared by what they ask for, not the
    /// message they carry ("Send Dhvan Shah a text …: <a whole calendar>" is "send … text"), and by
    /// the shorter goal's words, so a long goal still finds the short one it is an instance of.
    func recall(bundleID: String?, goal: String, limit: Int = recallLimit) -> [String] {
        guard let bundleID, !bundleID.isEmpty else { return [] }
        lock.lock(); let all = entries; lock.unlock()
        let scored: [(Entry, Double)] = all.compactMap { e in
            guard e.bundleID == bundleID, let overlap = Self.overlap(goal, e.goal) else { return nil }
            return (e, overlap)
        }
        let ranked = scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.at > $1.0.at }.map(\.0)
        let worked = ranked.filter(\.succeeded).prefix(limit)
        let failed = ranked.filter { !$0.succeeded }.prefix(min(Self.recallFailures, max(0, limit - worked.count) + Self.recallFailures))
        return worked.map { "\($0.goal) → \($0.actions.joined(separator: " · "))" }
            + failed.map { e in
                let did = e.actions.isEmpty ? "" : " → " + e.actions.joined(separator: " · ")
                return "✗ \(e.goal)\(did) — went wrong: \(e.lesson ?? "it did not get there")"
            }
    }

    /// How much two goals ask for the same thing (0…1), nil below the bar: shared intent words over
    /// the shorter goal's, at least `minSharedWords` of them (one for a one-word goal).
    static func overlap(_ a: String, _ b: String) -> Double? {
        let wa = words(intent(of: a)), wb = words(intent(of: b))
        guard !wa.isEmpty, !wb.isEmpty else { return nil }
        let shared = wa.intersection(wb).count
        guard shared >= min(minSharedWords, wa.count, wb.count) else { return nil }
        let o = Double(shared) / Double(min(wa.count, wb.count))
        return o >= minOverlap ? o : nil
    }

    /// What a goal asks for, without the text it carries: cut at the message (": …", "saying …",
    /// "that says …", a quote).
    static func intent(of goal: String) -> String {
        var g = goal
        if let r = g.range(of: ":"), g.distance(from: g.startIndex, to: r.lowerBound) >= 8 { g = String(g[..<r.lowerBound]) }
        for marker in [" saying ", " that says ", " which says ", " with the message ", " with the text ", "\"", "“", "‘"] {
            if let r = g.range(of: marker, options: .caseInsensitive), g.distance(from: g.startIndex, to: r.lowerBound) >= 8 {
                g = String(g[..<r.lowerBound])
            }
        }
        return g
    }

    /// The actions that did it, without detours: a step undone right after (Esc, Close, Cancel,
    /// Back) goes with its undo, and the same action twice in a row counts once. Typing is never undone.
    static func condense(_ actions: [String]) -> [String] {
        var out: [String] = []
        for a in actions {
            if isUndo(a), let last = out.last, !last.hasPrefix("Type "), !isUndo(last) {
                out.removeLast()
                continue
            }
            if out.last == a { continue }
            out.append(a)
        }
        return out
    }

    static func isUndo(_ action: String) -> Bool {
        ["Press Esc", "Press Escape", "Click ‘Close’", "Click ‘Cancel’", "Go back", "Press ⌘["].contains(action)
            || action.hasPrefix("Go back")
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    // MARK: Helpers

    static let stopWords: Set<String> = ["a", "an", "the", "to", "in", "on", "of", "for", "and", "then", "please", "can", "you", "me", "my",
                                         "it", "is", "at", "with", "that", "this", "up", "go", "into", "from", "about", "i", "so", "um", "uh"]

    /// Content words of a goal, lower-cased, minus filler.
    static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                .filter { $0.count > 1 && !stopWords.contains($0) })
    }

    private static func load(_ url: URL) -> [Entry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode([Entry].self, from: data)
    }

    private static func save(_ entries: [Entry], to url: URL) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try data.write(to: url, options: .atomic) } catch {
            Log.agent.error("AgentExperience: could not save: \(error.localizedDescription, privacy: .public)")
        }
    }
}
