import Foundation

/// What worked before, per app: the episodic half of the agent's knowledge
/// (`AppSkills` is the hand-written half). After a step completes, the goal
/// and the action labels that got there are stored; a later goal in the same
/// app that shares words with it gets those lines as `state.experience`, so
/// Jev starts from "last time this took ⌘N → type → Return" instead of
/// exploring. Mirrors Agent S's episodic memory (subtask → grounded actions,
/// successes only), kept deliberately small and local.
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
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Navi/agent-experience.json")
    }

    // MARK: Record / recall

    /// Stores a completed step. Replaces an earlier entry for the same app and
    /// (normalised) goal so the store keeps the latest way that worked.
    func record(bundleID: String?, appName: String?, goal: String, actions: [String], at: Date = Date()) {
        guard let bundleID, !bundleID.isEmpty, !actions.isEmpty else { return }
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !g.isEmpty else { return }
        let entry = Entry(bundleID: bundleID, appName: appName, goal: String(g.prefix(200)),
                          actions: actions.suffix(Self.maxActionsPerEntry).map { String($0.prefix(Self.maxLabelLength)) }, at: at)
        lock.lock()
        entries.removeAll { $0.bundleID == bundleID && Self.words($0.goal) == Self.words(g) }
        entries.append(entry)
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
        let snapshot = entries
        lock.unlock()
        if let fileURL { Self.save(snapshot, to: fileURL) }
    }

    /// Up to `recallLimit` past successes in this app whose goals overlap
    /// `goal`, best match first, as "goal → action · action · …" lines.
    func recall(bundleID: String?, goal: String, limit: Int = recallLimit) -> [String] {
        guard let bundleID, !bundleID.isEmpty else { return [] }
        let wanted = Self.words(goal)
        guard !wanted.isEmpty else { return [] }
        lock.lock(); let all = entries; lock.unlock()
        let scored: [(Entry, Double)] = all.compactMap { e in
            guard e.bundleID == bundleID else { return nil }
            let shared = wanted.intersection(Self.words(e.goal)).count
            guard shared >= min(Self.minSharedWords, wanted.count) else { return nil }
            let overlap = Double(shared) / Double(wanted.count)
            return overlap >= Self.minOverlap ? (e, overlap) : nil
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.at > $1.0.at }
            .prefix(limit)
            .map { "\($0.0.goal) → \($0.0.actions.joined(separator: " · "))" }
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
