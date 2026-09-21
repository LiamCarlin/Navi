import Foundation
import SwiftUI
import Combine

/// State for the Spotlight-style panel. Owns the query → route → results →
/// perform pipeline. The views (Panel/Views/*) are pure renderers of this.
///
/// Flow on each keystroke:
///   1. `instantResults` (sync, local) update the list immediately.
///   2. After a 120 ms debounce, Jev routes the query; results for the decided
///      intent are merged in, ranked, and the default (⏎) row is chosen.
///   3. ⏎ performs the selected row. Outcomes may stream an answer, start an
///      agent run, replace the list, or ask a follow-up (`.clarify`): the
///      panel shows the question with selectable interpretations and a
///      free-text box; the answer becomes a refined query that is routed
///      again (clarification suppressed) and run.
@MainActor
final class PanelViewModel: ObservableObject {
    // Input
    /// Only real edits re-route: the bar's NSTextField re-commits the same
    /// string whenever it loses focus (e.g. to the clarify text box).
    @Published var query: String = "" { didSet { if query != oldValue { queryChanged() } } }

    // Output
    @Published private(set) var results: [SearchResult] = []
    @Published var selectedIndex: Int = 0
    @Published private(set) var decision: RouteDecision?
    @Published private(set) var mode: Mode = .results
    @Published private(set) var answerText: String = ""
    @Published private(set) var isAnswering = false
    @Published private(set) var agentRun: AgentRunHandle?
    @Published private(set) var agentEvents: [AgentEvent] = []
    /// The task of the current or most recent run (survives `agentRun` ending).
    @Published private(set) var agentTaskTitle: String = ""
    /// True once the user has moved on from a finished run (typed a new query,
    /// performed something else, or pressed ⎋ on the outcome); until then
    /// reopening the panel shows the run again.
    private var agentDismissed = true
    /// A run is live, or finished and not yet dismissed.
    var hasAgentToShow: Bool { agentRun != nil || (!agentDismissed && !agentEvents.isEmpty) }
    @Published private(set) var agentScreenshot: NSImage?
    @Published private(set) var pendingApproval: (id: UUID, description: String, risk: String)?
    @Published private(set) var toast: String?
    @Published private(set) var errorMessage: String?
    // Clarification (mode == .clarify)
    @Published private(set) var clarification: ClarificationPrompt?
    @Published private(set) var isClarifying = false
    /// Free-text answer; typing anything selects the text box (see `clarifySelection`).
    @Published var clarifyAnswer: String = "" {
        didSet { if !clarifyAnswer.isEmpty, let c = clarification { clarifySelection = c.options.count } }
    }
    /// 0..<options.count selects an option; options.count selects the text box.
    @Published var clarifySelection: Int = 0
    @Published private(set) var statusLine: String = ""   // e.g. "Jev · openApp 92% · 140ms"
    @Published private(set) var isRouting = false

    // Panel UI hooks (additive; see Panel/Views/NaviPanelView.swift)
    /// Bumped every time the panel is shown so the view can re-focus the text field.
    @Published private(set) var focusRequestID: Int = 0
    /// Called by the root view whenever its rendered height changes so the
    /// NSPanel can resize/re-center. Set by `PanelController`.
    var onContentHeightChange: ((CGFloat) -> Void)?
    /// Set by `navi://run?q=…`: perform the top row as soon as routing finishes.
    var submitAfterRouting = false
    /// With `submitAfterRouting`, prefer the first row of this kind over row 0
    /// (after a clarification the refined task must win over an incidental app match).
    var submitPreferredKind: ResultKind?

    enum Mode: Equatable { case results, answer, agent, clarify }

    let services: NaviServices
    var onDismiss: (() -> Void)?
    /// The sparkle in the bar was clicked: hand over to voice control (set by `AppDelegate`).
    var onVoiceRequested: (() -> Void)?

    func startVoice() {
        Log.panel.info("voice requested from the bar")
        onVoiceRequested?()
    }

