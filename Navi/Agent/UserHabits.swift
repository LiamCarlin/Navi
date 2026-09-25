import Foundation

/// How *this* user does things, read from screen memory: the third kind of
/// knowledge the agent plans with, next to `AppSkills` (how apps work, for
/// anyone) and `AgentExperience` (what Navi's own runs did before).
///
/// Without it the planner guesses the generic default: it sent "go to my
/// outlook, summarize my emails" to outlook.office.com (the user reads mail in
/// the Outlook app and has never opened Outlook on the web), "what's due on
/// canvas" to canvas.instructure.com (the user's Canvas is canvas.olin.edu),
/// "text bella" to claude.ai. Screen memory already knows all three answers.
///
/// Three things ride into planning (`plannerSection`) — never OCR text, only
/// app names, page titles and cleaned URLs, all from the user's own Mac:
///   - `apps_for_this_kind_of_task`: the apps/sites that could do the task
///     (email → Mail, Outlook, Gmail, Outlook Web…) with how often the user
///     actually had each on screen, most used first;
///   - `most_used_apps` / `most_used_sites`: the user's overall profile;
///   - `seen_for_this_task`: where the task's own words (a person, a document,
///     a course) last appeared — digested activities first, then raw screens —
///     so "open the launch roadmap" can open the exact Slides URL.
/// Jev's surface classification (`TaskSurface`) gets a one-line summary, the
/// voice path's app inference breaks ties by use (`preferredSkill`), and web
/// start URLs move to the host the user really uses (`personalize`).
///
/// `MemoryService` installs the store (`install`); `NaviSettings.agentUsesScreenHabits`
/// turns the whole thing off. Every call is cheap (one grouped query, cached for
/// `profileTTL`, plus one FTS search per task) and never throws.
final class UserHabits: @unchecked Sendable {
    // MARK: Profile

    struct Use: Sendable, Equatable {
        /// Bundle id (apps) or site key (sites: host, plus the first path segment on shared hosts).
        var key: String
        var name: String
        var screens: Int
        var lastSeen: Date
    }

    struct Profile: Sendable, Equatable {
        var apps: [Use] = []      // most used first
        var sites: [Use] = []     // most used first
        var isEmpty: Bool { apps.isEmpty && sites.isEmpty }

        func screens(bundleID: String) -> Int { apps.first { $0.key == bundleID }?.screens ?? 0 }
    }

    /// One place the task's words showed up.
    struct Match: Sendable, Equatable {
        var app: String
        var title: String
        var url: String?
        var at: Date
        /// A digested activity ("Checked the hourly forecast on weather.com") rather than a raw screen.
        var isActivity: Bool
        /// How many of the task's words the title or URL itself carries (not just the screen's text).
        var relevance = 0
    }

    static let window: TimeInterval = 30 * 86_400
    static let profileTTL: TimeInterval = 600
    static let minScreens = 3
    static let maxMatches = 4

    // MARK: Installation (integration hook for MemoryService)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed: UserHabits?

    /// Called by `MemoryService` once its store is open.
    static func install(store: MemoryStore) {
        lock.lock(); defer { lock.unlock() }
        if installed?.store !== store { installed = UserHabits(store: store) }
    }

    /// The live instance, or nil when memory has no store or the user turned the feature off.
    /// Unit tests run hosted inside Navi.app, whose memory service opens the real
    /// store: without this, planner/start-URL tests would depend on the tester's history.
    private static let isUnderTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static var current: UserHabits? {
        guard !isUnderTests, UserDefaults.standard.object(forKey: "agentUsesScreenHabits") as? Bool ?? true else { return nil }
        lock.lock(); defer { lock.unlock() }
        return installed
    }

    let store: MemoryStore
    private let cacheLock = NSLock()
    private var cached: (profile: Profile, at: Date)?

    init(store: MemoryStore) { self.store = store }

    /// The user's app/site profile over the last `window`, cached for `profileTTL`.
    func profile(now: Date = Date()) -> Profile {
        cacheLock.lock()
        if let c = cached, now.timeIntervalSince(c.at) < Self.profileTTL { cacheLock.unlock(); return c.profile }
        cacheLock.unlock()
        let since = now.addingTimeInterval(-Self.window)
        let apps = (try? store.appUsage(since: since)) ?? []
        let visits = (try? store.siteVisits(since: since)) ?? []
        let p = Self.buildProfile(apps: apps, visits: visits)
        cacheLock.lock(); cached = (p, now); cacheLock.unlock()
        return p
    }

