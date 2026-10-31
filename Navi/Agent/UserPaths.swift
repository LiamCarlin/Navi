import Foundation

/// The user's own paths: how *they* get from where a run starts to what a task is about,
/// read from every click they made — not from a phrase that matches a task they once did.
///
/// `RoutineMiner` keeps whole tasks (a goal and its steps) and `UserRoutines` matches them by
/// their words, which fails two ways: most tasks were never done in that phrasing (a handful
/// of ~850 routines were done twice), and words match across places ("sign into DoorDash with
/// Google" followed the Atlassian Google sign-in). A path is found the other way round — from
/// the task's *target*:
///   1. `PathGraph.build`: every recorded action becomes an abstract step — the place (a site
///      in a browser, else the app), the page pattern ("canvas.olin.edu/courses/#/assignments"),
///      kind, role, container, and its label when it is the same every time (‘Assignments’,
///      ‘New Note’ ⌘N, the ‘Message’ field) or a *slot* when it is the item that changes (a
///      course, an assignment, a conversation row). Consecutive steps of one visit are edges
///      with counts; each item keeps the steps that led to it last time and the page it opened;
///      each page keeps its concrete URLs with their titles. Local, at launch and after each
///      digest (no model).
///   2. Targets (`plan`): what the task points at, in the place it names (else the place of
///      the thing `TaskGrounding` picked, else the places it implies): a page of theirs whose
///      title/URL carries the task's names ("generative ai assignments", "Assignment 3"), an
///      item they clicked whose label does ("joão", "Assignment 03"), a page kind for "my last
///      canvas assignment", or a kind of control (`PathIntent`: compose, new note, new
///      document, cart…) they use there.
///   3. `PathGraph.path`: their most-used way from the run's start to it (Dijkstra on
///      −log P(next | step)), items on the way taken from the chain that reached that very item
///      before, then what they usually do next there (type in ‘Message’, send with Return). A
///      web path starts on the deepest page of theirs it knows (the target's own URL when they
///      opened it before) and shows the whole usual way as `theirPath`.
///   4. The path reaches the drivers as a `Routine` (`UserRoutines` match source "path"), so
///      `UserRoute` follows it like a routine: navigation-only steps pressed by code, everything
///      else (typing, sending, adding, consent) left to Jev with the step marked `user_way_next`
///      and the way in `this_users_way` (+ `their_path`).
///   Place is respected: a path never leaves the app it starts in, and a place the task names
///   is the only place searched. A kind of control the user never used *there* is offered as a
///   pattern (their labels for it elsewhere), marked by what it does, never pressed.
///
/// Installed with `UserRoutines` (same toggle, `agentUsesScreenHabits`); lookups are index hits.
final class UserPaths: @unchecked Sendable {
    static let actionWindow: TimeInterval = 90 * 86_400

    // MARK: Installation (from `UserRoutines.install`)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed: UserPaths?

    static func install(store: MemoryStore) {
        lock.lock()
        let fresh = installed?.store !== store
        if fresh { installed = UserPaths(store: store) }
        let p = installed
        lock.unlock()
        if fresh, let p { Task.detached(priority: .utility) { p.rebuild() } }
    }

    /// After a digest (`UserRoutines.rebuild`): the graph again from the stored actions.
    static func installedRebuild(now: Date = Date()) {
        lock.lock(); let p = installed; lock.unlock()
        p?.rebuild(now: now)
    }

    /// nil when memory has no store, the user turned habits off, or under unit tests.
    static var current: UserPaths? {
        guard !TestHost.isActive, UserDefaults.navi.object(forKey: "agentUsesScreenHabits") as? Bool ?? true else { return nil }
        lock.lock(); defer { lock.unlock() }
        return installed
    }

    let store: MemoryStore?
    private let graphLock = NSLock()
    private var built: PathGraph?

    init(store: MemoryStore?) { self.store = store }

    /// For tests and probes: a graph already built.
    init(graph: PathGraph) { self.store = nil; self.built = graph }

    var graph: PathGraph? { graphLock.lock(); defer { graphLock.unlock() }; return built }

    @discardableResult
    func rebuild(now: Date = Date()) -> Int {
        guard let store else { return 0 }
        let t0 = Date()
        let actions = (try? store.actions(in: DateInterval(start: now.addingTimeInterval(-Self.actionWindow), end: now))) ?? []
        let g = PathGraph.build(actions: actions)
        graphLock.lock(); built = g; graphLock.unlock()
        Log.memory.info("UserPaths: \(g.nodes.count) steps, \(g.edgeCount) edges from \(actions.count) actions in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        return g.nodes.count
    }

    // MARK: Planning

    typealias Grounding = (url: String?, bundleID: String?, name: String)

    /// The user's way to what `task` points at, or nil when their history shows none.
    /// `named`: places the task names (or the app its person is reached in) — only those are
    /// searched; `places`: places it implies; `grounded`: what `TaskGrounding` resolved it to.
    func plan(task: String, grounded: Grounding? = nil, places: Set<String> = [], named: Set<String> = [], people: [String] = [],
              start: PathGraph.Start? = nil) -> PathPlan? {
        guard let g = graph else { return nil }
        return Self.plan(task: task, graph: g, grounded: grounded, places: places, named: named, people: people, start: start)
    }

    /// `people`: full names of the people the task names ("Mikey Ku" for "mikey"), from `UserKnowledge`.
    static func plan(task: String, graph g: PathGraph, grounded: Grounding? = nil, places: Set<String> = [], named: Set<String> = [],
                     people: [String] = [], start: PathGraph.Start? = nil) -> PathPlan? {
        let want = PathWords.taskWords(task).union(people.flatMap(PathWords.tokens))
        let intents = PathIntent.of(task: task)
        let groundedPlace = grounded.flatMap { gr in gr.url.flatMap(UserHabits.siteKey(of:)) ?? gr.bundleID }
        let scope = g.scope(named: named, implied: places, grounded: groundedPlace)
        // Mail is written new, not reopened from a thread that mentions the person; "the cheapest
        // filament" is any one, not the one they looked at last time.
        let anyOne = PathWords.wantsAnyOne(task)
        let items = !PathWords.isEmailTask(task) && !anyOne
        let recent = TaskGrounding.scope(of: task, now: Date()).recent

        func targets(in scope: PathGraph.Scope) -> [PathGraph.Target] {
            var out: [PathGraph.Target] = []
            // The thing the task names in their own work (grounded, or known by name): its own page.
            if !anyOne, let gr = grounded, let u = gr.url, let page = RoutineMiner.pagePattern(u), scope.allows(site: UserHabits.siteKey(of: u), bundle: nil) {
                out.append(.init(kind: .page, page: page, url: UserHabits.cleanURL(u), node: nil, label: gr.name, fill: [], cost: 0, what: gr.name, source: "thing"))
            }
            if !anyOne { out += g.pageTargets(words: want, scope: scope) }
            if items { out += g.itemTargets(words: want, scope: scope) }
            out += g.pageKindTargets(words: want, recent: recent, scope: scope)
            out += g.intentTargets(intents, scope: scope)
            return out.sorted { $0.cost < $1.cost }
        }
        var found = targets(in: scope)
        // Nothing where the task seemed to point (implied places are a guess): anywhere of theirs.
        if found.isEmpty, !scope.strict, !scope.places.isEmpty { found = targets(in: .init(places: [], strict: false)).filter { $0.kind != .intent } }
        for t in found.prefix(6) {
            if let p = g.plan(to: t, start: start, intents: intents) { return p }
        }
        // Nothing of theirs in this place: a kind of control they use elsewhere, as a pattern.
        if !scope.places.isEmpty, let p = g.pattern(intents, scope: scope) { return p }
        return nil
    }

    // MARK: Coverage (probe)

    struct Coverage: Equatable, Sendable {
        /// Apps and sites with ≥ `minActions` recorded steps.
        var places: Int
        /// …with a step taken the same way at least twice.
        var withRepeats: Int
        /// …with a two-step chain the user took at least twice (A → B, a usable path).
        var withChains: Int
        var nodes: Int
        var edges: Int
    }

    static func coverage(_ g: PathGraph, minActions: Int = 10) -> Coverage {
        var byPlace: [String: [String]] = [:]
        for (k, n) in g.nodes { byPlace[n.place, default: []].append(k) }
        var c = Coverage(places: 0, withRepeats: 0, withChains: 0, nodes: g.nodes.count, edges: g.edgeCount)
        for (_, keys) in byPlace {
            let total = keys.reduce(0) { $0 + (g.nodes[$1]?.count ?? 0) }
            guard total >= minActions else { continue }
            c.places += 1
            if keys.contains(where: { (g.nodes[$0]?.count ?? 0) >= 2 }) { c.withRepeats += 1 }
            let chain = keys.contains { k in (g.edges[k] ?? [:]).contains { $0.value >= 2 && $0.key != k && g.nodes[$0.key]?.place == g.nodes[k]?.place } }
            if chain { c.withChains += 1 }
        }
        return c
    }
}

// MARK: - Words

enum PathWords {
    static let dropped: Set<String> = ["open", "go", "show", "pull", "bring", "get", "take", "start", "working", "work", "on", "my", "the", "a",
                                       "an", "to", "in", "of", "for", "and", "then", "please", "can", "you", "me", "i", "it", "up", "at", "with",
                                       "from", "into", "this", "that", "last", "latest", "recent", "again", "navi", "hey", "page", "app",
                                       "s", "im", "m", "way", "is", "be", "are", "was", "will"]

