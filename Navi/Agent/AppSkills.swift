import AppKit
import Foundation

/// The background knowledge Jev does not have: how each app is laid out, what
/// its shortcuts do *there*, the recipe for the goals people ask for, what
/// "done" looks like, and the wrong moves it keeps making.
///
/// Jev decides from structured state only (TypeSafe: "do not rely on knowledge
/// stored in model weights when current information can come from your own
/// knowledge base" — and "the model cannot choose an omitted value"). Without
/// this it treats every app like a web form: it clicked seven times to make a
/// Notes note that ⌘N creates, chose DONE in Calculator without pressing a key,
/// and messaged the open conversation instead of the person asked for.
///
/// A skill rides along in three places:
///   - `state.playbook` of every Jev request (`JevDriver.stateJSON`), trimmed to
///     the recipes that match the goal so the state stays small;
///   - the KEY head: the skill's shortcuts are *offered* (an app-specific combo
///     such as Outlook's ⌘2 can't be chosen unless it is a candidate) and the
///     generic combos get their meaning in this app;
///   - Claude's prompts (planner deep links, coach, text helper field hints).
///
/// Web apps carry `hosts` and are also handed to the browser runner
/// (`webPlaybooksJSON`), which injects the matching one per page.
struct AppSkill: Sendable, Equatable {
    var name: String
    var bundleIDs: [String]
    /// Web apps: host names this skill applies to (suffix match: "docs.google.com").
    var hosts: [String] = []
    /// Where things are and how the UI behaves — 3–6 short facts.
    var howItWorks: [String]
    /// Key combo (in `KeyCombo.parse` spelling) → what it does in this app.
    var shortcuts: [String: String] = [:]
    var recipes: [Recipe] = []
    /// Visible evidence that the usual goals are complete.
    var doneWhen: [String] = []
    /// Wrong moves seen in real runs.
    var avoid: [String] = []
    /// Hints for the text helper (what a field's value should look like here).
    var fieldHints: [String] = []
    /// Web apps: a page the planner can open directly instead of navigating there.
    /// `"search"` ending in `=` (or `/`) takes a query: `startURL(for:)` appends it.
    var deepLinks: [String: String] = [:]
    /// Spoken names besides `name` ("texts", "imessage", "gcal", "vscode").
    var aliases: [String] = []
    /// Nouns/phrases in a task that imply this app when no app is named
    /// ("song", "playlist", "reminder", "email", "timer"). Lower-case.
    var triggers: [String] = []
    /// Verbs that imply this app only when the frontmost app does not claim
    /// them itself ("play", "pause", "skip"): a video page in Chrome keeps "play".
    var weakTriggers: [String] = []

    struct Recipe: Sendable, Equatable {
        var goal: String
        /// Lower-case words; a recipe is offered when the goal contains any of them.
        var keywords: [String]
        /// Ordered steps in Jev's operation vocabulary (KEY, CLICK, TYPE_TEXT, SELECT, …).
        var steps: [String]
    }
}

enum AppSkills {
    // MARK: Lookup

