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
        let journal: ActionJournal
    }

    // Only touched on the main actor.
    @MainActor private var stack: Stack?
    @MainActor private var digestTask: Task<Void, Never>?
    @MainActor private var pruneTask: Task<Void, Never>?
    @MainActor private var backfillTask: Task<Void, Never>?

    init(jev: JevClient, claude: ClaudeClient) {
        self.jev = jev
        self.claude = claude
        self.gemini = GeminiClient()
    }

    // MARK: MemoryServicing

    @MainActor func start() {
        // Never capture from the unit-test host (TestHost): it would write the real vault.
        guard !TestHost.isActive else { return }
        // Recall gate (account workstream): capture needs the `recall` entitlement.
        // Developer mode (vendor keys, no cloud) is entitled locally.
        guard NaviAccount.shared.entitlements.recall else {
            if status.isRunning { stop() }
            if !status.needsEntitlement {
                Log.memory.info("Memory service not started: the account has no Recall entitlement")
            }
            status.needsEntitlement = true
            return
        }
        status.needsEntitlement = false
        guard let stack = ensureStack() else { return }
        guard !status.isRunning else { return }
        stack.scheduler.start()
        stack.journal.start()

        digestTask?.cancel()
        digestTask = Task.detached(priority: .utility) { [weak self] in
            // The first pass comes soon after launch: waiting a whole interval from every launch
            // left frames undigested for hours on a day of relaunches (installs, updates).
            var wait = Self.firstDigestDelay
            while !Task.isCancelled {
                let minutes = await MainActor.run { max(1, NaviSettings.shared.memoryDigestIntervalMinutes) }
                try? await Task.sleep(for: .seconds(min(wait, Double(minutes * 60))))
                wait = .infinity
                guard !Task.isCancelled, let self else { return }
                await self.runDigest(includeOpen: false)
                await self.startBackfillIfNeeded()
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

    /// Seconds after start before the first digest (then every `memoryDigestIntervalMinutes`).
    static let firstDigestDelay: Double = 90

    @MainActor func stop() {
        stack?.scheduler.stop()
        stack?.journal.stop()
        digestTask?.cancel(); digestTask = nil
        pruneTask?.cancel(); pruneTask = nil
        backfillTask?.cancel(); backfillTask = nil
        if status.isRunning { Log.memory.info("Memory service stopped") }
        status.isRunning = false
        status.needsEntitlement = false
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

    /// Settings → Recall → "Remove blocked details already saved": what the
    /// current personal-data choices would redact in the store and the vault.
    func planPersonalDataCleanup() async throws -> PersonalDataCleanup.Plan {
        let cleanup = try await personalDataCleanup()
        return try await Task.detached(priority: .utility) { try cleanup.plan() }.value
    }

    func applyPersonalDataCleanup(_ plan: PersonalDataCleanup.Plan) async throws -> PersonalDataCleanup.Report {
        let cleanup = try await personalDataCleanup()
        let report = try await Task.detached(priority: .utility) { try cleanup.apply(plan) }.value
        Log.memory.info("Personal-data cleanup: \(report.framesRedacted) frames, \(report.sessionsRedacted) sessions redacted")
        await MainActor.run { refreshCounts() }
        return report
    }

    private func personalDataCleanup() async throws -> PersonalDataCleanup {
        let (stack, policy) = await MainActor.run { (ensureStack(), NaviSettings.shared.personalDataPolicy) }
        guard let stack else { throw NaviError.other("Screen memory isn't available.") }
        return PersonalDataCleanup(store: stack.store, vaultRoot: stack.vault.root, policy: policy)
    }

    /// Vault root (for "Open in Obsidian" / "Reveal vault" buttons).
    @MainActor var vaultURL: URL? { stack?.vault.root }

    // MARK: Internals

    /// Builds the store/vault/digester/scheduler once. Errors go to `status.lastError`.
    @MainActor private func ensureStack() -> Stack? {
        let settings = NaviSettings.shared
        let vaultPath = settings.memoryVaultPath.isEmpty
            ? NaviSettings.defaultVaultPath : settings.memoryVaultPath
        let vaultURL = URL(fileURLWithPath: vaultPath, isDirectory: true)

        if let existing = stack {
            guard existing.vault.root != vaultURL else { return existing }
            // Vault path changed in settings: swap the writer, keep the store.
            let vault = VaultWriter(root: vaultURL)
            let digester = Digester(store: existing.store, vault: vault, claude: claude, gemini: gemini, updateStatus: statusUpdater)
            stack = Stack(store: existing.store, vault: vault, recall: existing.recall, digester: digester, scheduler: existing.scheduler,
                          journal: existing.journal)
            return stack
        }
        do {
            let store = try MemoryStore(directory: NaviSettings.dataDirectory)
            let vault = VaultWriter(root: vaultURL)
            let recall = Recall(store: store)
            let digester = Digester(store: store, vault: vault, claude: claude, gemini: gemini, updateStatus: statusUpdater)
            let scheduler = CaptureScheduler(store: store, jev: jev, updateStatus: statusUpdater)
            let s = Stack(store: store, vault: vault, recall: recall, digester: digester, scheduler: scheduler,
                          journal: ActionJournal(store: store))
            stack = s
            // Integration hook (Agent): the planner learns how this user does things from the same store,
            // the agent learns their people, projects and documents (`UserKnowledge`), and how they
            // act — what they click, their shortcuts, the procedures they follow (`UserMoves`).
            UserHabits.install(store: store)
            UserKnowledge.install(store: store)
            UserMoves.install(store: store)
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
            if n > 0 {
                Log.memory.info("Digested \(n) sessions")
                refreshKnowledge(vault: stack.vault)
            }
            await MainActor.run { refreshCounts() }
        } catch {
            Log.memory.error("Digest run failed: \(error.localizedDescription)")
            await MainActor.run { status.lastError = "Digest failed: \(error.localizedDescription)" }
        }
    }

    /// Once the regular digest has caught up: give sessions from before the operational
    /// digest their routines (`ProcedureBackfill`), one run at a time, resumable.
    @MainActor private func startBackfillIfNeeded() {
        guard backfillTask == nil, let stack, !UserDefaults.navi.bool(forKey: ProcedureBackfill.doneKey) else { return }
        let settings = NaviSettings.shared
        guard settings.memoryRecordActions else { return }
        let provider = Digester.selectProvider(setting: settings.digestProvider, hasGemini: gemini.isConfigured, hasClaude: claude.isConfigured)
        let policy = settings.personalDataPolicy
        let backfill = ProcedureBackfill(store: stack.store, digester: stack.digester, vault: stack.vault)
        backfillTask = Task.detached(priority: .background) { [weak self] in
            var refreshedAt = 0
            let report = await backfill.run(provider: provider, policy: policy) { r in
                // The routines show up for the agent (and in How you work) as they come in.
                guard r.procedures - refreshedAt >= 50, let self else { return }
                refreshedAt = r.procedures
                self.refreshKnowledge(vault: stack.vault)
            }
            guard let self else { return }
            if report.procedures > 0 { self.refreshKnowledge(vault: stack.vault) }
            await MainActor.run { self.backfillTask = nil }
        }
    }

    /// Integration hook (Agent): new sessions → fresh `UserKnowledge` and `UserMoves`, and
    /// the vault's `Navi/How you work.md` shows the user what the agent now knows.
    private func refreshKnowledge(vault: VaultWriter) {
        guard let k = UserKnowledge.current else { return }
        k.invalidate()
        TaskGrounding.invalidate()   // "the last thing I did" may be a new session now
        let now = Date()
        var md = UserKnowledge.markdown(k.things(now: now), now: now)
        if let m = UserMoves.current {
            m.invalidate()
            md += UserMoves.markdown(m.profile(now: now))
        }
        do { try vault.writeGenerated("Navi/How you work.md", md) } catch {
            Log.memory.error("Could not write How you work: \(error.localizedDescription)")
        }
    }

    private func prune() async {
        // Tests run hosted inside Navi.app: never prune the tester's real memory from a test run.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        await applyRetention()
    }

    // MARK: Privacy (Settings → Privacy & Data)

    /// "Keep screen memory for N days": frames, sessions, thumbnails and — unless the user
    /// turned it off — the journal notes Navi wrote for them. 0 days = forever. Runs daily
    /// (`PrivacyMaintenance`) whether or not capture is on; never creates a database.
    @discardableResult
    func applyRetention(now: Date = Date()) async -> MemoryStore.PruneResult {
        let (days, includeVault) = await MainActor.run {
            (NaviSettings.shared.memoryRetentionDays, NaviSettings.shared.memoryRetentionIncludesVault)
        }
        guard days > 0 else { return .init() }
        guard let stack = await MainActor.run(body: { existingStack() }) else { return .init() }
        let cutoffs = MemoryStore.retentionCutoffs(days: days, now: now)
        let cutoff = cutoffs.frames
        do {
            // Clicks, shortcuts and learned routines are kept longer (`MemoryStore.actionRetentionDays`).
            let result = try stack.store.prune(before: cutoff, actionsBefore: cutoffs.actions, proceduresBefore: cutoffs.procedures)
            var notes = 0
            if includeVault {
                notes = VaultCleanup(root: stack.vault.root).prune(sessionNotePaths: result.sessionNotePaths, before: cutoff).notesDeleted
            }
            if result.frames + result.sessions + notes > 0 {
                Log.memory.info("Retention (\(days) days): removed \(result.frames) frames, \(result.sessions) sessions, \(notes) notes")
                await MainActor.run { refreshCounts() }
            }
            return result
        } catch {
            Log.memory.error("Prune failed: \(error.localizedDescription)")
            return .init()
        }
    }

    struct EraseReport: Sendable, Equatable {
        var frames = 0
        var sessions = 0
        var vault = VaultCleanup.Report()
    }

    /// "Delete everything Navi has stored", memory part: every frame, session, thumbnail and
    /// every journal note Navi wrote (never the user's own notes). Capture pauses for the
    /// erase and carries on afterwards, so Recall keeps working from an empty memory.
    func eraseAll() async throws -> EraseReport {
        let (open, wasRunning, vaultRoot, dir) = await MainActor.run { () -> (Stack?, Bool, URL, URL) in
            let running = status.isRunning
            self.stack?.scheduler.stop()
            return (existingStack(), running, Self.vaultRoot(), NaviSettings.dataDirectory)
        }
        let stack = open
        var report = EraseReport()
        if let stack {
            let r = try stack.store.deleteAll()
            report.frames = r.frames; report.sessions = r.sessions
        } else {
            // Never opened this launch: remove the files directly (no open connection to them).
            let fm = FileManager.default
            for name in ["memory.sqlite", "memory.sqlite-wal", "memory.sqlite-shm", "frames"] {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
        report.vault = VaultCleanup(root: stack?.vault.root ?? vaultRoot).deleteAllNaviNotes()
        UserKnowledge.current?.invalidate()
        UserMoves.current?.invalidate()
        TaskGrounding.invalidate()
        await MainActor.run {
            if wasRunning { stack?.scheduler.start() }
            status.framesToday = 0
            refreshCounts()
        }
        Log.memory.info("Erased screen memory: \(report.frames) frames, \(report.sessions) sessions, \(report.vault.notesDeleted) notes")
        return report
    }

    /// The open stack, or one opened only when a memory database already exists on disk.
    @MainActor private func existingStack() -> Stack? {
        if let stack { return stack }
        let db = NaviSettings.dataDirectory.appendingPathComponent("memory.sqlite")
        guard FileManager.default.fileExists(atPath: db.path) else { return nil }
        return ensureStack()
    }

    @MainActor static func vaultRoot() -> URL {
        let path = NaviSettings.shared.memoryVaultPath
        return URL(fileURLWithPath: path.isEmpty ? NaviSettings.defaultVaultPath : path, isDirectory: true)
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
