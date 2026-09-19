import Foundation
import AppKit

/// PLACEHOLDER — replaced by the Router workstream.
/// Contract: `QueryRouting`; init signature must stay `init(jev:claude:memory:agent:)`.
final class QueryRouter: QueryRouting, @unchecked Sendable {
    let jev: JevClient; let claude: ClaudeClient; let memory: MemoryServicing; let agent: ComputerAgentRunning
    init(jev: JevClient, claude: ClaudeClient, memory: MemoryServicing, agent: ComputerAgentRunning) {
        self.jev = jev; self.claude = claude; self.memory = memory; self.agent = agent
    }

    @MainActor func instantResults(for query: String, context: QueryContext) -> [SearchResult] {
        [SearchResult(id: "ask:\(query)", kind: .answer, title: "Ask Navi: \(query)", icon: .system("sparkle"), score: 0.1) {
            .dismiss
        }]
    }

    func route(query: String, context: QueryContext) async -> RouteDecision { .heuristic(.askQuestion) }

    @MainActor func results(for query: String, decision: RouteDecision, context: QueryContext) async -> [SearchResult] { [] }
}

/// PLACEHOLDER — replaced by the Router workstream (Claude-backed answers).
final class AnswerService: AnswerProviding, @unchecked Sendable {
    let claude: ClaudeClient
    init(claude: ClaudeClient) { self.claude = claude }
    func streamAnswer(query: String, context: QueryContext, memory: [MemoryHit]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { c in c.yield("(answers not wired yet) "); c.finish() }
    }
}
