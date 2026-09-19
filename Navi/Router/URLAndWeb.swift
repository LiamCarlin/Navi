import Foundation
import AppKit

/// URL / domain detection and the always-available web-search fallback row.
enum URLAndWeb {

    static let navigationPrefixes = ["go to ", "goto ", "open ", "visit ", "browse ", "navigate to "]

    /// Common TLDs so "github.com" is a URL but "budget.xlsx" is not.
    static let knownTLDs: Set<String> = [
        "com", "org", "net", "io", "dev", "ai", "co", "app", "edu", "gov", "mil", "me", "us", "uk", "ca", "de", "fr",
        "jp", "in", "au", "tv", "gg", "xyz", "info", "biz", "sh", "so", "to", "ly", "is", "it", "es", "nl", "se", "no",
        "fi", "ch", "ru", "br", "cn", "kr", "nz", "ie", "be", "at", "dk", "pl", "cz", "pt", "mx", "ar", "cl", "za",
        "sg", "hk", "tw", "id", "th", "vn", "tech", "cloud", "page", "site", "online", "store", "news", "blog", "pro",
        "one", "run", "fm", "am", "cc", "ws", "eu", "asia", "design", "studio", "zone", "team", "systems", "tools",
        "wiki", "docs", "chat", "email", "social", "video", "live", "world", "space", "work", "money", "bank", "shop",
        "health", "life", "today", "click", "link", "pizza", "bio", "art", "ing", "ink", "cafe", "rocks", "guru",
    ]

    private static let domainRegex = try! NSRegularExpression(
        pattern: #"^(?:(https?|ftp)://)?(?:[a-z0-9-]+\.)+([a-z]{2,24})(?::\d{1,5})?(?:[/?#][^\s]*)?$"#, options: [.caseInsensitive])
    private static let localRegex = try! NSRegularExpression(
        pattern: #"^(?:https?://)?(?:localhost|127\.0\.0\.1|0\.0\.0\.0|(?:\d{1,3}\.){3}\d{1,3})(?::\d{1,5})?(?:[/?#][^\s]*)?$"#, options: [.caseInsensitive])

    /// Strips "go to "/"open " and returns the URL if the query is one.
    static func detect(_ query: String) -> URL? {
        var q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = q.lowercased()
        for p in navigationPrefixes where lower.hasPrefix(p) { q = String(q.dropFirst(p.count)).trimmingCharacters(in: .whitespaces); break }
        guard !q.isEmpty, !q.contains(" "), !q.contains("@") else { return nil }
        let range = NSRange(q.startIndex..., in: q)
        if let m = domainRegex.firstMatch(in: q, range: range) {
            let hasScheme = m.range(at: 1).location != NSNotFound
            if let tldR = Range(m.range(at: 2), in: q) {
                let tld = q[tldR].lowercased()
                if !hasScheme && !knownTLDs.contains(tld) { return nil }
            }
            return URL(string: hasScheme ? q : "https://\(q)")
        }
        if localRegex.firstMatch(in: q, range: range) != nil {
            return URL(string: q.lowercased().hasPrefix("http") ? q : "http://\(q)")
        }
        return nil
    }

    static func results(for query: String) -> [SearchResult] {
        guard let url = detect(query) else { return [] }
        return [urlResult(url)]
    }

    static func urlResult(_ url: URL, score: Double = 0.96) -> SearchResult {
        let display = url.absoluteString
        let host = url.host ?? display
        return SearchResult(id: "url:\(display)", kind: .url, title: host, subtitle: display,
                            icon: .system("safari"), score: score, shortcutHint: "⏎ Open") {
            NSWorkspace.shared.open(url)
            return .dismiss
        }
    }

    // MARK: - Web search

    static func googleURL(for query: String) -> URL {
        var comps = URLComponents(string: "https://www.google.com/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        return comps.url!
    }

    /// Low-score fallback row: "Search Google for …".
    static func webSearchResult(for query: String, score: Double = 0.02) -> SearchResult {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = googleURL(for: q)
        return SearchResult(id: "web:\(q)", kind: .webSearch, title: "Search Google for “\(q)”", subtitle: "google.com",
                            icon: .system("magnifyingglass"), score: score, shortcutHint: "⏎ Search") {
            NSWorkspace.shared.open(url)
            return .dismiss
        }
    }
}
