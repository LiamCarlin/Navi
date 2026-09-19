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
///      agent run, or replace the list.
@MainActor
final class PanelViewModel: ObservableObject {
    // Input
    @Published var query: String = "" { didSet { queryChanged() } }

    // Output
    @Published private(set) var results: [SearchResult] = []
    @Published var selectedIndex: Int = 0
    @Published private(set) var decision: RouteDecision?
    @Published private(set) var mode: Mode = .results
    @Published private(set) var answerText: String = ""
    @Published private(set) var isAnswering = false
    @Published private(set) var agentRun: AgentRunHandle?
    @Published private(set) var agentEvents: [AgentEvent] = []
    @Published private(set) var agentScreenshot: NSImage?
    @Published private(set) var pendingApproval: (id: UUID, description: String, risk: String)?
    @Published private(set) var toast: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusLine: String = ""   // e.g. "Jev · openApp 92% · 140ms"
    @Published private(set) var isRouting = false

    enum Mode: Equatable { case results, answer, agent }

    let services: NaviServices
    var onDismiss: (() -> Void)?

    private var routeTask: Task<Void, Never>?
    private var answerTask: Task<Void, Never>?
    private var agentTask: Task<Void, Never>?
    private var context: QueryContext = .empty
    private var recentQueries: [String] = []

    init(services: NaviServices) {
        self.services = services
    }

    // MARK: - Lifecycle

    func willShow(prefill: String? = nil, context: QueryContext) {
        self.context = context
        errorMessage = nil
        toast = nil
        if let prefill { query = prefill } else if !query.isEmpty { query = "" }
        mode = .results
    }

    func reset() {
        routeTask?.cancel(); answerTask?.cancel()
        query = ""
        results = []
        decision = nil
        answerText = ""
        isAnswering = false
        mode = .results
        statusLine = ""
        errorMessage = nil
        // Leave a running agent alone; user may reopen to check on it.
        if agentRun == nil { agentEvents = []; agentScreenshot = nil }
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
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + results.count) % results.count
    }

    func performSelected() {
        guard !results.isEmpty, results.indices.contains(selectedIndex) else {
            // Nothing matched yet: treat ⏎ as "ask Navi".
            if !query.isEmpty { askNavi(query) }
            return
        }
        perform(results[selectedIndex])
    }

    func perform(_ result: SearchResult) {
        let q = query
        if !q.isEmpty { recentQueries = Array(([q] + recentQueries).prefix(20)) }
        Task { @MainActor in
            let outcome = await result.perform()
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
        pendingApproval = nil
        mode = .agent
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
            mode = .results
            return
        }
        onDismiss?()
    }
}
