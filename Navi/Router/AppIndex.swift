import Foundation
import AppKit

/// One installed application, as seen by the fuzzy matcher.
struct AppEntry: Sendable, Equatable, Hashable {
    let name: String            // localized display name without ".app"
    let path: String            // full path to the bundle
    let bundleID: String?
    let lowerName: String       // lowercased name
    let tokens: [String]        // lowercased words of the name ("google", "chrome")

    init(name: String, path: String, bundleID: String?) {
        self.name = name
        self.path = path
        self.bundleID = bundleID
        self.lowerName = name.lowercased()
        self.tokens = AppEntry.tokenize(name)
    }

    /// Stable id used for result rows and launch counters.
    var key: String { bundleID ?? path }

    static func tokenize(_ s: String) -> [String] {
        s.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}

struct AppMatch: Sendable {
    let entry: AppEntry
    let score: Double
}

/// In-memory index of installed applications with a fuzzy matcher.
///
/// Scans the usual application folders on a background queue, caches the
/// entries, refreshes every 5 minutes and whenever an app launches. Matching is
/// synchronous and cheap enough for every keystroke (a few hundred entries).
final class AppIndex: @unchecked Sendable {
    static let shared = AppIndex()

    static let launchCountsKey = "navi.launchCounts"
    static let refreshInterval: TimeInterval = 300

    private let lock = NSLock()
    private var _entries: [AppEntry] = []
    private var lastScan: Date?
    private var refreshTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private let scansFilesystem: Bool

