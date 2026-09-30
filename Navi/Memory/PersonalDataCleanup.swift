import Foundation

/// One-off cleanup for memory written before the personal-data guard existed
/// (`PersonalData`): finds frames and sessions holding identifiers and redacts
/// them in the database and the Obsidian vault.
///
/// `plan()` only reads. `apply(_:)` then:
/// - frames the guard now calls sensitive (and frames inside a flagged session
///   that carry any identifier) → `MemoryStore.markSensitiveAndDelete` (stub row,
///   thumbnail deleted);
/// - sessions → title/summary redacted, entities/topics that repeat a redacted
///   value dropped (`PersonalData.scrub`), search row rewritten;
/// - the session note → same text, personal key facts and the screenshot
///   removed (attachment deleted), renamed if its file name held an identifier;
/// - the Daily note and the hub notes of dropped entities/topics → redacted,
///   links to dropped names removed, hubs left with nothing deleted;
/// - finally the database is vacuumed so the old text is gone from disk.
///
/// Run it with `scripts/memscrub` (dry run by default). Nothing here logs a value.
struct PersonalDataCleanup {
    let store: MemoryStore
    let vaultRoot: URL

    struct SessionFix: Sendable, Equatable {
        var before: SessionRecord
        var after: SessionRecord
        /// Key facts to keep in the note (nil = the note has no key facts section).
        var keptKeyFacts: [String]?
        var kinds: Set<PersonalData.Kind>
    }

    struct Plan: Sendable {
        var frameIDs: [Int64] = []
        var sessions: [SessionFix] = []
        var framesScanned = 0
        var sessionsScanned = 0
    }

    struct Report: Sendable, Equatable, CustomStringConvertible {
        var framesRedacted = 0
        var sessionsRedacted = 0
        var notesRewritten = 0
        var notesRenamed = 0
        var dailyNotesRewritten = 0
        var hubNotesRewritten = 0
        var hubNotesDeleted = 0
        var attachmentsDeleted = 0

        var description: String {
            """
            frames redacted: \(framesRedacted)
            sessions redacted: \(sessionsRedacted)
            session notes rewritten: \(notesRewritten) (renamed \(notesRenamed))
            daily notes rewritten: \(dailyNotesRewritten)
            hub notes rewritten: \(hubNotesRewritten), deleted: \(hubNotesDeleted)
            screenshots deleted: \(attachmentsDeleted)
            """
        }
    }

    // MARK: Plan (read-only)

    func plan() throws -> Plan {
        var plan = Plan()
        var flagged = Set<Int64>()

        let sessions = try store.recentSessions(limit: 1_000_000)
        plan.sessionsScanned = sessions.count
        for s in sessions {
            let note = s.notePath.flatMap { try? String(contentsOf: vaultRoot.appendingPathComponent($0), encoding: .utf8) }
            let facts = note.map(Self.keyFacts(in:))
            let digest = DigestResult(title: s.title, summary: s.summary, topics: s.topics, entities: s.entities,
                                      keyFacts: facts ?? [], links: [])
            let (clean, removed) = PersonalData.scrub(digest)
            // The note also carries the file name, links and the day's one-liner.
            let noteHits = note.map { PersonalData.findings(in: $0, includeRedactOnly: true) } ?? []
            guard removed > 0 || !noteHits.isEmpty else { continue }
            var after = s
            after.title = clean.title; after.summary = clean.summary
            after.topics = clean.topics; after.entities = clean.entities
            let kinds = PersonalData.redact([s.title, s.summary, note ?? ""].joined(separator: "\n")).kinds
            plan.sessions.append(SessionFix(before: s, after: after, keptKeyFacts: facts.map { _ in clean.keyFacts }, kinds: kinds))

            // Frames of a flagged session: any identifier at all is enough.
            for f in try store.frames(in: DateInterval(start: s.start, end: max(s.start, s.end)), limit: 5000)
            where !f.ocrText.isEmpty || f.windowTitle != nil {
                let text = [f.windowTitle ?? "", f.url ?? "", f.ocrText].joined(separator: "\n")
                if !PersonalData.findings(in: text).isEmpty { flagged.insert(f.id) }
            }
        }

        var after: Int64 = 0
        while true {
            let page = try store.framesWithText(afterID: after)
            guard let last = page.last else { break }
            after = last.id
            plan.framesScanned += page.count
            for f in page {
                let input = FrameTriage.Input(bundleID: f.bundleID, appName: f.appName, windowTitle: f.windowTitle, url: f.url,
                                              timestamp: f.timestamp, ocrText: f.ocrText, previousApp: nil, previousTitle: nil)
                let signals = PersonalData.signals(text: f.ocrText, title: f.windowTitle, url: f.url)
                if FrameTriage.locallySensitive(input, signals: signals) { flagged.insert(f.id) }
            }
        }
        plan.frameIDs = flagged.sorted()
        return plan
    }

