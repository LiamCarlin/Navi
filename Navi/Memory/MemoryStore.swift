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
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: Schema

    private func migrate() throws {
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
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
        """)
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

    /// Deletes frames/sessions older than `days` and their thumbnails. Returns
    /// the number of frames removed.
    @discardableResult
    func pruneOlderThan(days: Int, now: Date = Date()) throws -> Int {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        return try queue.sync {
            let old = try query("SELECT id, thumb_path FROM frames WHERE ts < ?", [cutoff])
            for r in old {
                if let p = r["thumb_path"] as? String { try? FileManager.default.removeItem(atPath: p) }
            }
            try exec("BEGIN;")
            do {
                try run("DELETE FROM frames WHERE ts < ?", [cutoff])
                try run("DELETE FROM sessions_fts WHERE rowid IN (SELECT id FROM sessions WHERE end_ts < ?)", [cutoff])
                try run("DELETE FROM sessions WHERE end_ts < ?", [cutoff])
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
            Self.removeEmptyDirectories(under: framesDirectory)
            return old.count
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

    private static func json(_ obj: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return "[]" }
        return s
    }
}
