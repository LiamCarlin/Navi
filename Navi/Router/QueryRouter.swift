import Foundation
import AppKit

/// The brain: query → instant local rows → Jev intent → full rows.
///
/// - `instantResults` is synchronous and local (apps, math, URLs, system
///   commands, settings, plus the trailing "Ask Navi" and web-search rows).
/// - `route` makes ONE Jev call (speculative fan-out: intent + is_risky +
///   needs_clarification + wants_memory), time-boxed at 1.2 s, with
///   confidence gating against strong local matches; falls back to keyword
///   heuristics when Jev is not configured or fails.
/// - `results(for:decision:)` builds the rows for the decided intent.
final class QueryRouter: QueryRouting, @unchecked Sendable {
    let jev: JevClient
    let claude: ClaudeClient
    let memory: MemoryServicing
    let agent: ComputerAgentRunning
    let answers: AnswerService
    let appIndex: AppIndex

    static let recentQueriesKey = "navi.recentQueries"
    static let recentQueriesCap = 50
    static let jevTimeoutMs = 1200
    /// `needs_clarification` must be this sure before Navi asks a follow-up.
    /// Deliberately high: a wrong guess on most intents costs one keystroke,
    /// so asking should be rare.
    static let clarifyThreshold = 0.85
    /// Only intents where acting on a wrong guess has a real cost get a
    /// follow-up. Questions, searches and app launches always have an obvious
    /// default reading.
    static let clarifiableIntents: Set<Intent> = [.computerTask]

    /// Speculative answers from the last Jev call that `RouteDecision` has no field for.
    struct JevExtras: Sendable { var wantsMemory: Double; var isRisky: Double }
    private let lock = NSLock()
    private var extras: [String: JevExtras] = [:]
    /// Refined queries from a follow-up → the intent they were clarified for (see `didClarify`).
    private var clarified: [String: Intent] = [:]

    init(jev: JevClient, claude: ClaudeClient, memory: MemoryServicing, agent: ComputerAgentRunning) {
        self.jev = jev; self.claude = claude; self.memory = memory; self.agent = agent
        self.answers = AnswerService(claude: claude)
        self.appIndex = AppIndex.shared
    }

    /// Test seam: inject a fake app index (no filesystem scan).
    init(jev: JevClient, claude: ClaudeClient, memory: MemoryServicing, agent: ComputerAgentRunning, appIndex: AppIndex) {
        self.jev = jev; self.claude = claude; self.memory = memory; self.agent = agent
        self.answers = AnswerService(claude: claude)
        self.appIndex = appIndex
    }

    // MARK: - Instant

    @MainActor
    func instantResults(for query: String, context: QueryContext) -> [SearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var rows: [SearchResult] = []
        if Self.isNaviSettingsQuery(q) { rows.append(Self.settingsRow(score: 1.0)) }
        rows += appIndex.results(for: q, limit: 5)
        rows += Calculator.results(for: q)
        rows += URLAndWeb.results(for: q)
        rows += SystemCommands.results(for: q, context: context)
        rows = Self.orderByKind(rows)
        rows.append(askRow(q, context: context, memory: []))
        rows.append(URLAndWeb.webSearchResult(for: q))
        return recording(rows, query: q)
    }

    /// Keeps rows grouped by kind (each group sorted by score), groups ordered by their best score.
    static func orderByKind(_ rows: [SearchResult]) -> [SearchResult] {
        var groups: [ResultKind: [SearchResult]] = [:]
        var order: [ResultKind] = []
        for r in rows {
            if groups[r.kind] == nil { order.append(r.kind) }
            groups[r.kind, default: []].append(r)
        }
        let sortedKinds = order.sorted { (groups[$0]!.map(\.score).max() ?? 0) > (groups[$1]!.map(\.score).max() ?? 0) }
        return sortedKinds.flatMap { groups[$0]!.sorted { $0.score > $1.score } }
    }

    // MARK: - Routing

    func route(query: String, context: QueryContext) async -> RouteDecision {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var d = await decide(query: q, context: context)
        // A query the user just clarified keeps the intent they clarified it for.
        if let pinned = clarifiedIntent(for: q) {
            d.intent = pinned
            d.needsClarification = false
            d.probabilities[pinned] = max(d.probabilities[pinned] ?? 0, d.confidence)
        }
        return d
    }