    /// Production index: scans the filesystem and keeps itself fresh.
    private init() {
        scansFilesystem = true
        refresh()
        refreshTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(AppIndex.refreshInterval))
                self?.refresh()
            }
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.refresh() }
    }

    /// Test / fake index: fixed entries, no filesystem access, no timers.
    init(entries: [AppEntry]) {
        scansFilesystem = false
        _entries = entries
        lastScan = Date()
    }

    deinit {
        refreshTask?.cancel()
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    var entries: [AppEntry] {
        lock.lock(); defer { lock.unlock() }
        return _entries
    }

    // MARK: - Scanning

    /// Rescan asynchronously (never blocks the caller).
    func refresh() {
        guard scansFilesystem else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let found = AppIndex.scanFilesystem()
            self.lock.lock()
            self._entries = found
            self.lastScan = Date()
            self.lock.unlock()
            Log.router.debug("AppIndex: \(found.count) apps indexed")
        }
    }

    static var scanRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            home.appendingPathComponent("Applications"),
        ]
    }

    static func scanFilesystem() -> [AppEntry] {
        let fm = FileManager.default
        var seenPaths = Set<String>()
        var out: [AppEntry] = []

        func add(_ url: URL) {
            let path = url.path
            guard path.hasSuffix(".app"), !seenPaths.contains(path) else { return }
            seenPaths.insert(path)
            let bundle = Bundle(url: url)
            let bid = bundle?.bundleIdentifier
            if bid == Bundle.main.bundleIdentifier { return }   // don't index ourselves
            var name = fm.displayName(atPath: path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            out.append(AppEntry(name: name, path: path, bundleID: bid))
        }

        func list(_ dir: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                         options: [.skipsHiddenFiles])) ?? []
        }

        for root in scanRoots {
            for item in list(root) {
                if item.pathExtension == "app" {
                    add(item)
                } else if root.path == "/Applications",
                          (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    // One level deep: /Applications/Adobe Creative Cloud/*.app, etc.
                    for sub in list(item) where sub.pathExtension == "app" { add(sub) }
                }
            }
        }
        add(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        return out.sorted { $0.lowerName < $1.lowerName }
    }

    // MARK: - Matching

    /// Aliases: what people type → the app's display name.
    static let aliases: [String: String] = [
        "maps": "Maps",
        "chrome": "Google Chrome",
        "google": "Google Chrome",
        "settings": "System Settings",
        "preferences": "System Settings",
        "system preferences": "System Settings",
        "prefs": "System Settings",
        "terminal": "Terminal",
        "finder": "Finder",
        "calc": "Calculator",
        "calculator": "Calculator",
        "mail": "Mail",
        "email": "Mail",
        "messages": "Messages",
        "imessage": "Messages",
        "texts": "Messages",
        "notes": "Notes",
        "music": "Music",
        "itunes": "Music",
        "photos": "Photos",
        "safari": "Safari",
        "browser": "Safari",
        "vscode": "Visual Studio Code",
        "vs code": "Visual Studio Code",
        "code": "Visual Studio Code",
        "cursor": "Cursor",
        "slack": "Slack",
        "discord": "Discord",
        "spotify": "Spotify",
        "obsidian": "Obsidian",
        "xcode": "Xcode",
        "activity monitor": "Activity Monitor",
        "monitor": "Activity Monitor",
        "sim": "Simulator",
        "simulator": "Simulator",
        "cal": "Calendar",
        "calendar": "Calendar",
        "reminders": "Reminders",
        "facetime": "FaceTime",
        "zoom": "zoom.us",
        "word": "Microsoft Word",
        "excel": "Microsoft Excel",
        "powerpoint": "Microsoft PowerPoint",
        "outlook": "Microsoft Outlook",
        "teams": "Microsoft Teams",
        "ff": "Firefox",
        "firefox": "Firefox",
        "arc": "Arc",
        "1password": "1Password",
        "preview": "Preview",
        "textedit": "TextEdit",
        "quicktime": "QuickTime Player",
        "appstore": "App Store",
        "app store": "App Store",
        "store": "App Store",
        "disk utility": "Disk Utility",
        "keychain": "Keychain Access",
        "screen sharing": "Screen Sharing",
        "books": "Books",
        "podcasts": "Podcasts",
        "tv": "TV",
        "stocks": "Stocks",
        "weather": "Weather",
        "shortcuts": "Shortcuts",
        "automator": "Automator",
        "console": "Console",
        "font book": "Font Book",
        "iterm": "iTerm",
        "warp": "Warp",
        "figma": "Figma",
        "notion": "Notion",
        "linear": "Linear",
        "postman": "Postman",
        "docker": "Docker",
        "whatsapp": "WhatsApp",
        "telegram": "Telegram",
        "signal": "Signal",
        "raycast": "Raycast",
        "alfred": "Alfred",
        "ghostty": "Ghostty",
        "kitty": "kitty",
        "claude": "Claude",
        "chatgpt": "ChatGPT",
    ]

    static let launchPrefixes = ["open ", "launch ", "start ", "run ", "switch to ", "go to "]

    /// Lowercases, trims and strips "open "/"launch "/"start " and a trailing " app".
    static func normalize(_ query: String) -> String {
        var q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for p in launchPrefixes where q.hasPrefix(p) {
            q = String(q.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        if q.hasSuffix(" app") { q = String(q.dropLast(4)) }
        if q.hasSuffix(".app") { q = String(q.dropLast(4)) }
        return q.trimmingCharacters(in: .whitespaces)
    }

    /// Pure fuzzy score of an already-normalized query against one entry (0 = no match).
    ///   exact name → 1.0 · alias → 0.98 · prefix → 0.95 · word-start / acronym → 0.85 ·
    ///   subsequence → 0.6 × compactness
    static func baseScore(query q: String, entry: AppEntry) -> Double {
        guard !q.isEmpty else { return 0 }
        let name = entry.lowerName
        if q == name { return 1.0 }
        if let target = aliases[q], target.lowercased() == name { return 0.98 }
        if name.hasPrefix(q) { return 0.95 }
        // Word-start: query is a prefix of some token ("chrome" → Google Chrome, "code" → Visual Studio Code)
        if entry.tokens.contains(where: { $0.hasPrefix(q) }) { return 0.85 }
        // Acronym: each query char starts successive tokens ("gc" → Google Chrome)
        if q.count >= 2, acronymMatches(q, tokens: entry.tokens) { return 0.85 }
        // Multi-word query where every word is a token prefix ("vis code")
        let words = q.split(separator: " ").map(String.init)
        if words.count > 1, words.allSatisfy({ w in entry.tokens.contains { $0.hasPrefix(w) } }) { return 0.8 }
        // Subsequence with compactness scaling
        if q.count >= 2, let span = minimalSubsequenceSpan(q, in: name) {
            let compactness = Double(q.count) / Double(span)
            let s = 0.6 * compactness
            return s >= 0.25 ? s : 0
        }
        return 0
    }

    static func acronymMatches(_ q: String, tokens: [String]) -> Bool {
        guard q.count <= tokens.count else { return false }
        var ti = 0
        for ch in q {
            var found = false
            while ti < tokens.count {
                let t = tokens[ti]; ti += 1
                if t.first == ch { found = true; break }
            }
            if !found { return false }
        }
        return true
    }

    /// Smallest window of `name` containing the characters of `q` in order, or nil.
    static func minimalSubsequenceSpan(_ q: String, in name: String) -> Int? {
        let qc = Array(q), nc = Array(name)
        guard let first = qc.first else { return nil }
        var best: Int?
        for (start, ch) in nc.enumerated() where ch == first {
            var qi = 1, ni = start + 1
            while qi < qc.count && ni < nc.count {
                if nc[ni] == qc[qi] { qi += 1 }
                ni += 1
            }
            if qi == qc.count {
                let span = ni - start
                if best == nil || span < best! { best = span }
            } else {
                break   // later starts can't do better if this one failed
            }
        }
        return best
    }

    // MARK: Launch counts

    static func launchCounts() -> [String: Int] {
        UserDefaults.standard.dictionary(forKey: launchCountsKey) as? [String: Int] ?? [:]
    }

    static func recordLaunch(_ key: String) {
        var counts = launchCounts()
        counts[key, default: 0] += 1
        UserDefaults.standard.set(counts, forKey: launchCountsKey)
    }

    /// Ranked matches. `running` is the set of running bundle ids (for a small boost).
    func search(_ query: String, limit: Int = 5,
                running: Set<String> = [], launchCounts: [String: Int]? = nil) -> [AppMatch] {
        let q = AppIndex.normalize(query)
        guard !q.isEmpty else { return [] }
        let counts = launchCounts ?? AppIndex.launchCounts()
        var matches: [AppMatch] = []
        for e in entries {
            var s = AppIndex.baseScore(query: q, entry: e)
            guard s > 0 else { continue }
            let uses = counts[e.key] ?? 0
            if uses > 0 { s += min(0.03, 0.01 * Double(uses)) }
            if let bid = e.bundleID, running.contains(bid) { s += 0.02 }
            matches.append(AppMatch(entry: e, score: min(1.0, s)))
        }
        matches.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.entry.name.count != $1.entry.name.count { return $0.entry.name.count < $1.entry.name.count }
            return $0.entry.name < $1.entry.name
        }
        return Array(matches.prefix(limit))
    }

    // MARK: - Results

    @MainActor
    static func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
    }

    @MainActor
    func results(for query: String, limit: Int = 5) -> [SearchResult] {
        let running = AppIndex.runningBundleIDs()
        return search(query, limit: limit, running: running).map { m in
            let isRunning = m.entry.bundleID.map { running.contains($0) } ?? false
            return AppIndex.result(for: m.entry, score: m.score, isRunning: isRunning)
        }
    }

    /// Row subtitle: the kind, never the folder the bundle lives in.
    static func subtitle(isRunning: Bool) -> String {
        isRunning ? "Running" : "App"
    }

    static func result(for entry: AppEntry, score: Double, isRunning: Bool) -> SearchResult {
        let subtitle = AppIndex.subtitle(isRunning: isRunning)
        return SearchResult(id: "app:\(entry.key)", kind: .app, title: entry.name, subtitle: subtitle,
                            icon: .appBundle(entry.path), score: score,
                            shortcutHint: isRunning ? "⏎ Switch to" : "⏎ Open") {
            AppIndex.launch(entry)
            return .dismiss
        }
    }

    @MainActor
    static func launch(_ entry: AppEntry) {
        let url = URL(fileURLWithPath: entry.path)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error { Log.router.error("launch \(entry.name) failed: \(error.localizedDescription)") }
        }
        recordLaunch(entry.key)
    }
}