    private var routeTask: Task<Void, Never>?
    private var answerTask: Task<Void, Never>?
    private var agentTask: Task<Void, Never>?
    private var clarifyTask: Task<Void, Never>?
    private var context: QueryContext = .empty
    private var recentQueries: [String] = []

    init(services: NaviServices) {
        self.services = services
    }

    // MARK: - Lifecycle

    func willShow(prefill: String? = nil, context: QueryContext) {
        self.context = context
        // Open the model connections now, while the user is still typing, so the
        // routing call and the agent's first decision skip the TLS handshake.
        services.jev.warm()
        services.claude.warm()
        errorMessage = nil
        toast = nil
        if let prefill { query = prefill } else if !query.isEmpty { query = "" }
        // Reopening while a task runs (or just finished) lands on the task, not an
        // empty search — typing anything switches back to results.
        mode = prefill == nil && hasAgentToShow ? .agent : .results
        focusRequestID &+= 1
    }

    /// Menu bar / overlay entry point: show the panel on the current task.
    func showAgent() {
        guard hasAgentToShow else { return }
        mode = .agent
    }

    /// Ask the view to (re)focus the text field.
    func requestFocus() { focusRequestID &+= 1 }

    /// Dismisses the error banner.
    func clearError() { errorMessage = nil }

    /// Copies the current answer to the pasteboard and shows a toast.
    @discardableResult
    func copyAnswer() -> Bool {
        let text = answerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        showToast("Copied")
        return true
    }

    func reset() {
        routeTask?.cancel(); answerTask?.cancel(); clarifyTask?.cancel()
        query = ""
        results = []
        decision = nil
        answerText = ""
        isAnswering = false
        clearClarification()
        mode = .results
        statusLine = ""
        errorMessage = nil
        // Leave a running (or not-yet-dismissed) agent alone; user may reopen to check on it.
        if agentRun == nil, agentDismissed { agentEvents = []; agentScreenshot = nil; agentTaskTitle = "" }
    }

    // MARK: - Query pipeline

