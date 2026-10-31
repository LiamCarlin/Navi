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
        // …and the user's paths through each app and site (`UserPaths`), from the same store.
        UserPaths.install(store: store)
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
        // New actions since launch → the path graph again (local, ~0.2 s).
        UserPaths.installedRebuild(now: now)
        Log.memory.info("Routines: \(mined.count) from \(procedures.count) procedures (\(mined.filter { $0.count > 1 }.count) done more than once)")
        return mined.count
    }

    /// The agent followed `key`: remember whether the run worked.
    static func noteOutcome(key: String, worked: Bool) {
        // A path (`UserPaths`) is no stored routine: its record is the actions themselves.
        guard !key.hasPrefix("path:"), let r = current else { return }
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

    /// Words that say nothing about which task it is ("what's", "do", "your").
    static let functionWords: Set<String> = ["what", "whats", "when", "where", "why", "how", "who", "which", "do", "does", "did", "your",
                                             "our", "its", "there", "here", "just", "like", "want", "need", "could", "would", "should",
                                             "will", "be", "are", "was", "some", "any"]
    static let appWords: Set<String> = ["slack", "outlook", "canvas", "chrome", "app", "open", "go"]

    /// How much a word says about which task it is: names and things fully; verbs, kinds of
    /// things and app words ("send", "assignment", "slack", "updated", "making") a little.
    static func weight(_ w: String) -> Double {
        let g = RoutineMiner.generic
        if g.contains(w) { return 0.3 }
        for (suffix, back) in [("ing", ""), ("ing", "e"), ("ed", ""), ("d", ""), ("es", ""), ("s", "")] where w.hasSuffix(suffix) && w.count > suffix.count + 2 {
            if g.contains(String(w.dropLast(suffix.count)) + back) { return 0.3 }
        }
        return 1
    }

    static func weight(_ s: Set<String>) -> Double { s.reduce(0) { $0 + weight($1) } }

    /// A phrasing's first word after filler: what it does ("queue …", "reply to …").
    static func verb(_ s: String) -> String? {
        RoutineMiner.tokens(s).first { $0.count > 1 && !AgentExperience.stopWords.contains($0) && !CUReplay.filler.contains($0) }
            .map { synonyms[$0] ?? $0 }
    }

    /// How well a task (its `words`) is another instance of one phrasing of a routine.
    /// - `precision`: the task's words the phrasing has, names it ran with last time, or new
    ///   names its slots can take (worth a little less; no slots, no room for them);
    /// - `recall`: the phrasing's own content words (not verbs, kinds or app words) the task
    ///   names. "order me a burger" names 1 of the 10 in "order a … oz hot chocolate with
    ///   nonfat milk from Tatte Bakery for pickup at Wellesley": another task sharing a verb.
    /// - `verb`: the task does the phrasing's verb; `sameVerb` also counts the task's own verb
    ///   in the phrasing ("text joão" ↔ "send a message to …").
    struct Fit: Equatable { var precision: Double; var recall: Double; var named: Bool; var verb: Bool; var sameVerb: Bool; var onlySlots: Bool }

    /// `place`: the routine's app and site words; "Music" in "queue … to play next in Music" is
    /// where it happened, not a name the task repeats.
    static func fit(words: Set<String>, phrasing: String, slots: Set<String>, place: Set<String>, taskVerb: String? = nil) -> Fit? {
        let known = bag(phrasing, minus: slots)
        let shared = words.intersection(known)
        let named = words.intersection(slots).subtracting(place)
        let content = known.filter { weight($0) == 1 }
        let sharedContent = shared.filter { weight($0) == 1 }
        // At least one of the phrasing's own words, and one that says what is done, not only
        // the app's or a generic one ("View the … Review assignment for …" fits no task alone).
        let anchored = !shared.isEmpty && (!sharedContent.isEmpty || !named.isEmpty || (content.isEmpty && shared.contains { !appWords.contains($0) }))
        let total = weight(words)
        guard anchored, total > 0 else { return nil }
        let newNames = words.subtracting(known).subtracting(slots).filter { !RoutineMiner.generic.contains($0) }
        let room = Double(min(newNames.count, max(0, slots.subtracting(place).count - named.count)))
        let precision = min(1, (weight(shared) + weight(named) + 0.7 * room) / total)
        let recall = content.isEmpty && named.isEmpty ? 1 : Double(sharedContent.count + named.count) / Double(content.count + named.count)
        let does = verb(phrasing).map(words.contains) ?? false
        return Fit(precision: precision, recall: recall, named: !named.isEmpty, verb: does,
                   sameVerb: does || taskVerb.map(known.contains) == true, onlySlots: content.isEmpty)
    }

    /// Another instance of the task: most of the task is explained, and the task names most of
    /// what makes the routine that routine, or a third of it when it also does the routine's
    /// own verb ("reply to premkumar's message" ↔ "Reply to … message about VCs"; not "play the
    /// newest song" ↔ "queue … to play next in …"). A phrasing that is all verbs and slots
    /// ("submit … on Canvas") must at least do what the task does.
    static func accepts(_ f: Fit) -> Bool {
        guard f.precision >= 0.5 else { return false }
        if f.onlySlots { return f.sameVerb }
        return f.recall >= 0.6 || (f.verb && f.recall >= 0.33)
    }

    /// Routines the task could be another instance of, best first. `places`: bundle ids or
    /// site keys the task implies (its app, the app the person is reached in, the frontmost).
    static func candidates(task: String, routines: [Routine], places: Set<String> = [], named: Set<String> = [],
                           limit: Int = maxCandidates) -> [Candidate] {
        let words = taskWords(task).subtracting(functionWords)
        guard !words.isEmpty else { return [] }
        let taskVerb = verb(TaskGrounding.withoutDictation(task))
        var out: [Candidate] = []
        for r in routines where !r.isDiscredited {
            // Place first: a routine done in another app or site than the one the task names is
            // another task, however its words match ("sign into DoorDash with Google" is not the
            // Atlassian Google sign-in). Such kinds of control reach the run as `UserPaths` patterns.
            guard isInPlace(r, named: named) else { continue }
            let slots = r.slotWords
            let place = Set(RoutineMiner.tokens(r.appName + " " + (r.site ?? "")))
            let fits = (r.goals + [r.template]).compactMap { fit(words: words, phrasing: $0, slots: slots, place: place, taskVerb: taskVerb) }.filter(accepts)
            guard let best = fits.max(by: { $0.precision + $0.recall < $1.precision + $1.recall }) else { continue }
            var known = Set<String>()
            for g in r.goals + [r.template] { known.formUnion(bag(g, minus: slots)) }
            let fills = words.subtracting(known).filter { !RoutineMiner.generic.contains($0) }
            var score = (best.precision + best.recall) / 2
            // The task names what it ran with last time ("reply to premkumar's message").
            if best.named { score += 0.15 }
            if places.contains(r.bundleID) || r.site.map(places.contains) == true { score += 0.2 }
            if let site = r.site, words.contains(where: { site.contains($0) && $0.count >= 4 }) { score += 0.1 }
            if words.contains(where: { r.appName.lowercased().contains($0) && $0.count >= 4 }) { score += 0.1 }
            score += 0.05 * Double(min(r.count - 1, 3)) + 0.05 * Double(min(r.worked, 3))
            out.append(Candidate(routine: r, score: score, fills: fills.sorted(), coverage: min(best.precision, best.recall)))
        }
        return Array(out.sorted { $0.score != $1.score ? $0.score > $1.score : $0.routine.last > $1.routine.last }.prefix(limit))
    }

    struct Match: Sendable {
        var routine: Routine
        var fills: [String]
        var confidence: Double
        /// "jev", "local" (a routine); "path" (`UserPaths`: the user's way to the task's target).
        var source: String
        /// The path behind a "path" match.
        var path: PathPlan? = nil
        var isPath: Bool { path != nil }
        var route: UserRoute {
            var r = UserRoute(routine: routine, fills: fills, confidence: confidence)
            if let p = path { r.fromPath = true; r.pattern = p.pattern; r.theirPath = p.theirPath }
            return r
        }
    }

    // MARK: Place

    /// Labels of a host that are no brand ("docs" of docs.google.com, "app" of app.slack.com).
    static let hostNoise: Set<String> = ["www", "app", "my", "web", "m", "en", "us", "docs", "mail", "drive", "calendar", "sites", "maps",
                                         "photos", "meet", "chat", "news", "play", "store", "shop", "order", "online", "accounts", "login",
                                         "auth", "support", "help", "home", "api", "cdn", "com", "org", "net", "edu", "io", "ai", "co", "uk",
                                         "gov", "dev", "cloud", "the", "new", "go", "book", "secure", "portal", "google", "apple", "microsoft"]

    /// A site's own name ("doordash" of doordash.com, "mcmaster" of mcmaster.com): a label of its
    /// host that is no ordinary word ("start.godaddy.com" is not named by "start"). Apps and web
    /// apps with a playbook are named through `AppSkills` instead ("canvas", "slack").
    static func brand(of site: String) -> String? {
        let host = site.split(separator: "/").first.map(String.init) ?? site
        return host.split(separator: ".").map(String.init).first(where: isBrand)
    }

    /// Host labels that are ordinary words: a task saying them names no site.
    static let ordinaryWords: Set<String> = ["start", "account", "about", "info", "blog", "learn", "community", "forum", "status", "console",
                                             "admin", "dashboard", "studio", "platform", "labs", "share", "read", "watch", "live", "today",
                                             "time", "food", "world", "help", "photo", "music", "video", "games", "game", "school", "class",
                                             "student", "students", "pay", "money", "health", "news", "mobile", "cloud", "data", "code",
                                             "design", "free", "open", "best", "sale", "deal", "deals", "online", "store", "golf", "course"]

    /// The places a task names outright: an app or web app by name ("in slack", "on doordash"),
    /// or a site of the user's by its own name (`sites`). A browser named is no place for a site.
    static func namedPlaces(for task: String, sites: [String] = []) -> Set<String> {
        var out = Set<String>()
        let words = Set(RoutineMiner.tokens(TaskGrounding.withoutDictation(task)))
        var skillWords = Set<String>()
        if let s = AppSkills.mentioned(in: task), !s.bundleIDs.contains(where: AXSnapshotter.isBrowser) {
            out.formUnion(s.bundleIDs)
            out.formUnion(s.hosts)
            skillWords = Set(([s.name] + s.aliases).flatMap(RoutineMiner.tokens).filter { $0.count >= 4 && !hostNoise.contains($0) })
        }
        for site in sites {
            let labels = (site.split(separator: "/").first.map(String.init) ?? site).split(separator: ".").map(String.init)
            // The user's own instance of a named web app ("canvas" → canvas.olin.edu), or a site by its own name.
            if !skillWords.isEmpty, labels.contains(where: skillWords.contains) { out.insert(site); continue }
            if labels.contains(where: { words.contains($0) && isBrand($0) }) { out.insert(site) }
        }
        return out
    }

    static func isBrand(_ label: String) -> Bool {
        label.count >= 4 && !hostNoise.contains(label) && !ordinaryWords.contains(label)
            && (!PathWords.kindWords.contains(label) || appNames.contains(label))
    }

    /// App names among the generic task words: a site carrying one is named by it ("canvas.olin.edu").
    static let appNames: Set<String> = ["slack", "outlook", "gmail", "canvas", "github", "discord", "whatsapp", "claude", "notion", "linkedin",
                                        "zoom", "teams", "onshape"]

    /// May routine `r` be followed for a task that names `named`? Yes when it names nothing, or
    /// when the routine's own site or app is one of them.
    static func isInPlace(_ r: Routine, named: Set<String>) -> Bool {
        guard !named.isEmpty else { return true }
        if let site = r.site { return named.contains { PathGraph.Scope.samePlace(site, $0) } }
        return named.contains(r.bundleID)
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
    /// `memory`/`jev`: a memory of the caller's (the task bench's copy) instead of the installed one —
    /// the same code, uncached.
    static func match(task: String, timeout: Double = 1.5, memory: ScreenMemory? = nil, jev: JevClient? = nil) async -> Match? {
        if let memory {
            return await resolve(task: task, routines: memory.routines?.routines() ?? [], jev: jev, memory: memory, cached: false)
        }
        guard let r = current else { return nil }
        let key = cacheKey(task)
        guard !key.isEmpty else { return nil }
        let t: Task<Match?, Never>
        lock.lock()
        if let c = cache[key], Date().timeIntervalSince(c.at) < cacheTTL { lock.unlock(); return c.m }
        if let running = inflight[key] { t = running } else {
            let jev = jevClient
            t = Task(priority: .userInitiated) { await resolve(task: task, routines: r.routines(), jev: jev, memory: ScreenMemory.live) }
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
    static func places(for task: String, memory: ScreenMemory? = ScreenMemory.live) -> Set<String> {
        var out = Set<String>()
        if let s = AppSkills.mentioned(in: task) { out.formUnion(s.bundleIDs); if let h = s.hosts.first { out.insert(h) } }
        for s in AppSkills.inferApps(for: task, frontmostBundleID: nil).prefix(2) { out.formUnion(s.bundleIDs) }
        if let chat = memory?.channelApp(for: task) { out.insert(chat) }
        return out
    }

    private static func resolve(task: String, routines: [Routine], jev: JevClient?, memory: ScreenMemory?, cached: Bool = true) async -> Match? {
        let paths = memory?.paths
        let sites = (paths?.graph?.sites ?? []) + routines.compactMap(\.site)
        let named = namedPlaces(for: task, sites: sites)
        let implied = places(for: task, memory: memory)
        // The app the person is reached in ("text joão" → WhatsApp) is as good as named, for the path.
        let reach = named.isEmpty ? memory?.channelApp(for: task) : nil
        // Routines too: "message X" is followed in the app they reach X in, never in Slack on the web
        // because a Slack-web routine shares the words.
        let routinePlaces = reach.map { named.union([$0]) } ?? named
        // What the task points at in the user's own work (usually settled while typing), in parallel.
        async let grounding = cached ? TaskGrounding.ground(task: task, timeout: 1.0) : TaskGrounding.ground(task: task, memory: memory, jev: jev)
        let cs = candidates(task: task, routines: routines, places: implied, named: routinePlaces)
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
        // The user's own path to what the task points at (`UserPaths`): the primary plan unless a
        // routine of theirs for this very task, in the same place, was done more than once.
        var g: UserPaths.Grounding? = await grounding.map { ($0.thing.url, $0.thing.bundleID, $0.thing.name) }
        // Not grounded, but the task names a thing memory knows ("open the hci notes" → that page, not the
        // Notes app): its page is the target — unless the task reaches someone (then it is what to send).
        if g == nil, !TaskGrounding.isCommunication(task), !TaskGrounding.isErrand(task),
           let m = memory?.knowledge.matches(for: task).first(where: { $0.thing.type != "person" && $0.thing.url(for: task) != nil }) {
            g = (m.thing.url(for: task), nil, m.thing.name)
        }
        if let paths {
            let t0 = Date()
            // The people it names by their full name ("mikey" → "Mikey Ku"): their own chat, not a group listing them.
            let people = (memory?.knowledge.matches(for: task) ?? []).filter { $0.thing.type == "person" }.prefix(2).map(\.thing.name)
            let plan = paths.plan(task: task, grounded: g, places: implied, named: reach.map { [$0] } ?? named, people: Array(people))
            if let plan { Log.agent.info("UserPaths: \(plan.source, privacy: .public) path, \(plan.steps.count) steps, support \(plan.support) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms") }
            result = choose(routine: result, path: plan, task: task)
        }
        if cached { store(result, for: task) }
        return result
    }

    /// A routine of theirs for this very task done more than once (in the path's place) wins;
    /// otherwise the user's path; a pattern only when nothing else is known.
    static func choose(routine: Match?, path: PathPlan?, task: String) -> Match? {
        let pathMatch = path.map { p in
            Match(routine: p.routine(task: task), fills: [], confidence: p.confidence, source: "path", path: p)
        }
        guard let r = routine else { return pathMatch }
        guard let p = path, !p.pattern else { return r }
        let samePlace = p.site.map { s in r.routine.site.map { PathGraph.Scope.samePlace($0, s) } ?? false } ?? (r.routine.bundleID == p.bundleID)
        if r.routine.count >= 2 && (samePlace || r.confidence >= 0.8) { return r }
        if samePlace && r.confidence >= 0.8 { return r }
        return pathMatch
    }

    // MARK: Planner and runner

    /// For the planner: the user's routines like this task (best ≤ 2), as steps.
    static func plannerContext(for task: String) -> [[String: Any]]? {
        if let p = cachedMatch(for: task)?.path, !p.pattern {
            return [["their_usual_path_to": p.target, "in": p.site ?? p.appName, "times": p.support,
                     "path": p.theirPath, "steps_from_start": p.steps.map(\.human), "start_page": p.startURL ?? NSNull()]]
        }
        let matched = cachedMatch(for: task).map { [$0.routine] }
        let list = matched ?? current.map { r in
            let all = r.routines()
            let named = namedPlaces(for: task, sites: (UserPaths.current?.graph?.sites ?? []) + all.compactMap(\.site))
            return candidates(task: task, routines: all, places: places(for: task), named: named, limit: 2).map(\.routine)
        } ?? []
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
    /// The user's path to the task's target (`UserPaths`), not a stored routine: each step is
    /// found only on its own page, and an item on the way must carry all of its words.
    var fromPath = false
    /// A kind of control as the user uses it on other sites: found by what it does (its
    /// `PathIntent`) anywhere, marked for Jev, never pressed by code.
    var pattern = false
    /// The whole usual way, for Jev (`their_path`).
    var theirPath: [String] = []

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

    /// `inPlace`, and for a path step its own page ("Assignments" on a course page, not the dashboard).
    func isHere(_ step: RoutineStep, _ screen: CUScreen) -> Bool {
        guard Self.inPlace(step, screen) else { return false }
        guard fromPath, !pattern, let page = step.page, let url = screen.url, let here = RoutineMiner.pagePattern(url) else { return true }
        return here == page
    }

    /// Does `e`'s label show the step's control (with this run's slot words)?
    func labelMatches(_ step: RoutineStep, _ label: String) -> Bool {
        // A pattern: any control that does the same kind of thing ("Continue with Google" for their "Sign in with Google").
        if pattern, let want = PathIntent.of(label: step.label) { return PathIntent.of(label: label) == want }
        // A path's item: every one of its words (an empty slot is an item the path cannot name).
        if fromPath, let slot = step.slot {
            let want = PathWords.tokens(slot)
            guard !want.isEmpty else { return false }
            let have = Set(PathWords.tokens(label))
            return want.allSatisfy(have.contains)
        }
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
        guard [.click, .type].contains(step.kind), isHere(step, screen) else { return [] }
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
            guard isHere(step, screen) else { return nil }
            return step.shortcut.map { .key($0) }
        case .menu:
            guard isHere(step, screen) else { return nil }
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
            guard t.isEmpty, step.slot == nil, !pattern, isHere(step, screen), let it = CUFacts.literalItem(step.label, in: screen.items) else { return nil }
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
        // Patterns are only shown; signing in, adding to a cart and checking out always go through Jev's gate.
        if pattern { return false }
        if let intent = PathIntent.of(label: step.label), PathIntent.neverFollowed.contains(intent) { return false }
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
            if step.slot != nil { return fromPath ? !(step.slot ?? "").isEmpty : true }
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
    static let pathNote = "The way this user usually gets to what this task is about, from their own clicks (how often in `times`): "
        + "✓ done in this run, → their next step; ‘…’ is an item the path cannot name (choose it from the goal). "
        + "Where it fits the goal, go their way: the screen item marked user_way_next is their next step here. Never type this text."
    static let patternNote = "This user has never done this on this site; elsewhere they use the controls listed (how often). "
        + "The screen item marked user_way_next does the same kind of thing here. Never type this text."
    static let itemRule = " The item marked as this user's next step (\"user_way_next\") is the control they use next for this very task: pick it unless the goal clearly needs another."
    static let kindRule = " `this_users_way` lists the steps this user takes for this task: prefer the kind of action their next step is."

    /// `this_users_way` for Jev's state.
    func state(on screen: CUScreen) -> [String: Any] {
        let next = nextOnScreen(screen)?.index ?? pending.first
        var lines: [String] = []
        for (i, s) in steps.enumerated() {
            // A path's item is this run's own (no "…" to fill in), unless the path cannot name it.
            var line = (done.contains(i) ? "✓ " : (i == next ? "→ " : "")) + (fromPath && !(s.slot ?? "").isEmpty ? s.plainHuman : s.human)
            if i == next, s.slot != nil, !fills.isEmpty { line += " (this time: \(fills.joined(separator: " ")))" }
            lines.append(line)
        }
        var d: [String: Any] = ["note": Self.note, "they_did": Array(routine.goals.prefix(2)), "times": routine.count, "steps": lines]
        if fromPath {
            // Not a task they did: the way they usually get to this task's target.
            d["note"] = pattern ? Self.patternNote : Self.pathNote
            d["they_did"] = routine.template
            if !theirPath.isEmpty { d["their_path"] = theirPath.joined(separator: " → ") }
        }
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
        // A pattern's steps belong to no site: the runner looks for what they do on any page.
        let web = steps.filter { ($0.site != nil || pattern) && [.click, .type, .submit, .key].contains($0.kind) }
        guard !web.isEmpty else { return nil }
        var obj: [String: Any] = [
            "template": routine.template, "times": routine.count, "fills": fills,
            "steps": web.map { s -> [String: Any] in
                var d: [String: Any] = ["kind": s.kind.rawValue, "role": s.role, "label": s.label, "site": s.site ?? "",
                                        "fixed": s.fixedLabel, "human": s.human]
                if let slot = s.slot { d["slot"] = slot }
                if let k = s.shortcut { d["shortcut"] = k }
                if pattern, let intent = PathIntent.of(label: s.label) { d["intent"] = intent.rawValue }
                if fromPath, !(s.slot ?? "").isEmpty { d["human"] = s.plainHuman }
                return d
            },
        ]
        // UserPaths: the runner shows the whole usual way; a path's items need all their words.
        if fromPath {
            obj["source"] = pattern ? "pattern" : "path"
            if !theirPath.isEmpty { obj["their_path"] = theirPath.joined(separator: " → ") }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