    /// Content words of a task without what it dictates; numbers without leading zeros.
    static func taskWords(_ task: String) -> Set<String> {
        Set(tokens(TaskGrounding.withoutDictation(task)).filter { !dropped.contains($0) && ($0.count >= 2 || $0.allSatisfy(\.isNumber)) })
    }

    static func tokens(_ s: String) -> [String] { RoutineMiner.tokens(s).map(num) }

    /// "03" → "3": an assignment is the same whichever way its number is written.
    static func num(_ t: String) -> String {
        guard t.count > 1, t.allSatisfy(\.isNumber), t.hasPrefix("0") else { return t }
        let s = t.drop { $0 == "0" }
        return s.isEmpty ? "0" : String(s)
    }

    /// Words that only say what kind of thing or action it is: they never pick an item alone.
    static let kindWords: Set<String> = RoutineMiner.generic.union([
        "text", "texts", "message", "email", "reply", "conversation", "chat", "dm", "play", "playlist", "song", "songs", "album", "order",
        "buy", "cart", "checkout", "sign", "log", "login", "account", "doc", "google", "new", "note", "event", "browse", "search",
        "lab", "report", "homework", "assignment", "assignments", "fall", "spring", "2025", "2026", "2027", "me", "my",
        "cheapest", "best", "some", "one", "into", "something",
    ])

    static func specific(_ words: Set<String>) -> Set<String> {
        words.filter { !kindWords.contains($0) && ($0.count >= 3 || $0.contains(where: \.isNumber)) }
    }

    /// "the cheapest filament", "a burger", "some flowers": any one, not one they saw before.
    static func wantsAnyOne(_ task: String) -> Bool {
        TaskGrounding.withoutDictation(task).lowercased()
            .range(of: #"\b(cheapest|cheaper|cheap|best|top[- ]rated|highest[- ]rated|lowest|another|any|some|a few|a couple|random\w*)\b"#, options: .regularExpression) != nil
    }

    /// "email crawford the lab report": a new mail, not a thread that mentions them.
    static func isEmailTask(_ task: String) -> Bool {
        let w = Set(RoutineMiner.tokens(task))
        return !w.isDisjoint(with: ["email", "mail", "emails"]) && w.isDisjoint(with: ["reply", "respond", "thread", "forward"])
    }

    /// Path segments a task can ask for by name ("my canvas assignments", "the cart"), plural first.
    static let pageKinds: [String: [String]] = [
        "assignment": ["assignments"], "assignments": ["assignments"], "homework": ["assignments"], "calendar": ["calendar"],
        "grades": ["grades"], "grade": ["grades"], "inbox": ["inbox"], "cart": ["cart"], "bag": ["bag", "cart"], "modules": ["modules"],
        "files": ["files"], "syllabus": ["syllabus"], "quiz": ["quizzes"], "quizzes": ["quizzes"], "announcements": ["announcements"],
        "discussions": ["discussion_topics", "discussions"], "drafts": ["drafts"], "orders": ["orders", "order-history"],
    ]
}

// MARK: - Kinds of control (cross-site patterns)

/// A kind of control every app or site has some version of — how the user signs in, adds to a
/// cart, writes something new — recognised from its label's words, not from one site's markup.
enum PathIntent: String, CaseIterable, Sendable {
    case signInWithGoogle, signIn, addToCart, openCart, checkout, newDocument, compose, newNote, newEvent, search

    static func of(label: String) -> PathIntent? {
        let w = Set(RoutineMiner.tokens(label))
        guard w.count <= 8 else { return nil }   // a sentence that mentions a cart is no cart button
        let signs = !w.isDisjoint(with: ["sign", "signin", "log", "login", "continue"])
        if w.contains("google"), signs { return .signInWithGoogle }
        if w.contains("checkout") || (w.contains("check") && w.contains("out")) { return .checkout }
        let cart = !w.isDisjoint(with: ["cart", "bag", "basket"])
        if cart, w.contains("add") { return .addToCart }
        if cart { return .openCart }
        if (w.contains("sign") && w.contains("in")) || w.contains("signin") || (w.contains("log") && w.contains("in")) || w.contains("login") { return .signIn }
        if w.contains("blank") || (w.contains("new") && !w.isDisjoint(with: ["document", "doc", "spreadsheet", "presentation"])) { return .newDocument }
        if w.contains("compose") || (w.contains("new") && !w.isDisjoint(with: ["message", "email", "mail", "chat"])) { return .compose }
        if w.contains("new"), w.contains("note") { return .newNote }
        if (w.contains("new") || w.contains("create")), w.contains("event") { return .newEvent }
        if w.contains("search"), w.count <= 4 { return .search }
        return nil
    }

