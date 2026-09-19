import Foundation
import AppKit

/// Spotlight-index file search (`NSMetadataQuery`) scoped to the home folder.
/// Hard-capped at 400 ms: whatever has been gathered by then is returned.
enum FileSearch {

    struct Hit: Sendable, Equatable {
        let path: String
        let name: String
        let modified: Date?
    }

    static let filePrefixes = ["open file ", "find file ", "find ", "open ", "file ", "show ", "search "]
    static let fileWords: Set<String> = ["file", "files", "pdf", "doc", "docx", "screenshot", "screenshots", "document",
                                         "spreadsheet", "xlsx", "csv", "image", "photo", "png", "jpg", "folder", "download", "downloads"]
    private static let extensionRegex = try! NSRegularExpression(pattern: #"\.[a-z0-9]{1,5}$"#, options: [.caseInsensitive])

    /// True when the query has a file extension or mentions files/pdf/doc/screenshot.
    static func looksLikeFile(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty, URLAndWeb.detect(q) == nil else { return false }
        let last = q.split(separator: " ").last.map(String.init) ?? q
        if extensionRegex.firstMatch(in: last, range: NSRange(last.startIndex..., in: last)) != nil,
           !last.hasPrefix("."), last.count > 3 { return true }
        return q.split(separator: " ").contains { fileWords.contains(String($0)) }
    }

    /// Removes "open "/"find file " and filler words ("the", "my", "file") for the predicate.
    static func cleanQuery(_ query: String) -> String {
        var q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = q.lowercased()
        for p in filePrefixes where lower.hasPrefix(p) { q = String(q.dropFirst(p.count)); break }
        let filler: Set<String> = ["the", "my", "a", "that", "file", "files", "called", "named", "document"]
        let words = q.split(separator: " ").map(String.init).filter { !filler.contains($0.lowercased()) }
        return words.isEmpty ? q.trimmingCharacters(in: .whitespaces) : words.joined(separator: " ")
    }

    @MainActor
    static func search(_ query: String, limit: Int = 8, timeoutMs: Int = 400) async -> [Hit] {
        let term = cleanQuery(query)
        guard term.count >= 2 else { return [] }
        let runner = MetadataRunner(term: term, limit: limit)
        return await runner.run(timeoutMs: timeoutMs)
    }

    @MainActor
    static func results(for query: String, limit: Int = 8) async -> [SearchResult] {
        let hits = await search(query, limit: limit)
        let rel = RelativeDateTimeFormatter(); rel.unitsStyle = .abbreviated
        return hits.enumerated().map { (i, h) in
            let dir = ((h.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
            var subtitle = dir
            if let m = h.modified { subtitle += " · \(rel.localizedString(for: m, relativeTo: Date()))" }
            let url = URL(fileURLWithPath: h.path)
            return SearchResult(id: "file:\(h.path)", kind: .file, title: h.name, subtitle: subtitle,
                                icon: .file(h.path), score: 0.7 - Double(i) * 0.01, shortcutHint: "⏎ Open") {
                NSWorkspace.shared.open(url)
                return .dismiss
            }
        }
    }

    /// Owns one NSMetadataQuery lifecycle on the main thread.
    @MainActor
    private final class MetadataRunner {
        private let query = NSMetadataQuery()
        private var continuation: CheckedContinuation<[Hit], Never>?
        private var observer: NSObjectProtocol?
        private let limit: Int

        init(term: String, limit: Int) {
            self.limit = limit
            let name = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemDisplayNameKey, term)
            let content = NSPredicate(format: "%K CONTAINS[cd] %@", "kMDItemTextContent", term)
            query.predicate = term.count >= 4 ? NSCompoundPredicate(orPredicateWithSubpredicates: [name, content]) : name
            query.searchScopes = [NSMetadataQueryUserHomeScope]
            query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
            query.valueListAttributes = []
        }

        func run(timeoutMs: Int) async -> [Hit] {
            await withCheckedContinuation { (c: CheckedContinuation<[Hit], Never>) in
                continuation = c
                observer = NotificationCenter.default.addObserver(
                    forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.finish() }
                }
                guard query.start() else { finish(); return }
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(timeoutMs))
                    self?.finish()
                }
            }
        }

        private func finish() {
            guard let c = continuation else { return }
            continuation = nil
            query.disableUpdates()
            var hits: [Hit] = []
            let count = min(query.resultCount, limit)
            if count > 0 {
                for i in 0..<count {
                    guard let item = query.result(at: i) as? NSMetadataItem,
                          let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                    let name = (item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String) ?? (path as NSString).lastPathComponent
                    let mod = item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
                    hits.append(Hit(path: path, name: name, modified: mod))
                }
            }
            query.stop()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            c.resume(returning: hits)
        }
    }
}