    private func decide(query q: String, context: QueryContext) async -> RouteDecision {
        guard !q.isEmpty else { return .heuristic(.webSearch, confidence: 0.3) }
        let local = localSignals(for: q)
        guard jev.isConfigured else { return heuristicRoute(query: q, local: local) }

        let state = Self.jevState(query: q, context: context, local: local, now: context.timestamp)
        let questions = Self.jevQuestions
        let start = Date()
        do {
            let jev = self.jev
            // Metered as `route` under the query's run id (the answer/task that follows shares it).
            let resp = try await CloudRun.$current.withValue(CloudRun(feature: .route, runID: context.runID)) {
                try await Self.withTimeout(ms: Self.jevTimeoutMs) {
                    try await jev.ask(state: state, questions: questions)
                }
            }
            let threshold = await MainActor.run { NaviSettings.shared.jevConfidenceThreshold }
            let latency = resp.latencyMs > 0 ? resp.latencyMs : Int(Date().timeIntervalSince(start) * 1000)
            if let r = Self.decision(from: resp, local: local, threshold: threshold, latencyMs: latency) {
                let (decision, ex) = r
                storeExtras(ex, for: q)
                Log.router.info("jev → \(decision.intent.rawValue) \(Int(decision.confidence * 100))% in \(decision.latencyMs)ms")
                return decision
            }
            Log.router.warning("jev returned no usable intent; falling back to heuristics")
        } catch {
            // The next keystroke superseding this call is routine, not a failure.
            let ns = error as NSError
            let superseded = error is CancellationError
                || (ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled)
                || { if case .cancelled = error as? NaviError { return true }; return false }()
            if !superseded {
                Log.router.warning("jev routing failed (\(error.localizedDescription, privacy: .public)); falling back to heuristics")
            }
        }
        return heuristicRoute(query: q, local: local)
    }

    private func storeExtras(_ ex: JevExtras, for q: String) {
        lock.lock(); defer { lock.unlock() }
        if extras.count > 200 { extras.removeAll() }
        extras[q] = ex
    }

    private func extras(for q: String) -> JevExtras? {
        lock.lock(); defer { lock.unlock() }
        return extras[q]
    }

