import Foundation
import AppKit

/// The brain: query → instant local rows → Jev intent → full rows.
///
/// - `instantResults` is synchronous and local (apps, math, URLs, system
///   commands, settings, plus the trailing "Ask Navi" and web-search rows).
/// - `route` makes ONE Jev call (speculative fan-out: intent + is_risky +
///   needs_clarification + wants_memory + wants_to_schedule + wants_reminder), time-boxed at 1.2 s, with
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
    struct JevExtras: Sendable {
        var wantsMemory: Double
        var isRisky: Double
        var wantsSchedule: Double = 0
        var wantsReminder: Double = 0
    }
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
        if let browser = Self.browserControlRow(for: q, context: context) { rows.insert(browser, at: 0) }
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

    func scheduleLikelihood(for query: String) -> Double? {
        extras(for: query.trimmingCharacters(in: .whitespacesAndNewlines))?.wantsSchedule
    }

    func reminderLikelihood(for query: String) -> Double? {
        extras(for: query.trimmingCharacters(in: .whitespacesAndNewlines))?.wantsReminder
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
        "wants_to_schedule": .noul(instructions: "The user wants to put something on their calendar: a meeting, call, meal or block of time, with people or at a time"),
        "wants_reminder": .noul(instructions: "The user wants to be reminded of something later or to add a to-do item (not a calendar event with other people)"),
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
        return (d, JevExtras(wantsMemory: wantsMemory, isRisky: risky,
                             wantsSchedule: resp["wants_to_schedule"]?.noul ?? 0,
                             wantsReminder: resp["wants_reminder"]?.noul ?? 0))
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
            // "open youtube", "open canvas": a web app the user means when no installed app
            // really matches (a loose subsequence match is no app name).
            if (appIndex.search(q, limit: 1).first?.score ?? 0) < Self.strongAppScore, let web = Self.webAppRow(for: q) {
                rows.append(web)
            }
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
            // "use the calculator to do 1200 / 16": the user asked for the app, not an inline sum.
            if let app = Self.namesAppToUse(q) {
                rows.append(taskRow(q, context: context, id: "app-task:\(q)", title: "Do it in \(app.name): \(q)",
                                    risky: false, score: 1.0))
            }
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
            rows.append(taskRow(q, context: context, risky: decision.isRisky))

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
                var ctx = context
                ctx.memorySearched = true
                return .streamAnswer(answers.streamAnswer(query: q, context: ctx, memory: hits))
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
        // "go back", "reload", "close this tab" with a browser in front: one key press there.
        if let browser = Self.browserControlRow(for: q, context: context) { rows.insert(browser, at: 0) }
        // "Open the last assignment I did", "pull up the doc I was working on": the user's own
        // past work, which the agent finds in screen memory (`TaskGrounding`) and opens —
        // whatever intent the words read as ("that pdf from yesterday" looks like a file search).
        let reopen = decision.intent != .computerTask && UserKnowledge.current != nil
            && Self.reopensOwnWork(q, intent: decision.intent)
        // "open the hci notes": a document or project of the user's (`UserKnowledge`) is what they
        // mean over a Spotlight file that shares a word (file rows score <= 0.7) — unless they named
        // an installed app or a web app.
        if Self.thingIntents.contains(decision.intent),
           !rows.contains(where: { ($0.kind == .app && $0.score >= Self.strongAppScore) || $0.id.hasPrefix("webapp:") }),
           let thing = await Self.ownThingRow(for: q) {
            rows.insert(thing, at: 0)
        }
        // The routed action found nothing to do it with ("open youtube" with no YouTube app,
        // "go to next week" read as date math, "show me the files changed" read as a file search):
        // the named web app's page, else a question back for "open it", else a task — never the
        // text answer, which can only say it can't open anything.
        if Self.actionIntents.contains(decision.intent), !reopen, !rows.contains(where: { !Self.isFallbackRow($0) }) {
            rows.insert(contentsOf: actionFallbackRows(q, context: context), at: 0)
        }
        // The "Open it" row leads (`PanelViewModel.merge` pins it): ⏎ opens it instead of answering about it.
        if reopen {
            let agent = self.agent
            agent.prepare(task: q, context: context)
            rows.insert(SearchResult(id: "open-it:\(q)", kind: .task, title: "Open it: \(q)",
                                     subtitle: "From your screen memory · Navi finds it and opens it",
                                     icon: .system("clock.arrow.circlepath"), score: 0.97, shortcutHint: "⏎ Open") {
                .runAgent(agent.run(task: q, context: context))
            }, at: 0)
        }
        if decision.needsClarification, !rows.contains(where: { $0.id.hasPrefix("clarify:") }) {
            rows.insert(clarifyRow(q, context: context), at: 0)
        }
        return recording(rows, query: q)
    }

    // MARK: - Action rows: ⏎ does what Jev routed (taskbench overnight-20261101)
    //
    // Every query also carries "Ask Navi" and a web search. When the routed intent was an
    // action but produced no row for it, those were all that was left and ⏎ answered
    // "I can't open apps" (web-001 "open youtube", schoolwork-001 "open canvas", memory-005…).

    /// Intents whose rows are actions: ⏎ performs one of them, never the answer row.
    static let actionIntents: Set<Intent> = [.openApp, .openURL, .openFile, .systemCommand, .calculate, .settings]
    /// Intents where the words may name one of the user's own documents or projects.
    static let thingIntents: Set<Intent> = [.openApp, .openURL, .openFile]
    /// An app match at least this good is the app the user named (word start / acronym and up).
    static let strongAppScore = 0.85

    /// Rows that carry out nothing the query asked for: "Ask Navi", the web search,
    /// "No files match", "Screen memory is empty".
    static func isFallbackRow(_ r: SearchResult) -> Bool {
        r.id.hasPrefix("ask:") || r.kind == .webSearch || r.id.hasPrefix("file-none:") || r.id == "memory-empty"
    }

    /// Rows that lead whatever the intent (`PanelViewModel.merge`): reopening the user's own
    /// work, a browser key press, the task in the app the query names.
    static func isPinnedRow(_ r: SearchResult) -> Bool {
        r.id.hasPrefix("open-it:") || r.id.hasPrefix("browser:") || r.id.hasPrefix("app-task:")
    }

    /// What an action intent falls back to when it found nothing to act with.
    enum FallbackAction: Equatable, Sendable {
        /// A web app the query names: open its page ("open youtube" → youtube.com).
        case openWebApp
        /// "open it" with nothing selected: ask what "it" is.
        case clarify
        /// Anything else said as an instruction: the computer-use agent does it.
        case task
        /// A question: the answer row is the right default.
        case keepAnswer
    }

    static func fallbackAction(for query: String, hasSelection: Bool) -> FallbackAction {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .keepAnswer }
        if let s = AppSkills.mentioned(in: q), !s.hosts.isEmpty { return .openWebApp }
        if pointsAtScreenOnly(q) { return hasSelection ? .task : .clarify }
        if looksLikeQuestion(q) { return .keepAnswer }
        return .task
    }

    /// "open it", "open that", "show me this": the only object is a pronoun.
    static func pointsAtScreenOnly(_ q: String) -> Bool {
        let verbs: Set<String> = ["open", "launch", "start", "run", "show", "me", "pull", "bring", "up", "go", "to", "switch",
                                  "do", "please", "can", "you", "the"]
        let words = q.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        let rest = words.drop(while: { verbs.contains($0) }).filter { $0 != "please" }
        let pointers: Set<String> = ["it", "this", "that", "them", "these", "those", "one", "here", "there"]
        return !rest.isEmpty && rest.allSatisfy { pointers.contains($0) }
    }

    /// Asked, not instructed: "what…", "when is…", "how do…", or a question mark.
    static func looksLikeQuestion(_ q: String) -> Bool {
        let lower = q.lowercased().trimmingCharacters(in: .whitespaces)
        if lower.hasSuffix("?") { return true }
        let first = lower.split(whereSeparator: { $0 == " " }).first.map(String.init) ?? ""
        return ["what", "whats", "what's", "who", "whom", "whose", "when", "where", "why", "how", "is", "are", "was", "were",
                "can", "could", "should", "would", "does", "did", "will", "which", "explain", "define"].contains(first)
    }

    /// "use the calculator to do 1200 / 16", "2+2 in calculator": a native app the query asks
    /// to do it in (named after "use / in / on / with / open"), not just mentioned.
    static func namesAppToUse(_ query: String) -> AppSkill? {
        let lower = query.lowercased()
        guard let s = AppSkills.mentioned(in: lower), s.hosts.isEmpty, !s.bundleIDs.isEmpty else { return nil }
        let names = ([s.name] + s.aliases).map { NSRegularExpression.escapedPattern(for: $0.lowercased()) }.joined(separator: "|")
        let pattern = #"\b(?:use|using|with|in|on|into|open|launch)\s+(?:the\s+|my\s+)?(?:"# + names + #")(?:\s+app)?\b"#
        return lower.range(of: pattern, options: .regularExpression) != nil ? s : nil
    }

    /// "Open the last assignment I did" (explicit), or "the doc I was working on yesterday" —
    /// no verb, but Jev read it as something to open.
    static func reopensOwnWork(_ q: String, intent: Intent) -> Bool {
        if TaskGrounding.reopensOwnWork(q, possessive: false) { return true }
        guard thingIntents.contains(intent) else { return false }
        let first = q.lowercased().split(separator: " ").first.map(String.init) ?? ""
        return ["the", "that", "this", "my", "last", "yesterday's", "today's"].contains(first)
            && TaskGrounding.reopensOwnWork("open " + q, possessive: false)
    }

    @MainActor
    func actionFallbackRows(_ q: String, context: QueryContext) -> [SearchResult] {
        let hasSelection = !(context.selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch Self.fallbackAction(for: q, hasSelection: hasSelection) {
        case .openWebApp:
            if let row = Self.webAppRow(for: q) { return [row] }
            return [taskRow(q, context: context, risky: false, score: 0.9)]
        case .clarify: return [clarifyRow(q, context: context)]
        case .task: return [taskRow(q, context: context, risky: false, score: 0.9)]
        case .keepAnswer: return []
        }
    }

    /// The page of the web app a query names, on the user's own host for it
    /// ("open canvas" → canvas.olin.edu, `UserHabits.personalize`).
    @MainActor
    static func webAppRow(for q: String) -> SearchResult? {
        guard let skill = AppSkills.mentioned(in: q), !skill.hosts.isEmpty, let raw = AppSkills.startURL(for: q) else { return nil }
        let link = UserHabits.current?.cachedProfile().map { UserHabits.personalize(raw, profile: $0) } ?? raw
        guard let url = URL(string: link), url.scheme?.hasPrefix("http") == true else { return nil }
        return SearchResult(id: "webapp:\(link)", kind: .url, title: "Open \(skill.name)", subtitle: link,
                            icon: .system("safari"), score: 0.97, shortcutHint: "⏎ Open") {
            NSWorkspace.shared.open(url)
            return .dismiss
        }
    }

    /// A document or project of the user's the query names, by its page ("open the hci notes" →
    /// the HCI doc, `UserKnowledge.startURL`). nil without screen memory (and under tests).
    static func ownThingRow(for q: String) async -> SearchResult? {
        guard UserKnowledge.current != nil else { return nil }
        let link = await Task.detached(priority: .userInitiated) { UserKnowledge.liveStartURL(for: q) }.value
        guard let link, let url = URL(string: link), url.scheme?.hasPrefix("http") == true else { return nil }
        let name = AppIndex.normalize(q)
        return SearchResult(id: "thing:\(link)", kind: .url, title: "Open “\(name.isEmpty ? q : name)”",
                            subtitle: "From your work · \(url.host ?? link)", icon: .system("doc.richtext"),
                            score: 0.96, shortcutHint: "⏎ Open") {
            NSWorkspace.shared.open(url)
            return .dismiss
        }
    }

    /// "go back", "reload", "close this tab" with a browser in front (`BrowserControls`).
    @MainActor
    static func browserControlRow(for q: String, context: QueryContext) -> SearchResult? {
        guard let front = context.frontmostApp, AXSnapshotter.isBrowser(front), let cmd = BrowserControls.match(q) else { return nil }
        return SearchResult(id: "browser:\(cmd.title)", kind: .systemCommand, title: cmd.title,
                            subtitle: "In \(context.frontmostAppName ?? "the browser")", icon: .system("safari"),
                            score: 0.99, shortcutHint: "⏎ Run") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))   // the panel closes first
                _ = await BrowserControls.perform(cmd, input: InputController())
            }
            return .dismiss
        }
    }

    @MainActor
    func taskRow(_ q: String, context: QueryContext, id: String? = nil, title: String? = nil,
                 risky: Bool, score: Double = 0.95) -> SearchResult {
        let mode = NaviSettings.shared.agentApprovalMode.label
        let agent = self.agent
        agent.prepare(task: q, context: context)   // speculative: surface classification before ⏎
        let riskNote = risky ? " · may be hard to undo" : ""
        return SearchResult(id: id ?? "task:\(q)", kind: .task, title: title ?? "Do it: \(q)",
                            subtitle: "Navi will control your Mac · \(mode)\(riskNote)",
                            icon: .system("cursorarrow.motionlines"), score: score, shortcutHint: "⏎ Run") {
            .runAgent(agent.run(task: q, context: context))
        }
    }

    func clarifyRow(_ q: String, context: QueryContext) -> SearchResult {
        let answers = self.answers
        return SearchResult(id: "clarify:\(q)", kind: .answer, title: "Clarify: \(q)",
                            subtitle: "Navi needs one detail first — pick an interpretation or type one",
                            icon: .system("questionmark.bubble"), score: 1.0, shortcutHint: "⏎ Clarify") {
            .clarify(ClarificationRequest(originalQuery: q) {
                try await answers.clarification(query: q, context: context)
            })
        }
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
        let subtitle = memory.isEmpty ? (claude.isConfigured ? "Answer this question" : "Sign in to Navi to ask")
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
        UserDefaults.navi.stringArray(forKey: recentQueriesKey) ?? []
    }

    static func recordQuery(_ q: String) {
        var list = recentQueries().filter { $0 != q }
        list.insert(q, at: 0)
        if list.count > recentQueriesCap { list = Array(list.prefix(recentQueriesCap)) }
        UserDefaults.navi.set(list, forKey: recentQueriesKey)
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
