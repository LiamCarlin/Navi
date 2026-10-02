import Foundation

/// "Delete everything Navi has stored" and the daily retention pass.
///
/// **Hook for account deletion:** `await PrivacyData.deleteAllLocalData()` erases every
/// piece of user data Navi keeps on this Mac and returns what it removed. Navi keeps
/// working afterwards (screen memory restarts empty). It does **not** touch settings,
/// the Navi sign-in (Keychain) or system permissions — the account flow signs out itself.
@MainActor
enum PrivacyData {
    struct Report: Sendable, Equatable {
        var frames = 0
        var sessions = 0
        var notes = 0
        var screenshots = 0
        var logItems = 0
        var bytesFreed: Int64 = 0
        var errors: [String] = []

        var summary: String {
            var parts: [String] = []
            if frames > 0 { parts.append("\(frames) remembered moments") }
            if notes > 0 { parts.append("\(notes) journal notes") }
            if logItems > 0 { parts.append("\(logItems) task logs") }
            let freed = ByteCountFormatter.string(fromByteCount: bytesFreed, countStyle: .file)
            return parts.isEmpty ? "Nothing was stored." : "Deleted " + parts.joined(separator: ", ") + " (\(freed))."
        }
    }

    /// UserDefaults keys that hold user content (not preferences).
    static let contentDefaultsKeys = ["navi.recentQueries", "navi.launchCounts"]

    /// Erases screen memory (database, thumbnails, the journal notes Navi wrote), task logs,
    /// what the agent learned from past tasks, recent searches and leftovers of older builds.
    @discardableResult
    static func deleteAllLocalData() async -> Report {
        let paths = NaviDataPaths.live
        let before = DataInventory.scan(paths)
        var report = Report()

        if let memory = AppDelegate.shared?.services?.memory as? MemoryService {
            do {
                let r = try await memory.eraseAll()
                report.frames = r.frames
                report.sessions = r.sessions
                report.notes = r.vault.notesDeleted
                report.screenshots = r.vault.attachmentsDeleted
            } catch {
                report.errors.append("Screen memory: \(error.localizedDescription)")
            }
        } else {
            let r = eraseFiles(paths, includeMemoryDatabase: true)
            report.notes = r.notes
            report.screenshots = r.screenshots
        }

        AgentExperience.shared.removeAll()
        let files = eraseFiles(paths, includeMemoryDatabase: false)
        report.logItems = files.logItems
        for key in contentDefaultsKeys { UserDefaults.navi.removeObject(forKey: key) }

        let after = DataInventory.scan(paths)
        report.bytesFreed = max(0, before.totalBytes - after.totalBytes)
        Log.settings.info("Deleted all local data: \(report.frames) frames, \(report.notes) notes, \(report.logItems) log items")
        return report
    }

    /// The file-level part of `deleteAllLocalData`, on any layout (tests use temp dirs).
    /// `includeMemoryDatabase` only when nothing holds the database open.
    @discardableResult
    nonisolated static func eraseFiles(_ paths: NaviDataPaths, includeMemoryDatabase: Bool) -> Report {
        let fm = FileManager.default
        var report = Report()
        if includeMemoryDatabase {
            for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: paths.memoryDatabase.path + suffix) }
            try? fm.removeItem(at: paths.framesDirectory)
            let vault = VaultCleanup(root: paths.vaultRoot).deleteAllNaviNotes()
            report.notes = vault.notesDeleted
            report.screenshots = vault.attachmentsDeleted
        }
        try? fm.removeItem(at: paths.experienceFile)
        try? fm.removeItem(at: paths.voicePrintFile)
        for legacy in paths.legacyFiles { try? fm.removeItem(at: legacy) }
        let logs = TaskLogs.deleteAll(directory: paths.logsDirectory)
        report.logItems = logs.itemsRemoved
        return report
    }
}

/// Daily privacy housekeeping, for every user (not only while Recall runs): screen-memory
/// retention (`MemoryService.applyRetention`) and task-log retention (`TaskLogs.purge`).
@MainActor
enum PrivacyMaintenance {
    private static var task: Task<Void, Never>?
    static let interval: TimeInterval = 24 * 3600

    /// Integration hook: `NaviServices.startBackgroundServices()`.
    static func start(memory: MemoryServicing) {
        guard task == nil else { return }
        // Tests run hosted inside Navi.app: never prune the tester's real data from a test run.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let service = memory as? MemoryService
        task = Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(60))   // let launch settle
            while !Task.isCancelled {
                TaskLogs.purge()
                await service?.applyRetention()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }
}
