import Foundation
import SQLite3

// MARK: - Records

/// One captured screen moment (after OCR + Jev triage).
struct FrameRecord: Sendable, Equatable {
    var id: Int64 = 0
    var timestamp: Date
    var bundleID: String
    var appName: String
    var windowTitle: String?
    var url: String?
    /// Empty for sensitive frames (stub rows keep only app + time).
    var ocrText: String
    var thumbPath: String?
    var phash: UInt64 = 0
    var activity: String = "other"
    var importance: Double = 1
    var isNewContext: Bool = false
    var digested: Bool = false
}

/// A digested stretch of activity (several frames → one vault note).
struct SessionRecord: Sendable, Equatable {
    var id: Int64 = 0
    var start: Date
    var end: Date
    var bundleID: String
    var appName: String
    var url: String?
    var title: String
    var summary: String
    var topics: [String]
    var entities: [EntityRef]
    var importance: Double = 1
    var notePath: String?
}

/// One thing the user did with the mouse or keyboard (`ActionJournal`): the control
/// they clicked, the menu item they chose, the shortcut they pressed, or the field they
/// typed in. Never what they typed: labels are the control's own name (a text field's
/// label, not its value).
struct ActionRecord: Sendable, Equatable {
    /// `type`: the user typed in the field `label` (once per stretch of typing; never the text).
    enum Kind: String, Sendable { case click, menu, key, type }

    var id: Int64 = 0
    var timestamp: Date
    var bundleID: String
    var appName: String
    var windowTitle: String?
    var url: String?
    var kind: Kind
    /// AX role without the prefix ("button", "link", "row", "menu item"); "" for keys.
    var role: String = ""
    /// The control's name, or for a shortcut the menu item it triggers ("" when unknown).
    var label: String = ""
    /// "cmd+r": the key pressed, or the shortcut a clicked menu item shows.
    var shortcut: String?
    /// Where the control sits: the menu ("File", "Format › Font"), or its container.
    var path: String?
}

/// How the user got something done, from one digested session (`Digester`): the task
/// as they could ask Navi for it, the steps they took, and what it shows about how they work.
struct ProcedureRecord: Sendable, Equatable {
    var id: Int64 = 0
    var sessionID: Int64
    var start: Date
    var end: Date
    var bundleID: String
    var appName: String
    /// Site key of the session's page ("canvas.olin.edu", "docs.google.com/document").
    var site: String?
    var goal: String
    var steps: [String]
    var habits: [String]
    /// The journal rows (`actions.id`) that did the goal, in order, as the digester picked them
    /// from [ACTIONS]; empty for procedures digested before it named them (`RoutineMiner.align`).
    var actionIDs: [Int64] = []
}

struct EntityRef: Sendable, Equatable, Hashable, Codable {
    var name: String
    var type: String   // person|project|company|tool|site|file|concept
}

// MARK: - Store

