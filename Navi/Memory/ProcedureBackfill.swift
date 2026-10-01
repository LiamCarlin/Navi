import Foundation

/// One-time pass over sessions digested before the digest was operational (before
/// 2026-10-01): each one is digested again from its stored frames for the operational
/// half only — goal, steps, habits — so the routines Navi follows (`UserMoves`) start
/// from the user's whole history instead of from the day clicks began to be recorded.
///
/// The session's title, summary and entities stay as they were; a goal becomes a
/// procedure and the session note gets its How section. Newest first, a few calls at
/// a time, text only (no screenshots: cheaper, and old sessions have no recorded clicks
/// for a picture to add to). Progress is a cursor in UserDefaults, so a quit or a
/// failure resumes where it stopped; `doneKey` is set once every session was tried.
/// Runs only while "Learn how I work" (`memoryRecordActions`) is on and a model is
/// available (the local digest names no goal).
final class ProcedureBackfill: @unchecked Sendable {
    static let cursorKey = "memoryProcedureBackfillCursor"
    static let doneKey = "memoryProcedureBackfillDone"
    static let concurrency = 4
    /// This many failed calls in a row (no network, no credit) pause it until next launch.
    static let maxFailuresInARow = 6

    let store: MemoryStore
    let digester: Digester
    let vault: VaultWriter

    init(store: MemoryStore, digester: Digester, vault: VaultWriter) {
        self.store = store; self.digester = digester; self.vault = vault
    }

    struct Report: Sendable, Equatable {
        var sessions = 0
        var procedures = 0
        var failures = 0
        var finished = false
    }

    /// Runs (or resumes) the backfill. `onProgress` gets the running report after each batch.
    func run(provider: Digester.Provider, policy: PersonalData.Policy,
             onProgress: @escaping @Sendable (Report) -> Void = { _ in }) async -> Report {
        var report = Report()
        let d = UserDefaults.navi
        guard provider != .local, !d.bool(forKey: Self.doneKey) else { return report }
        var cursor = Int64(d.integer(forKey: Self.cursorKey))
        if cursor <= 0 { cursor = ((try? store.maxSessionID()) ?? 0) + 1; d.set(Int(cursor), forKey: Self.cursorKey) }
        var failuresInARow = 0
        Log.memory.info("Procedure backfill: resuming below session #\(cursor) via \(provider.label, privacy: .public)")

        while !Task.isCancelled {
            guard let batch = try? store.sessionsWithoutProcedure(below: cursor, limit: Self.concurrency) else { break }
            if batch.isEmpty {
                d.set(true, forKey: Self.doneKey)
                report.finished = true
                break
            }
            let results = await withTaskGroup(of: (Int64, Bool, Bool).self) { group -> [(Int64, Bool, Bool)] in
                for session in batch {
                    group.addTask { [self] in
                        let (ok, made) = await backfill(session, provider: provider, policy: policy)
                        return (session.id, ok, made)
                    }
                }
                var out: [(Int64, Bool, Bool)] = []
                for await r in group { out.append(r) }
                return out
            }
            let failed = results.filter { !$0.1 }
            report.sessions += results.count - failed.count
            report.procedures += results.filter(\.2).count
            report.failures += failed.count
            failuresInARow = failed.count == results.count ? failuresInARow + failed.count : 0
            if failuresInARow >= Self.maxFailuresInARow {
                Log.memory.warning("Procedure backfill paused after \(failuresInARow) failures in a row")
                break
            }
            // A failed session is skipped, not retried forever: the cursor moves past the whole batch.
            cursor = batch.map(\.id).min() ?? cursor
            d.set(Int(cursor), forKey: Self.cursorKey)
            onProgress(report)
        }
        Log.memory.info("Procedure backfill: \(report.sessions) sessions, \(report.procedures) procedures, \(report.failures) failed\(report.finished ? ", finished" : "")")
        return report
    }

    /// One session: (the call worked, a procedure was made).
    private func backfill(_ session: SessionRecord, provider: Digester.Provider, policy: PersonalData.Policy) async -> (Bool, Bool) {
        let frames = ((try? store.frames(in: DateInterval(start: session.start, end: max(session.start, session.end)), limit: 200)) ?? [])
        guard frames.contains(where: { !$0.ocrText.isEmpty }) else { return (true, false) }   // pruned or all sensitive stubs
        let actions = Digester.actions(for: frames, in: store)
        do {
            let raw = try await digester.summarize(frames, actions: actions, provider: provider, policy: policy, images: false)
            let (digest, _) = PersonalData.scrub(raw, policy: policy)
            guard let procedure = Digester.procedure(for: session, digest: digest) else { return (true, false) }
            try store.insertProcedure(procedure)
            if let note = session.notePath { try? vault.appendHow(notePath: note, digest: digest) }
            return (true, true)
        } catch {
            Log.memory.error("Procedure backfill: session #\(session.id) failed: \(error.localizedDescription)")
            return (false, false)
        }
    }
}
