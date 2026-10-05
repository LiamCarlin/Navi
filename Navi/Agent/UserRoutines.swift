import Foundation

/// The user's own ways of doing things, carried out the way they do them.
///
/// `RoutineMiner` (Memory) turns screen memory into routines: a task the user did and the
/// controls they used for it, in order, with the part that changes between runs (a person,
/// an assignment, a document) as a slot. This side matches a task to one of them and
/// follows it:
///   - `candidates`: routines whose tasks share the task's words (its new names fill the
///     slots), in the app or site the task implies first; one Jev `same_task` pick settles
///     which one the task is another instance of (prepared while the user types, cached);
///   - `UserRoute`: during the run, each of the user's steps is found again on the live
///     screen (`action(_:on:)`). A step whose control is there exactly once, that changes
///     nothing irreversible and that is the same every time (or whose slot the task fills)
///     is pressed directly — no Jev call, no Claude — as long as each one moves the screen.
///     Anything else (typing, sending, an ambiguous or missing control) goes to Jev with the
///     user's way in its state (`this_users_way`) and their next step marked on screen.
///   - how it went is stored with the routine (`worked`/`failed`): one that keeps failing
///     is no longer offered.
///
/// Installed by `MemoryService` next to `UserMoves`, behind the same toggle
/// (`agentUsesScreenHabits`).
final class UserRoutines: @unchecked Sendable {
    static let ttl: TimeInterval = 300
    static let maxCandidates = 5
    /// Jev's pick below this is no match.
    static let minConfidence = 0.5
    /// Without Jev, only a routine done before this often that covers the task this well.
    static let localMinCoverage = 0.75
    static let localMinCount = 2

    // MARK: Installation (integration hook for MemoryService)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed: UserRoutines?
    nonisolated(unsafe) private static var jevClient: JevClient?

    static func install(store: MemoryStore) {
        lock.lock()
        let fresh = installed?.store !== store
        if fresh { installed = UserRoutines(store: store) }
        let r = installed
        lock.unlock()
        // Mined at launch from what is already stored: routines exist before the next digest.
        if fresh, let r { Task.detached(priority: .utility) { r.rebuild() } }
    }

    /// Integration hook (`ComputerAgent.init`): the Jev client the match asks.
    static func install(jev: JevClient) { lock.lock(); jevClient = jev; lock.unlock() }

    /// nil when memory has no store, the user turned habits off, or under unit tests.
    static var current: UserRoutines? {
        guard !TestHost.isActive, UserDefaults.navi.object(forKey: "agentUsesScreenHabits") as? Bool ?? true else { return nil }
        lock.lock(); defer { lock.unlock() }
        return installed
    }

    let store: MemoryStore
    private let cacheLock = NSLock()
    private var cached: (routines: [Routine], at: Date)?

    init(store: MemoryStore) { self.store = store }

    /// The routines the agent may follow (not those that keep failing).
    func routines(now: Date = Date()) -> [Routine] {
        cacheLock.lock()
        if let c = cached, now.timeIntervalSince(c.at) < Self.ttl { cacheLock.unlock(); return c.routines }
        cacheLock.unlock()
        let list = ((try? store.routines()) ?? []).filter { !$0.isDiscredited }
        cacheLock.lock(); cached = (list, now); cacheLock.unlock()
        return list
    }

    func invalidate() { cacheLock.lock(); cached = nil; cacheLock.unlock() }

