import Foundation

/// Writes the Obsidian vault. Layout:
///
///   <vault>/
///     .obsidian/app.json, graph.json       created once
///     Navi/README.md                       explains the structure
///     Daily/YYYY-MM-DD.md                  timeline of the day + topic/entity lists
///     Sessions/YYYY-MM-DD HHmm <slug>.md   one note per digested session
///     Entities/<Name>.md                   people, projects, companies, tools, sites, files, concepts
///     Topics/<Topic>.md
///     Apps/<App>.md
///     attachments/<session>.jpg            one thumbnail per session (optional)
///
/// Every note links back to its Daily note, App, Topics and Entities, so the
/// Graph view becomes a map of the user's day. All writes are atomic
/// (temp file + rename) and serialised on one queue.
final class VaultWriter: @unchecked Sendable {
    let root: URL
    private let queue = DispatchQueue(label: "com.liamcarlin.navi.memory.vault", qos: .utility)
    private let calendar: Calendar

    enum Folder: String, CaseIterable {
        case daily = "Daily", sessions = "Sessions", entities = "Entities", topics = "Topics", apps = "Apps"
        case attachments = "attachments", navi = "Navi"
    }

    init(root: URL, calendar: Calendar = .current) {
        self.root = root
        self.calendar = calendar
    }

    // MARK: Scaffold

    /// Creates folders, `.obsidian` config and the README if they don't exist.
    func ensureScaffold() throws {
        try queue.sync { try scaffoldLocked() }
    }

    private func scaffoldLocked() throws {
        let fm = FileManager.default
        for f in Folder.allCases {
            try fm.createDirectory(at: root.appendingPathComponent(f.rawValue, isDirectory: true), withIntermediateDirectories: true)
        }
        let obsidian = root.appendingPathComponent(".obsidian", isDirectory: true)
        try fm.createDirectory(at: obsidian, withIntermediateDirectories: true)
        try writeIfMissing(obsidian.appendingPathComponent("app.json"), "{}\n")
        try writeIfMissing(obsidian.appendingPathComponent("graph.json"), Self.graphJSON)
        try writeIfMissing(root.appendingPathComponent("Navi/README.md"), Self.readme)
    }

    // MARK: Session write

    /// Writes the session note, updates the daily note and every linked
    /// entity/topic/app note. Returns the session note path relative to the vault.
    func write(session: SessionRecord, digest: DigestResult, frames: [FrameRecord], keepScreenshots: Bool) throws -> String {
        try queue.sync {
            try scaffoldLocked()
            let day = dayString(session.start)
            let stem = Self.sessionStem(start: session.start, title: session.title, calendar: calendar)
            var sessionName = stem
            var n = 2
            while FileManager.default.fileExists(atPath: root.appendingPathComponent("Sessions/\(sessionName).md").path) {
                sessionName = "\(stem) \(n)"; n += 1
            }
            let sessionRel = "Sessions/\(sessionName)"
            let sessionLink = Self.wikilink(sessionRel, alias: session.title)
            let appNote = Self.slug(session.appName.isEmpty ? "Unknown" : session.appName)
            let topics = digest.topics.map { Self.slug($0) }.filter { !$0.isEmpty }
            let entities = digest.entities.map { EntityRef(name: Self.slug($0.name), type: $0.type) }.filter { !$0.name.isEmpty && $0.name != appNote }

            // Attachment (one thumbnail per session).
            var attachment: String?
            if keepScreenshots,
               let best = frames.filter({ $0.thumbPath != nil }).max(by: { $0.importance == $1.importance ? $0.timestamp > $1.timestamp : $0.importance < $1.importance }),
               let src = best.thumbPath, FileManager.default.fileExists(atPath: src) {
                let dest = root.appendingPathComponent("attachments/\(sessionName).jpg")
                if let data = FileManager.default.contents(atPath: src) {
                    try data.write(to: dest, options: .atomic)
                    attachment = "attachments/\(sessionName).jpg"
                }
            }

            // Session note.
            let note = Self.sessionNote(session: session, digest: digest, day: day, appNote: appNote,
                                        topics: topics, entities: entities, attachment: attachment,
                                        frameCount: frames.count, calendar: calendar)
            try atomicWrite(root.appendingPathComponent("\(sessionRel).md"), note)

            // Daily note.
            try updateDaily(day: day, session: session, digest: digest, sessionLink: sessionLink,
                            appNote: appNote, topics: topics, entities: entities)

            // Hub notes.
            let seenIn = "- \(day) \(timeString(session.start)) \(sessionLink)"
            try upsertHub(path: "Apps/\(appNote).md", title: session.appName, type: "app", subtype: nil, day: day, seenIn: seenIn)
            for t in topics {
                try upsertHub(path: "Topics/\(t).md", title: t, type: "topic", subtype: nil, day: day, seenIn: seenIn)
            }
            for e in entities {
                try upsertHub(path: "Entities/\(e.name).md", title: e.name, type: "entity", subtype: e.type, day: day, seenIn: seenIn)
            }
            return "\(sessionRel).md"
        }
    }