    private func queryChanged() {
        routeTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode != .results && !q.isEmpty { mode = .results }
        guard !q.isEmpty else {
            results = []; decision = nil; statusLine = ""; selectedIndex = 0
            return
        }
        // 1. Instant local results.
        let instant = services.router.instantResults(for: q, context: context)
        results = instant
        selectedIndex = 0

        // 2. Debounced Jev routing.
        routeTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self.isRouting = true
            let d = await self.services.router.route(query: q, context: self.context)
            guard !Task.isCancelled, self.query.trimmingCharacters(in: .whitespacesAndNewlines) == q else { return }
            self.decision = d
            let pct = Int((d.probabilities[d.intent] ?? d.confidence) * 100)
            self.statusLine = d.source == .jev
                ? "Jev · \(d.intent.displayName) \(pct)% · \(d.latencyMs) ms"
                : "\(d.intent.displayName)"
            let full = await self.services.router.results(for: q, decision: d, context: self.context)
            guard !Task.isCancelled, self.query.trimmingCharacters(in: .whitespacesAndNewlines) == q else { return }
            self.results = Self.merge(instant: self.services.router.instantResults(for: q, context: self.context), routed: full, decision: d)
            self.selectedIndex = min(self.selectedIndex, max(0, self.results.count - 1))
            self.isRouting = false
            if self.submitAfterRouting {
                Log.panel.info("submitAfterRouting → \(d.intent.rawValue, privacy: .public), \(self.results.count) rows")
                #if DEBUG
                DebugTrace.log("submitAfterRouting → \(d.intent.rawValue) \(self.results.count) rows")
                #endif
                self.submitAfterRouting = false
                let preferred = self.submitPreferredKind
                self.submitPreferredKind = nil
                self.selectedIndex = preferred.flatMap { k in self.results.firstIndex { $0.kind == k } } ?? 0
                self.performSelected()
            }
        }
    }

    /// Merge rule: if Jev is confident the query is an app/URL/calc match, the
    /// instant rows stay first. Otherwise the routed intent's primary row leads.
    static func merge(instant: [SearchResult], routed: [SearchResult], decision: RouteDecision) -> [SearchResult] {
        var seen = Set<String>()
        var out: [SearchResult] = []
        let instantLeads: Bool = {
            switch decision.intent {
            case .openApp, .openURL, .calculate, .openFile, .systemCommand, .settings: return true
            default: return instant.first.map { $0.score >= 0.9 } ?? false
            }
        }()
        let ordered = instantLeads ? instant + routed : routed + instant
        for r in ordered where !seen.contains(r.id) {
            seen.insert(r.id); out.append(r)
        }
        return out
    }

    // MARK: - Actions

    func moveSelection(_ delta: Int) {
        if mode == .clarify {
            guard let c = clarification else { return }
            let n = c.options.count + 1   // options + the text box
            clarifySelection = (clarifySelection + delta + n) % n
            return
        }
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + results.count) % results.count
    }

    func performSelected() {
        if mode == .clarify { submitClarification(); return }
        guard !results.isEmpty, results.indices.contains(selectedIndex) else {
            // Nothing matched yet: treat ⏎ as "ask Navi".
            if !query.isEmpty { askNavi(query) }
            return
        }
        perform(results[selectedIndex])
    }

    func perform(_ result: SearchResult) {
        Log.panel.info("perform \(result.kind.rawValue, privacy: .public): \(result.title, privacy: .public)")
        #if DEBUG
        DebugTrace.log("perform \(result.kind.rawValue): \(result.title)")
        #endif
        let q = query
        if !q.isEmpty { recentQueries = Array(([q] + recentQueries).prefix(20)) }
        if agentRun == nil { agentDismissed = true }   // moving on from a finished run
        Task { @MainActor in
            let outcome = await result.perform()
            if case .keepOpen = outcome, result.kind == .calculation { showToast("Copied") }
            handle(outcome)
        }
    }

    func handle(_ outcome: ResultOutcome) {
        switch outcome {
        case .dismiss:
            onDismiss?()
        case .keepOpen:
            break
        case .streamAnswer(let stream):
            startAnswer(stream)
        case .runAgent(let handle):
            startAgent(handle)
        case .showResults(let rs):
            results = rs; selectedIndex = 0; mode = .results
        case .clarify(let req):
            startClarification(req)
        case .error(let msg):
            errorMessage = msg
        }
    }

    func askNavi(_ q: String) {
        let hits: [MemoryHit] = []
        startAnswer(services.answers.streamAnswer(query: q, context: context, memory: hits))
    }

    func startAnswer(_ stream: AsyncThrowingStream<String, Error>) {
        answerTask?.cancel()
        answerText = ""
        isAnswering = true
        mode = .answer
        answerTask = Task { [weak self] in
            do {
                for try await chunk in stream {
                    guard let self, !Task.isCancelled else { return }
                    self.answerText += chunk
                }
            } catch is CancellationError {
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            self?.isAnswering = false
        }
    }

    func startAgent(_ handle: AgentRunHandle) {
        agentTask?.cancel()
        agentRun = handle
        agentEvents = []
        agentTaskTitle = handle.task
        agentDismissed = false
        pendingApproval = nil
        mode = .agent
        // Background mode: nothing activates, so the panel would stay over the
        // user's work. Give them a beat to see the run start, then get out of
        // the way — the overlay pill and ⌘Space bring it back (same as the
        // foreground mode, where the driven app stealing key hides the panel).
        if NaviSettings.shared.agentRunInBackground {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(900))
                guard let self, self.agentRun === handle, self.pendingApproval == nil else { return }
                self.onDismiss?()
            }
        }
        agentTask = Task { [weak self] in
            for await ev in handle.events {
                guard let self else { return }
                switch ev {
                case .screenshot(let img): self.agentScreenshot = img
                case .needsApproval(let id, let d, let r): self.pendingApproval = (id, d, r)
                case .completed, .failed, .cancelled:
                    self.agentEvents.append(ev)
                    self.agentRun = nil
                    self.pendingApproval = nil
                    continue
                default: break
                }
                if case .screenshot = ev {} else { self.agentEvents.append(ev) }
            }
        }
    }

    // MARK: - Clarification

    func startClarification(_ req: ClarificationRequest) {
        clarifyTask?.cancel()
        clearClarification()
        isClarifying = true
        mode = .clarify
        clarifyTask = Task { [weak self] in
            do {
                let prompt = try await req.load()
                guard let self, !Task.isCancelled, self.mode == .clarify else { return }
                Log.panel.info("clarification ready: \(prompt.options.count) options")
                #if DEBUG
                DebugTrace.log("clarification ready: \(prompt.question) | \(prompt.options)")
                #endif
                self.clarification = prompt
                self.clarifySelection = 0
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                Log.panel.error("clarification failed: \(error.localizedDescription, privacy: .public)")
                #if DEBUG
                DebugTrace.log("clarification failed: \(error.localizedDescription)")
                #endif
                self.errorMessage = error.localizedDescription
                self.mode = .results
                self.requestFocus()
            }
            self?.isClarifying = false
        }
    }

    /// Runs the chosen interpretation (or the typed answer) as a refined query:
    /// routed once more with clarification suppressed, then performed.
    func submitClarification() {
        guard let c = clarification else { return }
        let refined: String?
        if clarifySelection >= c.options.count {
            refined = c.refinedQuery(typed: clarifyAnswer)
        } else {
            refined = c.refinedQuery(option: clarifySelection)
        }
        guard let refined else { return }
        let intent = decision?.intent ?? .computerTask
        Log.panel.info("clarified (\(intent.rawValue, privacy: .public)) → \(refined, privacy: .public)")
        services.router.didClarify(query: refined, intent: intent)
        clearClarification()
        mode = .results
        submitAfterRouting = true
        submitPreferredKind = intent == .computerTask ? .task : nil
        requestFocus()
        query = refined
    }

    private func clearClarification() {
        clarifyTask?.cancel()
        clarification = nil
        isClarifying = false
        clarifyAnswer = ""
        clarifySelection = 0
    }

    func approvePending(_ approve: Bool) {
        guard let p = pendingApproval, let run = agentRun else { return }
        run.respond(approve ? .approve(p.id) : .deny(p.id))
        pendingApproval = nil
    }

    func cancelAgent() {
        agentRun?.cancel()
    }

    func showToast(_ text: String) {
        toast = text
        Task { try? await Task.sleep(for: .seconds(1.6)); if self.toast == text { self.toast = nil } }
    }

    func escape() {
        if mode != .results {
            answerTask?.cancel()
            isAnswering = false
            if mode == .clarify { clearClarification(); requestFocus() }
            if mode == .agent, agentRun == nil { agentDismissed = true }   // ⎋ on a finished run puts it away
            mode = .results
            return
        }
        onDismiss?()
    }
}

