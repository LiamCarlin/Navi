import Foundation

/// The things in this user's life — people, projects, documents — and where
/// each one lives, learned from digested screen memory. `UserHabits` knows
/// which *tools* the user reaches for (the Outlook app for email); this knows
/// the *content*: that Bella Chen is someone they text in Messages, that "HCI
/// Team Notes" is one particular Google Doc they share with Suraj and Dhvan,
/// that an MTH3199 assignment starts on the Canvas assignment page and goes on
/// in MATLAB.
///
/// Built from the digester's sessions (entities + each session's app and URL),
/// never from OCR text or summaries. What a task names rides into:
///   - the planner (`user_habits.things_in_this_task`),
///   - every Jev step (`state.user_context`, native driver and browser runner),
///   - OPEN_URL targets and a browser task's start URL (the document itself),
///   - the voice path's app inference (the chat app a person is reached in),
/// and the whole map is written to the vault (`Navi/How you work.md`) so the
/// user can see what Navi learned.
///
/// Installed by `MemoryService` next to `UserHabits`, behind the same toggle
/// (`agentUsesScreenHabits`). Cheap: one sessions read per `ttl`, then pure matching.
final class UserKnowledge: @unchecked Sendable {
    struct Place: Sendable, Equatable {
        /// Bundle id (apps) or site key (web: "docs.google.com/document", "canvas.olin.edu").
        var key: String
        var app: String
        var isWeb: Bool
        /// The page seen most often there (cleaned: no query, no fragment).
        var url: String?
        var sessions: Int
        /// How this place reads in the state: the site for web places, the app otherwise.
        var label: String { isWeb ? key : app }
    }

    struct Thing: Sendable, Equatable {
        var name: String
        /// person | project | document
        var type: String
        var sessions: Int
        var days: Int
        var lastSeen: Date
        /// Where the user dealt with it, most sessions first.
        var places: [Place]
        /// People ↔ projects/documents seen together more than once, most first.
        var related: [String]
        /// Places in the order the user usually goes through them (only with ≥ 2 places).
        var workflow: [String]
        /// The name's words ("mth3199", "assignment", "2").
        var tokens: [String]

        /// The page to open for it: the most seen page of its most used web place.
        var url: String? { places.first(where: { $0.isWeb && $0.url != nil })?.url }

        /// The page for `task`: the web place the task names ("the MEPLM onshape" →
        /// cad.onshape.com, not the parts shop seen more often), else `url`.
        func url(for task: String) -> String? {
            let words = Set(UserKnowledge.tokens(task).filter { $0.count >= 3 && !UserKnowledge.genericWords.contains($0) })
            let named = places.first { p in
                guard p.isWeb, p.url != nil else { return false }
                let labels = Set(UserKnowledge.tokens(p.key)).subtracting(["com", "www", "org", "edu", "net", "io", "app", "google"])
                let skill = AppSkills.skill(url: "https://" + p.key).map { Set(UserKnowledge.tokens($0.name)) } ?? []
                return !words.isDisjoint(with: labels) || !words.isDisjoint(with: skill.subtracting(["google"]))
            }
            return named?.url ?? url
        }
    }

    struct Match: Sendable, Equatable {
        var thing: Thing
        var matched: Set<String>
        var coverage: Double
    }

    static let window: TimeInterval = 30 * 86_400
    static let ttl: TimeInterval = 600
    static let minSessions = 2
    static let maxThings = 400
    static let maxPlaces = 4
    static let maxRelated = 4
    static let maxMatches = 3

    // MARK: Installation (integration hook for MemoryService)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed: UserKnowledge?
    private static let isUnderTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static func install(store: MemoryStore) {
        lock.lock()
        let fresh = installed?.store !== store
        if fresh { installed = UserKnowledge(store: store) }
        let k = installed
        lock.unlock()
        if fresh, let k { Task.detached(priority: .utility) { _ = k.things() } }   // warm the cache off the main thread
    }