    /// Mines every procedure's routine again (after a digest, at launch) and stores them.
    @discardableResult
    func rebuild(now: Date = Date()) -> Int {
        let procedures = (try? store.procedures(since: now.addingTimeInterval(-Double(MemoryStore.procedureRetentionDays) * 86_400))) ?? []
        let mined = RoutineMiner.mine(procedures) { [store] p in
            if !p.actionIDs.isEmpty, let named = try? store.actions(ids: p.actionIDs), !named.isEmpty { return named }
            let window = (try? store.actions(in: DateInterval(start: p.start.addingTimeInterval(-30), end: max(p.start, p.end).addingTimeInterval(30)), limit: 400)) ?? []
            return RoutineMiner.align(steps: p.steps, actions: window)
        }
        do { try store.saveRoutines(mined) } catch {
            Log.memory.error("Routines not saved: \(error.localizedDescription, privacy: .public)")
            return 0
        }
        invalidate()
        Self.clearMatches()
        Log.memory.info("Routines: \(mined.count) from \(procedures.count) procedures (\(mined.filter { $0.count > 1 }.count) done more than once)")
        return mined.count
    }

    /// The agent followed `key`: remember whether the run worked.
    static func noteOutcome(key: String, worked: Bool) {
        guard let r = current else { return }
        try? r.store.noteRoutineOutcome(key: key, worked: worked)
        r.invalidate()
    }

    // MARK: Matching

    struct Candidate: Equatable, Sendable {
        var routine: Routine
        var score: Double
        /// The task's own words for the routine's slots ("pia" for "message … on Slack").
        var fills: [String]
        var coverage: Double
    }

    /// Words that ask for the same thing: "view", "check", "review" an assignment all open it;
    /// "text", "dm", "ping" someone all message them.
    static let synonyms: [String: String] = [
        "view": "open", "access": "open", "go": "open", "check": "open", "review": "open", "see": "open", "show": "open",
        "pull": "open", "visit": "open", "navigate": "open", "look": "open", "bring": "open", "launch": "open",
        "text": "message", "dm": "message", "ping": "message", "msg": "message", "messages": "message",
        "mail": "email", "emails": "email", "respond": "reply", "answer": "reply",
        "assignments": "assignment", "homework": "assignment",
    ]

    /// Content words, numbers kept ("assignment 2"), filler dropped, `minus` (a routine's slot
    /// words) left out before synonyms fold.
    static func bag(_ s: String, minus: Set<String> = []) -> Set<String> {
        Set(RoutineMiner.tokens(s)
            .filter { ($0.count > 1 || $0.contains(where: \.isNumber)) && !AgentExperience.stopWords.contains($0) && !CUReplay.filler.contains($0) && !minus.contains($0) }
            .map { synonyms[$0] ?? $0 })
    }

    /// Content words of a task without what it dictates ("saying …", quotes): those are the
    /// message, not names to look for.
    static func taskWords(_ task: String) -> Set<String> { bag(TaskGrounding.withoutDictation(task)) }

    /// Routines the task could be another instance of, best first. `places`: bundle ids or
    /// site keys the task implies (its app, the app the person is reached in, the frontmost).
    static func candidates(task: String, routines: [Routine], places: Set<String> = [], limit: Int = maxCandidates) -> [Candidate] {
        let words = taskWords(task)
        guard !words.isEmpty else { return [] }
        var out: [Candidate] = []
        for r in routines where !r.isDiscredited {
            let slots = r.slotWords
            var known = Set<String>()
            for g in r.goals + [r.template] { known.formUnion(bag(g, minus: slots)) }
            let shared = words.intersection(known)
            // At least one word that says what is done, not only the app's or a generic one.
            guard shared.contains(where: { !["slack", "outlook", "canvas", "chrome", "app", "open", "go"].contains($0) }) else { continue }
            let fills = words.subtracting(known).filter { !RoutineMiner.generic.contains($0) }
            let rest = words.subtracting(fills)
            let coverage = rest.isEmpty ? 0 : Double(shared.count) / Double(rest.count)
            guard coverage >= AgentExperience.minOverlap else { continue }
            var score = coverage
            // A task naming something new fits a routine with a slot for it, not a fixed one.
            if !fills.isEmpty { score += slots.isEmpty ? -0.25 : 0.15 }
            if places.contains(r.bundleID) || r.site.map(places.contains) == true { score += 0.2 }
            if let site = r.site, words.contains(where: { site.contains($0) && $0.count >= 4 }) { score += 0.1 }
            if words.contains(where: { r.appName.lowercased().contains($0) && $0.count >= 4 }) { score += 0.1 }
            score += 0.05 * Double(min(r.count - 1, 3)) + 0.05 * Double(min(r.worked, 3))
            out.append(Candidate(routine: r, score: score, fills: fills.sorted(), coverage: coverage))
        }
        return Array(out.sorted { $0.score != $1.score ? $0.score > $1.score : $0.routine.last > $1.routine.last }.prefix(limit))
    }

