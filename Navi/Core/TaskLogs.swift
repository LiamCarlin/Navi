import Foundation

/// Troubleshooting logs of agent tasks in `~/Library/Logs/Navi`:
///
///     runs/<timestamp>/          per-run folder (goal, every step's state, answers, a review screenshot)
///     agent-last-run.log         the latest run's events
///     agent-runs.log (+ .1)      the same lines across runs, rotated at ~2 MB
///     ultrafast-last-run.jsonl   the browser runner's raw event stream of the latest run
///     debug.log                  Debug builds only (`DebugTrace`)
///
/// They hold what a task saw and typed, so they are **off unless the user opts in**
/// (Settings → Privacy & Data → "Keep task logs for troubleshooting"), Developer mode is on,
/// or this is a Debug build that never chose. Whatever is kept passes through
/// `redact` (card/SSN/ID/DOB/phone/address patterns) and ages out after 7 days, with
/// run folders capped at 200 MB in total (`purge`, daily via `PrivacyMaintenance`).
enum TaskLogs {
    static let keepKey = "privacyKeepTaskLogs"
    static let maxAge: TimeInterval = 7 * 86_400
    static let maxRunFolderBytes: Int64 = 200 * 1_000_000
    /// File names Navi writes directly in the logs directory.
    static let knownFiles = ["agent-last-run.log", "agent-runs.log", "agent-runs.1.log", "ultrafast-last-run.jsonl", "debug.log"]

    static var directory: URL {
        // Under the test host a scratch dir, so nothing in a test can purge the user's logs.
        let home = TestHost.isActive ? TestHost.scratchDirectory : URL(fileURLWithPath: NSHomeDirectory())
        return home.appendingPathComponent("Library/Logs/Navi", isDirectory: true)
    }
    static var runsDirectory: URL { directory.appendingPathComponent("runs", isDirectory: true) }

    /// Whether task logs are written at all. Read off the main actor (UserDefaults).
    static var isEnabled: Bool { isEnabled(defaults: .navi) }

    static func isEnabled(defaults: UserDefaults, debugBuild: Bool = isDebugBuild) -> Bool {
        if defaults.bool(forKey: DeveloperMode.defaultsKey) { return true }
        if let chosen = defaults.object(forKey: keepKey) as? Bool { return chosen }
        return debugBuild
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    // MARK: Redaction

    /// Card, SSN, ID, date-of-birth, phone and address patterns → `[redacted]`, whatever
    /// the user allows screen memory to keep: a log is not the journal.
    static func redact(_ text: String) -> String {
        PersonalData.redact(text, policy: .strict).text
    }

    /// `redact` over every string inside a JSON-like value (run-folder payloads).
    static func redactJSON(_ value: Any) -> Any {
        switch value {
        case let s as String: return redact(s)
        case let d as [String: Any]: return d.mapValues(redactJSON)
        case let a as [Any]: return a.map(redactJSON)
        default: return value
        }
    }

    // MARK: Retention

    struct PurgeReport: Sendable, Equatable {
        var itemsRemoved = 0
        var bytesFreed: Int64 = 0
    }

    /// Removes run folders and log files older than `maxAge`, then the oldest run
    /// folders until the rest fit in `maxBytes`. Files Navi doesn't know are left alone.
    @discardableResult
    static func purge(directory: URL = directory, now: Date = Date(), maxAge: TimeInterval = maxAge,
                      maxBytes: Int64 = maxRunFolderBytes) -> PurgeReport {
        let fm = FileManager.default
        var report = PurgeReport()
        let cutoff = now.addingTimeInterval(-maxAge)

        func remove(_ url: URL, bytes: Int64) {
            if (try? fm.removeItem(at: url)) != nil {
                report.itemsRemoved += 1
                report.bytesFreed += bytes
            }
        }

        for name in knownFiles {
            let url = directory.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let modified = attrs[.modificationDate] as? Date, modified < cutoff else { continue }
            remove(url, bytes: (attrs[.size] as? NSNumber)?.int64Value ?? 0)
        }

        let runs = directory.appendingPathComponent("runs", isDirectory: true)
        let folders = ((try? fm.contentsOfDirectory(at: runs, includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles])) ?? [])
            .map { (url: $0, modified: modificationDate($0), bytes: size(of: $0)) }
            .sorted { $0.modified > $1.modified }   // newest first
        var total: Int64 = 0
        for f in folders {
            if f.modified < cutoff || total + f.bytes > maxBytes {
                remove(f.url, bytes: f.bytes)
            } else {
                total += f.bytes
            }
        }
        return report
    }

    /// "Delete everything Navi has stored": every run folder and log file Navi wrote.
    @discardableResult
    static func deleteAll(directory: URL = directory) -> PurgeReport {
        let fm = FileManager.default
        var report = PurgeReport()
        let runs = directory.appendingPathComponent("runs", isDirectory: true)
        for url in [runs] + knownFiles.map({ directory.appendingPathComponent($0) }) where fm.fileExists(atPath: url.path) {
            let bytes = size(of: url)
            if (try? fm.removeItem(at: url)) != nil {
                report.itemsRemoved += 1
                report.bytesFreed += bytes
            }
        }
        return report
    }

    // MARK: Sizes

    static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let u as URL in e {
                let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
            }
        }
        return total
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