    /// For the main thread: the last profile built (any age, nil before the first),
    /// refreshed in the background when stale — never a database read on the caller.
    func cachedProfile(now: Date = Date()) -> Profile? {
        cacheLock.lock(); let c = cached; cacheLock.unlock()
        if c == nil || now.timeIntervalSince(c!.at) >= Self.profileTTL {
            Task.detached(priority: .utility) { [self] in _ = self.profile() }
        }
        return c?.profile
    }

    /// Where the task's own words appeared (people, documents, courses…), best first.
    /// The most specific words decide: every term must match, and until a place
    /// whose title or URL carries them turns up, the most common term is dropped —
    /// "text bella I'm running late" ends at the "Bella Chen" conversation, not at
    /// whichever chat was open while "running" and "late" were on screen.
    func matches(for task: String, now: Date = Date()) -> [Match] {
        let counted = Self.terms(in: task).map { ($0, (try? store.termCount($0)) ?? 0) }.filter { $0.1 > 0 }
        var subset = counted.sorted { $0.1 < $1.1 }.map(\.0)
        var fallback: [Match] = []
        while !subset.isEmpty {
            let hits = (try? store.searchAll(query: subset.joined(separator: " "), limit: 24, now: now)) ?? []
            let m = Self.matches(from: hits, terms: subset)
            if m.contains(where: { $0.relevance > 0 }) { return m.filter { $0.relevance > 0 } }
            if fallback.isEmpty { fallback = m }
            subset.removeLast()
        }
        return fallback
    }

    /// The planner's `user_habits` state section for `task` (nil ⇒ nothing worth saying).
    func plannerSection(task: String, now: Date = Date()) -> [String: Any]? {
        Self.plannerSection(task: task, profile: profile(now: now), matches: matches(for: task, now: now), now: now)
    }

    // MARK: Pure logic

    /// Apps that are never "how the user does" something: the OS chrome, auth
    /// sheets, Navi itself.
    static let ignoredBundles: Set<String> = [
        "com.liamcarlin.navi", "com.apple.WindowManager", "com.apple.SecurityAgent", "com.apple.UserNotificationCenter",
        "com.apple.loginwindow", "com.apple.dock", "com.apple.Spotlight", "com.apple.controlcenter", "com.apple.systemuiserver",
        "com.apple.ScreenSaver.Engine", "com.apple.notificationcenterui", "com.apple.CoreLocationAgent", "com.apple.coreservices.uiagent",
    ]

    /// Hosts where one site holds several apps: the site key keeps the first path segment.
    static let sharedHosts: Set<String> = ["docs.google.com", "google.com"]

    /// Search pages, local servers and the like say nothing about where the user does things.
    static let ignoredSiteKeys: Set<String> = ["google.com/search", "google.com", "google.com/url", "localhost", "127.0.0.1"]