    struct Match: Sendable {
        var routine: Routine
        var fills: [String]
        var confidence: Double
        var source: String
        var route: UserRoute { UserRoute(routine: routine, fills: fills, confidence: confidence) }
    }

    static let note = "Tasks this user has done before on this computer, each with the steps they took (their own clicks). "
        + "A slot (…) is the part that changes between runs: the person, item or document."
    static let instructions = "Is the task asking to do one of these things this user has done before — the same kind of task, "
        + "perhaps for another person, item or document? Pick the one whose steps would carry the task out the way they did it. "
        + "Pick none when the task asks for something else, or only shares a few words with one."

    static func request(task: String, candidates: [Candidate], now: Date = Date()) -> (state: [String: Any], questions: [String: JevClient.Question]) {
        var criteria: [String: String] = [:]
        var listed: [[String: Any]] = []
        for (i, c) in candidates.enumerated() {
            let r = c.routine
            let id = "r\(i + 1)"
            criteria[id] = "\(r.template) (\(r.site ?? r.appName); done \(r.count)×) — " + r.steps.prefix(6).map(\.human).joined(separator: " → ")
            var d: [String: Any] = ["id": id, "task_they_did": r.goals.first ?? r.template, "in": r.site ?? r.appName,
                                    "times": r.count, "last_done": TaskGrounding.shortWhen(r.last, now: now),
                                    "steps": r.steps.map(\.human)]
            if r.goals.count > 1 { d["also_did"] = Array(r.goals.dropFirst().prefix(3)) }
            if !c.fills.isEmpty { d["task_words_for_its_slots"] = c.fills }
            listed.append(d)
        }
        criteria["none"] = "None of these: the task is something else, or only shares a few words with one of them."
        let state: [String: Any] = ["task": task, "note": note, "routines": listed]
        return (state, ["same_task": .choice(instructions: instructions, criteria: criteria)])
    }

    static func pick(_ answer: JevClient.Answer?, among cs: [Candidate]) -> (Candidate, Double)? {
        guard let choice = answer?.choice, choice != "none", let i = Int(choice.dropFirst()), i >= 1, i <= cs.count else { return nil }
        let p = answer?.probabilities?[choice] ?? answer?.confidence ?? 0
        return p >= minConfidence ? (cs[i - 1], p) : nil
    }

    /// No Jev: the top candidate only when it is clearly the same task and was done more than once.
    static func localPick(_ cs: [Candidate]) -> Candidate? {
        guard let top = cs.first, top.coverage >= localMinCoverage, top.routine.count >= localMinCount else { return nil }
        if cs.count > 1, cs[1].score >= top.score - 0.05 { return nil }
        return top
    }

    // MARK: Live

    nonisolated(unsafe) private static var cache: [String: (m: Match?, at: Date)] = [:]
    nonisolated(unsafe) private static var inflight: [String: Task<Match?, Never>] = [:]
    static let cacheTTL: TimeInterval = 180

    static func cacheKey(_ task: String) -> String { TaskGrounding.cacheKey(task) }

    /// The match already settled for `task`, if any (the browser runner, the planner).
    static func cachedMatch(for task: String) -> Match? {
        lock.lock(); defer { lock.unlock() }
        guard let c = cache[cacheKey(task)], Date().timeIntervalSince(c.at) < cacheTTL else { return nil }
        return c.m
    }