    // MARK: Apply

    @discardableResult
    func apply(_ plan: Plan) throws -> Report {
        var report = Report()
        for id in plan.frameIDs {
            try store.markSensitiveAndDelete(frameID: id)
            report.framesRedacted += 1
        }
        let fm = FileManager.default
        for fix in plan.sessions {
            var after = fix.after
            if let rel = fix.before.notePath {
                let url = vaultRoot.appendingPathComponent(rel)
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    let r = Self.scrubSessionNote(text, fix: fix)
                    try Self.write(r.text, to: url)
                    report.notesRewritten += 1
                    if let a = r.attachment, fm.fileExists(atPath: vaultRoot.appendingPathComponent(a).path) {
                        try fm.removeItem(at: vaultRoot.appendingPathComponent(a))
                        report.attachmentsDeleted += 1
                    }
                    // A file name that holds an identifier is renamed; links follow.
                    let oldStem = (rel as NSString).deletingPathExtension
                    let newStem = PersonalData.redact(oldStem).text.replacingOccurrences(of: PersonalData.placeholder, with: "redacted")
                    var renames: [(String, String)] = []
                    if newStem != oldStem {
                        try fm.moveItem(at: url, to: vaultRoot.appendingPathComponent(newStem + ".md"))
                        after.notePath = newStem + ".md"
                        try store.updateSessionNotePath(sessionID: fix.before.id, notePath: newStem + ".md")
                        renames.append((oldStem, newStem))
                        report.notesRenamed += 1
                    }
                    let day = MarkdownNote.parse(text).get("date")
                    report.dailyNotesRewritten += try scrubDaily(day: day, fix: fix, renames: renames)
                    let (rewritten, deleted) = try scrubHubs(fix: fix, sessionStem: oldStem, renames: renames)
                    report.hubNotesRewritten += rewritten; report.hubNotesDeleted += deleted
                }
            }
            try store.updateSessionText(after)
            report.sessionsRedacted += 1
        }
        if report.framesRedacted + report.sessionsRedacted > 0 { try store.compactAfterRedaction() }
        return report
    }

    // MARK: Vault helpers

    private func scrubDaily(day: String?, fix: SessionFix, renames: [(String, String)]) throws -> Int {
        guard let day else { return 0 }
        let url = vaultRoot.appendingPathComponent("Daily/\(day).md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        let dropped = Self.droppedLinks(fix)
        var lines = text.components(separatedBy: "\n").filter { line in
            !dropped.contains { line.trimmingCharacters(in: .whitespaces) == "- \($0)" }
        }
        lines = lines.map { Self.rename(PersonalData.redact($0).text, renames) }
        let out = lines.joined(separator: "\n")
        guard out != text else { return 0 }
        try Self.write(out, to: url)
        return 1
    }

    /// Hubs of dropped entities/topics lose this session's "Seen in" line; a hub
    /// left with none is deleted. Other hubs linking the session follow a rename.
    private func scrubHubs(fix: SessionFix, sessionStem: String, renames: [(String, String)]) throws -> (Int, Int) {
        var rewritten = 0, deleted = 0
        let fm = FileManager.default
        let droppedPaths = Self.droppedHubPaths(fix)
        var paths = droppedPaths
        if !renames.isEmpty {
            paths += fix.after.topics.map { "Topics/\(VaultWriter.slug($0)).md" }
            paths += fix.after.entities.map { "Entities/\(VaultWriter.slug($0.name)).md" }
            paths.append("Apps/\(VaultWriter.slug(fix.before.appName)).md")
        }
        for rel in Set(paths) {
            let url = vaultRoot.appendingPathComponent(rel)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var note = MarkdownNote.parse(text)
            if droppedPaths.contains(rel) {
                let lines = note.body.components(separatedBy: "\n").filter { !$0.contains("[[\(sessionStem)") }
                if !lines.contains(where: { $0.hasPrefix("- ") && $0.contains("[[Sessions/") }) {
                    try fm.removeItem(at: url); deleted += 1; continue
                }
                note.body = lines.joined(separator: "\n")
            }
            note.body = Self.rename(note.body, renames)
            let out = note.render()
            if out != text { try Self.write(out, to: url); rewritten += 1 }
        }
        return (rewritten, deleted)
    }

    private static func droppedLinks(_ fix: SessionFix) -> [String] {
        droppedHubPaths(fix).map { VaultWriter.wikilink(($0 as NSString).deletingPathExtension) }
    }

    private static func droppedHubPaths(_ fix: SessionFix) -> [String] {
        let keptTopics = Set(fix.after.topics.map { VaultWriter.slug($0) })
        let keptEntities = Set(fix.after.entities.map { VaultWriter.slug($0.name) })
        let topics = fix.before.topics.map { VaultWriter.slug($0) }.filter { !$0.isEmpty && !keptTopics.contains($0) }
        let entities = fix.before.entities.map { VaultWriter.slug($0.name) }.filter { !$0.isEmpty && !keptEntities.contains($0) }
        return topics.map { "Topics/\($0).md" } + entities.map { "Entities/\($0).md" }
    }

    private static func rename(_ s: String, _ renames: [(String, String)]) -> String {
        renames.reduce(s) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    private static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    // MARK: Pure note transforms (tested)

    /// Bullet lines of a session note's `## Key facts` section.
    static func keyFacts(in note: String) -> [String] {
        section("Key facts", in: note).compactMap { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : nil }
    }

    private static func section(_ heading: String, in note: String) -> [String] {
        let lines = note.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "## \(heading)") else { return [] }
        return Array(lines[(start + 1)...].prefix { !$0.hasPrefix("## ") && !$0.hasPrefix("# ") })
    }

    /// The session note with the fix applied: title, topics and entities from
    /// `fix.after`, only the kept key facts, no screenshot section, every other
    /// line redacted. Returns the attachment the screenshot pointed to.
    static func scrubSessionNote(_ text: String, fix: SessionFix) -> (text: String, attachment: String?) {
        let appNote = VaultWriter.slug(fix.before.appName.isEmpty ? "Unknown" : fix.before.appName)
        let topics = fix.after.topics.map { VaultWriter.slug($0) }.filter { !$0.isEmpty }
        let entities = fix.after.entities.map { VaultWriter.slug($0.name) }.filter { !$0.isEmpty && $0 != appNote }
        let keep = fix.keptKeyFacts.map { Set($0.map { "- \($0)" }) }
        var out: [String] = []
        var attachment: String?
        var inFrontmatter = false, frontmatterDone = false
        var current: String?
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            if line == "---", !frontmatterDone, i == 0 || inFrontmatter {
                inFrontmatter.toggle(); if !inFrontmatter { frontmatterDone = true }
                out.append(line); continue
            }
            if inFrontmatter {
                if line.hasPrefix("title:") { out.append("title: \(VaultWriter.yaml(fix.after.title))") }
                else if line.hasPrefix("topics:") { out.append("topics: [\(topics.map(VaultWriter.yaml).joined(separator: ", "))]") }
                else if line.hasPrefix("entities:") { out.append("entities: [\(entities.map(VaultWriter.yaml).joined(separator: ", "))]") }
                else { out.append(PersonalData.redact(line).text) }
                continue
            }
            if line.hasPrefix("## ") || line.hasPrefix("# ") { current = line }
            if line.hasPrefix("# ") { out.append("# \(fix.after.title)"); continue }
            switch current {
            case "## Screenshot":
                if line.hasPrefix("![["), let end = line.range(of: "]]") {
                    attachment = String(line[line.index(line.startIndex, offsetBy: 3)..<end.lowerBound])
                }
                continue   // the whole section goes
            case "## Key facts" where line.hasPrefix("- "):
                if let keep, !keep.contains(line) { continue }
            case "## Related" where line.hasPrefix("- Topics: "):
                if !topics.isEmpty { out.append("- Topics: " + topics.map { VaultWriter.wikilink("Topics/\($0)") }.joined(separator: ", ")) }
                continue
            case "## Related" where line.hasPrefix("- Entities: "):
                if !entities.isEmpty { out.append("- Entities: " + entities.map { VaultWriter.wikilink("Entities/\($0)") }.joined(separator: ", ")) }
                continue
            default:
                break
            }
            out.append(PersonalData.redact(line).text)
        }
        // A key-facts heading with nothing left under it goes too.
        var cleaned: [String] = []
        for (i, line) in out.enumerated() {
            if line == "## Key facts" {
                let rest = out[(i + 1)...].prefix { !$0.hasPrefix("## ") }
                if !rest.contains(where: { $0.hasPrefix("- ") }) { continue }
            }
            cleaned.append(line)
        }
        var result = cleaned.joined(separator: "\n")
        while result.contains("\n\n\n") { result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return (result, attachment)
    }
}