    // MARK: Note builders

    static func sessionNote(session: SessionRecord, digest: DigestResult, day: String, appNote: String,
                            topics: [String], entities: [EntityRef], attachment: String?, frameCount: Int,
                            calendar: Calendar) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = calendar.timeZone
        var fm: [String] = ["---", "type: session"]
        fm.append("title: \(yaml(session.title))")
        fm.append("date: \(day)")
        fm.append("start: \(iso.string(from: session.start))")
        fm.append("end: \(iso.string(from: session.end))")
        fm.append("app: \(yaml(session.appName))")
        if let u = session.url, !u.isEmpty { fm.append("url: \(yaml(u))") }
        fm.append("topics: [\(topics.map(yaml).joined(separator: ", "))]")
        fm.append("entities: [\(entities.map { yaml($0.name) }.joined(separator: ", "))]")
        fm.append("importance: \(Int(session.importance.rounded()))")
        fm.append("frames: \(frameCount)")
        fm.append("tags: [navi/session]")
        fm.append("---")

        var body: [String] = ["# \(session.title)", ""]
        let tf = DateFormatter(); tf.calendar = calendar; tf.timeZone = calendar.timeZone; tf.dateFormat = "HH:mm"
        body.append("*\(day) \(tf.string(from: session.start))–\(tf.string(from: session.end)) · \(wikilink("Apps/\(appNote)", alias: session.appName))*")
        body.append("")
        body.append(digest.summary.isEmpty ? "_No summary._" : digest.summary)
        body.append("")
        if !digest.keyFacts.isEmpty {
            body.append("## Key facts")
            body += digest.keyFacts.map { "- \($0)" }
            body.append("")
        }
        if !digest.links.isEmpty {
            body.append("## Links")
            body += digest.links.map { "- \($0)" }
            body.append("")
        }
        if let attachment {
            body.append("## Screenshot")
            body.append("![[\(attachment)]]")
            body.append("")
        }
        body.append("## Related")
        body.append("- \(wikilink("Daily/\(day)"))")
        body.append("- \(wikilink("Apps/\(appNote)"))")
        if !topics.isEmpty { body.append("- Topics: " + topics.map { wikilink("Topics/\($0)") }.joined(separator: ", ")) }
        if !entities.isEmpty { body.append("- Entities: " + entities.map { wikilink("Entities/\($0.name)") }.joined(separator: ", ")) }
        body.append("")
        return (fm + [""] + body).joined(separator: "\n")
    }

    private func updateDaily(day: String, session: SessionRecord, digest: DigestResult, sessionLink: String,
                             appNote: String, topics: [String], entities: [EntityRef]) throws {
        let url = root.appendingPathComponent("Daily/\(day).md")
        var note = (try? String(contentsOf: url, encoding: .utf8)).map(MarkdownNote.parse) ?? MarkdownNote(
            frontmatter: [("date", day), ("type", "daily"), ("tags", "[navi/daily]")],
            body: "# \(day)\n\n## Timeline\n\n## Topics\n\n## People & things\n")
        let oneLiner = Self.oneLine(digest.summary)
        let line = "- **\(timeString(session.start))–\(timeString(session.end))** \(sessionLink) — \(oneLiner) · \(Self.wikilink("Apps/\(appNote)"))"
        note.append(line, toSection: "Timeline", dedupe: true)
        for t in topics { note.append("- \(Self.wikilink("Topics/\(t)"))", toSection: "Topics", dedupe: true) }
        for e in entities { note.append("- \(Self.wikilink("Entities/\(e.name)"))", toSection: "People & things", dedupe: true) }
        try atomicWrite(url, note.render())
    }

    private func upsertHub(path: String, title: String, type: String, subtype: String?, day: String, seenIn: String) throws {
        let url = root.appendingPathComponent(path)
        var note: MarkdownNote
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            note = MarkdownNote.parse(existing)
            note.set("last_seen", day)
            let count = Int(note.get("count") ?? "0") ?? 0
            note.set("count", String(count + 1))
            if let subtype, note.get("entity_type") == nil { note.set("entity_type", subtype) }
        } else {
            var fm: [(String, String)] = [("type", type)]
            if let subtype { fm.append(("entity_type", subtype)) }
            fm += [("first_seen", day), ("last_seen", day), ("count", "1"), ("tags", "[navi/\(type)]")]
            note = MarkdownNote(frontmatter: fm, body: "# \(title)\n\n## Seen in\n")
        }
        note.append(seenIn, toSection: "Seen in", dedupe: true)
        try atomicWrite(url, note.render())
    }

    // MARK: Counting

    /// Number of `.md` notes in the vault (excluding `.obsidian`).
    func noteCount() -> Int {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return 0 }
        var n = 0
        for case let u as URL in e where u.pathExtension == "md" { n += 1 }
        return n
    }

    // MARK: Naming helpers

    /// Obsidian-safe note name: strips `/\:*?"<>|#^[]`, collapses whitespace, keeps case.
    static func slug(_ s: String, maxLength: Int = 60) -> String {
        let forbidden: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "#", "^", "[", "]"]
        var out = ""
        var lastSpace = false
        for ch in s {
            if forbidden.contains(ch) || ch.isNewline { continue }
            if ch.isWhitespace {
                if !lastSpace && !out.isEmpty { out.append(" ") }
                lastSpace = true
            } else {
                out.append(ch); lastSpace = false
            }
        }
        var trimmed = out.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix(".") { trimmed.removeLast() }
        if trimmed.count > maxLength {
            trimmed = String(trimmed.prefix(maxLength))
            if let cut = trimmed.lastIndex(of: " "), trimmed.distance(from: trimmed.startIndex, to: cut) > maxLength / 2 {
                trimmed = String(trimmed[..<cut])
            }
            trimmed = trimmed.trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    /// `[[path|alias]]` (alias omitted when equal to the note name).
    static func wikilink(_ path: String, alias: String? = nil) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        if let alias, !alias.isEmpty, alias != name { return "[[\(path)|\(alias.replacingOccurrences(of: "|", with: "-").replacingOccurrences(of: "]]", with: ""))]]" }
        return "[[\(path)]]"
    }

    static func sessionStem(start: Date, title: String, calendar: Calendar) -> String {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd HHmm"
        let s = slug(title, maxLength: 50)
        return "\(f.string(from: start)) \(s.isEmpty ? "Session" : s)"
    }

    static func oneLine(_ summary: String, max: Int = 160) -> String {
        let flat = summary.split(whereSeparator: \.isNewline).joined(separator: " ")
        var first = flat
        if let dot = flat.range(of: ". ") { first = String(flat[..<dot.lowerBound]) + "." }
        if first.count > max { first = String(first.prefix(max - 1)) + "…" }
        return first.trimmingCharacters(in: .whitespaces)
    }

    static func yaml(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func dayString(_ d: Date) -> String {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }

    private func timeString(_ d: Date) -> String {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "HH:mm"; return f.string(from: d)
    }

    // MARK: File helpers

    private func atomicWrite(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private func writeIfMissing(_ url: URL, _ text: String) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try atomicWrite(url, text)
    }

    // MARK: Static content

    static let graphJSON = """
    {
      "collapse-filter": true,
      "search": "",
      "showTags": false,
      "showAttachments": false,
      "hideUnresolved": true,
      "showOrphans": false,
      "collapse-color-groups": false,
      "colorGroups": [
        { "query": "path:Daily", "color": { "a": 1, "rgb": 16766720 } },
        { "query": "path:Sessions", "color": { "a": 1, "rgb": 8900331 } },
        { "query": "path:Entities", "color": { "a": 1, "rgb": 16738740 } },
        { "query": "path:Topics", "color": { "a": 1, "rgb": 5025616 } },
        { "query": "path:Apps", "color": { "a": 1, "rgb": 9662683 } }
      ],
      "collapse-display": true,
      "showArrow": false,
      "textFadeMultiplier": 0,
      "nodeSizeMultiplier": 1.1,
      "lineSizeMultiplier": 0.8,
      "collapse-forces": true,
      "centerStrength": 0.45,
      "repelStrength": 12,
      "linkStrength": 1,
      "linkDistance": 220,
      "scale": 1,
      "close": false
    }
    """

    static let readme = """
    # Navi Vault

    This vault is written automatically by **Navi → Screen Memory**. Every few minutes Navi
    snapshots the screen, reads the text on it locally (Vision OCR), lets Jev decide whether
    the moment matters, and asks a cheap model to summarise each stretch of activity.

    ## Layout

    - `Daily/YYYY-MM-DD.md` — the day's timeline, plus the topics and people/things it touched.
    - `Sessions/YYYY-MM-DD HHmm <title>.md` — one note per stretch of activity: summary, key facts, links, a screenshot.
    - `Entities/` — people, projects, companies, tools, sites, files, concepts. Each lists the sessions it appeared in.
    - `Topics/` — recurring subjects. Each lists the sessions about it.
    - `Apps/` — one note per application.
    - `attachments/` — one thumbnail per session (only when *Keep screenshots* is on).
    - `Navi/` — this file.

    Open **Graph view** to see the day as a map: sessions hang off their day, and share
    edges through the topics, entities and apps they have in common.

    ## Editing

    Feel free to edit any note. Navi only *appends* to Daily and hub notes (`Entities/`, `Topics/`,
    `Apps/`) and updates their `last_seen` / `count` frontmatter; it never rewrites your text.
    Sessions are written once. Deleting a note is safe.

    Nothing marked sensitive by Jev (password fields, banking, 2FA codes) ever reaches this vault.
    """
}