    /// nil when memory has no store, the user turned habits off, or under unit tests.
    static var current: UserKnowledge? {
        guard !isUnderTests, UserDefaults.standard.object(forKey: "agentUsesScreenHabits") as? Bool ?? true else { return nil }
        lock.lock(); defer { lock.unlock() }
        return installed
    }

    let store: MemoryStore
    private let cacheLock = NSLock()
    private var cached: (things: [Thing], at: Date)?

    init(store: MemoryStore) { self.store = store }

    /// Everything known, most seen first, cached for `ttl`.
    func things(now: Date = Date()) -> [Thing] {
        cacheLock.lock()
        if let c = cached, now.timeIntervalSince(c.at) < Self.ttl { cacheLock.unlock(); return c.things }
        cacheLock.unlock()
        let sessions = (try? store.sessions(in: DateInterval(start: now.addingTimeInterval(-Self.window), end: now), limit: 20_000)) ?? []
        let t = Self.build(sessions: sessions, selfNames: Self.selfNames)
        cacheLock.lock(); cached = (t, now); cacheLock.unlock()
        return t
    }

    /// The things `task` is about, best first.
    func matches(for task: String) -> [Match] { Self.matches(task: task, in: things()) }

    /// Drops the cache (after a digest run added sessions).
    func invalidate() { cacheLock.lock(); cached = nil; cacheLock.unlock() }

    // MARK: Live helpers (nil / [] when knowledge is off)

    /// `state.user_context` for Jev and the planner's `things_in_this_task`.
    static func context(for task: String, now: Date = Date()) -> [[String: Any]] {
        guard let k = current else { return [] }
        return k.matches(for: task).map { describe($0.thing, now: now) }
    }

    /// A document or project page the task is about, for a browser start URL.
    static func liveStartURL(for task: String) -> String? {
        guard let k = current else { return nil }
        return startURL(task: task, matches: k.matches(for: task))
    }

    /// Pages of the things the task names, for Jev's OPEN_URL head.
    static func liveURLCandidates(for task: String) -> [String] {
        guard let k = current else { return [] }
        return k.matches(for: task).filter { $0.thing.type != "person" }.compactMap { $0.thing.url(for: task) }
    }

    // MARK: Building

    /// Names that are the user themself: the digester lists them on every screen.
    static var selfNames: [String] { [NSFullUserName()] }

    static let keptTypes: [String: String] = ["person": "person", "project": "project", "file": "document"]

    /// "HCI Team Notes" → "hci team notes"; LTR marks and punctuation dropped.
    static func key(_ name: String) -> String { tokens(name).joined(separator: " ") }