    /// Starts matching `task` (the router calls this while the user types).
    static func prepare(task: String) {
        guard current != nil else { return }
        Task.detached(priority: .userInitiated) { _ = await match(task: task) }
    }

    /// The routine `task` is another instance of, settled once, ≤ `timeout` s.
    static func match(task: String, timeout: Double = 1.5) async -> Match? {
        guard let r = current else { return nil }
        let key = cacheKey(task)
        guard !key.isEmpty else { return nil }
        let t: Task<Match?, Never>
        lock.lock()
        if let c = cache[key], Date().timeIntervalSince(c.at) < cacheTTL { lock.unlock(); return c.m }
        if let running = inflight[key] { t = running } else {
            let jev = jevClient
            t = Task(priority: .userInitiated) { await resolve(task: task, routines: r.routines(), jev: jev) }
            inflight[key] = t
        }
        lock.unlock()
        return await TaskGrounding.value(of: t, within: timeout)
    }

    private static func store(_ m: Match?, for task: String) {
        lock.lock(); defer { lock.unlock() }
        inflight[cacheKey(task)] = nil
        cache[cacheKey(task)] = (m, Date())
        if cache.count > 200 { cache = cache.filter { Date().timeIntervalSince($0.value.at) < cacheTTL } }
    }

    static func clearMatches() { lock.lock(); cache.removeAll(); lock.unlock() }

    /// The places a task implies: the app it names or implies, the app the person it names is
    /// reached in, a site it names.
    static func places(for task: String) -> Set<String> {
        var out = Set<String>()
        if let s = AppSkills.mentioned(in: task) { out.formUnion(s.bundleIDs); if let h = s.hosts.first { out.insert(h) } }
        for s in AppSkills.inferApps(for: task, frontmostBundleID: nil).prefix(2) { out.formUnion(s.bundleIDs) }
        if let chat = UserKnowledge.liveChannelApp(for: task) { out.insert(chat) }
        return out
    }

    private static func resolve(task: String, routines: [Routine], jev: JevClient?) async -> Match? {
        let cs = candidates(task: task, routines: routines, places: places(for: task))
        var result: Match?
        if !cs.isEmpty {
            if let jev, jev.isConfigured {
                let (state, questions) = request(task: task, candidates: cs)
                do {
                    let r = try await jev.ask(state: JevClient.JSONValue(any: state), questions: questions)
                    if let (c, p) = pick(r["same_task"], among: cs) { result = Match(routine: c.routine, fills: c.fills, confidence: p, source: "jev") }
                    Log.agent.info("UserRoutines: \(cs.count) candidates, Jev → \(r["same_task"]?.choice ?? "?", privacy: .public) in \(r.latencyMs) ms")
                } catch {
                    Log.agent.warning("UserRoutines: Jev failed (\(error.localizedDescription, privacy: .public)); local pick")
                    if let c = localPick(cs) { result = Match(routine: c.routine, fills: c.fills, confidence: 0.6, source: "local") }
                }
            } else if let c = localPick(cs) {
                result = Match(routine: c.routine, fills: c.fills, confidence: 0.6, source: "local")
            }
        }
        store(result, for: task)
        return result
    }

    // MARK: Planner and runner

    /// For the planner: the user's routines like this task (best ≤ 2), as steps.
    static func plannerContext(for task: String) -> [[String: Any]]? {
        let matched = cachedMatch(for: task).map { [$0.routine] }
        let list = matched ?? current.map { candidates(task: task, routines: $0.routines(), places: places(for: task), limit: 2).map(\.routine) } ?? []
        guard !list.isEmpty else { return nil }
        return list.map { r in
            ["task_they_did": r.goals.first ?? r.template, "in": r.site ?? r.appName, "times": r.count,
             "steps": r.steps.map(\.human), "start_page": r.startURL ?? NSNull()]
        }
    }

