import Foundation

// Navi addition (docs/TYPESAFE_CU.md): a replay cache of runs that worked, after Stagehand's
// action cache, Skyvern's code cache and browser-use's workflow-use. Spoken commands repeat —
// "start a new Claude code chat", "select local", "open the downloads folder" — and each repeat
// used to pay the whole loop again, low-confidence stops and 2–6 s writer reads included.
//
// A run that completed records the actions that moved the screen, as semantic selectors (the
// control's role, label and place in the window — never an item number, never typed text). The
// same goal in the same app replays them: each step's control is found again in the live tree;
// a step whose control is gone, ambiguous, or that changes nothing ends the replay and hands the
// run to Jev from that screen (self-healing), and the run's own success rewrites the entry. A run
// that fails after a replay drops it. Typing, app switches and anything that needed approval are
// never replayed: the trajectory stops before them and Jev takes over there.

struct CUReplayStep: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case click, press, select, key, scroll }
    var kind: Kind
    /// AX role ("AXButton"); empty for a text line clicked by position.
    var role: String = ""
    /// `CUFacts.plainLabel` of the control's label (or the line's text).
    var label: String = ""
    /// The control's ancestors ("Claude › Sidebar"), to tell copies apart.
    var path: String = ""
    var option: String?
    var key: String?
    var up: Bool?

    /// "clicked ‘New session’ (replayed)" — for Jev's history and the panel.
    var human: String {
        switch kind {
        case .click, .press: return "clicked \(CUFacts.quoted(label))"
        case .select: return "chose \(CUFacts.quoted(option ?? "")) in \(CUFacts.quoted(label))"
        case .key: return "pressed \(key ?? "")"
        case .scroll: return (up ?? false) ? "scrolled up" : "scrolled down"
        }
    }
}

struct CUTrajectory: Codable, Equatable, Sendable {
    var bundleID: String
    /// `CUReplay.key(for:)` of the goal.
    var goal: String
    var steps: [CUReplayStep]
    /// The steps reach the goal by themselves (false: they stop before typing, a switch, an approval).
    var complete: Bool
    var at: Date
    var replays: Int = 0
}

final class CUReplay: @unchecked Sendable {
    static let shared = CUReplay()
    static let maxEntries = 200
    static let maxSteps = 10

    private let lock = NSLock()
    private let fileURL: URL?
    private var entries: [CUTrajectory]

