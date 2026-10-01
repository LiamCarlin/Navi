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
        /// People: half-hours in which the user had their conversation open here (`UserContacts`).
        var opened: Int = 0
        /// How this place reads in the state: the site for web places, the app otherwise.
        var label: String { isWeb ? key : app }
        /// How strongly a person is reached here: an open conversation says far more than a
        /// name in a chat list or on a page.
        var reach: Int { sessions + 3 * opened }
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
        /// People: the email addresses the user's mail showed for them, most seen first.
        var emails: [String] = []
        /// People: where those addresses were seen (the mail app or site they are mailed from).
        var emailPlace: Place?

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
        guard !TestHost.isActive, UserDefaults.navi.object(forKey: "agentUsesScreenHabits") as? Bool ?? true else { return nil }
        lock.lock(); defer { lock.unlock() }
        return installed
    }

    let store: MemoryStore
    private let cacheLock = NSLock()
    private var cached: Snapshot?

    init(store: MemoryStore) { self.store = store }

    /// What memory holds right now, read once per `ttl`: the things, plus the
    /// sessions and page titles `TaskGrounding` searches for what a task refers to.
    struct Snapshot: Sendable {
        var things: [Thing]
        /// Digested sessions of the last `window`, newest first.
        var sessions: [SessionRecord]
        /// Cleaned page URL → its latest title.
        var pageTitles: [String: String]
        var at: Date
    }

    func snapshot(now: Date = Date()) -> Snapshot {
        cacheLock.lock()
        if let c = cached, now.timeIntervalSince(c.at) < Self.ttl { cacheLock.unlock(); return c }
        cacheLock.unlock()
        let since = now.addingTimeInterval(-Self.window)
        let sessions = (try? store.sessions(in: DateInterval(start: since, end: now), limit: 20_000)) ?? []
        let signals = Self.loadSignals(store: store, since: since)
        var titles: [String: (String, Date)] = [:]
        for p in (try? store.pageTitles(since: since)) ?? [] where AXSnapshotter.isBrowser(p.bundleID) {
            guard let u = UserHabits.cleanURL(p.url) else { continue }
            if let have = titles[u], have.1 >= p.at { continue }
            titles[u] = (p.title, p.at)
        }
        let snap = Snapshot(things: Self.build(sessions: sessions, selfNames: Self.selfNames, signals: signals),
                            sessions: sessions, pageTitles: titles.mapValues(\.0), at: now)
        cacheLock.lock(); cached = snap; cacheLock.unlock()
        return snap
    }

    /// Everything known, most seen first, cached for `ttl`.
    func things(now: Date = Date()) -> [Thing] { snapshot(now: now).things }

    /// How the user reaches people (`UserContacts`): open conversations in Messages'
    /// window titles and in clicks on chat rows, and `Name <address>` in their mail.
    static func loadSignals(store: MemoryStore, since: Date) -> UserContacts.Signals {
        var sig = UserContacts.Signals()
        for f in (try? store.titledFrames(bundleIDs: UserContacts.titledByConversation, since: since)) ?? [] {
            guard let n = UserContacts.conversation(windowTitle: f.windowTitle) else { continue }
            sig.opened.append(.init(name: n, key: f.bundleID, app: f.appName, isWeb: false, at: f.timestamp))
        }
        for a in (try? store.actions(bundleIDs: UserContacts.channelBundles, since: since)) ?? [] where a.kind == .click {
            guard let n = UserContacts.conversation(clickedLabel: a.label, role: a.role) else { continue }
            sig.opened.append(.init(name: n, key: a.bundleID, app: a.appName, isWeb: false, at: a.timestamp))
        }
        for f in (try? store.framesWithAddresses(since: since)) ?? [] where UserContacts.isMailPlace(bundleID: f.bundleID, url: f.url) {
            guard let p = place(bundleID: f.bundleID, appName: f.appName, url: f.url) else { continue }
            var seen = Set<String>()
            for pair in UserContacts.pairs(in: f.ocrText) where seen.insert(pair.name + "|" + pair.address).inserted {
                sig.addresses.append(.init(name: pair.name, address: pair.address, key: p.key, app: p.app, isWeb: p.isWeb, at: f.timestamp))
            }
        }
        return sig
    }

    /// The things `task` is about, best first.
    func matches(for task: String) -> [Match] { Self.matches(task: task, in: things()) }

    /// Drops the cache (after a digest run added sessions).
    func invalidate() { cacheLock.lock(); cached = nil; cacheLock.unlock() }

    // MARK: Live helpers (nil / [] when knowledge is off)

    /// `state.user_context` for Jev and the planner's `things_in_this_task`: the people and
    /// things the task names, and first what it was grounded to (`TaskGrounding`: "the last
    /// assignment I did" → that assignment). `original`: the run's task when `task` is one
    /// of its planned steps.
    static func context(for task: String, original: String? = nil, now: Date = Date()) -> [[String: Any]] {
        guard let k = current else { return [] }
        var out = k.matches(for: task).map { describe($0.thing, now: now) }
        if let g = grounded(task, original: original) {
            out.removeAll { ($0["name"] as? String) == g.thing.name || ($0["url"] as? String).map { $0 == g.thing.url } == true }
            out.insert(TaskGrounding.context(g, now: now), at: 0)
        }
        return out
    }

    /// The run's grounding, for a task or one of its steps.
    static func grounded(_ task: String, original: String? = nil) -> TaskGrounding.Grounded? {
        TaskGrounding.cached(for: task) ?? original.flatMap(TaskGrounding.cached(for:))
    }

    /// A document or project page the task is about, for a browser start URL: what the
    /// task was grounded to ("the doc I was working on"), else a thing it names.
    static func liveStartURL(for task: String) -> String? {
        guard let k = current else { return nil }
        if let g = grounded(task), let u = g.thing.url, !TaskGrounding.isCommunication(task),
           !tokens(task).contains(where: creationWords.contains) { return u }
        return startURL(task: task, matches: k.matches(for: task))
    }

    /// Pages of the things the task names, for Jev's OPEN_URL head.
    static func liveURLCandidates(for task: String, original: String? = nil) -> [String] {
        guard let k = current else { return [] }
        var out = k.matches(for: task).filter { $0.thing.type != "person" }.compactMap { $0.thing.url(for: task) }
        if let u = grounded(task, original: original)?.thing.url, !out.contains(u) { out.insert(u, at: 0) }
        return out
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
        place(bundleID: s.bundleID, appName: s.appName, url: s.url)
    }

    static func place(bundleID: String, appName: String, url: String?) -> (key: String, app: String, isWeb: Bool, url: String?)? {
        let app = appName.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{200E}")))
        guard !UserHabits.ignoredBundles.contains(bundleID), !ignoredBundles.contains(bundleID), !UserHabits.isAssistant(bundleID: bundleID, appName: app) else { return nil }
        if let raw = url, UserHabits.host(of: raw) != nil {
            guard !UserHabits.isAuthPage(raw), !UserHabits.isAssistant(url: raw), let site = UserHabits.siteKey(of: raw),
                  !UserHabits.ignoredSiteKeys.contains(site) else { return nil }
            return (site, app, true, UserHabits.cleanURL(raw))
        }
        guard !bundleID.isEmpty, !AXSnapshotter.isBrowser(bundleID) else { return nil }
        return (bundleID, app, false, nil)
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
        /// People: half-hour slots their conversation was open, per place (`UserContacts`).
        var opened: [String: (app: String, isWeb: Bool, slots: Set<Int>)] = [:]
        /// People: addresses seen for them (how often, whether the address fits the name).
        var emails: [String: (n: Int, fits: Bool)] = [:]
        var emailPlaces: [String: (app: String, isWeb: Bool, n: Int)] = [:]
        /// Contact signals, for people known from them alone.
        var signals = 0

        mutating func open(_ key: String, app: String, isWeb: Bool, at: Date) {
            var o = opened[key] ?? (app, isWeb, [])
            o.slots.insert(Int(at.timeIntervalSince1970 / 1800))
            opened[key] = o
            lastSeen = max(lastSeen, at)
        }

        mutating func absorb(_ a: Acc) {
            sessions += a.sessions
            signals += a.signals
            days.formUnion(a.days)
            lastSeen = max(lastSeen, a.lastSeen)
            for (pk, p) in a.places {
                var q = places[pk] ?? (p.app, p.isWeb, 0, [:])
                q.n += p.n
                q.urls.merge(p.urls, uniquingKeysWith: +)
                places[pk] = q
            }
            for (pk, o) in a.opened {
                var q = opened[pk] ?? (o.app, o.isWeb, [])
                q.slots.formUnion(o.slots)
                opened[pk] = q
            }
            emails.merge(a.emails) { ($0.n + $1.n, $0.fits || $1.fits) }
            emailPlaces.merge(a.emailPlaces) { ($0.app, $0.isWeb, $0.n + $1.n) }
            for (d, order) in a.dayOrder where dayOrder[d] == nil { dayOrder[d] = order }
            with.merge(a.with, uniquingKeysWith: +)
        }
    }

    /// Apps and sites one talks to people in: a person named in such a session's title
    /// ("WhatsApp chat with Lena Conde Araujo …") is the conversation the user had open.
    static func isChannel(_ placeKey: String) -> Bool {
        let skill = AppSkills.skill(bundleID: placeKey) ?? AppSkills.skill(url: "https://" + placeKey)
        guard let skill else { return false }
        return UserHabits.kinds.contains { UserContacts.channelKinds.contains($0.kind) && $0.skills.contains(skill.name) }
    }

    static func build(sessions raw: [SessionRecord], selfNames: [String], signals: UserContacts.Signals = .init()) -> [Thing] {
        let me = selfKeys(selfNames)
        let dayFormat = DateFormatter()
        dayFormat.dateFormat = "yyyy-MM-dd"
        var acc: [String: Acc] = [:]
        var channel: [String: Bool] = [:]
        for s in raw.sorted(by: { $0.start < $1.start }) {
            let loc = Self.place(of: s)
            let day = dayFormat.string(from: s.start)
            let title = s.title.lowercased()
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
                    // The session is about this person ("Chat with Bella Chen about gym plans"): their chat was open.
                    if type == "person", !title.isEmpty, title.contains(name.lowercased()) {
                        let isChat = channel[p.key] ?? isChannel(p.key)
                        channel[p.key] = isChat
                        if isChat { a.open(p.key, app: p.app, isWeb: p.isWeb, at: s.start) }
                    }
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

        // How the user reaches people: conversations they opened, addresses their mail showed.
        func personKey(_ raw: String) -> String? {
            let name = UserContacts.stripMarks(raw)
            guard isUsableName(name) else { return nil }
            let ordered = key(name)
            guard !ordered.isEmpty, !me.contains(ordered), !me.contains(ordered.replacingOccurrences(of: " ", with: "")) else { return nil }
            let k = tokens(name).sorted().joined(separator: " ")
            if acc[k] == nil { var a = Acc(); a.names[name] = 1; a.types["person"] = 1; acc[k] = a }
            return k
        }
        for o in signals.opened {
            guard let k = personKey(o.name) else { continue }
            let before = acc[k]!.opened[o.key]?.slots.count ?? 0
            acc[k]!.open(o.key, app: o.app, isWeb: o.isWeb, at: o.at)
            if acc[k]!.opened[o.key]!.slots.count > before { acc[k]!.signals += 1 }
        }
        for e in signals.addresses {
            guard let k = personKey(e.name) else { continue }
            var a = acc[k]!
            let had = a.emails[e.address] ?? (0, false)
            a.emails[e.address] = (had.n + 1, had.fits || UserContacts.belongs(e.address, to: e.name))
            var pl = a.emailPlaces[e.key] ?? (e.app, e.isWeb, 0)
            pl.n += 1
            a.emailPlaces[e.key] = pl
            a.signals += 1
            a.lastSeen = max(a.lastSeen, e.at)
            acc[k] = a
        }

        func display(_ k: String) -> String? { acc[k]?.names.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key }

        // "Bella" is "Bella Chen" when she is the only Bella with a surname.
        func isPerson(_ a: Acc) -> Bool { (a.types["person"] ?? 0) * 2 >= a.sessions }
        // A group chat ("Mikey, David & Dhvan") is not anyone's full name.
        func isGroup(_ k: String) -> Bool { display(k).map { $0.contains("&") || $0.contains(",") || $0.contains(" + ") } ?? false }
        let firstNames = Dictionary(grouping: acc.filter { $0.key.contains(" ") && isPerson($0.value) && !isGroup($0.key) }.keys) { display($0).flatMap { tokens($0).first } ?? "" }
        for (k, a) in acc where !k.contains(" ") && isPerson(a) {
            let full = (firstNames[k] ?? []).filter { acc[$0] != nil }
            guard full.count == 1, let fk = full.first else { continue }
            acc[fk]!.absorb(a)
            acc[k] = nil
            for (ok, o) in acc where o.with[k] != nil {
                acc[ok]!.with[fk, default: 0] += o.with[k]!
                acc[ok]!.with[k] = nil
            }
        }

        var out: [Thing] = []
        for (k, a) in acc where a.sessions + a.signals >= minSessions {
            guard let name = display(k), let type = a.types.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })?.key else { continue }
            let isPersonThing = type == "person"
            let keys = Set(a.places.keys).union(isPersonThing ? Set(a.opened.keys) : [])
            let places = keys.compactMap { pk -> Place? in
                let p = a.places[pk], o = a.opened[pk]
                guard let app = p?.app ?? o?.app else { return nil }
                return Place(key: pk, app: app, isWeb: p?.isWeb ?? o?.isWeb ?? false,
                             url: p?.urls.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key,
                             sessions: p?.n ?? 0, opened: isPersonThing ? (o?.slots.count ?? 0) : 0)
            }.sorted { x, y in
                let (rx, ry) = isPersonThing ? (x.reach, y.reach) : (x.sessions, y.sessions)
                return rx != ry ? rx > ry : x.key < y.key
            }
                // A place seen once for something seen often is a coincidence (a receipt, a search).
                .filter { $0.sessions >= 2 || a.sessions < 5 || $0.opened > 0 }
            // Together often *for the other one*: a person in a fifth of a project's sessions
            // works on it; one who shows up in 3 of Navi's 160 is just around.
            let related = a.with.filter { w in
                guard w.value >= 2, let o = acc[w.key], o.sessions >= minSessions else { return false }
                return w.value * 5 >= o.sessions
            }
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(maxRelated).compactMap { display($0.key) }
            // An address seen once that does not fit the name is OCR pairing it with the next column.
            let emails = a.emails.filter { $0.value.fits || $0.value.n >= 2 }
                .sorted { x, y in
                    let (sx, sy) = (x.value.n * (x.value.fits ? 2 : 1), y.value.n * (y.value.fits ? 2 : 1))
                    return sx != sy ? sx > sy : x.key < y.key
                }.prefix(3).map(\.key)
            let emailPlace = emails.isEmpty ? nil : a.emailPlaces.max { $0.value.n != $1.value.n ? $0.value.n < $1.value.n : $0.key > $1.key }
                .map { Place(key: $0.key, app: $0.value.app, isWeb: $0.value.isWeb, url: nil, sessions: $0.value.n) }
            var thing = Thing(name: name, type: type, sessions: a.sessions > 0 ? a.sessions : a.signals, days: a.days.count,
                              lastSeen: a.lastSeen, places: Array(places.prefix(maxPlaces)), related: related,
                              workflow: isPersonThing ? [] : workflow(dayOrder: a.dayOrder, places: places, total: a.sessions),
                              tokens: tokens(name))
            if isPersonThing { thing.emails = Array(emails); thing.emailPlace = emailPlace }
            out.append(thing)
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
        let over = t.days > 0 ? " over \(t.days) day\(t.days == 1 ? "" : "s")" : ""
        var d: [String: Any] = ["name": t.name, "type": t.type, "seen": "\(t.sessions) times\(over), last \(UserHabits.ago(t.lastSeen, now: now))"]
        let where_ = t.places.map { p in
            p.opened > 0 ? "\(p.label) (\(p.sessions), their conversation opened \(p.opened)×)" : "\(p.label) (\(p.sessions))"
        }
        if !where_.isEmpty { d[t.type == "person" ? "talks_with_them_in" : "worked_on_in"] = where_ }
        if t.type == "person" {
            // The app this user reaches them in for each kind of contact ("texting": "WhatsApp").
            let reach = reachKinds(t)
            if !reach.isEmpty { d["reach_them_by"] = Dictionary(uniqueKeysWithValues: reach.map { ($0.kind, $0.place.label) }) }
            if let e = t.emails.first {
                d["email"] = e
                if t.emails.count > 1 { d["other_emails"] = Array(t.emails.dropFirst()) }
            }
        }
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

    /// For each kind of contact (texting, email, video calls), the place this user
    /// reaches the person in: the one with the most open conversations, then sightings;
    /// for email, where their address was shown.
    static func reachKinds(_ t: Thing) -> [(kind: String, place: Place)] {
        var out: [(String, Place)] = []
        for k in UserHabits.kinds where UserContacts.channelKinds.contains(k.kind) {
            let skills = Set(k.skills)
            func fits(_ p: Place) -> Bool {
                let s = p.isWeb ? AppSkills.skill(url: "https://" + p.key) : AppSkills.skill(bundleID: p.key)
                return s.map { skills.contains($0.name) } ?? (k.kind == "email" && UserContacts.extraMailBundles.contains(p.key))
            }
            var candidates = t.places.filter(fits)
            if k.kind == "email", let e = t.emailPlace, fits(e) {
                candidates.removeAll { $0.key == e.key }
                candidates.insert(e, at: 0)
            }
            if let best = candidates.max(by: { $0.reach != $1.reach ? $0.reach < $1.reach : $0.key > $1.key }) { out.append((k.kind, best)) }
        }
        return out
    }

    /// The app to reach the person the task names in, for the kind of contact it asks
    /// for ("text dhvan …" → where Dhvan's chat is opened, "facetime mom" → FaceTime),
    /// with no app named: a native app's bundle id, or nil.
    static func channelApp(task: String, matches: [Match]) -> String? {
        let kinds = UserHabits.candidates(for: task).map(\.kind).filter(UserContacts.channelKinds.contains)
        guard let kind = kinds.first else { return nil }
        for m in matches where m.thing.type == "person" {
            if let p = reachKinds(m.thing).first(where: { $0.kind == kind })?.place, !p.isWeb { return p.key }
        }
        return nil
    }

    /// `channelApp` against live memory.
    static func liveChannelApp(for task: String) -> String? {
        guard let k = current else { return nil }
        return channelApp(task: task, matches: k.matches(for: task))
    }

    /// The email address the user has mailed the person `name` names at ("meera",
    /// "Meera Baswan"), or nil when memory never showed one.
    static func emailAddress(named name: String, in things: [Thing]) -> String? {
        // One person: an address already, or a list ("Meera, Gabi") is left as typed.
        guard !RecipientPicker.looksLikeAddress(name), name.range(of: #"[,;&]|\band\b"#, options: .regularExpression) == nil,
              tokens(name).count <= 4 else { return nil }
        return matches(task: name, in: things.filter { $0.type == "person" && !$0.emails.isEmpty }, limit: 1).first?.thing.emails.first
    }

    static func liveEmailAddress(named name: String) -> String? {
        guard let k = current else { return nil }
        return emailAddress(named: name, in: k.things())
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
        who you talk to and where (the app you open their conversation in, the mail app you email them from), \
        and where your projects and documents live. Turn it off in \
        Navi → Settings → Agent → "Do things the way I do".

        """
        func line(_ t: Thing) -> String {
            var parts: [String] = []
            if t.type == "person" {
                let reach = reachKinds(t)
                if !reach.isEmpty { parts.append(reach.map { "\($0.kind) in \($0.place.label)" }.joined(separator: ", ")) }
            } else if !t.places.isEmpty {
                parts.append("in " + t.places.map { "\($0.label) (\($0.sessions))" }.joined(separator: ", "))
            }
            if t.workflow.count >= 2 { parts.append("usually " + t.workflow.joined(separator: " → ")) }
            if t.type != "person", let u = t.url { parts.append("[open](\(u))") }   // a person has no page of their own
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
