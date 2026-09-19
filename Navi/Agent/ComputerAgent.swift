import Foundation

/// PLACEHOLDER — replaced by the Agent workstream (Claude computer use + Jev gating).
/// Contract: `ComputerAgentRunning`; init signature must stay `init(jev:claude:)`.
final class ComputerAgent: ComputerAgentRunning, @unchecked Sendable {
    let jev: JevClient; let claude: ClaudeClient
    init(jev: JevClient, claude: ClaudeClient) { self.jev = jev; self.claude = claude }

    @MainActor func run(task: String, context: QueryContext) -> AgentRunHandle {
        let h = AgentRunHandle(task: task, cancel: {}, respond: { _ in })
        h.emit(.failed("Computer-use agent not implemented yet"))
        h.finish()
        return h
    }
}