// MARK: - Previews (Panel UI)

#if DEBUG
extension PanelViewModel {
    /// Builds a view model with canned state for SwiftUI previews. Uses the
    /// placeholder services so nothing touches the network.
    static func preview(query: String = "",
                        results: [SearchResult] = [],
                        decision: RouteDecision? = nil,
                        mode: Mode = .results,
                        answer: String = "",
                        isAnswering: Bool = false,
                        agentTask: String? = nil,
                        agentEvents: [AgentEvent] = [],
                        agentScreenshot: NSImage? = nil,
                        pendingApproval: (id: UUID, description: String, risk: String)? = nil,
                        clarification: ClarificationPrompt? = nil,
                        isClarifying: Bool = false,
                        toast: String? = nil,
                        error: String? = nil,
                        statusLine: String? = nil,
                        isRouting: Bool = false,
                        selectedIndex: Int = 0) -> PanelViewModel {
        let jev = JevClient()
        let claude = ClaudeClient()
        let memory = MemoryService(jev: jev, claude: claude)
        let agent = ComputerAgent(jev: jev, claude: claude)
        let router = QueryRouter(jev: jev, claude: claude, memory: memory, agent: agent)
        let services = NaviServices(jev: jev, claude: claude, router: router,
                                    answers: AnswerService(claude: claude), agent: agent, memory: memory)
        let vm = PanelViewModel(services: services)
        vm.query = query
        vm.routeTask?.cancel()          // keep the canned state; no heuristic re-route
        vm.results = results
        vm.selectedIndex = min(selectedIndex, max(0, results.count - 1))
        vm.decision = decision
        vm.mode = mode
        vm.answerText = answer
        vm.isAnswering = isAnswering
        vm.agentEvents = agentEvents
        vm.agentScreenshot = agentScreenshot
        vm.pendingApproval = pendingApproval
        vm.clarification = clarification
        vm.isClarifying = isClarifying
        vm.toast = toast
        vm.errorMessage = error
        vm.isRouting = isRouting
        if let agentTask {
            vm.agentRun = AgentRunHandle(task: agentTask, cancel: {}, respond: { _ in })
        }
        if let statusLine {
            vm.statusLine = statusLine
        } else if let d = decision {
            let pct = Int((d.probabilities[d.intent] ?? d.confidence) * 100)
            vm.statusLine = d.source == .jev ? "Jev · \(d.intent.displayName) \(pct)% · \(d.latencyMs) ms" : d.intent.displayName
        }
        return vm
    }

