import Foundation

/// PLACEHOLDER — replaced by the Memory workstream (capture → OCR → digest → Obsidian).
/// Contract: `MemoryServicing`; init signature must stay `init(jev:claude:)`.
final class MemoryService: MemoryServicing, @unchecked Sendable {
    let jev: JevClient; let claude: ClaudeClient
    @MainActor private(set) var status = MemoryStatus()
    init(jev: JevClient, claude: ClaudeClient) { self.jev = jev; self.claude = claude }
    @MainActor func start() { status.isRunning = true }
    @MainActor func stop() { status.isRunning = false }
    func search(query: String, limit: Int) async -> [MemoryHit] { [] }
    func digestNow() async {}
}
