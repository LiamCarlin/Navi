import Foundation

/// Removes the vault notes **Navi wrote** — never the user's own notes.
///
/// A note is Navi's when its frontmatter carries one of Navi's tags
/// (`navi/session`, `navi/daily`, `navi/app`, `navi/topic`, `navi/entity`) or it is
/// one of the generated files under `Navi/`. Screenshots are removed only when a
/// removed session note embeds them (`![[attachments/….jpg]]`), so an image the
/// user dropped into `attachments/` stays.
///
/// Two users:
/// - retention (`MemoryService.prune`): the notes of sessions that aged out, Daily notes
///   older than the cutoff, and their lines in hub notes (a hub left with nothing but
///   Navi's own scaffold goes too);
/// - "Delete everything Navi has stored" (`PrivacyData.deleteAllLocalData`): every note Navi wrote.
struct VaultCleanup {
    let root: URL
    var calendar: Calendar = .current

    struct Report: Sendable, Equatable {
        var notesDeleted = 0
        var attachmentsDeleted = 0
        var hubsEdited = 0
    }

    static let naviTags: Set<String> = ["navi/session", "navi/daily", "navi/app", "navi/topic", "navi/entity"]
    /// Files under `Navi/` that Navi generates outright.
    static let generatedNotes = ["Navi/README.md", "Navi/How you work.md"]
    static let hubFolders = ["Apps", "Topics", "Entities"]

    // MARK: Classification

    /// The Navi tag in a note's frontmatter (`tags: [navi/session]`), if any.
    static func naviTag(in text: String) -> String? {
        guard text.hasPrefix("---") else { return nil }
        let note = MarkdownNote.parse(text)
        guard let tags = note.get("tags") else { return nil }
        let list = tags.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        return list.first(where: naviTags.contains)
    }

    /// `attachments/<name>.jpg` embedded by a session note.
    static func attachments(in text: String) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        while let r = rest.range(of: "![[attachments/") {
            let after = rest[r.upperBound...]
            guard let end = after.range(of: "]]") else { break }
            let name = String(after[..<end.lowerBound]).split(separator: "|").first.map(String.init) ?? ""
            if !name.isEmpty, !name.contains("/"), !name.contains("..") { out.append("attachments/" + name) }
            rest = after[end.upperBound...]
        }
        return out
    }

    // MARK: Retention

    /// Drops the notes of `sessionNotePaths` (vault-relative), Daily notes for days before
    /// `cutoff`, and every hub line that links a removed session.
    @discardableResult
    func prune(sessionNotePaths: [String], before cutoff: Date) -> Report {
        var report = Report()
        var removedStems: Set<String> = []
        for rel in sessionNotePaths {
            guard let url = safeURL(rel) else { continue }
            if removeNaviNote(at: url, expecting: "navi/session", report: &report) {
                removedStems.insert(String(rel.dropLast(rel.hasSuffix(".md") ? 3 : 0)))
            }
        }
        // Daily notes: `Daily/YYYY-MM-DD.md` for days entirely before the cutoff.
        let cutoffDay = dayString(cutoff)
        for url in markdownFiles(in: "Daily") {
            let day = url.deletingPathExtension().lastPathComponent
            guard day.count == 10, day < cutoffDay else { continue }
            _ = removeNaviNote(at: url, expecting: "navi/daily", report: &report)
        }
        if !removedStems.isEmpty { pruneHubs(removing: removedStems, report: &report) }
        removeEmptyFolders()
        return report
    }

    /// Removes hub lines (`- day time [[Sessions/…|…]]`) that point at removed sessions; a
    /// hub whose body is only Navi's scaffold afterwards is deleted.
    private func pruneHubs(removing stems: Set<String>, report: inout Report) {
        // Daily notes that stay (the cutoff day) lose their timeline line for the session too;
        // they always keep their section headings, so they are never "empty".
        for folder in Self.hubFolders + ["Daily"] {
            for url in markdownFiles(in: folder) {
                guard let text = try? String(contentsOf: url, encoding: .utf8), Self.naviTag(in: text) != nil else { continue }
                var note = MarkdownNote.parse(text)
                let lines = note.body.components(separatedBy: "\n")
                let kept = lines.filter { line in !stems.contains { line.contains("[[\($0)|") || line.contains("[[\($0)]]") } }
                guard kept.count != lines.count else { continue }
                note.body = kept.joined(separator: "\n")
                if Self.isEmptyHub(note.body) {
                    try? FileManager.default.removeItem(at: url)
                    report.notesDeleted += 1
                } else {
                    try? Data(note.render().utf8).write(to: url, options: .atomic)
                    report.hubsEdited += 1
                }
            }
        }
    }

    /// A hub body with nothing but `# Title` and an empty `## Seen in` — no user text.
    static func isEmptyHub(_ body: String) -> Bool {
        let meaningful = body.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("# ") && $0 != "## Seen in" }
        return meaningful.isEmpty
    }

    // MARK: Delete everything

    /// Every note Navi wrote, the screenshots those notes embed, and Navi's generated files.
    @discardableResult
    func deleteAllNaviNotes() -> Report {
        var report = Report()
        for folder in ["Sessions", "Daily"] + Self.hubFolders {
            for url in markdownFiles(in: folder) {
                _ = removeNaviNote(at: url, expecting: nil, report: &report)
            }
        }
        for rel in Self.generatedNotes {
            if let url = safeURL(rel), FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
                report.notesDeleted += 1
            }
        }
        removeEmptyFolders()
        return report
    }

    // MARK: Helpers

    /// Deletes `url` if it is a note Navi wrote (optionally with a specific tag) and the
    /// screenshots it embeds. Returns whether it was removed.
    private func removeNaviNote(at url: URL, expecting tag: String?, report: inout Report) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8), let found = Self.naviTag(in: text) else { return false }
        if let tag, found != tag { return false }
        for rel in Self.attachments(in: text) {
            if let a = safeURL(rel), FileManager.default.fileExists(atPath: a.path) {
                try? FileManager.default.removeItem(at: a)
                report.attachmentsDeleted += 1
            }
        }
        guard (try? FileManager.default.removeItem(at: url)) != nil else { return false }
        report.notesDeleted += 1
        return true
    }

    private func markdownFiles(in folder: String) -> [URL] {
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return items.filter { $0.pathExtension == "md" }
    }

    /// Vault-relative path → URL inside the vault (never outside it).
    private func safeURL(_ rel: String) -> URL? {
        guard !rel.isEmpty, !rel.hasPrefix("/"), !rel.split(separator: "/").contains("..") else { return nil }
        return root.appendingPathComponent(rel)
    }

    /// Navi's folders, once nothing (but Finder's `.DS_Store`) is left in them.
    private func removeEmptyFolders() {
        let fm = FileManager.default
        for f in VaultWriter.Folder.allCases {
            let dir = root.appendingPathComponent(f.rawValue, isDirectory: true)
            guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            if items.allSatisfy({ $0 == ".DS_Store" }) { try? fm.removeItem(at: dir) }
        }
    }

    private func dayString(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