    /// The kinds of control a task needs, most specific first.
    static func of(task: String) -> [PathIntent] {
        let t = TaskGrounding.withoutDictation(task).lowercased()
        let w = Set(RoutineMiner.tokens(t))
        var out: [PathIntent] = []
        let signs = t.range(of: #"\b(sign|log)\s*(in|into|on)\b|\blogin\b|\bsignin\b"#, options: .regularExpression) != nil
        if signs, w.contains("google") { out.append(.signInWithGoogle) }
        if signs { out.append(.signIn) }
        if !w.isDisjoint(with: ["order", "buy", "purchase"]) || t.contains("add to cart") || t.contains("add to my cart")
            || t.range(of: #"\bto (my|the) (\w+ )?cart\b"#, options: .regularExpression) != nil { out += [.addToCart, .openCart] }
        if !w.isDisjoint(with: ["cart", "bag", "basket"]), !out.contains(.openCart) { out.append(.openCart) }
        let creates = !w.isDisjoint(with: ["new", "create", "make", "start", "blank", "write"])
        if creates, !w.isDisjoint(with: ["doc", "document", "docs", "spreadsheet", "sheet", "presentation", "slides"]) { out.append(.newDocument) }
        if creates, !w.isDisjoint(with: ["note", "notes"]) { out.append(.newNote) }
        if creates || w.contains("schedule"), !w.isDisjoint(with: ["event", "meeting"]) { out.append(.newEvent) }
        if !w.isDisjoint(with: ["email", "text", "message", "dm", "mail", "compose"]), w.isDisjoint(with: ["reply", "respond"]) { out.append(.compose) }
        if w.contains("search") || t.contains("look up") { out.append(.search) }
        return out
    }

    /// Kinds that consent, add or sign in: never pressed by code, whatever their role.
    static let neverFollowed: Set<PathIntent> = [.signInWithGoogle, .signIn, .addToCart, .checkout]
}

// MARK: - The graph

/// One abstract step of the user's: a control in a place (and on a page), the same every time
/// (`label`) or the item that changes (`isSlot`), with how often they took it.
struct PathNode: Sendable, Equatable {
    var key: String
    /// A site key in a browser, else the app's bundle id.
    var place: String
    var bundleID: String
    var appName: String
    /// Page pattern (also in apps that show web pages, e.g. Slack's).
    var page: String?
    var isWeb: Bool
    var kind: RoutineStep.Kind
    var role: String
    var container: String?
    /// The newest label (a slot's newest item).
    var label: String
    var isSlot: Bool
    var shortcut: String?
    var count = 0
    var last: Date
    /// Visits that began with this step.
    var entries = 0
    /// Normalised label → the item (a slot's items; a fixed step's one label).
    var items: [String: PathItem] = [:]
    /// What kind of control it is (fixed steps only).
    var intent: PathIntent?
    /// Words most of its items share ("assignment", "fall 2026"): they tell none apart.
    var common: Set<String> = []
}

struct PathItem: Sendable, Equatable {
    var label: String
    var words: [String]
    var count: Int
    var last: Date
    /// Clean URL of the page it opened (the next action's, when that was another page).
    var ledTo: String?
    /// The steps that led to it last time (node key, label), oldest first.
    var chain: [PathLink] = []
}

struct PathLink: Sendable, Equatable { var node: String; var label: String }

struct PathURL: Sendable, Equatable {
    var url: String
    var title: String
    var words: [String]
    var count: Int
    var last: Date
    /// Titles seen with it: the window's title is not always the tab the click went to.
    var titles: [String: Int] = [:]
}

struct PathRef: Sendable, Equatable, Hashable { var node: String; var item: String }

/// What a run gets: where to start, the user's steps from there, and how sure the history is.
struct PathPlan: Sendable, Equatable {
    /// "‘Assignment 03’ (canvas.olin.edu)": what the path reaches.
    var target: String
    var bundleID: String
    var appName: String
    var site: String?
    /// The page the run should start on (the deepest page of theirs the path knows).
    var startURL: String?
    var steps: [RoutineStep]
    /// The whole usual way, start included ("Dashboard → ‘Applied Math…’ → ‘Assignments’ → ‘Assignment 03’").
    var theirPath: [String]
    /// How often the user took the weakest link of it.
    var support: Int
    /// "page", "item", "kind", "intent", "pattern".
    var source: String
    /// A kind of control from other places: marked, never pressed, never a start.
    var pattern = false

    /// 0.5…0.9: how much the drivers may lean on it (a start page or app needs ≥ 0.6).
    var confidence: Double {
        if pattern { return 0.5 }
        return min(0.9, 0.6 + 0.1 * Double(min(support, 3)))
    }

    /// The path as a routine `UserRoute` follows (its key never collides with a stored one).
    func routine(task: String, now: Date = Date()) -> Routine {
        Routine(key: "path:" + RoutineMiner.key(bundleID: bundleID, site: site, steps: steps), goals: [task], template: "your usual way to \(target)",
                bundleID: bundleID, appName: appName, site: site, startURL: startURL, steps: steps,
                count: max(1, support), first: now, last: now)
    }
}

struct PathGraph: Sendable {
    var nodes: [String: PathNode] = [:]
    var edges: [String: [String: Int]] = [:]
    var out: [String: Int] = [:]
    /// Bundle id → visits (runs of actions in that app).
    var visits: [String: Int] = [:]
    /// Page pattern → its concrete URLs (clean) with titles.
    var pages: [String: [String: PathURL]] = [:]
    /// Word → items whose label carries it; word → URLs whose title or path does; URL → the item that opened it.
    var itemIndex: [String: [PathRef]] = [:]
    var pageIndex: [String: [(page: String, url: String)]] = [:]
    var openedBy: [String: PathRef] = [:]
    /// Site keys the user acts on (≥ 3 actions): the sites a task can name.
    var sites: [String] = []
    var edgeCount: Int { edges.values.reduce(0) { $0 + $1.count } }

    /// Assistants (Claude, ChatGPT): a chat that mentions a thing is not where the thing is.
    static func isAssistant(_ place: String) -> Bool {
        let p = place.lowercased()
        return TaskPlanner.assistantApps.contains { p.contains($0) } || p.contains("anthropic") || p.contains("openai")
    }

    /// Roles that open another page when clicked.
    static let opensPages: Set<String> = ["link", "row", "cell", "tab", "text", "menu item", "image"]
    static let searchSegments: Set<String> = ["s", "search", "results", "find", "query", "sch"]
    static let maxGap: TimeInterval = 120
    static let visitGap: TimeInterval = 10 * 60
    static let maxChain = 6
    static let maxPathSteps = 7
    static let maxURLsPerPage = 300
    static let maxItemsPerNode = 400

    // MARK: Building

    /// An action as an abstract step, before slots are known.
    struct Proto {
        var a: ActionRecord
        var place: String
        var page: String?
        var url: String?
        var isWeb: Bool
        var kind: RoutineStep.Kind
        var label: String
        var norm: String
        var container: String?
    }

    /// Per-URL parsing, done once per distinct URL.
    private struct URLFacts { var site: String?; var page: String?; var clean: String?; var auth: Bool }

    static func protos(_ actions: [ActionRecord]) -> [Proto?] {
        var out: [Proto?] = []
        var lastKind: [String: RoutineStep.Kind] = [:]
        var urlCache: [String: URLFacts] = [:]
        for a in actions.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard !a.bundleID.isEmpty, !RoutineMiner.incidentalBundles.contains(a.bundleID), a.bundleID != RoutineMiner.dockBundle else { continue }
            var place = a.bundleID
            var page: String?
            var clean: String?
            let browser = FrameCapture.browserBundleIDs.contains(a.bundleID)
            if let u = a.url {
                let f = urlCache[u] ?? {
                    let site = UserHabits.siteKey(of: u)
                    let f = URLFacts(site: site, page: site == nil ? nil : RoutineMiner.pagePattern(u), clean: UserHabits.cleanURL(u), auth: UserHabits.isAuthPage(u))
                    urlCache[u] = f
                    return f
                }()
                if let site = f.site {
                    // Search pages say nothing about a site's own paths: a break, not a step.
                    if browser, UserHabits.ignoredSiteKeys.contains(site) { out.append(nil); continue }
                    // A site is a place in a browser; an app that shows web pages (Slack, Claude) stays the app.
                    if browser { place = site }
                    page = f.page
                    clean = f.auth ? nil : f.clean
                }
            }
            var kind: RoutineStep.Kind
            switch a.kind {
            case .click:
                guard !a.label.isEmpty, !RoutineMiner.backLabels.contains(RoutineMiner.norm(a.label)) else { continue }
                kind = a.role == "field" ? .type : .click
            case .menu:
                if let s = a.shortcut?.lowercased(), RoutineMiner.incidentalKeys.contains(s) { continue }
                guard !a.label.isEmpty else { continue }
                kind = .menu
            case .type: kind = .type
            case .key:
                guard let combo = a.shortcut?.lowercased() else { continue }
                if RoutineMiner.submitKeys.contains(combo) {
                    if lastKind[a.bundleID] == .type { kind = .submit } else { continue }
                } else if RoutineMiner.incidentalKeys.contains(combo) || !combo.contains("+") {
                    continue
                } else { kind = .key }
            }
            lastKind[a.bundleID] = kind
            let label = stripState(a.label)
            let norm = kind == .key || kind == .submit ? (a.shortcut?.lowercased() ?? "") : UserMoves.norm(label)
            out.append(Proto(a: a, place: place, page: page, url: clean, isWeb: browser && place != a.bundleID, kind: kind, label: label,
                             norm: norm, container: a.path.map(UserMoves.norm)))
        }
        return out
    }

    /// Does a window title belong to this URL? Titles that end in a web app's name must be on its host.
    static func titleFits(_ title: String, url: String) -> Bool {
        let host = UserHabits.host(of: url) ?? ""
        for (suffix, h) in [(" - Google Docs", "docs.google.com"), (" - Google Sheets", "docs.google.com"), (" - Google Slides", "docs.google.com"),
                            (" - Google Drive", "drive.google.com"), (" - YouTube", "youtube.com"), (" - Gmail", "mail.google.com"),
                            (" - Slack", "slack.com"), (" | LinkedIn", "linkedin.com")] where title.contains(suffix) {
            return host.hasSuffix(h)
        }
        return true
    }

    /// "New Mail, pressed" → "New Mail": the control, not its state at the time.
    static func stripState(_ label: String) -> String {
        label.replacingOccurrences(of: #",\s*(pressed|selected|not selected|checked|unchecked|expanded|collapsed|dimmed)$"#, with: "",
                                   options: [.regularExpression, .caseInsensitive]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func dayNumber(_ d: Date) -> Int { Int(d.timeIntervalSince1970 / 86_400) }

    /// Is a clicked label the item that changes, not a control that is always there? Items carry
    /// numbers or many words, or were clicked on one day only (anywhere in the place); a kind of
    /// control (‘Add to cart’, ‘New Note’) never is.
    static func isItem(_ p: Proto, daysHere: Int, daysInPlace: Int, count: Int) -> Bool {
        guard p.kind == .click else { return false }
        let words = RoutineMiner.tokens(p.label)
        if words.contains(where: { $0.contains(where: \.isNumber) }) || words.count > 4 || p.label.count > 40 { return true }
        if PathIntent.of(label: p.label) != nil { return false }
        if words.count <= 3, daysInPlace >= 2 { return false }
        return daysHere < 2 && count < 3
    }

    static func build(actions: [ActionRecord]) -> PathGraph {
        let ps = protos(actions)
        // Days per (place, page, kind, role, label), per (place, label) and per container: what is always there.
        var labelDays: [String: Set<Int>] = [:], placeDays: [String: Set<Int>] = [:], labelCount: [String: Int] = [:], containerDays: [String: Set<Int>] = [:]
        func lkey(_ p: Proto) -> String { "\(p.place)|\(p.page ?? "")|\(p.kind.rawValue)|\(p.a.role)|\(p.norm)" }
        for case let p? in ps {
            let d = dayNumber(p.a.timestamp)
            labelDays[lkey(p), default: []].insert(d)
            placeDays["\(p.place)|\(p.norm)", default: []].insert(d)
            labelCount[lkey(p), default: 0] += 1
            if let c = p.container, !c.isEmpty { containerDays["\(p.place)|\(c)", default: []].insert(d) }
        }
        func stableContainer(_ p: Proto) -> String? {
            guard let c = p.container, !c.isEmpty, c.count <= 30, !c.contains(where: \.isNumber),
                  RoutineMiner.tokens(c).count <= 3, (containerDays["\(p.place)|\(c)"]?.count ?? 0) >= 2 else { return nil }
            return c
        }

        var g = PathGraph()
        var prev: (key: String, at: Date, bundle: String, item: String, page: String?)?
        var chain: [PathLink] = []
        var lastBundleAt: [String: Date] = [:]
        var titleCache: [String: String] = [:]
        for p in ps {
            guard let p else { prev = nil; chain = []; continue }
            let slot = isItem(p, daysHere: labelDays[lkey(p)]?.count ?? 0, daysInPlace: placeDays["\(p.place)|\(p.norm)"]?.count ?? 0,
                              count: labelCount[lkey(p)] ?? 0)
            let container = stableContainer(p)
            let shortcut = (p.kind == .key || p.kind == .submit || p.kind == .menu) ? p.a.shortcut?.lowercased() : nil
            let key = [p.place, p.page ?? "", p.kind.rawValue, p.a.role, container ?? "", slot ? "…" : p.norm, shortcut ?? ""].joined(separator: "|")
            let at = p.a.timestamp
            // A new visit: another app, or a long pause in this one.
            let newVisit = prev == nil || prev!.bundle != p.a.bundleID || at.timeIntervalSince(lastBundleAt[p.a.bundleID] ?? .distantPast) > visitGap
            if newVisit { g.visits[p.a.bundleID, default: 0] += 1; chain = [] }
            lastBundleAt[p.a.bundleID] = at
            var n = g.nodes[key] ?? PathNode(key: key, place: p.place, bundleID: p.a.bundleID, appName: p.a.appName, page: p.page, isWeb: p.isWeb,
                                            kind: p.kind, role: p.a.role, container: container, label: p.label, isSlot: slot,
                                            shortcut: shortcut, last: at)
            n.count += 1
            n.last = max(n.last, at)
            n.label = p.label
            if newVisit { n.entries += 1 }
            var item = n.items[p.norm] ?? PathItem(label: p.label, words: PathWords.tokens(p.label), count: 0, last: at)
            item.count += 1
            item.last = at
            if item.label != p.label { item.label = p.label; item.words = PathWords.tokens(p.label) }
            item.chain = Array(chain.suffix(maxChain))
            if n.items[p.norm] == nil, n.items.count >= maxItemsPerNode,
               let oldest = n.items.min(by: { $0.value.last < $1.value.last })?.key { n.items[oldest] = nil }
            n.items[p.norm] = item
            g.nodes[key] = n
            if let pv = prev, !newVisit, at.timeIntervalSince(pv.at) <= maxGap, pv.key != key {
                g.edges[pv.key, default: [:]][key, default: 0] += 1
                g.out[pv.key, default: 0] += 1
                // The item clicked last opened this page.
                // (Only what opens pages: a toolbar button pressed before switching tabs opened nothing.)
                if let u = p.url, p.isWeb, p.page != pv.page, let pn = g.nodes[pv.key], pn.kind == .click, pn.isWeb, Self.opensPages.contains(pn.role) {
                    g.nodes[pv.key]?.items[pv.item]?.ledTo = u
                }
            }
            // Pages a run can be sent to: those seen in a browser.
            if let page = p.page, let u = p.url, p.isWeb {
                var urls = g.pages[page] ?? [:]
                let raw = p.a.windowTitle ?? ""
                // A title that names another site's app ("… - Google Docs" on a YouTube URL) is another tab's.
                let title = Self.titleFits(raw, url: u) ? titleCache[raw] ?? { let t = TaskGrounding.cleanTitle(raw) ?? ""; titleCache[raw] = t; return t }() : ""
                var e = urls[u] ?? PathURL(url: u, title: "", words: [], count: 0, last: at)
                e.count += 1
                e.last = at
                if !title.isEmpty { e.titles[title, default: 0] += 1 }
                if urls[u] == nil, urls.count >= maxURLsPerPage, let oldest = urls.min(by: { $0.value.last < $1.value.last })?.key { urls[oldest] = nil }
                urls[u] = e
                g.pages[page] = urls
            }
            chain.append(PathLink(node: key, label: p.label))
            if chain.count > maxChain { chain.removeFirst(chain.count - maxChain) }
            prev = (key, at, p.a.bundleID, p.norm, p.page)
        }
        g.index()
        return g
    }

    /// Lookups: words → items and pages, URL → the item that opened it, each step's kind and shared words.
    mutating func index() {
        var perSite: [String: Int] = [:]
        for (k, var n) in nodes {
            if n.isWeb { perSite[n.place, default: 0] += n.count }
            if !n.isSlot { n.intent = PathIntent.of(label: n.label) }
            if n.items.count >= 3 {
                var df: [String: Int] = [:]
                for it in n.items.values { for t in Set(it.words) { df[t, default: 0] += 1 } }
                n.common = Set(df.filter { Double($0.value) >= Double(n.items.count) * 0.4 }.map(\.key))
            }
            if n.kind == .click {
                for (ik, it) in n.items {
                    for w in Set(it.words) where w.count >= 2 || w.allSatisfy(\.isNumber) { itemIndex[w, default: []].append(PathRef(node: k, item: ik)) }
                    // The item that opened a page most often (then most recently) is how they get there.
                    if let u = it.ledTo, openedBy[u].map({ r in
                        let o = nodes[r.node]?.items[r.item]
                        return (o?.count ?? 0, o?.last ?? .distantPast) < (it.count, it.last)
                    }) ?? true {
                        openedBy[u] = PathRef(node: k, item: ik)
                    }
                }
            }
            nodes[k] = n
        }
        for (page, urls) in pages {
            for (u, var e) in urls {
                // The title seen most with it; one seen once among others is another tab's.
                if let best = e.titles.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }),
                   best.value >= 2 || e.titles.count == 1 { e.title = best.key }
                e.titles = [:]
                e.words = PathWords.tokens(e.title + " " + TaskGrounding.pathWords(u))
                pages[page]?[u] = e
                for w in Set(e.words) where w.count >= 2 || w.allSatisfy(\.isNumber) { pageIndex[w, default: []].append((page, u)) }
            }
        }
        sites = perSite.filter { $0.value >= 3 }.map(\.key).sorted()
    }

    // MARK: Where to look

    struct Scope: Sendable {
        /// Site keys / bundle ids allowed; empty = anywhere.
        var places: Set<String>
        /// The task names this place: nothing else may be offered.
        var strict: Bool

        func allows(site: String?, bundle: String?) -> Bool {
            guard !places.isEmpty else { return true }
            if let site, places.contains(where: { Self.samePlace(site, $0) }) { return true }
            if let bundle, places.contains(bundle) { return true }
            return false
        }

        func allows(_ n: PathNode) -> Bool { allows(site: n.isWeb ? n.place : nil, bundle: n.isWeb ? nil : n.bundleID) }

        /// "canvas.olin.edu" and "olin.edu", "docs.google.com/document" and "docs.google.com" are one place.
        static func samePlace(_ a: String, _ b: String) -> Bool {
            if a == b { return true }
            if a.contains("/") && b.contains("/") { return false }
            let ha = a.split(separator: "/").first.map(String.init) ?? a, hb = b.split(separator: "/").first.map(String.init) ?? b
            return ha == hb || ha.hasSuffix("." + hb) || hb.hasSuffix("." + ha)
        }
    }

    /// The task's places: the ones it names win; the grounded thing's next; else what it implies.
    func scope(named: Set<String>, implied: Set<String>, grounded: String?) -> Scope {
        if !named.isEmpty { return Scope(places: named, strict: true) }
        if let grounded { return Scope(places: Set([grounded]).union(implied), strict: false) }
        return Scope(places: implied, strict: false)
    }

    // MARK: Targets

    struct Target: Sendable {
        enum Kind: String, Sendable { case page, item, kind, intent }
        var kind: Kind
        var page: String?
        /// A concrete page to start on (the target's own page, when known).
        var url: String?
        var node: String?
        var label: String
        /// The label's own words that pick this item out of its siblings.
        var fill: [String]
        var cost: Double
        var what: String
        /// Overrides the plan's source ("thing": the task's own named thing).
        var source: String? = nil
    }

    /// How well `have` carries the task's names: all of them, or "<kind> <number>" as the task
    /// says it ("assignment 3" in "Assignment 3: Numerical Integration") and half the rest.
    static func covers(_ names: Set<String>, task words: Set<String>, have: [String]) -> (ok: Bool, missing: Int) {
        let h = Set(have)
        let hit = names.filter(h.contains)
        let numbers = names.filter { $0.allSatisfy(\.isNumber) }
        // The number sits right after a kind word the task also says ("assignment 3").
        let paired = !numbers.isEmpty && numbers.allSatisfy { n in
            zip(have, have.dropFirst()).contains { $0.1 == n && words.contains($0.0) && PathWords.kindWords.contains($0.0) }
        }
        // A bare number names nothing ("Week 3", "10:03"): only with its kind word.
        if hit.count == names.count { return (numbers.count < names.count || paired, 0) }
        guard paired else { return (false, names.count - hit.count) }
        return (hit.count * 2 >= names.count - 1, names.count - hit.count)
    }

    /// Pages of theirs whose title and URL carry the task's names ("generative ai assignments"
    /// → canvas.olin.edu/courses/1083/assignments, "assignment 3" → that doc).
    func pageTargets(words: Set<String>, scope: Scope) -> [Target] {
        let names = PathWords.specific(words)
        guard !names.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [Target] = []
        for w in names {
            for (pattern, u) in pageIndex[w] ?? [] where seen.insert(u).inserted {
                guard let e = pages[pattern]?[u], scope.allows(site: UserHabits.siteKey(of: u), bundle: nil),
                      scope.strict || !Self.isAssistant(UserHabits.siteKey(of: u) ?? "") else { continue }
                let (ok, missing) = Self.covers(names, task: words, have: e.words)
                guard ok else { continue }
                // Kind words the page also carries ("assignments") make it the page, not a mention.
                let kinds = Set(e.words).intersection(words.subtracting(names)).count
                // Their own page beats walking to an item that names the same thing (it is where that walk ends).
                let cost = 0.1 + 0.3 * Double(missing) - 0.1 * Double(min(kinds, 2)) - 0.05 * log(Double(e.count + 1)) + (scope.places.isEmpty ? 0.5 : 0)
                out.append(Target(kind: .page, page: pattern, url: u, node: nil, label: e.title, fill: [], cost: cost, what: e.title.isEmpty ? pattern : e.title))
            }
        }
        return Array(out.sorted { $0.cost < $1.cost }.prefix(3))
    }

    /// Items they clicked whose label carries the task's names ("joão", "Assignment 03").
    func itemTargets(words: Set<String>, scope: Scope) -> [Target] {
        let names = PathWords.specific(words)
        guard !names.isEmpty else { return [] }
        var seen = Set<PathRef>()
        var out: [Target] = []
        for w in names {
            for ref in itemIndex[w] ?? [] where seen.insert(ref).inserted {
                guard let n = nodes[ref.node], let it = n.items[ref.item], scope.allows(n), scope.strict || !Self.isAssistant(n.place) else { continue }
                var (ok, missing) = Self.covers(names, task: words, have: it.words)
                // A person's first name is enough on a chat row ("joão" → "João Pedro Mendes").
                if !ok, n.role != "link", names.count <= 2, missing < names.count { ok = true }
                guard ok else { continue }
                // Every word of the task the label carries tells it apart ("ku" of "Mikey Ku").
                let hit = words.filter { Set(it.words).contains($0) && !PathWords.kindWords.contains($0) }
                // The conversation named after them beats a group that lists them ("Mikey Ku, …" over "Shanna, …, Mikey, …").
                let inHead = !Set(PathWords.tokens(UserMoves.head(it.label))).isDisjoint(with: hit)
                let cost = 0.7 + 0.4 * Double(missing) - 0.1 * log(Double(it.count + 1)) - 0.15 * Double(min(hit.count, 3))
                    - (inHead ? 0.3 : 0) + (scope.places.isEmpty ? 0.5 : 0)
                out.append(Target(kind: .item, page: n.page, url: it.ledTo, node: n.key, label: it.label,
                                  fill: fill(it, hit: hit, in: n), cost: cost, what: it.label))
            }
        }
        return Array(out.sorted { $0.cost < $1.cost }.prefix(4))
    }

    /// The words that pick `it` out on screen: the task's names it carries, plus — on a short
    /// label — its own words its siblings do not share ("03" of "Assignment 03").
    func fill(_ it: PathItem, hit: Set<String>, in n: PathNode) -> [String] {
        var out = hit
        // A row shown with its preview ("Mikey Ku, she's goated, 12:42 AM") is told apart by its name.
        let head = UserMoves.head(it.label)
        if head.count < it.label.count, PathWords.tokens(head).count <= 4, !hit.isEmpty {
            out.formUnion(PathWords.tokens(head).filter { !n.common.contains($0) && !PathWords.dropped.contains($0) })
        } else if it.words.count <= 6 {
            var own = it.words.filter { !n.common.contains($0) && !PathWords.dropped.contains($0) }
            // A number alone names nothing ("3" is in "Lab 3" too): with the word before it ("assignment 3").
            if !own.isEmpty, own.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
                for (a, b) in zip(it.words, it.words.dropFirst()) where own.contains(b) { own.append(a) }
            }
            out.formUnion(own)
        }
        return out.sorted()
    }