// MARK: - Minimal markdown note model

/// Frontmatter (ordered key/values) + body with `## Section` blocks. Just
/// enough to append bullets to a section and bump counters without
/// disturbing anything the user typed.
struct MarkdownNote: Equatable {
    var frontmatter: [(String, String)]
    var body: String

    static func == (a: MarkdownNote, b: MarkdownNote) -> Bool {
        a.body == b.body && a.frontmatter.map { "\($0.0)=\($0.1)" } == b.frontmatter.map { "\($0.0)=\($0.1)" }
    }

    static func parse(_ text: String) -> MarkdownNote {
        var lines = text.components(separatedBy: "\n")
        var fm: [(String, String)] = []
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            for l in lines[1..<end] {
                guard let colon = l.firstIndex(of: ":") else { continue }
                let key = String(l[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(l[l.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                fm.append((key, value))
            }
            lines.removeSubrange(0...end)
            if lines.first == "" { lines.removeFirst() }
        }
        return MarkdownNote(frontmatter: fm, body: lines.joined(separator: "\n"))
    }

    func get(_ key: String) -> String? { frontmatter.first { $0.0 == key }?.1 }

    mutating func set(_ key: String, _ value: String) {
        if let i = frontmatter.firstIndex(where: { $0.0 == key }) { frontmatter[i].1 = value } else { frontmatter.append((key, value)) }
    }

    /// Appends `line` at the end of `## heading` (creating the section at the
    /// end of the note if needed). With `dedupe`, an identical existing line is left alone.
    mutating func append(_ line: String, toSection heading: String, dedupe: Bool) {
        var lines = body.components(separatedBy: "\n")
        let marker = "## \(heading)"
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == marker }) else {
            var trimmed = lines
            while trimmed.last == "" { trimmed.removeLast() }
            body = (trimmed + ["", marker, line, ""]).joined(separator: "\n")
            return
        }
        var end = lines.count
        for i in (start + 1)..<lines.count where lines[i].hasPrefix("## ") || lines[i].hasPrefix("# ") { end = i; break }
        let section = lines[(start + 1)..<end]
        if dedupe, section.contains(where: { $0 == line }) { return }
        var insertAt = end
        while insertAt > start + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
        lines.insert(line, at: insertAt)
        if insertAt + 1 == lines.count || !lines[insertAt + 1].isEmpty { lines.insert("", at: insertAt + 1) }
        body = lines.joined(separator: "\n")
    }

    func render() -> String {
        var out = ""
        if !frontmatter.isEmpty {
            out += "---\n" + frontmatter.map { "\($0.0): \($0.1)" }.joined(separator: "\n") + "\n---\n\n"
        }
        out += body
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }
}
