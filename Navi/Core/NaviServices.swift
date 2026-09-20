import Foundation

// MARK: - Service protocols
//
// Each subsystem implements one of these. `NaviServices.bootstrap()` wires the
// concrete types together; the panel and settings only talk to the protocols.

/// Turns a raw query into a routing decision and a ranked list of results.
protocol QueryRouting: AnyObject, Sendable {
    /// Cheap, synchronous, no-network results (installed apps, URLs, math).
    /// Called on every keystroke; must return in < 5 ms.
    @MainActor func instantResults(for query: String, context: QueryContext) -> [SearchResult]

    /// Jev-backed intent decision (speculative fan-out, ~100–300 ms).
    func route(query: String, context: QueryContext) async -> RouteDecision

    /// Full results for a decided intent (may hit Spotlight index, memory, etc.).
    @MainActor func results(for query: String, decision: RouteDecision, context: QueryContext) async -> [SearchResult]
}

/// Streams a text answer for a question (Claude).
protocol AnswerProviding: AnyObject, Sendable {
    func streamAnswer(query: String, context: QueryContext, memory: [MemoryHit]) -> AsyncThrowingStream<String, Error>
}

/// Runs a multi-step computer-use task.
protocol ComputerAgentRunning: AnyObject, Sendable {
    @MainActor func run(task: String, context: QueryContext) -> AgentRunHandle
    /// Optional: the router calls this as soon as a query routes to a computer
    /// task, before the user presses ⏎, so the agent can do speculative work
    /// (classify the task surface, warm connections) off the critical path.
    @MainActor func prepare(task: String, context: QueryContext)
}

extension ComputerAgentRunning {
    @MainActor func prepare(task: String, context: QueryContext) {}
}

/// Background screen-memory: capture → OCR → digest → Obsidian vault.
protocol MemoryServicing: AnyObject, Sendable {
    @MainActor func start()
    @MainActor func stop()
    @MainActor var status: MemoryStatus { get }
    func search(query: String, limit: Int) async -> [MemoryHit]
    /// Runs a digest pass immediately (used by Settings → "Digest now").
    func digestNow() async
}

struct MemoryStatus: Sendable, Equatable {
    var isRunning: Bool = false
    var framesToday: Int = 0
    var lastCaptureAt: Date? = nil
    var lastDigestAt: Date? = nil
    var vaultNoteCount: Int = 0
    var lastError: String? = nil
}

// MARK: - Container

final class NaviServices: @unchecked Sendable {
    let jev: JevClient
    let claude: ClaudeClient
    let router: QueryRouting
    let answers: AnswerProviding
    let agent: ComputerAgentRunning
    let memory: MemoryServicing

    init(jev: JevClient, claude: ClaudeClient, router: QueryRouting, answers: AnswerProviding,
         agent: ComputerAgentRunning, memory: MemoryServicing) {
        self.jev = jev; self.claude = claude; self.router = router
        self.answers = answers; self.agent = agent; self.memory = memory
    }

    /// Production wiring. Concrete types live in their own modules:
    ///   Providers/JevClient.swift, Providers/ClaudeClient.swift,
    ///   Router/QueryRouter.swift, Agent/ComputerAgent.swift, Memory/MemoryService.swift
    @MainActor
    static func bootstrap() -> NaviServices {
        let jev = JevClient()
        let claude = ClaudeClient()
        let memory = MemoryService(jev: jev, claude: claude)
        let agent = ComputerAgent(jev: jev, claude: claude)
        // Browser tasks run on browser-use/jev-ultrafast (vendored) via the Python bridge.
        ComputerAgent.browserRunner = { task, startURL, handle in
            let maxSteps = UserDefaults.standard.integer(forKey: "agentMaxSteps")
            let shots = UserDefaults.standard.bool(forKey: "ultrafastScreenshots")
            await UltrafastBridge.run(task: task, startURL: startURL, handle: handle, maxSteps: maxSteps, screenshots: shots)
        }
        let router = QueryRouter(jev: jev, claude: claude, memory: memory, agent: agent)
        let answers = AnswerService(claude: claude)
        return NaviServices(jev: jev, claude: claude, router: router, answers: answers, agent: agent, memory: memory)
    }

    @MainActor
    func startBackgroundServices() {
        if NaviSettings.shared.memoryCaptureEnabled { memory.start() }
        NotificationCenter.default.addObserver(forName: .naviSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                if NaviSettings.shared.memoryCaptureEnabled { self.memory.start() } else { self.memory.stop() }
            }
        }
    }

    @MainActor
    func stopBackgroundServices() {
        memory.stop()
    }
}