    static func tokens(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Letter/digit runs of a token: "mth3199" → ["mth", "3199"] (speech says "m t h 3199").
    static func parts(_ token: String) -> [String] {
        var out: [String] = [], cur = ""
        for c in token {
            if let l = cur.last, l.isNumber != c.isNumber { out.append(cur); cur = "" }
            cur.append(c)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func selfKeys(_ names: [String]) -> Set<String> {
        var out: Set<String> = ["user", "you", "me", "the user"]
        for n in names {
            let t = tokens(n)
            guard !t.isEmpty else { continue }
            out.insert(t.joined(separator: " "))
            out.insert(t.joined())
            out.insert(t[0])
        }
        return out
    }

    /// A name worth keeping: not an email, phone number, id or sentence.
    static func isUsableName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard n.count >= 2, n.count <= 60, !n.contains("@"), !n.contains("://"), !n.hasPrefix("/"), !n.hasPrefix("~") else { return false }
        let t = tokens(n)
        guard !t.isEmpty, t.count <= 7 else { return false }
        let digits = n.filter(\.isNumber).count
        return digits * 2 < n.count || t.count > 1 || n.count <= 6
    }

    /// Where a session happened, or nil when it says nothing about where things live
    /// (assistant chats, Navi, OS chrome, sign-in and search pages, a browser without a page).
    static func place(of s: SessionRecord) -> (key: String, app: String, isWeb: Bool, url: String?)? {
        let app = s.appName.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{200E}")))
        guard !UserHabits.ignoredBundles.contains(s.bundleID), !ignoredBundles.contains(s.bundleID), !UserHabits.isAssistant(bundleID: s.bundleID, appName: app) else { return nil }
        if let raw = s.url, UserHabits.host(of: raw) != nil {
            guard !UserHabits.isAuthPage(raw), !UserHabits.isAssistant(url: raw), let site = UserHabits.siteKey(of: raw),
                  !UserHabits.ignoredSiteKeys.contains(site) else { return nil }
            return (site, app, true, UserHabits.cleanURL(raw))
        }
        guard !s.bundleID.isEmpty, !AXSnapshotter.isBrowser(s.bundleID) else { return nil }
        return (s.bundleID, app, false, nil)
    }

    /// Apps where nothing lives that the agent should go to: password managers, keychains.
    static let ignoredBundles: Set<String> = [
        "com.apple.Passwords", "com.apple.keychainaccess", "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "com.apple.systempreferences", "com.apple.finder.Open",
    ]

    /// Settings, account and admin pages: seen often while setting something up, never the thing itself.
    static func isSetupPage(_ url: String) -> Bool {
        let path = (URL(string: url)?.path ?? "").lowercased()
        return ["/settings", "/account", "/preferences", "/billing", "/admin", "/checkout", "/cart", "/buy/", "/orders", "/thankyou"]
            .contains { path.contains($0) }
    }

    private struct Acc {
        var names: [String: Int] = [:]
        var types: [String: Int] = [:]
        var sessions = 0
        var days = Set<String>()
        var lastSeen = Date.distantPast
        var places: [String: (app: String, isWeb: Bool, n: Int, urls: [String: Int])] = [:]
        /// Per day, places in first-seen order.
        var dayOrder: [String: [String]] = [:]
        var with: [String: Int] = [:]
    }

    static func build(sessions raw: [SessionRecord], selfNames: [String]) -> [Thing] {
        let me = selfKeys(selfNames)
        let dayFormat = DateFormatter()
        dayFormat.dateFormat = "yyyy-MM-dd"
        var acc: [String: Acc] = [:]
        for s in raw.sorted(by: { $0.start < $1.start }) {
            let loc = Self.place(of: s)
            let day = dayFormat.string(from: s.start)
            var here: [(key: String, isPerson: Bool)] = []
            for e in s.entities {
                guard let type = keptTypes[e.type.lowercased()], isUsableName(e.name) else { continue }
                let name = e.name.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{200E}")))
                let ordered = key(name)
                // Word order is not identity: "Lead Screw Executive Summary" is "Executive Summary: Lead Screw".
                let k = tokens(name).sorted().joined(separator: " ")
                guard !k.isEmpty, !me.contains(ordered), !me.contains(ordered.replacingOccurrences(of: " ", with: "")),
                      !here.contains(where: { $0.key == k }) else { continue }
                here.append((k, type == "person"))
                var a = acc[k] ?? Acc()
                a.names[name, default: 0] += 1
                a.types[type, default: 0] += 1
                a.sessions += 1
                a.days.insert(day)
                a.lastSeen = max(a.lastSeen, s.end)
                if let p = loc {
                    var pl = a.places[p.key] ?? (p.app, p.isWeb, 0, [:])
                    pl.n += 1
                    if let u = p.url, !isSetupPage(u) { pl.urls[u, default: 0] += 1 }
                    a.places[p.key] = pl
                    if !(a.dayOrder[day] ?? []).contains(p.key) { a.dayOrder[day, default: []].append(p.key) }
                }
                acc[k] = a
            }
            // People and the projects/documents on the same screen.
            for x in here where x.isPerson {
                for y in here where !y.isPerson {
                    acc[x.key]?.with[y.key, default: 0] += 1
                    acc[y.key]?.with[x.key, default: 0] += 1
                }
            }
        }

        func display(_ k: String) -> String? { acc[k]?.names.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key }

        // "Bella" is "Bella Chen" when she is the only Bella with a surname.
        func isPerson(_ a: Acc) -> Bool { (a.types["person"] ?? 0) * 2 >= a.sessions }
        let firstNames = Dictionary(grouping: acc.filter { $0.key.contains(" ") && isPerson($0.value) }.keys) { display($0).flatMap { tokens($0).first } ?? "" }
        for (k, a) in acc where !k.contains(" ") && isPerson(a) {
            let full = (firstNames[k] ?? []).filter { acc[$0] != nil }
            guard full.count == 1, let fk = full.first else { continue }
            var f = acc[fk]!
            f.sessions += a.sessions
            f.days.formUnion(a.days)
            f.lastSeen = max(f.lastSeen, a.lastSeen)
            for (pk, p) in a.places {
                var q = f.places[pk] ?? (p.app, p.isWeb, 0, [:])
                q.n += p.n
                q.urls.merge(p.urls, uniquingKeysWith: +)
                f.places[pk] = q
            }
            for (d, order) in a.dayOrder where f.dayOrder[d] == nil { f.dayOrder[d] = order }
            f.with.merge(a.with, uniquingKeysWith: +)
            acc[fk] = f
            acc[k] = nil
            for (ok, o) in acc where o.with[k] != nil {
                acc[ok]!.with[fk, default: 0] += o.with[k]!
                acc[ok]!.with[k] = nil
            }
        }

        var out: [Thing] = []
        for (k, a) in acc where a.sessions >= minSessions {
            guard let name = display(k), let type = a.types.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })?.key else { continue }
            let places = a.places.map { pk, p in
                Place(key: pk, app: p.app, isWeb: p.isWeb,
                      url: p.urls.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key, sessions: p.n)
            }.sorted { $0.sessions != $1.sessions ? $0.sessions > $1.sessions : $0.key < $1.key }
                // A place seen once for something seen often is a coincidence (a receipt, a search).
                .filter { $0.sessions >= 2 || a.sessions < 5 }
            // Together often *for the other one*: a person in a fifth of a project's sessions
            // works on it; one who shows up in 3 of Navi's 160 is just around.
            let related = a.with.filter { w in
                guard w.value >= 2, let o = acc[w.key], o.sessions >= minSessions else { return false }
                return w.value * 5 >= o.sessions
            }
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(maxRelated).compactMap { display($0.key) }
            out.append(Thing(name: name, type: type, sessions: a.sessions, days: a.days.count, lastSeen: a.lastSeen,
                             places: Array(places.prefix(maxPlaces)), related: related,
                             workflow: type == "person" ? [] : workflow(dayOrder: a.dayOrder, places: places, total: a.sessions),
                             tokens: tokens(name)))
        }
        return Array(out.sorted { $0.sessions != $1.sessions ? $0.sessions > $1.sessions : $0.name < $1.name }.prefix(maxThings))
    }