    /// No names, only a kind of page ("my last canvas assignment", "my canvas calendar"): their
    /// newest such page when the task points back, else the list page they open most.
    func pageKindTargets(words: Set<String>, recent: Bool, scope: Scope) -> [Target] {
        guard PathWords.specific(words).isEmpty, !scope.places.isEmpty else { return [] }
        let segs = Set(words.flatMap { PathWords.pageKinds[$0] ?? [] })
        guard !segs.isEmpty else { return [] }
        var out: [Target] = []
        for (pattern, urls) in pages {
            let parts = pattern.split(separator: "/").map(String.init)
            guard let i = parts.firstIndex(where: segs.contains), let site = UserHabits.siteKey(of: "https://" + pattern), scope.allows(site: site, bundle: nil) else { continue }
            // "/assignments/#" is one assignment; "/assignments" the list.
            let isOne = i + 1 < parts.count && parts[i + 1] == "#"
            guard isOne == recent, let best = urls.values.max(by: { recent ? $0.last < $1.last : $0.count < $1.count }) else { continue }
            let cost = 0.9 - (recent ? 0 : 0.05 * log(Double(best.count + 1)))
            out.append(Target(kind: .kind, page: pattern, url: best.url, node: nil, label: best.title, fill: [], cost: cost,
                              what: best.title.isEmpty ? pattern : best.title))
        }
        return Array(out.sorted { a, b in
            recent ? (pages[a.page!]?[a.url!]?.last ?? .distantPast) > (pages[b.page!]?[b.url!]?.last ?? .distantPast) : a.cost < b.cost
        }.prefix(2))
    }