/// SQLite (system libsqlite3, FTS5) store for frames + sessions. All access is
/// serialised on a private queue; every method is synchronous and safe to call
/// from any thread or task.
///
/// Schema
///   frames(id, ts, bundle_id, app_name, window_title, url, ocr_text, thumb_path,
///          phash, activity, importance, is_new_context, digested)
///   sessions(id, start_ts, end_ts, bundle_id, app_name, url, title, summary,
///            topics JSON, entities JSON, importance, note_path)
///   frames_fts(ocr_text, window_title, url)  — external-content FTS5 over frames
///   sessions_fts(summary, topics, entities, title) — standalone FTS5, rowid = session id
///   actions(id, ts, bundle_id, app_name, window_title, url, kind, role, label, shortcut, path)
///   procedures(id, session_id, start_ts, end_ts, bundle_id, app_name, site, goal, steps JSON, habits JSON, action_ids JSON)
///   routines(key, template, goals JSON, bundle_id, app_name, site, start_url, steps JSON, count,
///            first_ts, last_ts, worked, failed) — derived from procedures + actions (`RoutineMiner`)
final class MemoryStore: @unchecked Sendable {
    let databaseURL: URL
    /// Where JPEG thumbnails live (`frames/YYYY/MM/DD/<ts>.jpg`).
    let framesDirectory: URL

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.liamcarlin.navi.memory.store", qos: .utility)
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    enum StoreError: LocalizedError {
        case open(String), sql(String), bind(String)
        var errorDescription: String? {
            switch self {
            case .open(let m): return "Could not open memory database: \(m)"
            case .sql(let m): return "Memory database error: \(m)"
            case .bind(let m): return "Memory database bind error: \(m)"
            }
        }
    }

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Screen memory is readable by this user only (the database, its WAL and the thumbnails).
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        databaseURL = directory.appendingPathComponent("memory.sqlite")
        framesDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw StoreError.open(msg)
        }
        db = handle
        sqlite3_busy_timeout(handle, 2000)
        try queue.sync { try migrate() }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path + suffix)
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: Schema

    private func migrate() throws {
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        // Deleted rows (pruned, redacted, "Delete everything") are overwritten with zeros
        // instead of lingering in free pages where a file carver could read them back.
        try exec("PRAGMA secure_delete=ON;")
        try exec("""
        CREATE TABLE IF NOT EXISTS frames(
            id INTEGER PRIMARY KEY,
            ts REAL NOT NULL,
            bundle_id TEXT NOT NULL DEFAULT '',
            app_name TEXT NOT NULL DEFAULT '',
            window_title TEXT,
            url TEXT,
            ocr_text TEXT NOT NULL DEFAULT '',
            thumb_path TEXT,
            phash INTEGER NOT NULL DEFAULT 0,
            activity TEXT NOT NULL DEFAULT 'other',
            importance REAL NOT NULL DEFAULT 1,
            is_new_context INTEGER NOT NULL DEFAULT 0,
            digested INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS frames_ts ON frames(ts);
        CREATE INDEX IF NOT EXISTS frames_digested ON frames(digested, ts);
        CREATE TABLE IF NOT EXISTS sessions(
            id INTEGER PRIMARY KEY,
            start_ts REAL NOT NULL,
            end_ts REAL NOT NULL,
            bundle_id TEXT NOT NULL DEFAULT '',
            app_name TEXT NOT NULL DEFAULT '',
            url TEXT,
            title TEXT NOT NULL DEFAULT '',
            summary TEXT NOT NULL DEFAULT '',
            topics TEXT NOT NULL DEFAULT '[]',
            entities TEXT NOT NULL DEFAULT '[]',
            importance REAL NOT NULL DEFAULT 1,
            note_path TEXT
        );
        CREATE INDEX IF NOT EXISTS sessions_start ON sessions(start_ts);
        CREATE VIRTUAL TABLE IF NOT EXISTS frames_fts USING fts5(
            ocr_text, window_title, url,
            content='frames', content_rowid='id', tokenize='unicode61'
        );
        CREATE TRIGGER IF NOT EXISTS frames_ai AFTER INSERT ON frames BEGIN
            INSERT INTO frames_fts(rowid, ocr_text, window_title, url)
            VALUES (new.id, new.ocr_text, new.window_title, new.url);
        END;
        CREATE TRIGGER IF NOT EXISTS frames_ad AFTER DELETE ON frames BEGIN
            INSERT INTO frames_fts(frames_fts, rowid, ocr_text, window_title, url)
            VALUES ('delete', old.id, old.ocr_text, old.window_title, old.url);
        END;
        CREATE TRIGGER IF NOT EXISTS frames_au AFTER UPDATE OF ocr_text, window_title, url ON frames BEGIN
            INSERT INTO frames_fts(frames_fts, rowid, ocr_text, window_title, url)
            VALUES ('delete', old.id, old.ocr_text, old.window_title, old.url);
            INSERT INTO frames_fts(rowid, ocr_text, window_title, url)
            VALUES (new.id, new.ocr_text, new.window_title, new.url);
        END;
        CREATE VIRTUAL TABLE IF NOT EXISTS sessions_fts USING fts5(
            summary, topics, entities, title, tokenize='unicode61'
        );
        CREATE TABLE IF NOT EXISTS actions(
            id INTEGER PRIMARY KEY,
            ts REAL NOT NULL,
            bundle_id TEXT NOT NULL DEFAULT '',
            app_name TEXT NOT NULL DEFAULT '',
            window_title TEXT,
            url TEXT,
            kind TEXT NOT NULL,
            role TEXT NOT NULL DEFAULT '',
            label TEXT NOT NULL DEFAULT '',
            shortcut TEXT,
            path TEXT
        );
        CREATE INDEX IF NOT EXISTS actions_ts ON actions(ts);
        CREATE TABLE IF NOT EXISTS procedures(
            id INTEGER PRIMARY KEY,
            session_id INTEGER NOT NULL DEFAULT 0,
            start_ts REAL NOT NULL,
            end_ts REAL NOT NULL,
            bundle_id TEXT NOT NULL DEFAULT '',
            app_name TEXT NOT NULL DEFAULT '',
            site TEXT,
            goal TEXT NOT NULL,
            steps TEXT NOT NULL DEFAULT '[]',
            habits TEXT NOT NULL DEFAULT '[]'
        );
        CREATE INDEX IF NOT EXISTS procedures_start ON procedures(start_ts);
        CREATE TABLE IF NOT EXISTS routines(
            key TEXT PRIMARY KEY,
            template TEXT NOT NULL,
            goals TEXT NOT NULL DEFAULT '[]',
            bundle_id TEXT NOT NULL DEFAULT '',
            app_name TEXT NOT NULL DEFAULT '',
            site TEXT,
            start_url TEXT,
            steps TEXT NOT NULL DEFAULT '[]',
            count INTEGER NOT NULL DEFAULT 1,
            first_ts REAL NOT NULL,
            last_ts REAL NOT NULL,
            worked INTEGER NOT NULL DEFAULT 0,
            failed INTEGER NOT NULL DEFAULT 0
        );
        """)
        // Databases from before procedures named their actions.
        let columns = try query("PRAGMA table_info(procedures)", []).compactMap { $0["name"] as? String }
        if !columns.contains("action_ids") {
            try exec("ALTER TABLE procedures ADD COLUMN action_ids TEXT NOT NULL DEFAULT '[]';")
        }
    }

    // MARK: Frames

    @discardableResult
    func insertFrame(_ f: FrameRecord) throws -> Int64 {
        try queue.sync {
            try run("""
            INSERT INTO frames(ts, bundle_id, app_name, window_title, url, ocr_text, thumb_path, phash,
                               activity, importance, is_new_context, digested)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            """, [f.timestamp.timeIntervalSince1970, f.bundleID, f.appName, f.windowTitle, f.url, f.ocrText,
                  f.thumbPath, Int64(bitPattern: f.phash), f.activity, f.importance, f.isNewContext, f.digested])
            return sqlite3_last_insert_rowid(db)
        }
    }

    /// Strips OCR text + thumbnail from a frame (keeps the app/time stub) — used
    /// when something is found to be sensitive after the fact.
    func markSensitiveAndDelete(frameID: Int64) throws {
        try queue.sync {
            let rows = try query("SELECT thumb_path FROM frames WHERE id = ?", [frameID])
            if let p = rows.first?["thumb_path"] as? String { try? FileManager.default.removeItem(atPath: p) }
            try run("UPDATE frames SET ocr_text = '', window_title = NULL, url = NULL, thumb_path = NULL, importance = 0 WHERE id = ?", [frameID])
        }
    }

    /// Frames that still hold text, by id, one page at a time (for `PersonalDataCleanup`).
    func framesWithText(afterID: Int64, limit: Int = 500) throws -> [FrameRecord] {
        try queue.sync {
            try query("SELECT * FROM frames WHERE id > ? AND (ocr_text != '' OR window_title IS NOT NULL) ORDER BY id ASC LIMIT ?",
                      [afterID, limit]).map(Self.frame(from:))
        }
    }

    /// Frames not yet folded into a session, oldest first.
    func undigestedFrames(since: Date? = nil, limit: Int = 2000) throws -> [FrameRecord] {
        try queue.sync {
            let rows = try query("""
            SELECT * FROM frames WHERE digested = 0 AND ts >= ? ORDER BY ts ASC LIMIT ?
            """, [since?.timeIntervalSince1970 ?? 0, limit])
            return rows.map(Self.frame(from:))
        }
    }

    func markDigested(frameIDs: [Int64]) throws {
        guard !frameIDs.isEmpty else { return }
        try queue.sync {
            try exec("BEGIN;")
            defer { try? exec("COMMIT;") }
            for id in frameIDs { try run("UPDATE frames SET digested = 1 WHERE id = ?", [id]) }
        }
    }

    func latestFrame() throws -> FrameRecord? {
        try queue.sync {
            try query("SELECT * FROM frames ORDER BY ts DESC LIMIT 1", []).first.map(Self.frame(from:))
        }
    }

    func frame(id: Int64) throws -> FrameRecord? {
        try queue.sync { try query("SELECT * FROM frames WHERE id = ?", [id]).first.map(Self.frame(from:)) }
    }

    func frames(in interval: DateInterval, limit: Int = 500) throws -> [FrameRecord] {
        try queue.sync {
            try query("SELECT * FROM frames WHERE ts >= ? AND ts <= ? ORDER BY ts ASC LIMIT ?",
                      [interval.start.timeIntervalSince1970, interval.end.timeIntervalSince1970, limit]).map(Self.frame(from:))
        }
    }

    func framesToday(calendar: Calendar = .current, now: Date = Date()) throws -> Int {
        let start = calendar.startOfDay(for: now)
        return try queue.sync {
            let rows = try query("SELECT COUNT(*) AS n FROM frames WHERE ts >= ?", [start.timeIntervalSince1970])
            return Int((rows.first?["n"] as? Int64) ?? 0)
        }
    }

    func frameCount() throws -> Int {
        try queue.sync { Int((try query("SELECT COUNT(*) AS n FROM frames", []).first?["n"] as? Int64) ?? 0) }
    }

    // MARK: Habits (read by `UserHabits`)

    struct AppUsage: Sendable, Equatable {
        var bundleID: String
        var appName: String
        var screens: Int
        var lastSeen: Date
    }

    struct SiteVisit: Sendable, Equatable {
        var url: String
        var at: Date
    }

    /// Frames per app since `since`, most first. Sensitive stubs count too: they
    /// keep only the app and the time, which is all this needs.
    func appUsage(since: Date) throws -> [AppUsage] {
        try queue.sync {
            try query("""
            SELECT bundle_id, MAX(app_name) AS app_name, COUNT(*) AS n, MAX(ts) AS last
            FROM frames WHERE ts >= ? GROUP BY bundle_id ORDER BY n DESC
            """, [since.timeIntervalSince1970]).map { r in
                AppUsage(bundleID: r["bundle_id"] as? String ?? "", appName: r["app_name"] as? String ?? "",
                         screens: Int(r["n"] as? Int64 ?? 0), lastSeen: Date(timeIntervalSince1970: r["last"] as? Double ?? 0))
            }
        }
    }

    /// Browser frames' URLs since `since`, newest first (capped).
    func siteVisits(since: Date, limit: Int = 20_000) throws -> [SiteVisit] {
        try queue.sync {
            try query("SELECT url, ts FROM frames WHERE ts >= ? AND url IS NOT NULL AND url != '' ORDER BY ts DESC LIMIT ?",
                      [since.timeIntervalSince1970, limit]).compactMap { r in
                (r["url"] as? String).map { SiteVisit(url: $0, at: Date(timeIntervalSince1970: r["ts"] as? Double ?? 0)) }
            }
        }
    }

    // MARK: Sessions

    @discardableResult
    func insertSession(_ s: SessionRecord) throws -> Int64 {
        try queue.sync {
            let topics = Self.json(s.topics)
            let entities = Self.json(s.entities.map { ["name": $0.name, "type": $0.type] })
            try exec("BEGIN;")
            do {
                try run("""
                INSERT INTO sessions(start_ts, end_ts, bundle_id, app_name, url, title, summary, topics, entities, importance, note_path)
                VALUES (?,?,?,?,?,?,?,?,?,?,?)
                """, [s.start.timeIntervalSince1970, s.end.timeIntervalSince1970, s.bundleID, s.appName, s.url,
                      s.title, s.summary, topics, entities, s.importance, s.notePath])
                let id = sqlite3_last_insert_rowid(db)
                // Index names only (not the JSON syntax) so "jev" matches entity "Jev".
                let entityNames = s.entities.map(\.name).joined(separator: ", ")
                try run("INSERT INTO sessions_fts(rowid, summary, topics, entities, title) VALUES (?,?,?,?,?)",
                        [id, s.summary, s.topics.joined(separator: ", "), entityNames, s.title])
                try exec("COMMIT;")
                return id
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    /// Rewrites a session's text (and its search row) after redaction.
    func updateSessionText(_ s: SessionRecord) throws {
        try queue.sync {
            try exec("BEGIN;")
            do {
                try run("UPDATE sessions SET title = ?, summary = ?, topics = ?, entities = ? WHERE id = ?",
                        [s.title, s.summary, Self.json(s.topics), Self.json(s.entities.map { ["name": $0.name, "type": $0.type] }), s.id])
                try run("DELETE FROM sessions_fts WHERE rowid = ?", [s.id])
                try run("INSERT INTO sessions_fts(rowid, summary, topics, entities, title) VALUES (?,?,?,?,?)",
                        [s.id, s.summary, s.topics.joined(separator: ", "), s.entities.map(\.name).joined(separator: ", "), s.title])
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    /// After redacting: merges the FTS indexes and rewrites the file so the old
    /// text survives in no free page, index segment or WAL frame.
    func compactAfterRedaction() throws {
        try queue.sync {
            try exec("INSERT INTO frames_fts(frames_fts) VALUES('optimize');")
            try exec("INSERT INTO sessions_fts(sessions_fts) VALUES('optimize');")
            try exec("VACUUM;")
            try exec("PRAGMA wal_checkpoint(TRUNCATE);")
        }
    }

    func updateSessionNotePath(sessionID: Int64, notePath: String) throws {
        try queue.sync { try run("UPDATE sessions SET note_path = ? WHERE id = ?", [notePath, sessionID]) }
    }

    func sessions(in interval: DateInterval, limit: Int = 50) throws -> [SessionRecord] {
        try queue.sync {
            try query("SELECT * FROM sessions WHERE end_ts >= ? AND start_ts <= ? ORDER BY start_ts DESC LIMIT ?",
                      [interval.start.timeIntervalSince1970, interval.end.timeIntervalSince1970, limit]).map(Self.session(from:))
        }
    }

    func recentSessions(limit: Int = 20) throws -> [SessionRecord] {
        try queue.sync {
            try query("SELECT * FROM sessions ORDER BY start_ts DESC LIMIT ?", [limit]).map(Self.session(from:))
        }
    }

    /// Highest-importance thumbnail captured in a time range (for session hits).
    func bestThumbnail(between start: Date, and end: Date) throws -> String? {
        try queue.sync {
            try query("""
            SELECT thumb_path FROM frames WHERE ts >= ? AND ts <= ? AND thumb_path IS NOT NULL
            ORDER BY importance DESC, ts ASC LIMIT 1
            """, [start.timeIntervalSince1970, end.timeIntervalSince1970]).first?["thumb_path"] as? String
        }
    }

    func sessionCount() throws -> Int {
        try queue.sync { Int((try query("SELECT COUNT(*) AS n FROM sessions", []).first?["n"] as? Int64) ?? 0) }
    }

    // MARK: Actions (`ActionJournal` writes, `UserMoves` and the digester read)

    func insertActions(_ list: [ActionRecord]) throws {
        guard !list.isEmpty else { return }
        try queue.sync {
            try exec("BEGIN;")
            do {
                for a in list {
                    try run("""
                    INSERT INTO actions(ts, bundle_id, app_name, window_title, url, kind, role, label, shortcut, path)
                    VALUES (?,?,?,?,?,?,?,?,?,?)
                    """, [a.timestamp.timeIntervalSince1970, a.bundleID, a.appName, a.windowTitle, a.url,
                          a.kind.rawValue, a.role, a.label, a.shortcut, a.path])
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    /// The actions with these ids, in the order given (ids no longer stored are skipped).
    func actions(ids: [Int64]) throws -> [ActionRecord] {
        guard !ids.isEmpty else { return [] }
        let rows = try queue.sync {
            try query("SELECT * FROM actions WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))", ids.map { $0 as Any? })
        }.map(Self.action(from:))
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byID[$0] }
    }

    /// Actions in a time range, oldest first.
    func actions(in interval: DateInterval, limit: Int = 50_000) throws -> [ActionRecord] {
        try queue.sync {
            try query("SELECT * FROM actions WHERE ts >= ? AND ts <= ? ORDER BY ts ASC LIMIT ?",
                      [interval.start.timeIntervalSince1970, interval.end.timeIntervalSince1970, limit]).map(Self.action(from:))
        }
    }

    // MARK: Contacts and pages (read by `UserKnowledge`)

    /// Clicks and keys in `bundleIDs` since `since`, oldest first.
    func actions(bundleIDs: Set<String>, since: Date, limit: Int = 20_000) throws -> [ActionRecord] {
        guard !bundleIDs.isEmpty else { return [] }
        let list = Array(bundleIDs)
        return try queue.sync {
            try query("SELECT * FROM actions WHERE ts >= ? AND bundle_id IN (\(list.map { _ in "?" }.joined(separator: ","))) ORDER BY ts ASC LIMIT ?",
                      Self.binds(since, list, limit)).map(Self.action(from:))
        }
    }

    /// Frames of `bundleIDs` that have a window title, since `since` (no OCR text loaded).
    func titledFrames(bundleIDs: Set<String>, since: Date, limit: Int = 20_000) throws -> [FrameRecord] {
        guard !bundleIDs.isEmpty else { return [] }
        let list = Array(bundleIDs)
        return try queue.sync {
            try query("""
            SELECT id, ts, bundle_id, app_name, window_title, url FROM frames
            WHERE ts >= ? AND window_title IS NOT NULL AND bundle_id IN (\(list.map { _ in "?" }.joined(separator: ","))) ORDER BY ts ASC LIMIT ?
            """, Self.binds(since, list, limit)).map(Self.frame(from:))
        }
    }

    private static func binds(_ since: Date, _ list: [String], _ limit: Int) -> [Any?] {
        [since.timeIntervalSince1970 as Any?] + list.map { $0 as Any? } + [limit as Any?]
    }

    /// Frames whose text shows a `Name <address>` pair, since `since`.
    func framesWithAddresses(since: Date, limit: Int = 5000) throws -> [FrameRecord] {
        try queue.sync {
            try query("SELECT * FROM frames WHERE ts >= ? AND ocr_text LIKE '%<%@%>%' ORDER BY ts ASC LIMIT ?",
                      [since.timeIntervalSince1970, limit]).map(Self.frame(from:))
        }
    }

    /// Each page's latest window title (a browser's title is the page's), since `since`.
    /// `bundleID` is the app that was in front: only a browser's window title is the page's.
    func pageTitles(since: Date, limit: Int = 20_000) throws -> [(url: String, title: String, bundleID: String, at: Date)] {
        try queue.sync {
            try query("""
            SELECT url, window_title, bundle_id, MAX(ts) AS at FROM frames
            WHERE ts >= ? AND url IS NOT NULL AND window_title IS NOT NULL AND window_title != '' GROUP BY url, bundle_id LIMIT ?
            """, [since.timeIntervalSince1970, limit]).compactMap { r in
                guard let u = r["url"] as? String, let t = r["window_title"] as? String else { return nil }
                return (u, t, r["bundle_id"] as? String ?? "", Date(timeIntervalSince1970: r["at"] as? Double ?? 0))
            }
        }
    }

    func actionCount() throws -> Int {
        try queue.sync { Int((try query("SELECT COUNT(*) AS n FROM actions", []).first?["n"] as? Int64) ?? 0) }
    }

    // MARK: Procedures

    @discardableResult
    func insertProcedure(_ p: ProcedureRecord) throws -> Int64 {
        try queue.sync {
            try run("""
            INSERT INTO procedures(session_id, start_ts, end_ts, bundle_id, app_name, site, goal, steps, habits, action_ids)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            """, [p.sessionID, p.start.timeIntervalSince1970, p.end.timeIntervalSince1970, p.bundleID, p.appName,
                  p.site, p.goal, Self.json(p.steps), Self.json(p.habits), Self.json(p.actionIDs)])
            return sqlite3_last_insert_rowid(db)
        }
    }

    /// Sessions below `id` that have no procedure yet, newest first (`ProcedureBackfill`).
    func sessionsWithoutProcedure(below id: Int64, limit: Int) throws -> [SessionRecord] {
        try queue.sync {
            try query("""
            SELECT * FROM sessions WHERE id < ? AND id NOT IN (SELECT session_id FROM procedures)
            ORDER BY id DESC LIMIT ?
            """, [id, limit]).map(Self.session(from:))
        }
    }

    func maxSessionID() throws -> Int64 {
        try queue.sync { (try query("SELECT COALESCE(MAX(id), 0) AS n FROM sessions", []).first?["n"] as? Int64) ?? 0 }
    }

    /// Procedures that started after `since`, newest first.
    func procedures(since: Date, limit: Int = 5000) throws -> [ProcedureRecord] {
        try queue.sync {
            try query("SELECT * FROM procedures WHERE start_ts >= ? ORDER BY start_ts DESC LIMIT ?",
                      [since.timeIntervalSince1970, limit]).map(Self.procedure(from:))
        }
    }

    // MARK: Routines (`RoutineMiner` writes, `UserRoutines` reads)

    /// Replaces the mined routines with `list`, keeping how the agent fared with each one
    /// that is still there (`worked`/`failed`, by key).
    func saveRoutines(_ list: [Routine]) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try queue.sync {
            let kept = Dictionary(try query("SELECT key, worked, failed FROM routines", []).compactMap { r -> (String, (Int64, Int64))? in
                guard let k = r["key"] as? String else { return nil }
                return (k, (r["worked"] as? Int64 ?? 0, r["failed"] as? Int64 ?? 0))
            }, uniquingKeysWith: { a, _ in a })
            try exec("BEGIN;")
            do {
                try exec("DELETE FROM routines;")
                for r in list {
                    let steps = (try? enc.encode(r.steps)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
                    let stats = kept[r.key] ?? (Int64(r.worked), Int64(r.failed))
                    try run("""
                    INSERT OR REPLACE INTO routines(key, template, goals, bundle_id, app_name, site, start_url, steps, count, first_ts, last_ts, worked, failed)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, [r.key, r.template, Self.json(r.goals), r.bundleID, r.appName, r.site, r.startURL, steps, r.count,
                          r.first.timeIntervalSince1970, r.last.timeIntervalSince1970, stats.0, stats.1])
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    /// Every mined routine, most done first.
    func routines(limit: Int = 2000) throws -> [Routine] {
        try queue.sync {
            try query("SELECT * FROM routines ORDER BY count DESC, last_ts DESC LIMIT ?", [limit]).compactMap(Self.routine(from:))
        }
    }

    /// The agent followed the routine `key`: it worked, or the run failed.
    func noteRoutineOutcome(key: String, worked: Bool) throws {
        try queue.sync {
            try run(worked ? "UPDATE routines SET worked = worked + 1 WHERE key = ?" : "UPDATE routines SET failed = failed + 1 WHERE key = ?", [key])
        }
    }

    /// Rewrites action labels/titles and procedure text that `redact` changes (it returns
    /// nil for text it leaves alone). `dryRun` only counts. Returns the rows affected.
    @discardableResult
    func redactActionsAndProcedures(dryRun: Bool, _ redact: (String) -> String?) throws -> Int {
        try queue.sync {
            var changed = 0
            if !dryRun { try exec("BEGIN;") }
            do {
                for r in try query("SELECT id, label, window_title, path FROM actions", []) {
                    let fields = ["label", "window_title", "path"]
                    let fixed = fields.map { f in (r[f] as? String).flatMap(redact) }
                    guard fixed.contains(where: { $0 != nil }) else { continue }
                    changed += 1
                    guard !dryRun else { continue }
                    let values: [Any?] = zip(fields, fixed).map { f, v in v ?? r[f] }
                    try run("UPDATE actions SET label = ?, window_title = ?, path = ? WHERE id = ?", values + [r["id"]])
                }
                for r in try query("SELECT id, goal, steps, habits FROM procedures", []) {
                    let decode = { (k: String) in (try? JSONSerialization.jsonObject(with: Data((r[k] as? String ?? "[]").utf8))) as? [String] ?? [] }
                    let goal = r["goal"] as? String ?? ""
                    let steps = decode("steps"), habits = decode("habits")
                    let newGoal = redact(goal), newSteps = steps.map { redact($0) }, newHabits = habits.map { redact($0) }
                    guard newGoal != nil || newSteps.contains(where: { $0 != nil }) || newHabits.contains(where: { $0 != nil }) else { continue }
                    changed += 1
                    guard !dryRun else { continue }
                    try run("UPDATE procedures SET goal = ?, steps = ?, habits = ? WHERE id = ?",
                            [newGoal ?? goal, Self.json(zip(steps, newSteps).map { $1 ?? $0 }),
                             Self.json(zip(habits, newHabits).map { $1 ?? $0 }), r["id"]])
                }
                // Routines are derived from both: mined again from the redacted rows.
                if !dryRun, changed > 0 { try exec("DELETE FROM routines;") }
                if !dryRun { try exec("COMMIT;") }
            } catch {
                if !dryRun { try? exec("ROLLBACK;") }
                throw error
            }
            return changed
        }
    }

    // MARK: Search

    /// A ranked hit from either FTS table.
    struct Hit: Sendable {
        enum Source: Sendable { case frame, session }
        var source: Source
        var id: Int64
        var timestamp: Date
        var endTimestamp: Date?
        var bundleID: String
        var appName: String
        var windowTitle: String?
        var url: String?
        var snippet: String
        var thumbnailPath: String?
        var notePath: String?
        /// Positive; higher is better. `-bm25 * exp(-ageDays / 7)` (× 1.5 for sessions).
        var score: Double
    }

    /// Full-text search over frames + sessions, recency-weighted.
    /// `within` restricts by time (frames: ts; sessions: overlap).
    func search(query raw: String, limit: Int = 20, within: DateInterval? = nil, now: Date = Date()) throws -> [Hit] {
        guard let match = Self.ftsQuery(raw, requireAll: true) else { return [] }
        var hits = try runSearch(match: match, limit: limit, within: within, now: now)
        if hits.count < max(3, limit / 2), let any = Self.ftsQuery(raw, requireAll: false), any != match {
            let more = try runSearch(match: any, limit: limit, within: within, now: now)
            let seen = Set(hits.map { "\($0.source)-\($0.id)" })
            hits += more.filter { !seen.contains("\($0.source)-\($0.id)") }
        }
        return Self.dedupe(hits).sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    /// Strict search: every term must match (no OR fallback), recency-weighted.
    func searchAll(query raw: String, limit: Int = 20, now: Date = Date()) throws -> [Hit] {
        guard let match = Self.ftsQuery(raw, requireAll: true) else { return [] }
        return Self.dedupe(try runSearch(match: match, limit: limit, within: nil, now: now)).sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    /// Frames + sessions a single term (prefix) matches: how specific it is.
    func termCount(_ term: String) throws -> Int {
        guard let match = Self.ftsQuery(term, requireAll: true) else { return 0 }
        return try queue.sync {
            let f = try query("SELECT COUNT(*) AS n FROM frames_fts WHERE frames_fts MATCH ?", [match]).first?["n"] as? Int64 ?? 0
            let s = try query("SELECT COUNT(*) AS n FROM sessions_fts WHERE sessions_fts MATCH ?", [match]).first?["n"] as? Int64 ?? 0
            return Int(f + s)
        }
    }

    private func runSearch(match: String, limit: Int, within: DateInterval?, now: Date) throws -> [Hit] {
        try queue.sync {
            var out: [Hit] = []
            let candidates = max(limit * 3, 30)
            let lo = within?.start.timeIntervalSince1970 ?? 0
            let hi = within?.end.timeIntervalSince1970 ?? Double.greatestFiniteMagnitude

            let frameRows = try query("""
            SELECT f.id, f.ts, f.bundle_id, f.app_name, f.window_title, f.url, f.thumb_path,
                   snippet(frames_fts, -1, '', '', '…', 22) AS snip,
                   bm25(frames_fts, 1.0, 3.0, 2.0) AS rank
            FROM frames_fts JOIN frames f ON f.id = frames_fts.rowid
            WHERE frames_fts MATCH ? AND f.ocr_text != '' AND f.ts >= ? AND f.ts <= ?
            ORDER BY rank LIMIT ?
            """, [match, lo, hi, candidates])
            for r in frameRows {
                let ts = Date(timeIntervalSince1970: r["ts"] as? Double ?? 0)
                out.append(Hit(source: .frame, id: r["id"] as? Int64 ?? 0, timestamp: ts, endTimestamp: nil,
                               bundleID: r["bundle_id"] as? String ?? "", appName: r["app_name"] as? String ?? "",
                               windowTitle: r["window_title"] as? String, url: r["url"] as? String,
                               snippet: Self.cleanSnippet(r["snip"] as? String ?? ""),
                               thumbnailPath: r["thumb_path"] as? String, notePath: nil,
                               score: Self.weighted(rank: r["rank"] as? Double ?? 0, at: ts, now: now)))
            }

            let sessionRows = try query("""
            SELECT s.id, s.start_ts, s.end_ts, s.bundle_id, s.app_name, s.url, s.title, s.note_path,
                   snippet(sessions_fts, -1, '', '', '…', 28) AS snip,
                   bm25(sessions_fts, 2.0, 1.5, 1.5, 3.0) AS rank
            FROM sessions_fts JOIN sessions s ON s.id = sessions_fts.rowid
            WHERE sessions_fts MATCH ? AND s.end_ts >= ? AND s.start_ts <= ?
            ORDER BY rank LIMIT ?
            """, [match, lo, hi, candidates])
            for r in sessionRows {
                let start = Date(timeIntervalSince1970: r["start_ts"] as? Double ?? 0)
                let end = Date(timeIntervalSince1970: r["end_ts"] as? Double ?? 0)
                let thumb = try query("""
                SELECT thumb_path FROM frames WHERE ts >= ? AND ts <= ? AND thumb_path IS NOT NULL
                ORDER BY importance DESC, ts ASC LIMIT 1
                """, [start.timeIntervalSince1970, end.timeIntervalSince1970]).first?["thumb_path"] as? String
                out.append(Hit(source: .session, id: r["id"] as? Int64 ?? 0, timestamp: start, endTimestamp: end,
                               bundleID: r["bundle_id"] as? String ?? "", appName: r["app_name"] as? String ?? "",
                               windowTitle: r["title"] as? String, url: r["url"] as? String,
                               snippet: Self.cleanSnippet(r["snip"] as? String ?? ""),
                               thumbnailPath: thumb, notePath: r["note_path"] as? String,
                               score: 1.5 * Self.weighted(rank: r["rank"] as? Double ?? 0, at: end, now: now)))
            }
            return out
        }
    }

    static func weighted(rank bm25: Double, at date: Date, now: Date) -> Double {
        // FTS5 bm25() is negative (more negative = better). Flip to positive.
        let base = max(-bm25, 0.01)
        let ageDays = max(0, now.timeIntervalSince(date)) / 86_400
        return base * exp(-ageDays / 7)
    }

    /// Collapses near-identical frame hits (same app + title within 10 minutes).
    static func dedupe(_ hits: [Hit]) -> [Hit] {
        var best: [String: Hit] = [:]
        var order: [String] = []
        for h in hits {
            let bucket = h.source == .frame ? Int(h.timestamp.timeIntervalSince1970 / 600) : Int(h.id)
            let key = "\(h.source)|\(h.bundleID)|\(h.windowTitle ?? "")|\(bucket)"
            if let existing = best[key] {
                if h.score > existing.score { best[key] = h }
            } else {
                best[key] = h; order.append(key)
            }
        }
        return order.compactMap { best[$0] }
    }

    static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "to", "in", "on", "at", "for", "with", "about", "that", "this",
        "these", "those", "is", "was", "were", "are", "be", "been", "being", "i", "me", "my", "we", "our", "you",
        "your", "it", "its", "what", "which", "who", "when", "where", "how", "did", "do", "does", "doing", "done",
        "have", "has", "had", "from", "by", "as", "up", "into", "than", "then", "there", "here", "some", "any",
        "working", "work", "looking", "look", "reading", "read", "again", "earlier", "ago", "show", "find",
        "remember", "recall", "thing", "stuff", "something", "just", "like", "so", "not", "no", "yes",
    ]

    /// Turns free text into an FTS5 MATCH expression of quoted prefix terms.
    static func ftsQuery(_ raw: String, requireAll: Bool) -> String? {
        var terms: [String] = []
        var seen = Set<String>()
        for chunk in raw.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }) {
            let t = String(chunk)
            guard t.count >= 2, !stopwords.contains(t), !seen.contains(t) else { continue }
            seen.insert(t); terms.append(t)
            if terms.count >= 8 { break }
        }
        guard !terms.isEmpty else { return nil }
        return terms.map { "\"\($0)\"*" }.joined(separator: requireAll ? " AND " : " OR ")
    }

    static func cleanSnippet(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Retention

    /// What Navi learned outlives the raw frames: clicks and shortcuts (no screen text) are
    /// kept this long, the procedures distilled from them longer still — "the more you use
    /// it, the more it learns" needs more than a fortnight. Never shorter than the frames.
    /// An explicit delete (`prune(before:)` alone, `deleteAll`) removes them like the rest.
    static let actionRetentionDays = 90
    static let procedureRetentionDays = 365

    /// What one retention pass removed.
    struct PruneResult: Sendable, Equatable {
        var frames = 0
        var sessions = 0
        /// Vault-relative note paths of the removed sessions (`Sessions/….md`), so
        /// the vault can drop the notes Navi wrote for them.
        var sessionNotePaths: [String] = []
    }

    /// The retention cutoffs for "keep N days": frames/sessions, then actions and procedures.
    static func retentionCutoffs(days: Int, now: Date) -> (frames: Date, actions: Date, procedures: Date) {
        func ago(_ d: Int) -> Date { now.addingTimeInterval(-Double(d) * 86_400) }
        return (ago(days), ago(max(days, actionRetentionDays)), ago(max(days, procedureRetentionDays)))
    }

    /// Deletes frames/sessions older than `days` and their thumbnails, actions and
    /// procedures past their own (longer) retention. Returns the number of frames removed.
    @discardableResult
    func pruneOlderThan(days: Int, now: Date = Date()) throws -> Int {
        let c = Self.retentionCutoffs(days: days, now: now)
        return try prune(before: c.frames, actionsBefore: c.actions, proceduresBefore: c.procedures).frames
    }

    /// Deletes every frame and session that ended before `cutoff`, their thumbnails,
    /// and the search-index entries for them — and actions/procedures before their own
    /// cutoffs (default: the same one); then folds the WAL back so the deleted
    /// text does not linger on disk.
    @discardableResult
    func prune(before cutoff: Date, actionsBefore: Date? = nil, proceduresBefore: Date? = nil) throws -> PruneResult {
        let cut = cutoff.timeIntervalSince1970
        let actionCut = (actionsBefore ?? cutoff).timeIntervalSince1970
        let procedureCut = (proceduresBefore ?? cutoff).timeIntervalSince1970
        return try queue.sync {
            let old = try query("SELECT id, thumb_path FROM frames WHERE ts < ?", [cut])
            for r in old {
                if let p = r["thumb_path"] as? String { try? FileManager.default.removeItem(atPath: p) }
            }
            let oldSessions = try query("SELECT id, note_path FROM sessions WHERE end_ts < ?", [cut])
            try exec("BEGIN;")
            do {
                try run("DELETE FROM frames WHERE ts < ?", [cut])
                try run("DELETE FROM sessions_fts WHERE rowid IN (SELECT id FROM sessions WHERE end_ts < ?)", [cut])
                try run("DELETE FROM sessions WHERE end_ts < ?", [cut])
                try run("DELETE FROM actions WHERE ts < ?", [actionCut])
                try run("DELETE FROM procedures WHERE end_ts < ?", [procedureCut])
                try run("DELETE FROM routines WHERE last_ts < ?", [procedureCut])
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
            if !old.isEmpty || !oldSessions.isEmpty {
                try? exec("INSERT INTO frames_fts(frames_fts) VALUES('optimize');")
                try? exec("INSERT INTO sessions_fts(sessions_fts) VALUES('optimize');")
                try? exec("PRAGMA wal_checkpoint(TRUNCATE);")
            }
            Self.removeEmptyDirectories(under: framesDirectory)
            return PruneResult(frames: old.count, sessions: oldSessions.count,
                               sessionNotePaths: oldSessions.compactMap { $0["note_path"] as? String })
        }
    }

    /// Settings → Privacy → "Delete everything": every frame, session, recorded click and
    /// shortcut, learned procedure, index entry and thumbnail. The connection stays open, so screen memory keeps working afterwards.
    @discardableResult
    func deleteAll() throws -> PruneResult {
        try queue.sync {
            let frames = try query("SELECT count(*) AS n FROM frames", []).first?["n"] as? Int64 ?? 0
            let sessions = try query("SELECT note_path FROM sessions", [])
            try exec("BEGIN;")
            do {
                try exec("DELETE FROM frames;")
                try exec("DELETE FROM sessions_fts;")
                try exec("DELETE FROM sessions;")
                try exec("DELETE FROM actions;")
                try exec("DELETE FROM procedures;")
                try exec("DELETE FROM routines;")
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
            // Deleted FTS terms live on in old index segments until they are merged away.
            try? exec("INSERT INTO frames_fts(frames_fts) VALUES('rebuild');")
            try? exec("INSERT INTO sessions_fts(sessions_fts) VALUES('optimize');")
            try? exec("VACUUM;")
            try? exec("PRAGMA wal_checkpoint(TRUNCATE);")
            try? FileManager.default.removeItem(at: framesDirectory)
            return PruneResult(frames: Int(frames), sessions: sessions.count,
                               sessionNotePaths: sessions.compactMap { $0["note_path"] as? String })
        }
    }

    private static func removeEmptyDirectories(under root: URL) {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        var dirs: [URL] = []
        for case let u as URL in e where (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { dirs.append(u) }
        for d in dirs.sorted(by: { $0.path.count > $1.path.count }) {
            if let items = try? fm.contentsOfDirectory(atPath: d.path), items.isEmpty { try? fm.removeItem(at: d) }
        }
    }

    // MARK: Low-level helpers

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.sql(msg)
        }
    }

    private func prepare(_ sql: String, _ binds: [Any?]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        for (i, v) in binds.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch v {
            case .none: rc = sqlite3_bind_null(stmt, idx)
            case let s as String: rc = sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            case let d as Double: rc = sqlite3_bind_double(stmt, idx, d)
            case let n as Int64: rc = sqlite3_bind_int64(stmt, idx, n)
            case let n as Int: rc = sqlite3_bind_int64(stmt, idx, Int64(n))
            case let b as Bool: rc = sqlite3_bind_int(stmt, idx, b ? 1 : 0)
            case let data as Data:
                rc = data.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(data.count), Self.transient) }
            default:
                sqlite3_finalize(stmt)
                throw StoreError.bind("unsupported value at \(idx): \(type(of: v))")
            }
            guard rc == SQLITE_OK else {
                sqlite3_finalize(stmt)
                throw StoreError.bind(String(cString: sqlite3_errmsg(db)))
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ binds: [Any?]) throws {
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw StoreError.sql(String(cString: sqlite3_errmsg(db))) }
    }

    private func query(_ sql: String, _ binds: [Any?]) throws -> [[String: Any]] {
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        var rows: [[String: Any]] = []
        let n = sqlite3_column_count(stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw StoreError.sql(String(cString: sqlite3_errmsg(db))) }
            var row: [String: Any] = [:]
            for i in 0..<n {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(stmt, i)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(stmt, i))
                case SQLITE_BLOB:
                    if let p = sqlite3_column_blob(stmt, i) { row[name] = Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i))) }
                default: break
                }
            }
            rows.append(row)
        }
        return rows
    }

    private static func frame(from r: [String: Any]) -> FrameRecord {
        FrameRecord(id: r["id"] as? Int64 ?? 0,
                    timestamp: Date(timeIntervalSince1970: r["ts"] as? Double ?? 0),
                    bundleID: r["bundle_id"] as? String ?? "",
                    appName: r["app_name"] as? String ?? "",
                    windowTitle: r["window_title"] as? String,
                    url: r["url"] as? String,
                    ocrText: r["ocr_text"] as? String ?? "",
                    thumbPath: r["thumb_path"] as? String,
                    phash: UInt64(bitPattern: r["phash"] as? Int64 ?? 0),
                    activity: r["activity"] as? String ?? "other",
                    importance: r["importance"] as? Double ?? 1,
                    isNewContext: (r["is_new_context"] as? Int64 ?? 0) != 0,
                    digested: (r["digested"] as? Int64 ?? 0) != 0)
    }

    private static func session(from r: [String: Any]) -> SessionRecord {
        let topics = (try? JSONSerialization.jsonObject(with: Data((r["topics"] as? String ?? "[]").utf8))) as? [String] ?? []
        let ents = ((try? JSONSerialization.jsonObject(with: Data((r["entities"] as? String ?? "[]").utf8))) as? [[String: String]] ?? [])
            .compactMap { d -> EntityRef? in d["name"].map { EntityRef(name: $0, type: d["type"] ?? "concept") } }
        return SessionRecord(id: r["id"] as? Int64 ?? 0,
                             start: Date(timeIntervalSince1970: r["start_ts"] as? Double ?? 0),
                             end: Date(timeIntervalSince1970: r["end_ts"] as? Double ?? 0),
                             bundleID: r["bundle_id"] as? String ?? "",
                             appName: r["app_name"] as? String ?? "",
                             url: r["url"] as? String,
                             title: r["title"] as? String ?? "",
                             summary: r["summary"] as? String ?? "",
                             topics: topics, entities: ents,
                             importance: r["importance"] as? Double ?? 1,
                             notePath: r["note_path"] as? String)
    }

    private static func action(from r: [String: Any]) -> ActionRecord {
        ActionRecord(id: r["id"] as? Int64 ?? 0,
                     timestamp: Date(timeIntervalSince1970: r["ts"] as? Double ?? 0),
                     bundleID: r["bundle_id"] as? String ?? "",
                     appName: r["app_name"] as? String ?? "",
                     windowTitle: r["window_title"] as? String,
                     url: r["url"] as? String,
                     kind: ActionRecord.Kind(rawValue: r["kind"] as? String ?? "") ?? .click,
                     role: r["role"] as? String ?? "",
                     label: r["label"] as? String ?? "",
                     shortcut: r["shortcut"] as? String,
                     path: r["path"] as? String)
    }

    private static func procedure(from r: [String: Any]) -> ProcedureRecord {
        func list(_ key: String) -> [String] {
            (try? JSONSerialization.jsonObject(with: Data((r[key] as? String ?? "[]").utf8))) as? [String] ?? []
        }
        return ProcedureRecord(id: r["id"] as? Int64 ?? 0,
                               sessionID: r["session_id"] as? Int64 ?? 0,
                               start: Date(timeIntervalSince1970: r["start_ts"] as? Double ?? 0),
                               end: Date(timeIntervalSince1970: r["end_ts"] as? Double ?? 0),
                               bundleID: r["bundle_id"] as? String ?? "",
                               appName: r["app_name"] as? String ?? "",
                               site: r["site"] as? String,
                               goal: r["goal"] as? String ?? "",
                               steps: list("steps"), habits: list("habits"),
                               actionIDs: ((try? JSONSerialization.jsonObject(with: Data((r["action_ids"] as? String ?? "[]").utf8))) as? [NSNumber] ?? [])
                                   .map(\.int64Value))
    }

    private static func routine(from r: [String: Any]) -> Routine? {
        guard let key = r["key"] as? String,
              let steps = try? JSONDecoder().decode([RoutineStep].self, from: Data((r["steps"] as? String ?? "[]").utf8)), !steps.isEmpty
        else { return nil }
        let goals = (try? JSONSerialization.jsonObject(with: Data((r["goals"] as? String ?? "[]").utf8))) as? [String] ?? []
        return Routine(key: key, goals: goals, template: r["template"] as? String ?? goals.first ?? "",
                       bundleID: r["bundle_id"] as? String ?? "", appName: r["app_name"] as? String ?? "",
                       site: r["site"] as? String, startURL: r["start_url"] as? String, steps: steps,
                       count: Int(r["count"] as? Int64 ?? 1),
                       first: Date(timeIntervalSince1970: r["first_ts"] as? Double ?? 0),
                       last: Date(timeIntervalSince1970: r["last_ts"] as? Double ?? 0),
                       worked: Int(r["worked"] as? Int64 ?? 0), failed: Int(r["failed"] as? Int64 ?? 0))
    }

    private static func json(_ obj: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return "[]" }
        return s
    }
}