    /// For the browser runner (`NAVI_USER_ROUTE_JSON`): the matched routine's web steps.
    static func runnerJSON(for task: String, original: String?) -> String? {
        guard let m = cachedMatch(for: original ?? task) ?? cachedMatch(for: task) else { return nil }
        return m.route.runnerJSON()
    }
}

/// One run's progress along the user's routine: which steps are done, what is next on this
/// screen, and whether code may do it without asking Jev.
struct UserRoute: Sendable {
    let routine: Routine
    /// The task's words for the routine's slots.
    let fills: [String]
    let confidence: Double
    private(set) var done = Set<Int>()
    /// Steps carried out directly (no Jev call).
    var followed = 0

    static let lookahead = 2
    static let maxFollowed = 10
    /// Keys that send, delete or quit: never pressed without Jev's gate.
    static let unsafeKeys: Set<String> = ["return", "kp_enter", "cmd+return", "cmd+enter", "cmd+kp_enter", "cmd+delete", "cmd+backspace",
                                          "cmd+shift+d", "cmd+q", "delete", "shift+cmd+return"]

    init(routine: Routine, fills: [String], confidence: Double) {
        self.routine = routine; self.fills = fills; self.confidence = confidence
    }

    var steps: [RoutineStep] { routine.steps }
    var pending: [Int] { steps.indices.filter { !done.contains($0) } }
    var isFinished: Bool { pending.isEmpty }

    /// The words a slot step's control should carry in this run: the task's own, else the
    /// routine's (the same person or item again).
    func wanted(_ step: RoutineStep) -> [String] {
        guard let slot = step.slot else { return [] }
        return fills.isEmpty ? RoutineMiner.tokens(slot) : fills
    }

    // MARK: Finding a step on screen

    static func sameApp(_ name: String, _ screen: CUScreen) -> Bool {
        let clean: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
        let want = clean(name)
        return !want.isEmpty && (clean(screen.snapshot.appName ?? "") == want || clean(screen.app) == want)
    }

    /// Is the screen the step's place (its app; on the web, its site)?
    static func inPlace(_ step: RoutineStep, _ screen: CUScreen) -> Bool {
        if !step.bundleID.isEmpty, let b = screen.snapshot.bundleID, b != step.bundleID { return false }
        if let site = step.site { return screen.url.flatMap(UserHabits.siteKey(of:)) == site }
        return true
    }

    /// Does `e`'s label show the step's control (with this run's slot words)?
    func labelMatches(_ step: RoutineStep, _ label: String) -> Bool {
        guard step.slot != nil else {
            if CUFacts.matchesLiteral(label, step.label) { return true }
            let a = UserMoves.norm(label), b = UserMoves.norm(step.label)
            return UserMoves.sameControl(a, b) || (step.role == "row" && UserMoves.head(a).count >= 4 && UserMoves.head(a) == UserMoves.head(b))
        }
        let have = Set(RoutineMiner.tokens(label))
        // A short fixed part ("Message to …") must be there; a long one is the last run's item's
        // own text (a profile card's headline) and says nothing about this run's.
        let fixed = Set(RoutineMiner.tokens(step.fixedLabel))
        guard fixed.count > Self.maxFixedWords || fixed.isSubset(of: have) else { return false }
        return wanted(step).contains(where: have.contains)
    }

    static let maxFixedWords = 4

    /// How many of this run's slot words the label carries (more is a better match).
    func slotHits(_ step: RoutineStep, _ label: String) -> Int {
        let have = Set(RoutineMiner.tokens(label))
        return wanted(step).filter(have.contains).count
    }

    static func roleWord(_ e: AXElement) -> String { ActionJournal.roleWord(e.role, subrole: e.subrole) }