    /// The control they use here for a kind of thing (‘New Note’ ⌘N, ‘Blank document’, ‘Go to Cart’).
    func intentTargets(_ intents: [PathIntent], scope: Scope) -> [Target] {
        guard !intents.isEmpty, !scope.places.isEmpty else { return [] }
        var out: [Target] = []
        for (rank, intent) in intents.enumerated() {
            for n in nodes.values where n.intent == intent && scope.allows(n) {
                // A field named "Compose message" is where they type, not how they start something.
                guard n.kind != .type || intent == .search else { continue }
                let cost = 1.3 + 0.2 * Double(rank) - 0.1 * log(Double(n.count + 1))
                out.append(Target(kind: .intent, page: n.page, url: nil, node: n.key, label: n.label, fill: [], cost: cost, what: n.label))
            }
        }
        return Array(out.sorted { $0.cost < $1.cost }.prefix(4))
    }

    // MARK: Paths

    enum Start: Sendable, Equatable {
        /// The app comes forward (native run).
        case app(String)
        /// A page in the browser (`bundleID`, page pattern).
        case page(String, String)
    }

    /// The most-used way from `start` to one of `targets` (node key → extra cost), within one app.
    func path(from start: Start, to targets: [String: Double], banned: Set<String> = [], maxSteps: Int = maxPathSteps) -> [String]? {
        guard !targets.isEmpty else { return nil }
        let bundle: String
        var dist: [String: Double] = [:]
        switch start {
        case .app(let b):
            bundle = b
            let v = Double(max(1, visits[b] ?? 1))
            for n in nodes.values where n.bundleID == b {
                // Where their visits begin; anywhere else in the app at a price (it may be there already).
                dist[n.key] = n.entries > 0 ? min(4, -log(Double(n.entries) / v)) : 4.5
            }
        case .page(let b, let page):
            bundle = b
            let onPage = nodes.values.filter { $0.page == page }
            let total = Double(max(1, onPage.reduce(0) { $0 + $1.count }))
            for n in onPage where n.bundleID == b { dist[n.key] = min(3, -log(Double(n.count) / total)) }
            // Jumping in elsewhere costs more than walking a few of their steps.
            for k in targets.keys where dist[k] == nil { dist[k] = 8 }
        }
        // A way never starts by sending, nor in the field the task's own text goes into.
        for (k, _) in dist where targets[k] == nil && (banned.contains(k) || nodes[k]?.kind == .submit) { dist[k] = nil }
        var steps: [String: Int] = [:]
        var back: [String: String] = [:]
        var heap = MinHeap()
        for (k, d) in dist { heap.push(d, k); steps[k] = 1 }
        var done = Set<String>()
        var best: (key: String, cost: Double)?
        while let (d, k) = heap.pop() {
            guard !done.contains(k), d <= (dist[k] ?? .infinity) else { continue }
            done.insert(k)
            if let extra = targets[k], best == nil || d + extra < best!.cost { best = (k, d + extra) }
            if let b = best, d > b.cost { break }
            guard (steps[k] ?? 1) < maxSteps, let next = edges[k], let total = out[k], total > 0 else { continue }
            for (to, c) in next {
                guard let tn = nodes[to], tn.bundleID == bundle, targets[to] != nil || !banned.contains(to) else { continue }
                let cost = d - log(Double(c) / Double(total)) + 0.25 + (c == 1 ? 0.7 : 0)
                if cost < (dist[to] ?? .infinity) {
                    dist[to] = cost
                    back[to] = k
                    steps[to] = (steps[k] ?? 1) + 1
                    heap.push(cost, to)
                }
            }
        }
        guard let end = best?.key else { return nil }
        var path = [end]
        while let p = back[path[0]], path.count <= maxSteps { path.insert(p, at: 0) }
        return path
    }

