import Foundation
import Combine

/// Screen memory: capture → OCR → Jev triage → digest → Obsidian vault → recall.
///
/// Owns the SQLite store, the capture loop, the periodic digester, daily
/// retention pruning and the recall index. `status` is `@Published` so the
/// settings UI can observe it (`services.memory as? MemoryService`).
/// Every failure is caught into `status.lastError`; nothing here can crash the app.
final class MemoryService: ObservableObject, MemoryServicing, @unchecked Sendable {
    let jev: JevClient
    let claude: ClaudeClient
    let gemini: GeminiClient

    @MainActor @Published private(set) var status = MemoryStatus()

    private struct Stack {
        let store: MemoryStore
        let vault: VaultWriter
        let recall: Recall
        let digester: Digester
        let scheduler: CaptureScheduler
    }

    // Only touched on the main actor.
    @MainActor private var stack: Stack?
    @MainActor private var digestTask: Task<Void, Never>?
    @MainActor private var pruneTask: Task<Void, Never>?

    init(jev: JevClient, claude: ClaudeClient) {
        self.jev = jev
        self.claude = claude
        self.gemini = GeminiClient()
    }

    // MARK: MemoryServicing

    @MainActor func start() {
        guard let stack = ensureStack() else { return }
        guard !status.isRunning else { return }
        stack.scheduler.start()

        digestTask?.cancel()
        digestTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let minutes = await MainActor.run { max(1, NaviSettings.shared.memoryDigestIntervalMinutes) }
                try? await Task.sleep(for: .seconds(minutes * 60))
                guard !Task.isCancelled, let self else { return }
                await self.runDigest(includeOpen: false)
            }
        }

        pruneTask?.cancel()
        pruneTask = Task.detached(priority: .background) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.prune()
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }

        status.isRunning = true
        status.lastError = nil
        refreshCounts()
        Log.memory.info("Memory service started (vault: \(stack.vault.root.path, privacy: .public))")
    }

    @MainActor func stop() {
        stack?.scheduler.stop()
        digestTask?.cancel(); digestTask = nil
        pruneTask?.cancel(); pruneTask = nil
        if status.isRunning { Log.memory.info("Memory service stopped") }
        status.isRunning = false
    }

    func search(query: String, limit: Int) async -> [MemoryHit] {
        guard let stack = await MainActor.run(body: { ensureStack() }) else { return [] }
        return await stack.recall.search(query: query, limit: limit)
    }

    func digestNow() async {
        await runDigest(includeOpen: true)
    }

    /// LLM-ready context for a recall query (used by the answer service).
    func context(for query: String, limit: Int = 8) async -> String {
        guard let stack = await MainActor.run(body: { ensureStack() }) else { return "" }
        return await stack.recall.context(for: query, limit: limit)
    }

    /// Vault root (for "Open in Obsidian" / "Reveal vault" buttons).
    @MainActor var vaultURL: URL? { stack?.vault.root }

    // MARK: Internals

    /// Builds the store/vault/digester/scheduler once. Errors go to `status.lastError`.
    @MainActor private func ensureStack() -> Stack? {
        let settings = NaviSettings.shared
        let vaultPath = settings.memoryVaultPath.isEmpty
            ? NSString(string: "~/Navi Vault").expandingTildeInPath : settings.memoryVaultPath
        let vaultURL = URL(fileURLWithPath: vaultPath, isDirectory: true)

        if let existing = stack {
            guard existing.vault.root != vaultURL else { return existing }
            // Vault path changed in settings: swap the writer, keep the store.
            let vault = VaultWriter(root: vaultURL)
            let digester = Digester(store: existing.store, vault: vault, claude: claude, gemini: gemini, updateStatus: statusUpdater)
            stack = Stack(store: existing.store, vault: vault, recall: existing.recall, digester: digester, scheduler: existing.scheduler)
            return stack
        }
        do {
            let store = try MemoryStore(directory: NaviSettings.dataDirectory)
            let vault = VaultWriter(root: vaultURL)
            let recall = Recall(store: store)
            let digester = Digester(store: store, vault: vault, claude: claude, gemini: gemini, updateStatus: statusUpdater)
            let scheduler = CaptureScheduler(store: store, jev: jev, updateStatus: statusUpdater)
            let s = Stack(store: store, vault: vault, recall: recall, digester: digester, scheduler: scheduler)
            stack = s
            return s
        } catch {
            Log.memory.error("Memory store unavailable: \(error.localizedDescription)")
            status.lastError = error.localizedDescription
            return nil
        }
    }

    private var statusUpdater: CaptureScheduler.StatusUpdate {
        { [weak self] mutate in
            guard let self else { return }
            Task { @MainActor in mutate(&self.status) }
        }
    }

    private func runDigest(includeOpen: Bool) async {
        guard let stack = await MainActor.run(body: { ensureStack() }) else { return }
        do {
            let n = try await stack.digester.run(includeOpen: includeOpen)
            if n > 0 { Log.memory.info("Digested \(n) sessions") }
            await MainActor.run { refreshCounts() }
        } catch {
            Log.memory.error("Digest run failed: \(error.localizedDescription)")
            await MainActor.run { status.lastError = "Digest failed: \(error.localizedDescription)" }
        }
    }

    private func prune() async {
        guard let stack = await MainActor.run(body: { stack }) else { return }
        let days = await MainActor.run { max(1, NaviSettings.shared.memoryRetentionDays) }
        do {
            let n = try stack.store.pruneOlderThan(days: days)
            if n > 0 { Log.memory.info("Pruned \(n) frames older than \(days) days") }
        } catch {
            Log.memory.error("Prune failed: \(error.localizedDescription)")
        }
    }

    @MainActor private func refreshCounts() {
        guard let stack else { return }
        let store = stack.store, vault = stack.vault
        Task.detached(priority: .utility) { [weak self] in
            let frames = (try? store.framesToday()) ?? 0
            let notes = vault.noteCount()
            guard let self else { return }
            await MainActor.run {
                self.status.framesToday = frames
                self.status.vaultNoteCount = notes
            }
        }
    }
}