    static func skill(bundleID: String?) -> AppSkill? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return all.first { $0.bundleIDs.contains(bundleID) }
    }

    static func skill(appName: String?) -> AppSkill? {
        guard let appName else { return nil }
        let wanted = appName.lowercased().replacingOccurrences(of: ".app", with: "").trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return nil }
        return all.first { $0.name.lowercased() == wanted }
    }

    /// The web skill for a URL: longest matching host entry wins
    /// ("docs.google.com/spreadsheets" over "docs.google.com" over "google.com").
    /// A host entry may carry a path prefix.
    static func skill(url: String?) -> AppSkill? {
        guard let url, let parsed = URL(string: url), let host = parsed.host?.lowercased() else { return nil }
        let path = parsed.path.isEmpty ? "/" : parsed.path.lowercased()
        var best: (AppSkill, Int)?
        for s in all {
            for h in s.hosts where hostEntry(h, matchesHost: host, path: path) {
                if best == nil || h.count > best!.1 { best = (s, h.count) }
            }
        }
        return best?.0
    }

    /// "docs.google.com/spreadsheets" matches host docs.google.com (or a
    /// subdomain) with a path under /spreadsheets; "google.com" matches any path.
    static func hostEntry(_ entry: String, matchesHost host: String, path: String) -> Bool {
        let e = entry.lowercased()
        let slash = e.firstIndex(of: "/")
        let eHost = slash.map { String(e[..<$0]) } ?? e
        let ePath = slash.map { String(e[$0...]) } ?? ""
        guard host == eHost || host.hasSuffix("." + eHost) else { return false }
        return ePath.isEmpty || path == ePath || path.hasPrefix(ePath + "/") || path.hasPrefix(ePath)
    }

    /// The skill for what's on screen: a web app open in a browser beats the
    /// browser's own skill; otherwise the app's.
    static func skill(bundleID: String?, url: String?) -> AppSkill? {
        if let b = bundleID, AXSnapshotter.isBrowser(b), let web = skill(url: url) { return web }
        return skill(bundleID: bundleID)
    }

    // MARK: Which app does a task mean?

    /// Names that are also ordinary words: they count as an app mention only
    /// after an opener ("in music", "open notes", "the weather app"), so "play
    /// some music" does not pin the Music app over a running Spotify.
    static let commonWordNames: Set<String> = ["music", "notes", "mail", "messages", "photos", "calendar", "maps", "contacts",
                                               "reminders", "books", "news", "home", "clock", "weather", "stocks", "terminal",
                                               "finder", "preview", "pages", "numbers", "keynote", "translate", "shortcuts",
                                               "dictionary", "tv", "podcasts", "settings", "calculator", "voice memos", "freeform",
                                               "word", "excel", "outlook", "teams", "code", "cursor", "signal", "things", "bear",
                                               "zoom", "meet", "keep", "arc", "cal", "canvas", "classroom", "linear", "target", "flights",
                                               "memos", "files", "shell", "prime", "insta", "search"]
    static let openers = #"(?:in|on|into|open|launch|use|using|with|via|to|inside|from|switch to|go to)\s+(?:the\s+|my\s+)?"#

    /// One compiled pattern per name/alias, built once.
    private static let mentionPatterns: [(skill: AppSkill, name: String, regex: NSRegularExpression)] = all.flatMap { s in
        ([s.name] + s.aliases).compactMap { a -> (AppSkill, String, NSRegularExpression)? in
            let name = a.lowercased()
            let escaped = NSRegularExpression.escapedPattern(for: name)
            let pattern = commonWordNames.contains(name)
                ? #"\b(?:"# + openers + escaped + #"|"# + escaped + #"\s+app)\b"#
                : #"\b"# + escaped + #"\b"#
            return (try? NSRegularExpression(pattern: pattern)).map { (s, name, $0) }
        }
    }

    /// The skill a task names outright — by name or spoken alias, as a whole
    /// word/phrase ("in slack", "on youtube", "texts"). Longest mention wins.
    static func mentioned(in task: String) -> AppSkill? {
        let lower = task.lowercased().replacingOccurrences(of: #"[^a-z0-9.+' ]"#, with: " ", options: .regularExpression)
        let range = NSRange(lower.startIndex..., in: lower)
        var best: (AppSkill, Int)?
        for m in mentionPatterns where m.regex.firstMatch(in: lower, range: range) != nil {
            if best == nil || m.name.count > best!.1 { best = (m.skill, m.name.count) }
        }
        return best?.0
    }

    /// Native skills a task implies, with scores, best first: the one it names,
    /// then by trigger hits. Weak (verb) triggers that the frontmost app's own
    /// skill claims do not count — "play the video" in Chrome is no reason to
    /// open Spotify.
    /// Triggers that mean something else in these phrasings ("call it Report" is a rename).
    static let triggerExclusions: [String: String] = ["call": #"\bcall (it|this|that|them|these|those|him|her|me back)\b"#]

    static func rankApps(for task: String, frontmostBundleID: String? = nil) -> [(skill: AppSkill, score: Int)] {
        let lower = task.lowercased()
        let words = Set(lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init))
        func hits(_ list: [String]) -> Int {
            list.filter { t in
                if let ex = triggerExclusions[t], lower.range(of: ex, options: .regularExpression) != nil { return false }
                return t.contains(" ") ? lower.contains(t) : words.contains(t)
            }.count
        }
        let claimed = Set(skill(bundleID: frontmostBundleID)?.weakTriggers ?? [])
        let named = mentioned(in: task)
        var scored: [(AppSkill, Int, Int)] = []
        for (i, s) in native.enumerated() where !s.bundleIDs.isEmpty {
            let strong = hits(s.triggers)
            let weak = hits(s.weakTriggers.filter { !claimed.contains($0) })
            let score = strong * 2 + weak + (named?.name == s.name ? 100 : 0)
            if score > 0 { scored.append((s, score, i)) }
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }.map { ($0.0, $0.1) }
    }

    static func inferApps(for task: String, frontmostBundleID: String? = nil) -> [AppSkill] {
        rankApps(for: task, frontmostBundleID: frontmostBundleID).map(\.skill)
    }

    /// The app a task with no app named should run in, and which of its bundle
    /// ids to open: the best-scoring skill that is installed; among skills tied
    /// at the top score (Music / Spotify, Mail / Outlook, Calendar / Outlook) a
    /// running one wins, then Apple's own app, then the library order.
    /// nil ⇒ nothing implied (stay in the frontmost app).
    static func inferApp(for task: String, frontmostBundleID: String?,
                         isInstalled: (String) -> Bool, isRunning: (String) -> Bool) -> (skill: AppSkill, bundleID: String)? {
        let ranked = rankApps(for: task, frontmostBundleID: frontmostBundleID)
        guard let top = ranked.first?.score else { return nil }
        let tied = ranked.filter { $0.score == top }.compactMap { r -> (AppSkill, String, Bool)? in
            let installed = r.skill.bundleIDs.filter(isInstalled)
            guard let b = installed.first(where: isRunning) ?? installed.first else { return nil }
            return (r.skill, b, isRunning(b))
        }
        guard let pick = tied.first(where: { $0.2 }) ?? tied.first(where: { $0.1.hasPrefix("com.apple.") }) ?? tied.first else { return nil }
        return (pick.0, pick.1)
    }

    /// Filler a spoken query starts with, stripped before it becomes a search.
    static let queryFiller: [String] = ["please", "can you", "could you", "would you", "go", "go to", "open", "launch", "pull up", "bring up", "and", "then",
                                        "search", "search for", "find", "find me", "look up", "look for", "play", "watch", "listen to", "put on", "throw on",
                                        "show me", "get", "get me", "buy", "order", "book", "browse", "check", "read", "see", "for", "me", "a", "an", "the",
                                        "some", "my", "up", "on", "in", "at", "to", "about", "of"]

    /// A page to start a browser task on, from a web app the task names and the
    /// words that go with it: "play lofi beats on youtube" → YouTube results
    /// for "lofi beats"; "open gmail" → the inbox; "google drive shared with me"
    /// → that deep link. nil when no web app is named.
    static func startURL(for task: String) -> String? {
        guard let s = mentioned(in: task), !s.hosts.isEmpty else { return nil }
        let names = ([s.name] + s.aliases).map { $0.lowercased() }.sorted { $0.count > $1.count }
        var q = UltrafastBridge.searchQuery(for: task).lowercased()
            .replacingOccurrences(of: #"[^a-z0-9.+'$%&/ -]"#, with: " ", options: .regularExpression)
        for n in names {
            let escaped = NSRegularExpression.escapedPattern(for: n)
            q = q.replacingOccurrences(of: #"\b(?:on|in|at|from|using|with|via|through|to|inside)\s+(?:the\s+|my\s+)?"# + escaped + #"(?:\s+(?:app|site|website|page|tab))?\b"#,
                                       with: " ", options: .regularExpression)
            q = q.replacingOccurrences(of: #"\b"# + escaped + #"(?:\s+(?:app|site|website|page|tab))?\b"#, with: " ", options: .regularExpression)
        }
        // Leading filler, longest phrase first, until none is left.
        var words = q.split(separator: " ").map(String.init)
        let fillers = queryFiller.map { $0.split(separator: " ").map(String.init) }.sorted { $0.count > $1.count }
        var stripped = true
        while stripped, !words.isEmpty {
            stripped = false
            for f in fillers where words.count >= f.count && Array(words.prefix(f.count)) == f {
                words.removeFirst(f.count); stripped = true; break
            }
        }
        while let last = words.last, ["please", "now", "thanks", "thank you"].contains(last) { words.removeLast() }
        let query = words.joined(separator: " ").trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        let stop: Set<String> = ["", "it", "that", "this", "there", "here", "page", "site", "tab", "up"]
        if let link = s.deepLinks.first(where: { $0.key.lowercased() == query })?.value { return link }
        if !stop.contains(query), let search = s.deepLinks["search"], search.hasSuffix("=") || search.hasSuffix("/") {
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?.replacingOccurrences(of: "&", with: "%26") ?? query
            return search + encoded
        }
        return s.deepLinks["home"] ?? s.hosts.first.map { "https://" + $0 }
    }

    /// The name to show for a bundle id ("com.apple.MobileSMS" → "Messages").
    static func displayName(bundleID: String) -> String {
        if let s = skill(bundleID: bundleID) { return s.name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID
    }

    // MARK: Playbook (state section)

    static let maxRecipes = 3

    /// Recipes whose keywords appear in the goal, best match first.
    static func recipes(for skill: AppSkill, goal: String) -> [AppSkill.Recipe] {
        let words = Set(goal.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let lower = goal.lowercased()
        let scored: [(recipe: AppSkill.Recipe, hits: Int, index: Int)] = skill.recipes.enumerated().compactMap { i, r in
            let hits = r.keywords.filter { k in k.contains(" ") ? lower.contains(k) : words.contains(k) }.count
            return hits > 0 ? (r, hits, i) : nil
        }
        // Most hits first; the library's own order breaks ties (deterministic state → cache hits).
        return scored.sorted { $0.hits != $1.hits ? $0.hits > $1.hits : $0.index < $1.index }.prefix(maxRecipes).map(\.recipe)
    }

    /// The compact JSON object Jev gets as `state.playbook`.
    static func playbook(for skill: AppSkill, goal: String) -> [String: Any] {
        var p: [String: Any] = ["app": skill.name, "how_it_works": skill.howItWorks]
        if !skill.shortcuts.isEmpty { p["shortcuts"] = skill.shortcuts }
        let matched = recipes(for: skill, goal: goal)
        if !matched.isEmpty { p["recipes"] = matched.map { ["goal": $0.goal, "steps": $0.steps] } }
        if !skill.doneWhen.isEmpty { p["done_when"] = skill.doneWhen }
        if !skill.avoid.isEmpty { p["avoid"] = skill.avoid }
        return p
    }

    /// KEY candidates for this app: the generic combos, re-described where the
    /// skill gives them an app-specific meaning, plus the skill's own combos.
    static func keyCombos(for skill: AppSkill?, base: [(String, String)] = JevDriver.keyCombos) -> [(String, String)] {
        guard let skill else { return base }
        var out: [(String, String)] = base.map { k, d in (k, skill.shortcuts[k].map { "\($0) (\(skill.name))" } ?? d) }
        let known = Set(base.map { $0.0.lowercased() })
        for (k, d) in skill.shortcuts.sorted(by: { $0.key < $1.key }) where !known.contains(k.lowercased()) {
            out.append((k, "\(d) (\(skill.name))"))
        }
        return out
    }

    // MARK: For Claude

    /// Deep links and app names for the planner: a step that starts on the
    /// right page needs no navigation at all.
    static func plannerReference() -> [String: Any] {
        var links: [String: String] = [:]
        for s in all { for (k, v) in s.deepLinks { links["\(s.name): \(k)"] = v } }
        let apps = all.filter { !$0.bundleIDs.isEmpty }.map(\.name).sorted()
        return ["known_apps": apps, "deep_links": links]
    }

    /// Every web skill as JSON for the browser runner (`NAVI_PLAYBOOKS_JSON`).
    static func webPlaybooksJSON() -> String {
        let web: [[String: Any]] = all.filter { !$0.hosts.isEmpty }.map { s in
            var d: [String: Any] = ["app": s.name, "hosts": s.hosts, "how_it_works": s.howItWorks,
                                    "recipes": s.recipes.map { ["goal": $0.goal, "keywords": $0.keywords, "steps": $0.steps] }]
            if !s.doneWhen.isEmpty { d["done_when"] = s.doneWhen }
            if !s.avoid.isEmpty { d["avoid"] = s.avoid }
            if !s.fieldHints.isEmpty { d["field_hints"] = s.fieldHints }
            return d
        }
        let data = (try? JSONSerialization.data(withJSONObject: web, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