    static func host(of url: String) -> String? {
        guard let u = URL(string: url), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var h = u.host?.lowercased(), !h.isEmpty else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    /// "docs.google.com/presentation", "canvas.olin.edu", "youtube.com".
    static func siteKey(of url: String) -> String? {
        guard let h = host(of: url) else { return nil }
        if sharedHosts.contains(h), let seg = URL(string: url)?.pathComponents.dropFirst().first, !seg.isEmpty {
            return h + "/" + seg.lowercased()
        }
        return h
    }

    /// Sign-in, sign-out and consent pages: never a place to send the agent.
    static func isAuthPage(_ url: String) -> Bool {
        guard let u = URL(string: url), let h = u.host?.lowercased() else { return false }
        if ["accounts.", "login.", "auth.", "signin.", "sso.", "id."].contains(where: { h.hasPrefix($0) }) { return true }
        if ["login.microsoftonline.com", "appleid.apple.com", "accounts.google.com"].contains(h) { return true }
        let p = u.path.lowercased()
        return ["/signin", "/sign-in", "/login", "/logout", "/signout", "/sign-out", "/oauth", "/sso", "/auth"].contains { p.hasPrefix($0) || p.contains($0 + "/") }
    }

    /// A URL the planner may be handed: http(s), not an auth page, query and
    /// fragment dropped (they carry session ids, emails, return_to junk) — except
    /// a YouTube video's `v`.
    static func cleanURL(_ url: String?) -> String? {
        guard let url, host(of: url) != nil, !isAuthPage(url), var c = URLComponents(string: url) else { return nil }
        let keep = (c.host ?? "").contains("youtube.com") ? c.queryItems?.filter { $0.name == "v" } : nil
        c.queryItems = (keep?.isEmpty == false) ? keep : nil
        c.fragment = nil
        return c.string
    }

    static func buildProfile(apps: [MemoryStore.AppUsage], visits: [MemoryStore.SiteVisit]) -> Profile {
        var p = Profile()
        p.apps = apps.filter { !$0.bundleID.isEmpty && !ignoredBundles.contains($0.bundleID) && $0.screens >= minScreens }
            .map { Use(key: $0.bundleID, name: $0.appName.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{200E}"))),
                       screens: $0.screens, lastSeen: $0.lastSeen) }
            .sorted { $0.screens != $1.screens ? $0.screens > $1.screens : $0.key < $1.key }
        var sites: [String: Use] = [:]
        for v in visits {
            guard !isAuthPage(v.url), let key = siteKey(of: v.url), !ignoredSiteKeys.contains(key) else { continue }
            var u = sites[key] ?? Use(key: key, name: key, screens: 0, lastSeen: v.at)
            u.screens += 1
            u.lastSeen = max(u.lastSeen, v.at)
            sites[key] = u
        }
        p.sites = sites.values.filter { $0.screens >= minScreens }
            .sorted { $0.screens != $1.screens ? $0.screens > $1.screens : $0.key < $1.key }
        return p
    }

    // MARK: Which skill does a site belong to?

    /// The web skill a site key belongs to: the library's own host match, else a
    /// "personal" host that carries the skill's one-word name — canvas.olin.edu is
    /// the user's Canvas even though Canvas lists only instructure.com.
    static func skill(forSite key: String) -> AppSkill? {
        if let s = AppSkills.skill(url: "https://" + key) { return s }
        let labels = Set((key.split(separator: "/").first ?? "").split(separator: ".").map(String.init))
        return AppSkills.web.first { s in
            ([s.name] + s.aliases).contains { n in
                let w = n.lowercased()
                return w.count >= 4 && !w.contains(" ") && !w.contains(".") && labels.contains(w)
            }
        }
    }

    /// How often the user had a skill's app or sites on screen, and where.
    static func usage(of skill: AppSkill, in profile: Profile) -> (screens: Int, sites: [Use], app: Use?) {
        let app = profile.apps.first { skill.bundleIDs.contains($0.key) }
        let sites = skill.hosts.isEmpty ? [] : profile.sites.filter { Self.skill(forSite: $0.key)?.name == skill.name }
        return ((app?.screens ?? 0) + sites.reduce(0) { $0 + $1.screens }, sites, app)
    }

    // MARK: Kinds of work

    /// The kinds of work where users pick different tools, the words that mean
    /// them, and the skills (native and web) that can do them. Resolved by name
    /// against the library; a name the library lacks is skipped.
    static let kinds: [(kind: String, words: [String], skills: [String])] = [
        ("email", ["email", "emails", "e-mail", "mail", "inbox", "emailed", "reply", "unread"], ["Mail", "Outlook", "Gmail", "Outlook Web"]),
        ("calendar", ["calendar", "event", "events", "meeting", "meetings", "schedule", "appointment", "agenda", "free"],
         ["Calendar", "Outlook", "Google Calendar", "Outlook Web"]),
        ("texting", ["text", "texts", "texted", "message", "messages", "imessage", "sms", "dm", "chat", "tell"],
         ["Messages", "WhatsApp", "Telegram", "Signal", "Discord", "Slack", "Microsoft Teams", "WhatsApp Web", "Instagram"]),
        ("coursework", ["homework", "assignment", "assignments", "due", "course", "courses", "class", "classes", "grade", "grades", "syllabus", "quiz", "exam"],
         ["Canvas", "Gradescope", "Google Classroom", "Piazza"]),
        ("documents", ["doc", "docs", "document", "essay", "paper", "draft", "write-up", "writeup", "report"],
         ["Google Docs", "Pages", "Microsoft Word", "Notion", "Notion Web"]),
        ("spreadsheets", ["spreadsheet", "spreadsheets", "sheet", "sheets", "budget", "table"], ["Google Sheets", "Numbers", "Microsoft Excel"]),
        ("slides", ["slides", "slide", "presentation", "deck", "slideshow"], ["Google Slides", "Keynote", "Microsoft PowerPoint"]),
        ("notes", ["note", "notes", "jot", "journal"], ["Notes", "Obsidian", "Notion", "Bear", "Google Keep", "Stickies"]),
        ("to-dos", ["todo", "to-do", "reminder", "reminders", "task", "tasks"], ["Reminders", "Things", "Todoist", "Notion"]),
        ("music", ["song", "songs", "music", "playlist", "album", "artist"], ["Spotify", "Music", "Spotify Web", "YouTube"]),
        ("video calls", ["call", "facetime", "videocall", "video call", "zoom"], ["FaceTime", "zoom.us", "Google Meet", "Microsoft Teams"]),
        ("files", ["file", "files", "folder", "folders", "download", "downloads", "pdf"], ["Finder", "Google Drive", "Dropbox"]),
        ("directions", ["directions", "route", "map", "maps", "drive", "commute", "far"], ["Maps", "Google Maps"]),
        ("videos", ["video", "videos", "watch"], ["YouTube", "Netflix"]),
    ]

    /// The skills that could do `task`, in the library's order within each kind:
    /// the app the task names first, then every kind the task's words mean.
    static func candidates(for task: String) -> [(kind: String, skills: [AppSkill])] {
        let lower = task.lowercased()
        let words = Set(lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" }).map(String.init))
        var out: [(String, [AppSkill])] = []
        for k in kinds where k.words.contains(where: { $0.contains(" ") ? lower.contains($0) : words.contains($0) }) {
            let skills = k.skills.compactMap { name in AppSkills.all.first { $0.name == name } }
            if !skills.isEmpty { out.append((k.kind, skills)) }
        }
        return out
    }

    // MARK: Terms for "seen for this task"

    /// Words that say *what to do*, not *what about*: they would match every screen.
    static let actionWords: Set<String> = [
        "open", "go", "goto", "navigate", "launch", "start", "click", "type", "press", "send", "text", "message", "email", "mail",
        "write", "reply", "tell", "ask", "check", "look", "see", "get", "give", "make", "create", "new", "add", "put", "set",
        "summarize", "summary", "summarise", "list", "find", "search", "pull", "bring", "play", "watch", "listen", "call",
        "close", "delete", "remove", "move", "copy", "paste", "save", "share", "print", "download", "upload", "export",
        "edit", "change", "update", "fix", "turn", "show", "read", "tab", "window", "app", "page", "site", "website",
        "please", "can", "could", "would", "will", "want", "need", "let", "know", "got", "get", "getting", "sent", "received",
        "all", "every", "latest", "last", "recent", "first", "next", "previous", "since", "until", "before", "after",
        "today", "tonight", "tomorrow", "yesterday", "week", "month", "year", "morning", "afternoon", "evening", "night",
        "am", "pm", "now", "later", "soon", "hey", "okay", "ok", "one", "two", "three", "also", "too", "them", "him", "her",
    ]

    /// Content words of a task worth searching memory for: no filler, no
    /// verbs, no times, no numbers, no app names or kind words (the kind table
    /// already covers "email", "calendar"…).
    static func terms(in task: String) -> [String] {
        let kindWords = Set(kinds.flatMap(\.words))
        let appWords = Set(AppSkills.all.flatMap { ([$0.name] + $0.aliases).flatMap { $0.lowercased().split(separator: " ").map(String.init) } })
        var out: [String] = []
        for chunk in task.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }) {
            var w = String(chunk)
            if w.hasSuffix("'s") { w.removeLast(2) }
            w = w.replacingOccurrences(of: "'", with: "")
            guard w.count >= 3, !w.allSatisfy(\.isNumber), !MemoryStore.stopwords.contains(w), !AgentExperience.stopWords.contains(w),
                  !actionWords.contains(w), !kindWords.contains(w), !appWords.contains(w), !out.contains(w) else { continue }
            out.append(w)
            if out.count >= 6 { break }
        }
        return out
    }