    /// The controls on this screen that are step `i`'s (on screen first, then those scrolled away).
    func targets(_ i: Int, on screen: CUScreen) -> [AXElement] {
        let step = steps[i]
        guard [.click, .type].contains(step.kind), Self.inPlace(step, screen) else { return [] }
        let wantsField = step.kind == .type
        var pool = screen.snapshot.elements.filter { labelMatches(step, $0.label) && $0.isTextInput == wantsField && !$0.isSecure }
        if pool.isEmpty, !wantsField { pool = screen.offscreen.filter { labelMatches(step, $0.label) && !$0.isTextInput } }
        guard pool.count > 1 else { return pool }
        // The same role, then the same container, then the most slot words.
        let sameRole = pool.filter { Self.roleWord($0) == step.role }
        if !sameRole.isEmpty { pool = sameRole }
        if pool.count > 1, let path = step.path, !path.isEmpty,
           step.slot.map({ !RoutineMiner.tokens(path).contains(where: Set(RoutineMiner.tokens($0)).contains) }) ?? true {
            let inPath = pool.filter { $0.path.localizedCaseInsensitiveContains(path) }
            if !inPath.isEmpty { pool = inPath }
        }
        if pool.count > 1, step.slot != nil {
            let best = pool.map { slotHits(step, $0.label) }.max() ?? 0
            pool = pool.filter { slotHits(step, $0.label) == best }
        }
        return pool
    }

    /// The action that does step `i` on this screen; nil when its control is not there, or not once.
    func action(_ i: Int, on screen: CUScreen) -> AgentAction? {
        let step = steps[i]
        switch step.kind {
        case .open:
            return Self.sameApp(step.label, screen) ? nil : .openApp(step.label)
        case .key, .submit:
            guard Self.inPlace(step, screen) else { return nil }
            return step.shortcut.map { .key($0) }
        case .menu:
            guard Self.inPlace(step, screen) else { return nil }
            return step.shortcut.map { .key($0) }
        case .type:
            let t = targets(i, on: screen)
            return t.count == 1 ? .typeText(elementID: t[0].id) : nil
        case .click:
            let t = targets(i, on: screen)
            if t.count == 1 {
                return screen.offscreen.contains(where: { $0.id == t[0].id }) ? .press(elementID: t[0].id) : .click(elementID: t[0].id)
            }
            // A line of text with no control of its own, named exactly (a fixed step only).
            guard t.isEmpty, step.slot == nil, Self.inPlace(step, screen), let it = CUFacts.literalItem(step.label, in: screen.items) else { return nil }
            if let id = screen.elementForItem[it.index] { return .click(elementID: id) }
            return .clickPoint(x: Double(it.center.x), y: Double(it.center.y), label: it.text)
        }
    }

    /// Controls that only take the user somewhere — what code may press without Jev.
    static let navigationRoles: Set<String> = ["link", "tab", "row", "cell", "control", "text", "dock item", "menu item"]
    /// Words a navigation button is made of ("Show more", "Next", "View all").
    static let navigationWords: Set<String> = ["show", "more", "less", "next", "previous", "prev", "open", "view", "see", "all", "expand",
                                               "collapse", "menu", "settings", "options", "details", "home", "back", "new", "page", "go", "to",
                                               "list", "grid", "sidebar", "tab", "tabs", "inbox", "drafts", "sent", "files", "the", "my"]
    /// Words that commit, share, consent or change something: never pressed without Jev's gate.
    static let committingWords: Set<String> = ["add", "invite", "share", "create", "save", "accept", "allow", "approve", "continue",
                                               "join", "follow", "like", "connect", "request", "export", "import", "install", "upload",
                                               "download", "archive", "move", "rename", "reply", "forward", "mark", "enable", "disable",
                                               "turn", "subscribe", "leave", "block", "report", "authorize", "grant", "done", "finish",
                                               "apply", "update", "upgrade", "decline", "reject", "cancel", "close"]