    /// What they usually do right after `key`: typing, sending, the next fixed control (≤ 3 steps).
    func continuation(after key: String, limit: Int = 3) -> [String] {
        var result: [String] = []
        var at = key
        var seen: Set<String> = [key]
        while result.count < limit, let next = edges[at], let total = out[at], total > 0 {
            guard let (to, c) = next.max(by: { $0.value < $1.value }), c >= 2, Double(c) / Double(total) >= 0.35,
                  !seen.contains(to), let n = nodes[to], n.bundleID == nodes[key]?.bundleID, !n.isSlot else { break }
            result.append(to)
            seen.insert(to)
            if n.kind == .submit { break }
            at = to
        }
        return result
    }

    /// The weakest link of a path (how often the user took every step of it, at least).
    func support(_ path: [String]) -> Int {
        guard path.count > 1 else { return nodes[path.first ?? ""]?.count ?? 0 }
        return zip(path, path.dropFirst()).map { edges[$0.0]?[$0.1] ?? 0 }.min() ?? 0
    }

    /// The page their visits to `site` usually begin on.
    func entryPage(site: String) -> String? {
        var count: [String: Int] = [:]
        for n in nodes.values where n.place == site && n.entries > 0 { if let p = n.page { count[p, default: 0] += n.entries } }
        return count.max { $0.value < $1.value }?.key
    }