    func didClarify(query: String, intent: Intent) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock(); defer { lock.unlock() }
        if clarified.count > 200 { clarified.removeAll() }
        clarified[q] = intent
    }

    func clarifiedIntent(for query: String) -> Intent? {
        lock.lock(); defer { lock.unlock() }
        return clarified[query.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    static let jevQuestions: [String: JevClient.Question] = [
        "intent": .choice(instructions: "What does the user want Navi to do?",
                          criteria: Dictionary(uniqueKeysWithValues: Intent.allCases.map { ($0.rawValue, $0.jevCriteria) })),
        "is_risky": .noul(instructions: "Carrying this out would send a message, spend money, delete data, or otherwise be hard to undo"),
        "needs_clarification": .noul(instructions: "The request cannot be carried out at all without more information from the user: there is no reasonable default reading (e.g. 'send it to him' with no recipient or content, 'book that' with nothing to book). Short, casual, or underspecified requests that still have an obvious best interpretation are NOT ambiguous"),
        "wants_memory": .noul(instructions: "Answering well requires knowing what the user was doing or looking at earlier on this computer"),
    ]

    /// Local, deterministic signals passed to Jev as context and used for gating.
    struct LocalSignals: Sendable {
        var bestApp: (name: String, score: Double)?
        var isCalc: Bool
        var isURL: Bool
        var looksLikeFile: Bool
        var systemScore: Double
        var isSettings: Bool
    }

    func localSignals(for query: String) -> LocalSignals {
        let best = appIndex.search(query, limit: 1).first
        return LocalSignals(
            bestApp: best.map { ($0.entry.name, $0.score) },
            isCalc: Calculator.evaluate(query) != nil || Calculator.parseCurrency(query) != nil,
            isURL: URLAndWeb.detect(query) != nil,
            looksLikeFile: FileSearch.looksLikeFile(query),
            systemScore: SystemCommands.matches(query).first?.score ?? 0,
            isSettings: Self.isNaviSettingsQuery(query))
    }

    /// Structured state for Jev (labelled sections, not prose).
    static func jevState(query: String, context: QueryContext, local: LocalSignals,
                         now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = timeZone
        iso.formatOptions = [.withInternetDateTime]
        let appLine: String = {
            let name = context.frontmostAppName ?? "unknown"
            if let b = context.frontmostApp { return "\(name) (\(b))" }
            return name
        }()
        let appMatch = local.bestApp.map { "\($0.name):\(String(format: "%.2f", $0.score))" } ?? "none"
        let recent = context.recentQueries.prefix(5)
        return """
        [QUERY]
        \(query)
        [CONTEXT]
        frontmost_app: \(appLine)
        window_title: \(context.frontmostWindowTitle ?? "")
        time: \(iso.string(from: now))
        local_matches: app=\(appMatch), calc=\(local.isCalc ? "yes" : "no"), url=\(local.isURL ? "yes" : "no"), file=\(local.looksLikeFile ? "yes" : "no")
        recent_queries: \(recent.isEmpty ? "(none)" : recent.joined(separator: " | "))
        """
    }

    /// Maps a Jev response to a decision, applying confidence gating.
    static func decision(from resp: JevClient.Response, local: LocalSignals, threshold: Double,
                         latencyMs: Int) -> (RouteDecision, JevExtras)? {
        guard let ans = resp["intent"], let choice = ans.choice, var intent = Intent(rawValue: choice) else { return nil }
        var probs: [Intent: Double] = [:]
        for (k, v) in ans.probabilities ?? [:] { if let i = Intent(rawValue: k) { probs[i] = v } }
        let confidence = ans.confidence
        // Confidence gating: uncertain Jev + strong local app match → open the app.
        if confidence < threshold, let app = local.bestApp, app.score >= 0.9, intent != .openApp {
            intent = .openApp
        }
        let risky = resp["is_risky"]?.noul ?? 0
        let clarify = resp["needs_clarification"]?.noul ?? 0
        let wantsMemory = resp["wants_memory"]?.noul ?? 0
        let needsClarification = clarify >= clarifyThreshold && clarifiableIntents.contains(intent)
        let d = RouteDecision(intent: intent, confidence: confidence, probabilities: probs,
                              isRisky: risky >= 0.5, needsClarification: needsClarification,
                              latencyMs: latencyMs, source: .jev)
        return (d, JevExtras(wantsMemory: wantsMemory, isRisky: risky))
    }

    static func withTimeout<T: Sendable>(ms: Int, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(for: .milliseconds(ms))
                throw NaviError.other("Jev timed out after \(ms) ms")
            }
            guard let first = try await group.next() else { throw NaviError.cancelled }
            group.cancelAll()
            return first
        }
    }

    // MARK: - Heuristics (no Jev)

    static let questionStarters = ["what", "whats", "what's", "who", "whom", "whose", "when", "where", "why", "how", "is", "are",
                                   "was", "were", "can", "could", "should", "would", "does", "do", "did", "will", "explain",
                                   "define", "tell", "summarize", "summarise", "write", "translate", "compare", "convert",
                                   "give", "list", "describe", "help", "which", "recommend", "suggest", "draft", "rewrite", "fix"]
    static let memoryPatterns = ["yesterday", "earlier", "what was i", "what did i", "was i looking", "was i reading",
                                 "that article", "that site", "that page", "that website", "that pdf", "that doc",
                                 "last week", "this morning", "last night", "an hour ago", "hours ago", "i was working",
                                 "i was reading", "i was looking", "did i read", "did i see", "remember when", "i saw earlier",
                                 "working on yesterday", "the thing i", "what tabs"]
    static let taskVerbs = ["click", "fill", "fill in", "fill out", "send", "book", "type", "scroll", "navigate", "log in",
                            "login", "sign in", "reply", "order", "schedule", "submit", "download", "upload", "post", "tweet",
                            "message", "text", "email", "buy", "purchase", "add to cart", "check out", "search for",
                            "look up", "rename", "move", "delete", "create a", "make a", "set up", "install", "compose"]

    func heuristicRoute(query: String) -> RouteDecision {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return heuristicRoute(query: q, local: localSignals(for: q))
    }

    func heuristicRoute(query: String, local: LocalSignals) -> RouteDecision {
        let q = query.lowercased()
        let words = q.split(whereSeparator: { $0 == " " }).map(String.init)
        let hasQuestionMark = q.hasSuffix("?")

        if local.isSettings { return .heuristic(.settings, confidence: 0.9) }
        if local.isURL { return .heuristic(.openURL, confidence: 0.9) }
        if local.isCalc { return .heuristic(.calculate, confidence: 0.9) }
        if local.systemScore >= 0.75 { return .heuristic(.systemCommand, confidence: 0.85) }
        if Self.memoryPatterns.contains(where: { q.contains($0) }) { return .heuristic(.recallMemory, confidence: 0.8) }

        let multiStep = (q.hasPrefix("open ") && (q.contains(" and ") || q.contains(", "))) || q.contains(" then ")
        let hasTaskVerb = Self.taskVerbs.contains { v in
            q.hasPrefix(v + " ") || q.contains(" " + v + " ") || q.hasSuffix(" " + v)
        }
        if words.count >= 3, multiStep || (hasTaskVerb && !hasQuestionMark && !Self.startsWithQuestion(words)) {
            return .heuristic(.computerTask, confidence: 0.75)
        }
        if let app = local.bestApp, app.score >= 0.85, words.count <= 3 { return .heuristic(.openApp, confidence: 0.9) }
        if local.looksLikeFile { return .heuristic(.openFile, confidence: 0.7) }
        if hasQuestionMark || Self.startsWithQuestion(words) { return .heuristic(.askQuestion, confidence: 0.7) }
        if let app = local.bestApp, app.score >= 0.6, words.count <= 2 { return .heuristic(.openApp, confidence: 0.6) }
        if q.count > 25 { return .heuristic(.askQuestion, confidence: 0.5) }
        return .heuristic(.webSearch, confidence: 0.5)
    }

    static func startsWithQuestion(_ words: [String]) -> Bool {
        guard let first = words.first else { return false }
        if questionStarters.contains(first) { return true }
        if words.count >= 2, ["tell me", "give me", "show me"].contains("\(first) \(words[1])") { return true }
        return false
    }

    // MARK: - Results for a decision

    @MainActor
    func results(for query: String, decision: RouteDecision, context: QueryContext) async -> [SearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var rows: [SearchResult] = []
        let ex = extras(for: q)

        switch decision.intent {
        case .openApp:
            let apps = appIndex.results(for: q, limit: 5)
            rows += apps
            if let best = appIndex.search(q, limit: 1).first, let bid = best.entry.bundleID,
               let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bid }) {
                let name = best.entry.name
                rows.append(SearchResult(id: "app-switch:\(bid)", kind: .app, title: "Switch to \(name)",
                                         subtitle: "Already running · bring its windows forward",
                                         icon: .appBundle(best.entry.path), score: 0.5, shortcutHint: "⏎ Switch") {
                    running.activate(options: [.activateAllWindows])
                    return .dismiss
                })
            }
            if apps.isEmpty { rows.append(URLAndWeb.webSearchResult(for: q, score: 0.3)) }

        case .openFile:
            let files = await FileSearch.results(for: q)
            rows += files
            if files.isEmpty {
                rows.append(SearchResult(id: "file-none:\(q)", kind: .suggestion, title: "No files match “\(FileSearch.cleanQuery(q))”",
                                         subtitle: "Spotlight index · home folder", icon: .system("doc.questionmark"), score: 0.3) { .keepOpen })
            }

        case .openURL, .webSearch:
            rows += URLAndWeb.results(for: q)
            rows.append(URLAndWeb.webSearchResult(for: q, score: decision.intent == .webSearch ? 0.9 : 0.3))

        case .calculate:
            rows += Calculator.results(for: q)
            if let req = Calculator.parseCurrency(q) {
                do {
                    let r = try await Calculator.convertCurrency(req)
                    rows.append(Calculator.result(r))
                } catch {
                    Log.router.warning("currency lookup failed: \(error.localizedDescription)")
                    rows.append(SearchResult(id: "calc-err:\(q)", kind: .calculation, title: "Couldn't fetch exchange rate",
                                             subtitle: error.localizedDescription, icon: .system("wifi.exclamationmark"), score: 0.5) { .keepOpen })
                }
            }

        case .askQuestion:
            var hits: [MemoryHit] = []
            let wantsMemory = (ex?.wantsMemory ?? 0) > 0.5
            if wantsMemory, Self.recallEntitled() { hits = await memory.search(query: q, limit: 6) }
            rows.append(askRow(q, context: context, memory: hits, score: 0.95))
            // Recall gate: the question leans on screen memory the plan doesn't include.
            if wantsMemory, !Self.recallEntitled() { rows.append(Self.unlockRecallRow(score: 0.9)) }
            rows.append(URLAndWeb.webSearchResult(for: q, score: 0.2))

        case .computerTask:
            let mode = NaviSettings.shared.agentApprovalMode.label
            let agent = self.agent
            agent.prepare(task: q, context: context)   // speculative: surface classification before ⏎
            let riskNote = decision.isRisky ? " · may be hard to undo" : ""
            rows.append(SearchResult(id: "task:\(q)", kind: .task, title: "Do it: \(q)",
                                     subtitle: "Navi will control your Mac · \(mode)\(riskNote)",
                                     icon: .system("cursorarrow.motionlines"), score: 0.95, shortcutHint: "⏎ Run") {
                .runAgent(agent.run(task: q, context: context))
            })

        case .recallMemory:
            // Recall gate (account workstream): without the entitlement the only row is the upsell.
            guard Self.recallEntitled() else {
                rows.append(Self.unlockRecallRow(score: 1.0))
                break
            }
            let hits = await memory.search(query: q, limit: 8)
            rows.append(SearchResult(id: "ask-memory:\(q)", kind: .answer, title: "Ask about this: \(q)",
                                     subtitle: hits.isEmpty ? "No matching screen memories" : "Answer using \(hits.count) matching moment\(hits.count == 1 ? "" : "s")",
                                     icon: .system("clock.badge.questionmark"), score: 0.95, shortcutHint: "⏎ Ask") { [answers] in
                .streamAnswer(answers.streamAnswer(query: q, context: context, memory: hits))
            })
            rows += hits.enumerated().map { (i, h) in Self.memoryRow(h, score: 0.9 - Double(i) * 0.02) }
            if hits.isEmpty {
                rows.append(SearchResult(id: "memory-empty", kind: .suggestion, title: "Screen memory is empty or off",
                                         subtitle: "Enable Memory in Navi settings to recall what you were doing",
                                         icon: .system("clock.arrow.circlepath"), score: 0.4, shortcutHint: "⏎ Settings") {
                    AppDelegate.shared?.openMainWindow(); return .dismiss
                })
            }

        case .systemCommand:
            rows += SystemCommands.results(for: q, context: context)

        case .settings:
            rows.append(Self.settingsRow(score: 1.0))
        }

        // Extra file rows when the query looks like a filename but wasn't routed there.
        if decision.intent != .openFile, FileSearch.looksLikeFile(q) {
            rows += (await FileSearch.results(for: q, limit: 4)).map { r in var r = r; r.score = min(r.score, 0.45); return r }
        }
        if decision.needsClarification {
            let answers = self.answers
            rows.insert(SearchResult(id: "clarify:\(q)", kind: .answer, title: "Clarify: \(q)",
                                     subtitle: "Navi needs one detail first — pick an interpretation or type one",
                                     icon: .system("questionmark.bubble"), score: 1.0, shortcutHint: "⏎ Clarify") {
                .clarify(ClarificationRequest(originalQuery: q) {
                    try await answers.clarification(query: q, context: context)
                })
            }, at: 0)
        }
        return recording(rows, query: q)
    }

    // MARK: - Row builders

    // MARK: - Recall gate (account workstream)

    /// Whether screen memory may be searched. Seam for tests; the app reads the account.
    @MainActor static var recallEntitled: () -> Bool = { NaviAccount.shared.entitlements.recall }

    /// The one row shown when a memory question lands on a plan without Recall.
    @MainActor static func unlockRecallRow(score: Double) -> SearchResult {
        let signedIn = NaviAccount.shared.isSignedIn
        return SearchResult(id: "unlock-recall", kind: .suggestion, title: "Unlock Recall",
                            subtitle: signedIn ? "Navi remembers your screen so you can ask about it · Add Recall"
                                               : "Sign in to Navi to add Recall",
                            icon: .system("clock.arrow.circlepath"), score: score,
                            shortcutHint: signedIn ? "⏎ Add Recall" : "⏎ Sign in") {
            if NaviAccount.shared.isSignedIn { NaviAccount.shared.openCheckout(plan: .proRecall, interval: .month) }
            else { NaviAccount.shared.signIn() }
            return .dismiss
        }
    }

    func askRow(_ q: String, context: QueryContext, memory: [MemoryHit], score: Double = 0.05) -> SearchResult {
        let answers = self.answers
        let subtitle = memory.isEmpty ? (claude.isConfigured ? "Answer with Claude" : "Sign in to Navi to ask")
                                      : "Answer using \(memory.count) moment\(memory.count == 1 ? "" : "s") from screen memory"
        return SearchResult(id: "ask:\(q)", kind: .answer, title: "Ask Navi: \(q)", subtitle: subtitle,
                            icon: .system("sparkle"), score: score, shortcutHint: "⏎ Ask") {
            .streamAnswer(answers.streamAnswer(query: q, context: context, memory: memory))
        }
    }

    static func settingsRow(score: Double) -> SearchResult {
        SearchResult(id: "settings:navi", kind: .settings, title: "Navi Settings",
                     subtitle: "Hotkey, AI providers, memory, permissions", icon: .system("gearshape"),
                     score: score, shortcutHint: "⏎ Open") {
            AppDelegate.shared?.openMainWindow()
            return .dismiss
        }
    }

    static func memoryRow(_ h: MemoryHit, score: Double) -> SearchResult {
        let rel = RelativeDateTimeFormatter(); rel.unitsStyle = .short
        let head = h.snippet.split(separator: "\n").first.map(String.init) ?? h.snippet
        let title = head.count > 90 ? String(head.prefix(90)) + "…" : head
        var subtitle = "\(h.appName) · \(rel.localizedString(for: h.timestamp, relativeTo: Date()))"
        if let t = h.windowTitle, !t.isEmpty { subtitle += " · \(t.prefix(60))" }
        let icon: ResultIcon = h.thumbnailPath.map { .file($0) } ?? .system("clock.arrow.circlepath")
        let url = h.url.flatMap(URL.init(string:))
        let thumb = h.thumbnailPath
        return SearchResult(id: "memory:\(h.id)", kind: .memory, title: title.isEmpty ? h.appName : title, subtitle: subtitle,
                            icon: icon, score: score, shortcutHint: url != nil ? "⏎ Open link" : (thumb != nil ? "⏎ View" : nil)) {
            if let url { NSWorkspace.shared.open(url); return .dismiss }
            if let thumb, FileManager.default.fileExists(atPath: thumb) { NSWorkspace.shared.open(URL(fileURLWithPath: thumb)); return .dismiss }
            return .keepOpen
        }
    }

    // MARK: - Settings query / recents

    static func isNaviSettingsQuery(_ query: String) -> Bool {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard q.contains("navi") else { return false }
        let keys = ["settings", "setting", "preferences", "prefs", "options", "hotkey", "shortcut", "api key", "keys",
                    "config", "configure", "permissions", "providers", "memory"]
        return keys.contains { q.contains($0) }
    }

    static func recentQueries() -> [String] {
        UserDefaults.standard.stringArray(forKey: recentQueriesKey) ?? []
    }

    static func recordQuery(_ q: String) {
        var list = recentQueries().filter { $0 != q }
        list.insert(q, at: 0)
        if list.count > recentQueriesCap { list = Array(list.prefix(recentQueriesCap)) }
        UserDefaults.standard.set(list, forKey: recentQueriesKey)
    }

    /// Wraps each row's `perform` so the query is remembered when the row is used.
    private func recording(_ rows: [SearchResult], query: String) -> [SearchResult] {
        rows.map { row in
            var r = row
            let inner = row.perform
            r.perform = {
                QueryRouter.recordQuery(query)
                return await inner()
            }
            return r
        }
    }
}