    /// May step `i` be carried out without Jev? Only a move that takes the user somewhere — a
    /// link, tab, row, sidebar item, menu item, a "Show more"-like button, a harmless shortcut,
    /// opening an app — never typing, sending, toggling, or a control that adds, shares,
    /// consents or reads like paying or deleting (those go through Jev and its approval gate).
    /// A fixed control only when it is the same every time: it names nothing particular the
    /// task does not name itself, or it is a short navigation control the user takes in several
    /// of their routines (or this routine was done more than once) — never a long, numbered item.
    func mayFollow(_ i: Int, task: String) -> Bool {
        let step = steps[i]
        switch step.kind {
        case .type, .submit: return false
        case .open: return true
        case .key, .menu:
            guard let k = step.shortcut?.lowercased(), !Self.unsafeKeys.contains(k) else { return false }
            return !CUReplay.looksIrreversible(CUReplayStep(kind: .key, label: CUFacts.plainLabel(step.label)))
                && !RoutineMiner.tokens(step.label).contains(where: Self.committingWords.contains)
        case .click:
            let words = RoutineMiner.tokens(step.label)
            guard !CUReplay.looksIrreversible(CUReplayStep(kind: .click, label: CUFacts.plainLabel(step.label))),
                  !words.contains(where: Self.committingWords.contains) else { return false }
            if step.role == "button" {
                guard !words.isEmpty, words.allSatisfy(Self.navigationWords.contains) else { return false }
            } else if !Self.navigationRoles.contains(step.role) {
                return false   // checkboxes, radios, pop-ups, steppers and fields change something
            }
            if step.slot != nil { return true }
            if RoutineMiner.specificWords(step.label).isSubset(of: UserRoutines.taskWords(task)) { return true }
            let tokens = RoutineMiner.tokens(step.label)
            guard tokens.count <= 3, !tokens.contains(where: { $0.contains(where: \.isNumber) }) else { return false }
            return routine.count >= 2 || (step.seen ?? 0) >= 2
        }
    }

    /// The first pending step (looking ≤ `lookahead` past it) that this screen shows, and its action.
    func nextOnScreen(_ screen: CUScreen) -> (index: Int, action: AgentAction)? {
        for i in pending.prefix(Self.lookahead + 1) {
            if steps[i].kind == .open, Self.sameApp(steps[i].label, screen) { continue }
            if let a = action(i, on: screen) { return (i, a) }
        }
        return nil
    }

    /// Steps already true of this screen: an app to open that is the one in front.
    mutating func settle(on screen: CUScreen) {
        for i in pending.prefix(Self.lookahead + 1) {
            guard steps[i].kind == .open else { break }
            if Self.sameApp(steps[i].label, screen) { done.insert(i) } else { break }
        }
    }

    /// The step code may carry out now, without Jev: the next one on screen, when followable.
    mutating func direct(on screen: CUScreen, task: String) -> (index: Int, action: AgentAction)? {
        settle(on: screen)
        guard followed < Self.maxFollowed, let next = nextOnScreen(screen), mayFollow(next.index, task: task) else { return nil }
        return next
    }

    /// Steps up to and including `i` are behind the run (earlier ones were skipped: the screen
    /// was already past them).
    mutating func complete(through i: Int) {
        for j in steps.indices where j <= i { done.insert(j) }
    }

    /// An action Jev (or code) took: the pending step it carried out, if any, is done.
    mutating func observe(_ action: AgentAction, on screen: CUScreen) {
        for i in pending.prefix(Self.lookahead + 1) {
            let step = steps[i]
            let hit: Bool
            switch action {
            case .click(let id), .press(let id): hit = step.kind == .click && targets(i, on: screen).contains { $0.id == id }
            case .clickPoint(_, _, let label): hit = step.kind == .click && labelMatches(step, label)
            case .typeText(let id): hit = step.kind == .type && targets(i, on: screen).contains { $0.id == id }
            case .key(let k): hit = [.key, .submit, .menu].contains(step.kind) && step.shortcut.map { Self.sameCombo($0, k) } == true
            case .openApp(let name): hit = step.kind == .open && name.lowercased().contains(step.label.lowercased())
            default: hit = false
            }
            if hit { complete(through: i); return }
        }
    }