    /// A page to start a run on: one with no ids in it (a list, a home), their most visited URL of it.
    func startURL(page: String) -> String? {
        // Not a page of ids, nor a search page stripped of its query ("amazon.com/s").
        guard !page.contains("#"), !Self.searchSegments.contains(String(page.split(separator: "/").last ?? "")), let urls = pages[page] else { return nil }
        return urls.values.max { $0.count != $1.count ? $0.count < $1.count : $0.last < $1.last }?.url
    }

    /// The clicks of a chain that took the user to another page on the way to `target` (web only):
    /// how they got there, without what they did on each page meanwhile.
    func navChain(_ chain: [PathLink], to target: PathNode) -> [String] {
        guard target.isWeb else { return [] }
        var out: [String] = []
        let links = chain.filter { nodes[$0.node]?.bundleID == target.bundleID }
        for (i, l) in links.enumerated() {
            guard let n = nodes[l.node], n.kind == .click, n.isWeb, n.place == target.place else { continue }
            let nextPage = i + 1 < links.count ? nodes[links[i + 1].node]?.page : target.page
            if nextPage != n.page, l.node != target.key { out.append(l.node) }
        }
        var seen = Set<String>()
        return Array(out.reversed().filter { seen.insert($0).inserted }.reversed().suffix(Self.maxChain - 1))
    }

    /// "Dashboard → ‘Applied Mathematics…’ → ‘Assignments’ → ‘Assignment 03’": the page changes
    /// that reached `ref` last time, from the page they started on.
    func usualWay(to ref: PathRef) -> [String] {
        guard let n = nodes[ref.node], let it = n.items[ref.item] else { return [] }
        let keys = navChain(it.chain, to: n)
        var out: [String] = []
        if let p = nodes[keys.first ?? ref.node]?.page, let u = startURL(page: p) ?? pages[p]?.values.first?.url {
            out.append(pages[p]?[u]?.title.nonEmpty ?? p)
        }
        for k in keys { if let l = it.chain.last(where: { $0.node == k }) { out.append("‘\(l.label)’") } }
        out.append("‘\(it.label)’")
        return out
    }