    init(fileURL: URL? = CUReplay.defaultFileURL) {
        self.fileURL = fileURL
        self.entries = fileURL.flatMap(Self.load) ?? []
    }

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Navi/agent-replays.json")
    }

    /// Words that change nothing about what is asked.
    static let filler: Set<String> = ["please", "um", "uh", "now", "just", "quickly", "the", "a", "an", "for", "me", "can", "you", "navi", "okay", "ok"]

    /// A goal as a cache key: spoken politeness, case and punctuation dropped; word order kept
    /// ("select local" and "select cloud" stay two goals; "click send" never matches "send").
    static func key(for goal: String) -> String {
        var g = VoiceDecider.normalizedGoal(goal).lowercased()
        // A voice follow-up names its app up front ("In System Settings: …"); the app is the key's other half.
        if let r = g.range(of: #"^in [^:]{1,40}:\s*"#, options: .regularExpression) { g = String(g[r.upperBound...]) }
        return g
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !filler.contains($0) }
            .joined(separator: " ")
    }

    func lookup(bundleID: String?, goal: String) -> CUTrajectory? {
        guard let bundleID else { return nil }
        let k = Self.key(for: goal)
        guard !k.isEmpty else { return nil }
        return lock.withLock { entries.last { $0.bundleID == bundleID && $0.goal == k } }
    }

    /// Stores (or replaces) the trajectory a successful run took.
    func record(bundleID: String?, goal: String, steps: [CUReplayStep], complete: Bool, replayed: Bool, at: Date = Date()) {
        guard let bundleID, !steps.isEmpty, steps.count <= Self.maxSteps else { return }
        let k = Self.key(for: goal)
        guard !k.isEmpty else { return }
        let snapshot: [CUTrajectory] = lock.withLock {
            let previous = entries.last { $0.bundleID == bundleID && $0.goal == k }
            entries.removeAll { $0.bundleID == bundleID && $0.goal == k }
            var t = CUTrajectory(bundleID: bundleID, goal: k, steps: steps, complete: complete, at: at)
            if replayed, let previous, previous.steps == steps { t.replays = previous.replays + 1 }
            entries.append(t)
            if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
            return entries
        }
        save(snapshot)
    }

    /// A replay that led to a failed run: forget it.
    func forget(bundleID: String?, goal: String) {
        guard let bundleID else { return }
        let k = Self.key(for: goal)
        let snapshot: [CUTrajectory] = lock.withLock {
            entries.removeAll { $0.bundleID == bundleID && $0.goal == k }
            return entries
        }
        save(snapshot)
    }

    var count: Int { lock.withLock { entries.count } }

    // MARK: Recording

    /// The step to store for an action taken on `screen`, or nil when it must never be replayed
    /// (typing, opening an app or a site, waiting) — the trajectory ends before such a step.
    static func step(for action: AgentAction, screen: CUScreen, itemText: String?) -> CUReplayStep? {
        switch action {
        case .click(let id), .press(let id):
            guard let e = screen.snapshot.element(id) ?? screen.offscreen.first(where: { $0.id == id }) else { return nil }
            let label = CUFacts.plainLabel(e.label.isEmpty ? (itemText ?? "") : e.label)
            guard !label.isEmpty else { return nil }
            if case .press = action { return CUReplayStep(kind: .press, role: e.role, label: label, path: e.path) }
            return CUReplayStep(kind: .click, role: e.role, label: label, path: e.path)
        case .clickPoint(_, _, let text):
            let label = CUFacts.plainLabel(text)
            return label.isEmpty ? nil : CUReplayStep(kind: .click, label: label)
        case .select(let id, let option):
            guard let e = screen.snapshot.element(id) else { return nil }
            return CUReplayStep(kind: .select, role: e.role, label: CUFacts.plainLabel(e.label), path: e.path, option: option)
        case .key(let k): return CUReplayStep(kind: .key, key: k)
        case .scroll(let up): return CUReplayStep(kind: .scroll, up: up)
        case .typeText, .wait, .openApp, .openURL: return nil
        }
    }

    // MARK: Replaying

    /// The action that carries `step` out on `screen`, or nil when its control is not there or
    /// is not one control (self-healing: Jev decides from this screen instead).
    static func resolve(_ step: CUReplayStep, on screen: CUScreen) -> AgentAction? {
        switch step.kind {
        case .key: return step.key.map { .key($0) }
        case .scroll: return .scroll(up: step.up ?? false)
        case .click, .press, .select:
            if !step.role.isEmpty {
                // A control scrolled out of a sidebar or list is still exposed: pressed, not clicked.
                let pool = step.kind == .select ? screen.snapshot.elements : screen.snapshot.elements + screen.offscreen
                var hits = pool.filter { $0.role == step.role && CUFacts.matchesLiteral($0.label, step.label) }
                if hits.count > 1 { hits = hits.filter { $0.path == step.path } }
                if hits.count == 1, let e = hits.first {
                    switch step.kind {
                    case .select:
                        guard let o = step.option, e.options.isEmpty || e.options.contains(o) else { return nil }
                        return .select(elementID: e.id, option: o)
                    default: return screen.offscreen.contains(where: { $0.id == e.id }) ? .press(elementID: e.id) : .click(elementID: e.id)
                    }
                }
                if hits.count > 1 { return nil }
            }
            guard step.kind == .click else { return nil }
            // A text line (or a control that came back without its role): the one item with that text.
            guard let it = CUFacts.literalItem(step.label, in: screen.items) else { return nil }
            if let id = screen.elementForItem[it.index] { return .click(elementID: id) }
            return .clickPoint(x: Double(it.center.x), y: Double(it.center.y), label: it.text)
        }
    }

    /// Steps never replayed without Jev's say: their labels read like sending, paying or deleting.
    static func looksIrreversible(_ step: CUReplayStep) -> Bool {
        let l = " " + step.label + " " + (step.option ?? "") + " "
        return ["send", "pay", "buy", "purchase", "delete", "remove", "erase", "submit", "post", "publish", "confirm", "order",
                "transfer", "unsubscribe", "trash", "sign out", "log out", "quit"].contains { l.contains(" \($0) ") }
    }

    // MARK: Storage

    private static func load(_ url: URL) -> [CUTrajectory]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode([CUTrajectory].self, from: data)
    }

    private func save(_ entries: [CUTrajectory]) {
        guard let fileURL else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try data.write(to: fileURL, options: .atomic) } catch {
            Log.agent.error("CUReplay: could not save: \(error.localizedDescription, privacy: .public)")
        }
    }
}
