import Foundation
import SQLite3

/// Where Navi keeps things on this Mac. `live` is the real layout; tests pass temp dirs.
struct NaviDataPaths: Sendable, Equatable {
    /// `~/Library/Application Support/Navi` — memory.sqlite, frames/, agent-experience.json.
    var dataDirectory: URL
    /// `~/Library/Logs/Navi` — task logs (`TaskLogs`).
    var logsDirectory: URL
    /// The journal (Obsidian vault) Navi writes, default `~/Navi Vault`.
    var vaultRoot: URL

    var memoryDatabase: URL { dataDirectory.appendingPathComponent("memory.sqlite") }
    var framesDirectory: URL { dataDirectory.appendingPathComponent("frames", isDirectory: true) }
    var experienceFile: URL { dataDirectory.appendingPathComponent("agent-experience.json") }
    /// The user's voiceprint (`VoicePrintStore`).
    var voicePrintFile: URL { dataDirectory.appendingPathComponent("voiceprint.json") }
    /// Files older builds left in the data directory.
    var legacyFiles: [URL] { [dataDirectory.appendingPathComponent("history.json")] }

    @MainActor static var live: NaviDataPaths {
        NaviDataPaths(dataDirectory: NaviSettings.dataDirectory, logsDirectory: TaskLogs.directory,
                      vaultRoot: MemoryService.vaultRoot())
    }
}

/// The truth about what Navi has stored, measured from disk (Settings → Privacy & Data,
/// docs/PRIVACY.md). Counting only — it never reads note text, OCR or logs.
struct DataInventory: Sendable, Equatable {
    enum Kind: String, CaseIterable, Sendable, Identifiable {
        case screenMemory, screenshots, journal, taskLogs, taskExperience, recentSearches
        var id: String { rawValue }

        var title: String {
            switch self {
            case .screenMemory: return "Screen memory"
            case .screenshots: return "Screenshots"
            case .journal: return "Journal notes Navi wrote"
            case .taskLogs: return "Task logs"
            case .taskExperience: return "What worked in past tasks"
            case .recentSearches: return "Recent searches"
            }
        }

        var explanation: String {
            switch self {
            case .screenMemory: return "The text read from your screen, the app, window title and page address of each moment, the summaries made from them, the buttons and menu items you click and shortcuts you press (never what you type), and the routines Navi learned from them."
            case .screenshots: return "Small screenshots of remembered moments, if “Keep screenshots” is on."
            case .journal: return "Daily, session, people, topic and app notes in your journal folder. Your own notes there are never touched."
            case .taskLogs: return "Step-by-step records of tasks Navi ran, kept only if you turned on troubleshooting logs."
            case .taskExperience: return "Short task descriptions and the buttons that worked, so Navi repeats what succeeded. Never what it typed."
            case .recentSearches: return "Your last 50 searches in the Navi bar, to rank results."
            }
        }

        var symbol: String {
            switch self {
            case .screenMemory: return "brain"
            case .screenshots: return "photo.on.rectangle"
            case .journal: return "book.closed"
            case .taskLogs: return "doc.text.magnifyingglass"
            case .taskExperience: return "checkmark.seal"
            case .recentSearches: return "magnifyingglass"
            }
        }
    }

    struct Item: Sendable, Equatable, Identifiable {
        var kind: Kind
        var bytes: Int64 = 0
        var count = 0
        var oldest: Date?
        /// What "Show in Finder" reveals.
        var location: URL?
        var id: Kind { kind }
    }

    var items: [Item]
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    func item(_ kind: Kind) -> Item { items.first { $0.kind == kind } ?? Item(kind: kind) }

    // MARK: Scan

    static func scan(_ paths: NaviDataPaths, recentSearches: Int = 0) -> DataInventory {
        let fm = FileManager.default
        var memory = Item(kind: .screenMemory, location: paths.dataDirectory)
        for suffix in ["", "-wal", "-shm"] {
            memory.bytes += TaskLogs.size(of: URL(fileURLWithPath: paths.memoryDatabase.path + suffix))
        }
        if fm.fileExists(atPath: paths.memoryDatabase.path) {
            let c = memoryCounts(paths.memoryDatabase)
            memory.count = c.frames
            memory.oldest = c.oldest
        }

        var shots = Item(kind: .screenshots, location: paths.framesDirectory)
        (shots.count, shots.bytes) = files(under: paths.framesDirectory) { $0.pathExtension == "jpg" }

        var journal = Item(kind: .journal, location: paths.vaultRoot)
        for folder in ["Sessions", "Daily"] + VaultCleanup.hubFolders + ["attachments"] {
            let (n, b) = files(under: paths.vaultRoot.appendingPathComponent(folder, isDirectory: true)) { _ in true }
            if folder != "attachments" { journal.count += n }
            journal.bytes += b
        }
        for rel in VaultCleanup.generatedNotes where fm.fileExists(atPath: paths.vaultRoot.appendingPathComponent(rel).path) {
            journal.count += 1
        }

        var logs = Item(kind: .taskLogs, location: paths.logsDirectory)
        logs.bytes = TaskLogs.size(of: paths.logsDirectory)
        logs.count = ((try? fm.contentsOfDirectory(atPath: paths.logsDirectory.appendingPathComponent("runs").path)) ?? [])
            .filter { !$0.hasPrefix(".") }.count

        var experience = Item(kind: .taskExperience, location: paths.dataDirectory)
        experience.bytes = TaskLogs.size(of: paths.experienceFile)
        if let data = try? Data(contentsOf: paths.experienceFile),
           let list = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            experience.count = list.count
        }
        for legacy in paths.legacyFiles { experience.bytes += TaskLogs.size(of: legacy) }

        let searches = Item(kind: .recentSearches, count: recentSearches)
        return DataInventory(items: [memory, shots, journal, logs, experience, searches])
    }

    /// Frames stored and the oldest one, read-only (the app may hold the database open).
    static func memoryCounts(_ db: URL) -> (frames: Int, sessions: Int, oldest: Date?) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(db.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return (0, 0, nil)
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 1000)
        func scalar(_ sql: String) -> Double? {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
            return sqlite3_column_double(stmt, 0)
        }
        let frames = Int(scalar("SELECT count(*) FROM frames") ?? 0)
        let sessions = Int(scalar("SELECT count(*) FROM sessions") ?? 0)
        let oldest = scalar("SELECT min(ts) FROM frames").map { Date(timeIntervalSince1970: $0) }
        return (frames, sessions, oldest)
    }

    private static func files(under dir: URL, _ include: (URL) -> Bool) -> (Int, Int64) {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return (0, 0) }
        var n = 0
        var bytes: Int64 = 0
        for case let u as URL in e {
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard v?.isRegularFile == true, include(u) else { continue }
            n += 1
            bytes += Int64(v?.fileSize ?? 0)
        }
        return (n, bytes)
    }
}