    /// A plan to `t`: the start (the deepest page of theirs on the way), the steps, what follows.
    func plan(to t: Target, start: Start?, intents: [PathIntent]) -> PathPlan? {
        switch t.kind {
        case .page, .kind:
            // Their own page: start right there; then the control on it their task needs, if any.
            guard let page = t.page, let u = t.url else { return nil }
            let site = UserHabits.siteKey(of: u)
            let onPage = nodes.values.filter { $0.page == page && $0.isWeb }
            var follow: [String] = []
            if let k = onPage.filter({ !$0.isSlot && $0.intent.map(intents.contains) == true }).max(by: { $0.count < $1.count })?.key {
                follow = [k] + continuation(after: k, limit: 2)
            }
            let steps = follow.compactMap { k in nodes[k].map { step($0, label: nil, fill: nil) } }
            let way = openedBy[u].map(usualWay) ?? []
            let any = onPage.first ?? nodes.values.first { $0.isWeb && $0.place == site }
            return PathPlan(target: "‘\(t.what)’" + (site.map { " (\($0))" } ?? ""), bundleID: any?.bundleID ?? "", appName: any?.appName ?? "",
                            site: site, startURL: u, steps: steps, theirPath: (way.isEmpty ? [t.what] : way) + steps.map(Self.shown),
                            support: max(1, pages[page]?[u]?.count ?? 1), source: t.source ?? t.kind.rawValue)
        case .item, .intent:
            guard let key = t.node, let n = nodes[key] else { return nil }
            let entry = n.isWeb ? entryPage(site: n.place) : nil
            let from: Start = start ?? entry.map { .page(n.bundleID, $0) } ?? .app(n.bundleID)
            let after = continuation(after: key)
            let banned = Set(after.filter { nodes[$0]?.kind == .type || nodes[$0]?.kind == .submit })
            var path = self.path(from: from, to: [key: 0], banned: banned) ?? [key]
            let it = n.items[UserMoves.norm(t.label)]
            if path.count > 1, support(path) < 2 {
                // A way taken once is chance: the pages the chain to this very item went through, else the item alone.
                path = (it.map { navChain($0.chain, to: n) } ?? []) + [key]
            }
            // In an app, an item reached by searching: their search (typing, then Return) comes first.
            if !n.isWeb, path == [key], let ch = it?.chain, ch.count >= 2 {
                let tail = Array(ch.suffix(2))
                if nodes[tail[0].node]?.kind == .type, nodes[tail[1].node]?.kind == .submit, !banned.contains(tail[0].node) {
                    path = tail.map(\.node) + [key]
                }
            }
            var steps: [RoutineStep] = []
            for k in path {
                guard let pn = nodes[k] else { continue }
                if k == key {
                    // A row shown with its preview ("Mikey Ku, see you at 5") is found by its name.
                    let shown = pn.isSlot && pn.role != "link" && UserMoves.head(t.label).count < t.label.count ? UserMoves.head(t.label) : t.label
                    steps.append(step(pn, label: shown.count >= 2 ? shown : t.label, fill: pn.isSlot ? t.fill : nil))
                } else if pn.isSlot {
                    // An item on the way: the one their chain to this target went through, when known.
                    let known = it?.chain.last(where: { $0.node == k })?.label
                    let known_it = known.flatMap { pn.items[UserMoves.norm($0)] }
                    steps.append(step(pn, label: known ?? "…", fill: known_it.map { fill($0, hit: [], in: pn) } ?? []))
                } else {
                    steps.append(step(pn, label: nil, fill: nil))
                }
            }
            for k in after { if let an = nodes[k] { steps.append(step(an, label: nil, fill: nil)) } }
            // A web path starts on the page its first step is on (a URL of theirs with no ids), else the site.
            var startURL: String?
            var human = steps.map(Self.shown)
            if n.isWeb {
                let firstPage = nodes[path[0]]?.page
                startURL = firstPage.flatMap(self.startURL(page:)) ?? entry.flatMap(self.startURL(page:)) ?? "https://" + n.place
                if let p = firstPage, let u = startURL, let title = pages[p]?[u]?.title, !title.isEmpty { human.insert(title, at: 0) }
            }
            let site = n.isWeb ? n.place : nil
            return PathPlan(target: "‘\(t.what)’ (\(site ?? n.appName))", bundleID: n.bundleID, appName: n.appName, site: site,
                            startURL: startURL, steps: steps, theirPath: human,
                            support: max(1, path.count > 1 ? support(path) : (it?.count ?? n.count)), source: t.kind.rawValue)
        }
    }

    /// How a path step reads: a path's item by its own label, "…" only for one it cannot name.
    static func shown(_ s: RoutineStep) -> String { (s.slot ?? "").isEmpty ? s.human : s.plainHuman }

    /// `n` as a step `UserRoute` can find and follow. A slot step carries this run's words for it
    /// (empty: an item the path cannot name — shown, never matched).
    func step(_ n: PathNode, label: String?, fill: [String]?) -> RoutineStep {
        var s = RoutineStep(kind: n.kind, app: n.appName, bundleID: n.bundleID, site: n.isWeb ? n.place : nil, page: n.page,
                            role: n.role, label: label ?? n.label, path: n.container, shortcut: n.shortcut)
        if n.isSlot { s.slot = (fill ?? []).joined(separator: " ") }
        s.seen = n.count
        return s
    }

    /// A kind of control the user has never used in this place, as they use it elsewhere:
    /// labels to look for, never pressed (`PathPlan.pattern`).
    func pattern(_ intents: [PathIntent], scope: Scope) -> PathPlan? {
        for intent in intents {
            var labels: [String: (count: Int, role: String)] = [:]
            for n in nodes.values where n.intent == intent && n.kind != .type && !scope.allows(n) {
                let e = labels[n.label] ?? (0, n.role)
                labels[n.label] = (e.count + n.count, e.role)
            }
            let top = labels.sorted { $0.value.count > $1.value.count }.prefix(3)
            guard let best = top.first else { continue }
            let s = RoutineStep(kind: .click, app: "", bundleID: "", site: nil, page: nil, role: best.value.role, label: best.key, seen: best.value.count)
            return PathPlan(target: "\(intent.rawValue) (as you do it on other sites)", bundleID: "", appName: "", site: nil, startURL: nil,
                            steps: [s], theirPath: top.map { "‘\($0.key)’ \($0.value.count)×" }, support: best.value.count,
                            source: "pattern", pattern: true)
        }
        return nil
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// A binary min-heap of (cost, key).
struct MinHeap {
    private var a: [(Double, String)] = []
    var isEmpty: Bool { a.isEmpty }

    mutating func push(_ d: Double, _ k: String) {
        a.append((d, k))
        var i = a.count - 1
        while i > 0 {
            let p = (i - 1) / 2
            guard a[i].0 < a[p].0 else { break }
            a.swapAt(i, p); i = p
        }
    }

    mutating func pop() -> (Double, String)? {
        guard !a.isEmpty else { return nil }
        let top = a[0]
        let last = a.removeLast()
        if !a.isEmpty {
            a[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < a.count, a[l].0 < a[m].0 { m = l }
                if r < a.count, a[r].0 < a[m].0 { m = r }
                guard m != i else { break }
                a.swapAt(i, m); i = m
            }
        }
        return top
    }
}