    /// The order the user usually goes through a thing's places: each place's
    /// average position among the places of a day (first seen = 0), over the days
    /// it was used. Only places used in ≥ 2 sessions and a twentieth of `total`; [] under two places.
    static func workflow(dayOrder: [String: [String]], places: [Place], total: Int = 0) -> [String] {
        let steady = places.filter { $0.sessions >= 2 && $0.sessions * 20 >= total }
        guard steady.count >= 2 else { return [] }
        let keys = Set(steady.map(\.key))
        var rank: [String: (sum: Double, n: Double)] = [:]
        for order in dayOrder.values {
            for (i, k) in order.filter(keys.contains).enumerated() { rank[k, default: (0, 0)].sum += Double(i); rank[k, default: (0, 0)].n += 1 }
        }
        let labels = Dictionary(uniqueKeysWithValues: steady.map { ($0.key, $0.label) })
        let ordered = steady.map(\.key).enumerated().sorted { a, b in
            let ra = rank[a.element].map { $0.sum / max($0.n, 1) } ?? 99, rb = rank[b.element].map { $0.sum / max($0.n, 1) } ?? 99
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
        var seen = Set<String>()
        return ordered.compactMap { labels[$0] }.filter { seen.insert($0).inserted }.prefix(maxPlaces).map { $0 }
    }

    // MARK: Matching a task

    /// Words that name no particular thing: "notes" alone must not pull in every notes doc.
    static let genericWords: Set<String> = [
        "team", "notes", "note", "doc", "docs", "document", "project", "projects", "assignment", "homework", "file", "files",
        "part", "studio", "meeting", "chat", "group", "page", "draft", "final", "class", "course", "lab", "report", "sheet",
        "slides", "deck", "the", "and", "for", "with", "college", "school", "university", "inc", "app", "template", "test",
        "untitled", "copy", "new", "old", "version", "summary", "plan", "list", "folder", "pdf", "png", "jpg",
    ]

    /// Filler of a task: articles, pronouns, polite words, verbs of doing.
    static func isFiller(_ w: String) -> Bool {
        AgentExperience.stopWords.contains(w) || MemoryStore.stopwords.contains(w) || UserHabits.actionWords.contains(w)
    }

    /// The things `task` names, best first. A thing matches through its own
    /// words (a word of the task, or all letter/digit parts of a joined word
    /// like "mth3199"); at least one matched word must be specific — not generic,
    /// not filler, not shared by a large share of everything known. People match
    /// on a first or last name; others need half their name or two specific words.
    static func matches(task: String, in things: [Thing], limit: Int = maxMatches) -> [Match] {
        let words = tokens(task)
        let taskSet = Set(words + words.flatMap(parts))
        guard !taskSet.isEmpty, !things.isEmpty else { return [] }
        var df: [String: Int] = [:]
        for t in things { for w in Set(t.tokens) { df[w, default: 0] += 1 } }
        let common = max(4, things.count * 3 / 10)
        func specific(_ w: String) -> Bool {
            (w.count >= 3 || (w.count >= 2 && w.contains(where: \.isNumber))) && !genericWords.contains(w) && !isFiller(w) && (df[w] ?? 0) < common
        }
        func hit(_ w: String) -> Bool {
            if taskSet.contains(w) { return true }
            let p = parts(w)
            return p.count > 1 && p.allSatisfy(taskSet.contains)
        }
        var found: [Match] = []
        for t in things where !t.tokens.isEmpty {
            let matched = Set(t.tokens.filter(hit))
            guard !matched.isEmpty, matched.contains(where: specific) else { continue }
            let coverage = Double(matched.count) / Double(Set(t.tokens).count)
            let ok: Bool
            if t.type == "person" {
                ok = matched.contains(t.tokens[0]) || (t.tokens.count > 1 && matched.contains(t.tokens.last!) && t.tokens.last!.count >= 4)
            } else {
                ok = coverage >= 0.5 || matched.filter(specific).count >= 2
            }
            if ok { found.append(Match(thing: t, matched: matched, coverage: coverage)) }
        }
        func byFirstName(_ m: Match) -> Bool { m.thing.type == "person" && m.matched.contains(m.thing.tokens[0]) }
        found.sort { a, b in
            if a.matched.count != b.matched.count { return a.matched.count > b.matched.count }
            if byFirstName(a) != byFirstName(b) { return byFirstName(a) }      // "crawford" is Crawford Phillips before Lena Crawford
            if a.coverage != b.coverage { return a.coverage > b.coverage }
            return a.thing.sessions > b.thing.sessions
        }
        // "mth3199 assignment 2" names Assignment-2, not also Assignment-1.
        var kept: [Match] = []
        for m in found where !kept.contains(where: { m.matched.isSubset(of: $0.matched) && (m.matched != $0.matched || m.coverage < $0.coverage) })
            && !kept.contains(where: { $0.thing.type != "person" && $0.thing.url != nil && $0.thing.url == m.thing.url }) {
            kept.append(m)
            if kept.count >= limit { break }
        }
        return kept
    }

    // MARK: Output

    /// One thing as structured state (planner and Jev read the same shape).
    static func describe(_ t: Thing, now: Date) -> [String: Any] {
        var d: [String: Any] = ["name": t.name, "type": t.type, "seen": "\(t.sessions) times over \(t.days) day\(t.days == 1 ? "" : "s"), last \(UserHabits.ago(t.lastSeen, now: now))"]
        let where_ = t.places.map { "\($0.label) (\($0.sessions))" }
        if !where_.isEmpty { d[t.type == "person" ? "talks_with_them_in" : "worked_on_in"] = where_ }
        if t.type != "person", let u = t.url { d["url"] = u }
        if t.workflow.count >= 2 { d["usual_workflow"] = t.workflow.joined(separator: " → ") }
        if !t.related.isEmpty { d[t.type == "person" ? "works_with_user_on" : "people_involved"] = t.related }
        return d
    }

    /// Words that ask to make something new: then the existing document is not the start.
    static let creationWords: Set<String> = ["new", "create", "make", "blank", "start", "draft", "compose"]

    /// The page a browser task should open: the document or project the task
    /// names (most of its name, and it has a web page), unless the task asks for
    /// something new.
    static func startURL(task: String, matches: [Match]) -> String? {
        guard !tokens(task).contains(where: creationWords.contains),
              !UserHabits.candidates(for: task).contains(where: { ["texting", "email", "calendar", "video calls"].contains($0.kind) }) else { return nil }
        return matches.first { $0.thing.type != "person" && $0.coverage >= 0.5 }?.thing.url(for: task)
    }

    /// The chat app a person the task names is reached in (their most used
    /// native place that is a messaging skill), for "text dhvan …" with no app named.
    static func chatApp(task: String, matches: [Match]) -> String? {
        guard UserHabits.candidates(for: task).contains(where: { $0.kind == "texting" }) else { return nil }
        let chat = Set((UserHabits.kinds.first { $0.kind == "texting" }?.skills ?? []))
        for m in matches where m.thing.type == "person" {
            for p in m.thing.places where !p.isWeb {
                if let s = AppSkills.skill(bundleID: p.key), chat.contains(s.name) { return p.key }
            }
        }
        return nil
    }

    /// `chatApp` against live memory.
    static func liveChatApp(for task: String) -> String? {
        guard let k = current else { return nil }
        return chatApp(task: task, matches: k.matches(for: task))
    }

    // MARK: Vault note

    /// `Navi/How you work.md`: what Navi believes about the user's people, projects
    /// and documents — readable, and wiki-linked into the entity hubs.
    static func markdown(_ things: [Thing], now: Date) -> String {
        var out = """
        ---
        type: navi-knowledge
        updated: \(ISO8601DateFormatter().string(from: now))
        tags: [navi/knowledge]
        ---
        # How you work

        What Navi learned from your screen memory (last 30 days) and uses when it does things for you: \
        who you talk to and where, and where your projects and documents live. Turn it off in \
        Navi → Settings → Agent → "Do things the way I do".

        """
        func line(_ t: Thing) -> String {
            var parts: [String] = []
            if !t.places.isEmpty { parts.append((t.type == "person" ? "talk in " : "in ") + t.places.map { "\($0.label) (\($0.sessions))" }.joined(separator: ", ")) }
            if t.workflow.count >= 2 { parts.append("usually " + t.workflow.joined(separator: " → ")) }
            if let u = t.url { parts.append("[open](\(u))") }
            if !t.related.isEmpty { parts.append((t.type == "person" ? "on " : "with ") + t.related.map { "[[\($0)]]" }.joined(separator: ", ")) }
            return "- [[\(t.name)]] — " + (parts.isEmpty ? "seen \(t.sessions)×" : parts.joined(separator: "; "))
        }
        for (title, type) in [("People", "person"), ("Projects", "project"), ("Documents", "document")] {
            let list = things.filter { $0.type == type }.prefix(40)
            guard !list.isEmpty else { continue }
            out += "\n## \(title)\n\n" + list.map(line).joined(separator: "\n") + "\n"
        }
        return out
    }
}