    /// Assistant chats (Claude, ChatGPT…) are where the user *talked about*
    /// things, never where a task gets done: the planner must not route there.
    static func isAssistant(bundleID: String, appName: String) -> Bool {
        if let s = AppSkills.skill(bundleID: bundleID), TaskPlanner.assistantApps.contains(where: { s.name.lowercased().contains($0) }) { return true }
        if bundleID.hasPrefix("com.openai.") || bundleID.hasPrefix("com.anthropic.") { return true }
        let n = appName.lowercased()
        return TaskPlanner.assistantApps.contains { n == $0 }
    }

    static func isAssistant(url: String?) -> Bool {
        guard let url, let s = AppSkills.skill(url: url) else { return false }
        return TaskPlanner.assistantApps.contains { s.name.lowercased().contains($0) }
    }

    /// Search hits → distinct places (same app + page/title collapse), auth pages,
    /// assistant chats and ignored apps dropped. Hits whose title or URL carries
    /// the task's words lead; at most two digested activities and two raw screens
    /// (screens carry the URLs the planner can open).
    static func matches(from hits: [MemoryStore.Hit], terms: [String] = []) -> [Match] {
        func relevance(_ h: MemoryStore.Hit) -> Int {
            let text = ((h.windowTitle ?? "") + " " + (h.url ?? "")).lowercased()
            return terms.filter { text.contains($0) }.count
        }
        let ordered = hits.sorted { a, b in
            let (ra, rb) = (relevance(a), relevance(b))
            if ra != rb { return ra > rb }
            if a.source != b.source { return a.source == .session }
            return a.score > b.score
        }
        var seen = Set<String>()
        var activities = 0, screens = 0
        var out: [Match] = []
        for h in ordered where !ignoredBundles.contains(h.bundleID) && !isAssistant(bundleID: h.bundleID, appName: h.appName) && !isAssistant(url: h.url) {
            if let u = h.url, isAuthPage(u) { continue }
            let url = cleanURL(h.url)
            let title = (h.windowTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty || url != nil else { continue }
            let isActivity = h.source == .session
            guard isActivity ? activities < 2 : screens < 2 else { continue }
            let key = "\(h.bundleID)|\(url ?? title.lowercased())"
            guard seen.insert(key).inserted else { continue }
            if isActivity { activities += 1 } else { screens += 1 }
            out.append(Match(app: h.appName.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{200E}"))),
                             title: String(title.prefix(90)), url: url, at: h.timestamp, isActivity: isActivity, relevance: relevance(h)))
            if out.count >= maxMatches { break }
        }
        return out
    }

    // MARK: Output

    static func ago(_ date: Date, now: Date) -> String {
        let days = Int(max(0, now.timeIntervalSince(date)) / 86_400)
        switch days {
        case 0: return "today"
        case 1: return "yesterday"
        default: return "\(days) days ago"
        }
    }

    static func describe(_ skill: AppSkill, in profile: Profile, now: Date) -> [String: Any] {
        let u = usage(of: skill, in: profile)
        var d: [String: Any] = ["app": skill.name, "type": skill.bundleIDs.isEmpty ? "website" : (skill.hosts.isEmpty ? "mac app" : "mac app or website")]
        if !u.sites.isEmpty { d["user_sites"] = u.sites.prefix(3).map(\.key) }
        if u.screens == 0 {
            d["used"] = "never seen on this user's screen"
        } else {
            let last = ([u.app?.lastSeen] + u.sites.map(\.lastSeen)).compactMap { $0 }.max() ?? now
            d["used"] = "\(u.screens) screens, last \(ago(last, now: now))"
            if let app = u.app, !u.sites.isEmpty { d["used_as"] = "mac app \(app.screens), website \(u.screens - app.screens)" }
        }
        return d
    }

    static func plannerSection(task: String, profile: Profile, matches: [Match], now: Date) -> [String: Any]? {
        guard !profile.isEmpty || !matches.isEmpty else { return nil }
        var s: [String: Any] = ["source": "this user's own screen history (last 30 days) — how they actually do things"]
        var kinds: [[String: Any]] = []
        for (kind, skills) in candidates(for: task) {
            let ranked = skills.map { ($0, usage(of: $0, in: profile).screens) }
            guard ranked.contains(where: { $0.1 > 0 }) else { continue }       // no signal for this kind
            let list = ranked.enumerated().sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
                .prefix(4).map { describe($0.element.0, in: profile, now: now) }
            kinds.append(["kind": kind, "options_most_used_first": list])
        }
        if !kinds.isEmpty { s["apps_for_this_kind_of_task"] = kinds }
        let apps = profile.apps.filter { !isAssistant(bundleID: $0.key, appName: $0.name) }
        let sites = profile.sites.filter { !isAssistant(url: "https://" + $0.key) }
        if !apps.isEmpty { s["most_used_apps"] = apps.prefix(10).map { "\($0.name) (\($0.screens))" } }
        if !sites.isEmpty { s["most_used_sites"] = sites.prefix(12).map { "\($0.key) (\($0.screens))" } }
        if !matches.isEmpty {
            s["seen_for_this_task"] = matches.map { m -> [String: Any] in
                var d: [String: Any] = ["app": m.app, "title": m.title, "when": ago(m.at, now: now),
                                        "what": m.isActivity ? "something the user did" : "on screen"]
                if let u = m.url { d["url"] = u }
                return d
            }
        }
        return s.count > 1 ? s : nil
    }

    /// One line for Jev's surface question: which app/site the user uses for
    /// what this task is about. nil ⇒ no signal.
    static func surfaceHint(task: String, profile: Profile) -> String? {
        var seen = Set<String>()
        var used: [(name: String, screens: Int, form: String)] = []
        let named = AppSkills.mentioned(in: task).map { [$0] } ?? []
        for s in named + candidates(for: task).flatMap(\.skills) where seen.insert(s.name).inserted {
            let u = usage(of: s, in: profile)
            guard u.screens > 0 else { continue }
            let form = u.sites.isEmpty ? "native mac app" : (u.app == nil ? "website \(u.sites[0].key)" : "native mac app and website")
            used.append((s.name, u.screens, form))
        }
        guard !used.isEmpty else { return nil }
        return used.sorted { $0.screens > $1.screens }.prefix(4)
            .map { "\($0.name): \($0.form), \($0.screens) screens" }.joined(separator: "; ")
    }

    /// Among skills the task implies equally (Mail / Outlook for "email"), the
    /// one the user actually uses — nil when none of them was ever on screen.
    static func preferred(_ skills: [AppSkill], profile: Profile) -> AppSkill? {
        let scored = skills.map { ($0, usage(of: $0, in: profile).screens) }.filter { $0.1 > 0 }
        return scored.max { $0.1 < $1.1 }?.0
    }

    /// A native app the task names that this user really uses as an app (not
    /// a browser, not a web app): "go to my outlook" means the Outlook app for
    /// someone who has never opened Outlook on the web.
    static func namedNativeApp(in task: String, profile: Profile) -> AppSkill? {
        guard let s = AppSkills.mentioned(in: task), s.hosts.isEmpty, !s.bundleIDs.isEmpty,
              !s.bundleIDs.contains(where: AXSnapshotter.isBrowser) else { return nil }
        return (usage(of: s, in: profile).app?.screens ?? 0) >= minScreens * 2 ? s : nil
    }

    /// Moves a web start URL to the host this user really uses for that web app:
    /// canvas.instructure.com/calendar → canvas.olin.edu/calendar,
    /// outlook.office.com/mail → outlook.office365.com/mail. Unchanged when the
    /// URL's host is already one of the user's, the app is unknown, or the user
    /// has no site of their own for it. Only the *same* product moves: a host the
    /// user reached under the app's name (canvas.olin.edu), or another subdomain of
    /// the same library host (babson.instructure.com) — never across a skill that
    /// groups rival sites ("Shopping sites": target.com is not ebay.com).
    static func personalize(_ url: String, profile: Profile) -> String {
        guard let h = host(of: url), let skill = AppSkills.skill(url: url), !skill.hosts.isEmpty else { return url }
        let mine = usage(of: skill, in: profile).sites.map { (use: $0, host: String($0.key.split(separator: "/").first ?? "")) }
        guard !mine.contains(where: { $0.host == h }) else { return url }
        func sameProduct(_ other: String) -> Bool {
            if AppSkills.skill(url: "https://" + other) == nil { return true }        // personal host, matched by name
            return skill.hosts.contains { entry in
                let e = String(entry.split(separator: "/").first ?? "").replacingOccurrences(of: "www.", with: "")
                return (h == e || h.hasSuffix("." + e)) && (other == e || other.hasSuffix("." + e)) && h != e && other != e
            }
        }
        guard let best = mine.first(where: { !$0.host.isEmpty && sameProduct($0.host) }), var c = URLComponents(string: url) else { return url }
        c.host = best.host
        return c.string ?? url
    }

    /// `personalize` against the live profile (unchanged when habits are off).
    static func personalized(_ url: String) -> String {
        guard let h = current else { return url }
        return personalize(url, profile: h.profile())
    }
}