    /// Sample rows used by the previews.
    static var sampleResults: [SearchResult] {
        func row(_ id: String, _ kind: ResultKind, _ title: String, _ subtitle: String?, _ icon: ResultIcon,
                 hint: String? = nil) -> SearchResult {
            SearchResult(id: id, kind: kind, title: title, subtitle: subtitle, icon: icon, shortcutHint: hint) { .dismiss }
        }
        return [
            row("app:maps", .app, "Maps", "Application", .appBundle("/System/Applications/Maps.app"), hint: "⏎ Open"),
            row("app:mail", .app, "Mail", "Application", .appBundle("/System/Applications/Mail.app"), hint: "⏎ Open"),
            row("calc", .calculation, "= 40.8", "12% of 340", .system("equal"), hint: "⏎ Copy"),
            row("url", .url, "maps.google.com", "Open in browser", .system("globe"), hint: "⏎ Open"),
            row("file", .file, "Q3 roadmap.md", "~/Documents/Notes", .file(NSHomeDirectory()), hint: "⏎ Open"),
            row("web", .webSearch, "Search the web for “maps”", "Google", .system("magnifyingglass")),
            row("mem", .memory, "You read the Jev docs yesterday at 4:12 pm", "Safari · docs.typesafe.ai", .system("clock.arrow.circlepath")),
            row("ask", .answer, "Ask Navi", "Stream an answer from Claude", .system("sparkle"), hint: "⌘⏎ Ask"),
            row("task", .task, "Do it for me", "Open Chrome, search and click", .system("cursorarrow.motionlines")),
            row("sys", .systemCommand, "Toggle Dark Mode", "System", .system("moon.fill")),
        ]
    }

    static var sampleAnswer: String {
        """
        ## DNS in one minute

        **DNS** (Domain Name System) turns names like `api.typesafe.ai` into IP addresses.

        1. Your Mac asks its **resolver** (usually your router or `1.1.1.1`).
        2. The resolver walks the hierarchy: root → `.ai` TLD → the authoritative server.
        3. The answer is cached according to its *TTL*.

        - Records: `A`, `AAAA`, `CNAME`, `MX`, `TXT`
        - Lookups are UDP on port 53, with DoH/DoT for privacy

        ```bash
        dig +short api.typesafe.ai
        ```

        > Tip: `sudo dscacheutil -flushcache` clears the local cache.
        """
    }
}
#endif