    static func sameCombo(_ a: String, _ b: String) -> Bool {
        if a.lowercased() == b.lowercased() { return true }
        guard let x = try? KeyCombo.parse(a), let y = try? KeyCombo.parse(b) else { return false }
        return x.keyCode == y.keyCode && x.flags == y.flags
    }

    // MARK: For Jev

    /// Items on screen that are the user's next step.
    func marks(on screen: CUScreen) -> Set<Int> {
        guard let next = nextOnScreen(screen) else { return [] }
        let ids = Set(targets(next.index, on: screen).map(\.id))
        if ids.isEmpty, case .clickPoint(_, _, let label) = next.action {
            return Set(screen.items.filter { $0.text == label }.map(\.index))
        }
        return Set(screen.elementForItem.filter { ids.contains($0.value) }.map(\.key))
    }

    static let note = "How this user does this kind of task themselves, step by step, from their own clicks: "
        + "✓ done in this run, → their next step. A … is the part that changes (here: the task's person or item). "
        + "Where it fits the goal, do it their way: the screen item marked user_way_next is their next step here. Never type this text."
    static let itemRule = " The item marked as this user's next step (\"user_way_next\") is the control they use next for this very task: pick it unless the goal clearly needs another."
    static let kindRule = " `this_users_way` lists the steps this user takes for this task: prefer the kind of action their next step is."

    /// `this_users_way` for Jev's state.
    func state(on screen: CUScreen) -> [String: Any] {
        let next = nextOnScreen(screen)?.index ?? pending.first
        var lines: [String] = []
        for (i, s) in steps.enumerated() {
            var line = (done.contains(i) ? "✓ " : (i == next ? "→ " : "")) + s.human
            if i == next, s.slot != nil, !fills.isEmpty { line += " (this time: \(fills.joined(separator: " ")))" }
            lines.append(line)
        }
        var d: [String: Any] = ["note": Self.note, "they_did": Array(routine.goals.prefix(2)), "times": routine.count, "steps": lines]
        if let submit = steps.first(where: { $0.kind == .submit })?.shortcut { d["they_send_with"] = submit }
        return d
    }

    /// The shortcut list with the user's own keys for this routine marked or added.
    func shortcuts(_ base: [(String, String)]) -> [(String, String)] {
        var out = base
        for i in pending.prefix(Self.lookahead + 1) {
            let s = steps[i]
            guard [.key, .menu, .submit].contains(s.kind), let combo = s.shortcut,
                  !CUDecide.keysThatAreKinds.contains(combo.lowercased()), (try? KeyCombo.parse(combo)) != nil else { continue }
            let note = s.kind == .submit ? "how this user sends here — their next step" : "this user's next step for this task"
            if let j = out.firstIndex(where: { Self.sameCombo($0.0, combo) }) {
                if !out[j].1.contains("next step") { out[j].1 += " — \(note)" }
            } else {
                out.append((combo, (s.label.isEmpty ? (s.kind == .submit ? "Send" : combo) : s.label) + " — \(note)"))
            }
        }
        return out
    }

    // MARK: For the browser runner

    /// `{"template", "times", "fills", "steps": [{kind, role, label, slot, site, shortcut}]}` —
    /// only the routine's web steps; nil when it has none.
    func runnerJSON() -> String? {
        let web = steps.filter { $0.site != nil && [.click, .type, .submit, .key].contains($0.kind) }
        guard !web.isEmpty else { return nil }
        let obj: [String: Any] = [
            "template": routine.template, "times": routine.count, "fills": fills,
            "steps": web.map { s -> [String: Any] in
                var d: [String: Any] = ["kind": s.kind.rawValue, "role": s.role, "label": s.label, "site": s.site ?? "",
                                        "fixed": s.fixedLabel, "human": s.human]
                if let slot = s.slot { d["slot"] = slot }
                if let k = s.shortcut { d["shortcut"] = k }
                return d
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
