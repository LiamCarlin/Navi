import Foundation

/// How this user *acts* in each app and site, learned from screen memory, so the
/// agent clicks what they would click. `UserHabits` knows which tools they reach
/// for, `UserKnowledge` the people and documents in their life; this knows their
/// moves:
///   - the controls they click in each place, how often, and what they click
///     right after each one (`ActionJournal` records),
///   - the shortcuts they press there, and the menu items they choose that have one,
///   - the procedures the digester distilled from their sessions: a task as they
///     could ask for it, the steps they took, what that shows about how they work.
///
/// Every native step, `hints` marks the on-screen items this user clicks here
/// ("user_clicks": 14) and the one they usually click next after the agent's last
/// click, adds their shortcuts to the shortcut question, and puts
/// `how_this_user_works` (similar things they did before and how, their habits here,
/// what they click most) in Jev's state. The planner and the browser runner get the
/// procedures too, and the vault's "How you work" note shows all of it — plus
/// faster ways (menu items they keep clicking that have a shortcut).
///
/// Installed by `MemoryService` next to `UserKnowledge`, behind the same toggle
/// (`agentUsesScreenHabits`). One actions + procedures read per `ttl`, then lookups.
final class UserMoves: @unchecked Sendable {
    struct Control: Sendable, Equatable {
        var label: String
        var role: String
        var kind: ActionRecord.Kind
        var count: Int
        var shortcut: String?
        var path: String?
        var lastSeen: Date
    }

    struct Shortcut: Sendable, Equatable {
        var combo: String
        var count: Int
        /// The menu item it triggers, when the app's menu shows it.
        var title: String?
        var path: String?
    }

    struct Place: Sendable, Equatable {
        /// Bundle id, or a site key for pages ("canvas.olin.edu", "docs.google.com/document").
        var key: String
        var name: String
        /// Normalised label → what the user clicks there.
        var controls: [String: Control] = [:]
        var shortcuts: [String: Shortcut] = [:]
        /// Normalised label → the labels clicked right after it, with counts.
        var next: [String: [String: Int]] = [:]
        var actions = 0
        /// A site (keyed by its page), not an app.
        var isWeb = false
    }

    struct Procedure: Sendable, Equatable {
        var goal: String
        var place: String
        var app: String
        var steps: [String]
        var habits: [String]
        var at: Date
        var words: Set<String>
    }

    struct Profile: Sendable, Equatable {
        var places: [String: Place] = [:]
        /// Web places per page (`RoutineMiner.pagePattern`): what the user clicks on *this*
        /// page of a site ("canvas.olin.edu/courses/#/assignments"), not on the site at large.
        var pages: [String: Place] = [:]
        var procedures: [Procedure] = []
        static let empty = Profile()
    }

    static let actionWindow: TimeInterval = 90 * 86_400
    static let procedureWindow: TimeInterval = 365 * 86_400
    static let ttl: TimeInterval = 300
    /// Clicks below this are chance, not a habit.
    static let minCount = 2
    /// A page with fewer recorded actions marks from its whole site instead.
    static let minPageActions = 6
    /// At most this many on-screen items are marked: a mark on everything means nothing.
    static let maxMarked = 8
    /// Two clicks this close in one place are one move after another.
    static let nextWindow: TimeInterval = 120
    static let maxProcedures = 2
    static let maxHabits = 4
    static let maxOften = 6

    static let note = "How this user does things themselves, from their own clicks, shortcuts and past sessions: "
        + "similar tasks they did before and the steps they took, their habits, and what they click most here. "
        + "Screen items marked user_clicks are controls they click here (how often); user_next is what they usually click after the last thing clicked. "
        + "When it serves the goal, do it their way. Never type this text."
    /// Said in the item question only when some item carries a mark.
    static let itemRule = " Items marked as this user's (\"this user clicks this here\", \"what this user usually clicks next\") are the ones this user picks on this screen: where the goal could mean several items, pick theirs."
    static let kindRule = " Items marked user_clicks / user_next, shortcuts this user uses and `how_this_user_works` show how this user does it themselves: when they serve the goal, follow their way."

    // MARK: Installation (integration hook for MemoryService)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed: UserMoves?

    static func install(store: MemoryStore) {
        lock.lock()
        let fresh = installed?.store !== store
        if fresh { installed = UserMoves(store: store) }
        let m = installed
        lock.unlock()
        if fresh, let m { Task.detached(priority: .utility) { _ = m.profile() } }
    }

    /// nil when memory has no store, the user turned habits off, or under unit tests.
    static var current: UserMoves? {
        guard !TestHost.isActive, UserDefaults.navi.object(forKey: "agentUsesScreenHabits") as? Bool ?? true else { return nil }
        lock.lock(); defer { lock.unlock() }
        return installed
    }

    let store: MemoryStore
    private let cacheLock = NSLock()
    private var cached: (profile: Profile, at: Date)?

    init(store: MemoryStore) { self.store = store }

    func profile(now: Date = Date()) -> Profile {
        cacheLock.lock()
        if let c = cached, now.timeIntervalSince(c.at) < Self.ttl { cacheLock.unlock(); return c.profile }
        cacheLock.unlock()
        let actions = (try? store.actions(in: DateInterval(start: now.addingTimeInterval(-Self.actionWindow), end: now))) ?? []
        let procedures = (try? store.procedures(since: now.addingTimeInterval(-Self.procedureWindow))) ?? []
        let p = Self.build(actions: actions, procedures: procedures)
        cacheLock.lock(); cached = (p, now); cacheLock.unlock()
        return p
    }

    func invalidate() { cacheLock.lock(); cached = nil; cacheLock.unlock() }

    // MARK: Building

    /// Where an action happened: the site for a page, else the app.
    static func placeKey(bundleID: String, url: String?) -> String {
        if let u = url, let k = UserHabits.siteKey(of: u), !UserHabits.ignoredSiteKeys.contains(k) { return k }
        return bundleID
    }

    static func build(actions: [ActionRecord], procedures: [ProcedureRecord]) -> Profile {
        var p = Profile()
        var previous: [String: (label: String, at: Date)] = [:]
        for a in actions.sorted(by: { $0.timestamp < $1.timestamp }) where !a.bundleID.isEmpty {
            // Typing says where the user writes, not what they click.
            guard a.kind != .type else { continue }
            let key = placeKey(bundleID: a.bundleID, url: a.url)
            var place = p.places[key] ?? Place(key: key, name: key == a.bundleID ? a.appName : key, isWeb: key != a.bundleID)
            place.actions += 1
            if key != a.bundleID, a.kind != .key, let page = a.url.flatMap(RoutineMiner.pagePattern) {
                var pg = p.pages[page] ?? Place(key: page, name: page, isWeb: true)
                pg.actions += 1
                let n = norm(a.label)
                if !n.isEmpty {
                    var c = pg.controls[n] ?? Control(label: a.label, role: a.role, kind: a.kind, count: 0, shortcut: a.shortcut, path: a.path, lastSeen: a.timestamp)
                    c.count += 1
                    c.lastSeen = a.timestamp
                    pg.controls[n] = c
                }
                p.pages[page] = pg
            }
            if a.kind == .key, let combo = a.shortcut {
                var s = place.shortcuts[combo] ?? Shortcut(combo: combo, count: 0)
                s.count += 1
                if !a.label.isEmpty { s.title = a.label; s.path = a.path }
                place.shortcuts[combo] = s
            } else if a.kind != .key {
                let n = norm(a.label)
                if !n.isEmpty {
                    var c = place.controls[n] ?? Control(label: a.label, role: a.role, kind: a.kind, count: 0,
                                                        shortcut: a.shortcut, path: a.path, lastSeen: a.timestamp)
                    c.count += 1
                    c.lastSeen = a.timestamp
                    c.label = a.label
                    if a.shortcut != nil { c.shortcut = a.shortcut }
                    place.controls[n] = c
                    if let prev = previous[key], prev.label != n, a.timestamp.timeIntervalSince(prev.at) <= nextWindow {
                        place.next[prev.label, default: [:]][n, default: 0] += 1
                    }
                    previous[key] = (n, a.timestamp)
                }
            }
            p.places[key] = place
        }
        p.procedures = procedures.compactMap { r in
            let words = AgentExperience.words(r.goal)
            guard !words.isEmpty, !r.steps.isEmpty else { return nil }   // a goal with no steps shows no way of doing it
            return Procedure(goal: r.goal, place: r.site ?? r.bundleID, app: r.appName, steps: r.steps, habits: r.habits,
                             at: r.start, words: words)
        }.sorted { $0.at > $1.at }
        return p
    }

    /// Lower-case, one space, no trailing "…", ":" or badge count ("Drafts (3)"). A bare
    /// number stays: "Assignment 2" is not "Assignment 3".
    static func norm(_ s: String) -> String {
        var t = s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let last = t.last, "…:.".contains(last) { t.removeLast() }
        if let r = t.range(of: #"\s*\(\d{1,5}\)$"#, options: .regularExpression), r.lowerBound != t.startIndex { t.removeSubrange(r) }
        return String(t.trimmingCharacters(in: .whitespaces).prefix(80))
    }

    /// A row named after its first line ("Mikey Ku") still matches the row shown with its
    /// preview ("Mikey Ku, see you at 5"): the shorter must be a whole leading part.
    static func sameControl(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        guard short.count >= 6, long.hasPrefix(short) else { return false }
        let rest = long.dropFirst(short.count)
        return separators.contains { rest.hasPrefix($0) }
    }

    static let separators = [",", " ·", " -", " —", ":", " |", " ("]

    /// A list row's name: its text up to the first separator ("mikey ku, are we…" → "mikey ku").
    static func head(_ s: String) -> String {
        var cut = s.endIndex
        for sep in separators { if let r = s.range(of: sep), r.lowerBound < cut { cut = r.lowerBound } }
        return String(s[..<cut])
    }

    /// Does an on-screen item (normalised text) show this control? A row matches on its name, so
    /// a conversation still matches once its preview has changed.
    static func matches(_ c: Control, _ text: String) -> Bool {
        let label = norm(c.label)
        if sameControl(label, text) { return true }
        guard c.role == "row" else { return false }
        let h = head(label)
        return h.count >= 4 && h == head(text)
    }

    // MARK: Per-step hints

    struct Hints: @unchecked Sendable {
        /// Item index → how often this user clicks it here.
        var clicks: [Int: Int] = [:]
        /// Items this user usually clicks after the last thing clicked.
        var next: Set<Int> = []
        /// The shortcut list with this user's own added or marked.
        var shortcuts: [(String, String)] = []
        var state: [String: Any]?
        /// Items that are the next step of the user's routine for this task (`UserRoute.marks`).
        var routeNext: Set<Int> = []
        /// `this_users_way` (`UserRoute.state`).
        var route: [String: Any]?

        var isEmpty: Bool { clicks.isEmpty && next.isEmpty && state == nil && routeNext.isEmpty && route == nil }
    }

    /// Everything one Jev step gets from this user's moves. `lastClicked`: the label of the
    /// item the agent clicked last, if any.
    static func hints(profile: Profile, goal: String, bundleID: String?, url: String?, items: [(index: Int, text: String)],
                      lastClicked: String?, shortcuts: [(String, String)]) -> Hints {
        var h = Hints(shortcuts: shortcuts)
        let key = bundleID.map { placeKey(bundleID: $0, url: url) }
        let place = key.flatMap { profile.places[$0] }

        if let place {
            // Marks: on-screen items that are controls this user clicks here, most clicked first —
            // on this page of a site when they have used it enough, else anywhere on the site.
            let page = place.isWeb ? url.flatMap(RoutineMiner.pagePattern).flatMap { profile.pages[$0] } : nil
            let marking = page.map { $0.actions >= minPageActions } == true ? page! : place
            var counted: [(Int, Int)] = []
            for it in items {
                let n = norm(it.text)
                guard !n.isEmpty else { continue }
                let c = marking.controls[n] ?? marking.controls.values.first { matches($0, n) }
                if let c, c.count >= minCount { counted.append((it.index, c.count)) }
            }
            for (i, n) in counted.sorted(by: { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }).prefix(maxMarked) { h.clicks[i] = n }

            // What they click after the last thing clicked.
            if let last = lastClicked.map(norm), !last.isEmpty,
               let after = place.next[last] ?? place.next.first(where: { k, _ in place.controls[k].map { matches($0, last) } ?? sameControl(k, last) })?.value {
                let wanted = after.filter { $0.value >= minCount }.sorted { $0.value > $1.value }.prefix(2).compactMap { place.controls[$0.key] }
                for it in items where wanted.contains(where: { matches($0, norm(it.text)) }) { h.next.insert(it.index) }
            }

            h.shortcuts = merged(shortcuts, place: place)
        }

        var state: [String: Any] = [:]
        let done = matching(goal: goal, place: key, in: profile.procedures, limit: maxProcedures)
        if !done.isEmpty { state["did_before"] = done.map(line) }
        var habits: [String] = []
        for p in done + profile.procedures.filter({ $0.place == key }) {
            for hb in p.habits where !habits.contains(where: { norm($0) == norm(hb) }) { habits.append(hb) }
        }
        if !habits.isEmpty { state["habits"] = Array(habits.prefix(maxHabits)) }
        if let place {
            let often = place.controls.values.filter { $0.count >= minCount && $0.role != "row" && $0.label.count <= 40 }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }.prefix(maxOften)
                .map { "‘\($0.label)’ (\($0.kind == .menu ? "menu item" : $0.role), \($0.count)×)" }
            if !often.isEmpty { state["often_clicks_here"] = Array(often) }
        }
        if !state.isEmpty {
            state["note"] = note
            if let place { state["here"] = place.name }
            h.state = state
        }
        return h
    }

    /// The shortcut list with this user's: a shortcut already offered says they use it; one they
    /// press (or whose menu item they pick) that the list lacks is added, named by its menu item.
    static func merged(_ base: [(String, String)], place: Place) -> [(String, String)] {
        var out = base
        func index(of combo: String) -> Int? {
            guard let want = try? KeyCombo.parse(combo) else { return nil }
            return out.firstIndex { (try? KeyCombo.parse($0.0)).map { $0.keyCode == want.keyCode && $0.flags == want.flags } ?? false }
        }
        var uses: [(combo: String, title: String?, count: Int, how: String)] = place.shortcuts.values
            .filter { $0.count >= minCount }.map { ($0.combo, $0.title, $0.count, "this user presses it here") }
        for c in place.controls.values where c.kind == .menu && c.count >= minCount {
            if let s = c.shortcut { uses.append((s, c.label, c.count, "this user chooses ‘\(c.label)’ from the \(c.path ?? "app") menu")) }
        }
        for u in uses.sorted(by: { $0.count > $1.count }).prefix(12) {
            guard !CUDecide.keysThatAreKinds.contains(u.combo.lowercased()), (try? KeyCombo.parse(u.combo)) != nil else { continue }
            let note = "\(u.how), \(u.count)×"
            if let i = index(of: u.combo) {
                if !out[i].1.contains("this user") { out[i].1 += " — \(note)" }
            } else if let title = u.title, !title.isEmpty {
                out.append((u.combo, "\(title) — \(note)"))
            }
        }
        return out
    }

    /// Procedures whose goal shares enough words with `goal` (as `AgentExperience` matches),
    /// the same place first, then the most recent.
    static func matching(goal: String, place: String?, in procedures: [Procedure], limit: Int) -> [Procedure] {
        let wanted = AgentExperience.words(goal)
        guard !wanted.isEmpty else { return [] }
        let scored: [(Procedure, Double)] = procedures.compactMap { p in
            let shared = wanted.intersection(p.words).count
            guard shared >= min(AgentExperience.minSharedWords, wanted.count) else { return nil }
            let overlap = Double(shared) / Double(wanted.count)
            guard overlap >= AgentExperience.minOverlap else { return nil }
            return (p, overlap + (place != nil && p.place == place ? 0.3 : 0))
        }
        var seen = Set<String>()
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.at > $1.0.at }.map(\.0)
            .filter { seen.insert(norm($0.goal)).inserted }.prefix(limit).map { $0 }
    }

    static func line(_ p: Procedure) -> String {
        "\(p.goal) (\(p.app)) → " + (p.steps.isEmpty ? "no steps recorded" : p.steps.joined(separator: " · "))
    }

    // MARK: Live helpers (empty when moves are off)

    static func liveHints(goal: String, bundleID: String?, url: String?, items: [(index: Int, text: String)],
                          lastClicked: String?, shortcuts: [(String, String)]) -> Hints {
        guard let m = current else { return Hints(shortcuts: shortcuts) }
        return hints(profile: m.profile(), goal: goal, bundleID: bundleID, url: url, items: items,
                     lastClicked: lastClicked, shortcuts: shortcuts)
    }

    /// For the planner and the browser runner: how the user did tasks like this before.
    static func liveContext(for task: String) -> [String: Any]? {
        guard let m = current else { return nil }
        let done = matching(goal: task, place: nil, in: m.profile().procedures, limit: 3)
        guard !done.isEmpty else { return nil }
        var habits: [String] = []
        for p in done { for h in p.habits where !habits.contains(h) { habits.append(h) } }
        var out: [String: Any] = ["note": note, "did_before": done.map(line)]
        if !habits.isEmpty { out["habits"] = Array(habits.prefix(maxHabits)) }
        return out
    }

    // MARK: Browser runner (`NAVI_USER_MOVES_JSON`, runner adaptation 21)

    static let runnerMaxSites = 25
    static let runnerMaxControls = 120

    /// What this user clicks on each site, for the browser runner to mark page elements with:
    /// `{"sites": {site: {"clicks": [{label, role, count}], "next": {label: {label: count}}}}}`.
    /// The busiest sites (plus `prefer`, the start page's) only; nil when nothing qualifies.
    static func runnerJSON(_ profile: Profile, prefer: String? = nil) -> String? {
        let preferred = prefer.flatMap(UserHabits.siteKey(of:))
        let web = profile.places.values.filter(\.isWeb).sorted {
            ($0.key == preferred) != ($1.key == preferred) ? $0.key == preferred : $0.actions > $1.actions
        }
        var sites: [String: Any] = [:]
        for place in web where sites.count < runnerMaxSites {
            let controls = place.controls.filter { $0.value.count >= minCount }
                .sorted { $0.value.count > $1.value.count }.prefix(runnerMaxControls)
            guard !controls.isEmpty else { continue }
            let kept = Set(controls.map(\.key))
            var next: [String: [String: Int]] = [:]
            for (from, tos) in place.next where kept.contains(from) {
                let strong = tos.filter { $0.value >= minCount && kept.contains($0.key) }
                if !strong.isEmpty { next[from] = strong }
            }
            sites[place.key] = ["clicks": controls.map { ["label": $0.value.label, "role": $0.value.role, "count": $0.value.count] },
                                "next": next]
        }
        guard !sites.isEmpty, let data = try? JSONSerialization.data(withJSONObject: ["sites": sites], options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func liveRunnerJSON(startURL: String?) -> String? {
        guard let m = current else { return nil }
        return runnerJSON(m.profile(), prefer: startURL)
    }

    // MARK: Vault ("How you work")

    /// A menu item chosen by mouse that has a shortcut the user rarely presses.
    struct Tip: Equatable, Sendable {
        var place: String
        var item: String
        var path: String?
        var shortcut: String
        var clicks: Int
        var presses: Int
    }

    static func tips(_ profile: Profile, minClicks: Int = 3) -> [Tip] {
        var out: [Tip] = []
        for place in profile.places.values {
            for c in place.controls.values where c.kind == .menu && c.count >= minClicks {
                guard let s = c.shortcut, let want = try? KeyCombo.parse(s) else { continue }
                let presses = place.shortcuts.values.filter { (try? KeyCombo.parse($0.combo)).map { $0.keyCode == want.keyCode && $0.flags == want.flags } ?? false }
                    .map(\.count).reduce(0, +)
                if presses < c.count { out.append(Tip(place: place.name, item: c.label, path: c.path, shortcut: s, clicks: c.count, presses: presses)) }
            }
        }
        return out.sorted { $0.clicks != $1.clicks ? $0.clicks > $1.clicks : $0.item < $1.item }
    }

    /// "⌘⇧T" for a combo.
    static func display(_ combo: String) -> String { (try? KeyCombo.parse(combo))?.displayLabel ?? combo }

    static func markdown(_ profile: Profile, routines: [Routine] = []) -> String {
        var out = ""
        if !routines.isEmpty {
            // The routines the agent follows, as their steps: the ones done most first.
            out += "\n## Your routines\n\nThings you do and the steps you take — when you ask for one of these, Navi takes the same steps itself"
                + " (… is the part that changes: the person, the file).\n\n"
            for r in routines.prefix(30) {
                let times = r.count > 1 ? ", \(r.count)×" : ""
                let record = r.worked + r.failed > 0 ? " · Navi followed it \(r.worked + r.failed)× (\(r.worked) worked)" : ""
                out += "- **\(r.template)** (\(r.site ?? r.appName)\(times)\(record)): " + r.steps.map(\.human).joined(separator: " → ") + "\n"
            }
            return out + markdownHabits(profile)
        }
        // Routines: goals that came back, then the latest others.
        var groups: [String: [Procedure]] = [:]
        var order: [String] = []
        for p in profile.procedures {
            let k = norm(p.goal)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(p)
        }
        let routines = order.compactMap { groups[$0] }.sorted { $0.count != $1.count ? $0.count > $1.count : $0[0].at > $1[0].at }.prefix(25)
        if !routines.isEmpty {
            out += "\n## Your routines\n\nTasks you did and how — Navi follows these steps when you ask for the same thing.\n\n"
            for r in routines {
                let p = r[0]
                out += "- **\(p.goal)** (\(p.app)\(r.count > 1 ? ", \(r.count)×" : "")): " + (p.steps.isEmpty ? "—" : p.steps.joined(separator: " → ")) + "\n"
            }
        }
        return out + markdownHabits(profile)
    }

    /// "How you do things", "What you click" and "Faster ways".
    static func markdownHabits(_ profile: Profile) -> String {
        var out = ""
        var habits: [String] = []
        for p in profile.procedures { for h in p.habits where !habits.contains(where: { norm($0) == norm(h) }) { habits.append(h) } }
        if !habits.isEmpty {
            out += "\n## How you do things\n\n" + habits.prefix(30).map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        let places = profile.places.values.filter { $0.actions >= 10 }.sorted { $0.actions > $1.actions }.prefix(12)
        if !places.isEmpty {
            out += "\n## What you click\n\n"
            for pl in places {
                let top = pl.controls.values.filter { $0.count >= minCount && $0.role != "row" }.sorted { $0.count > $1.count }.prefix(6)
                    .map { "‘\($0.label)’ \($0.count)×" }
                let keys = pl.shortcuts.values.filter { $0.count >= minCount }.sorted { $0.count > $1.count }.prefix(5)
                    .map { "\(display($0.combo))\($0.title.map { " \($0)" } ?? "") \($0.count)×" }
                guard !top.isEmpty || !keys.isEmpty else { continue }
                out += "- **\(pl.name)** — " + ([top.isEmpty ? nil : top.joined(separator: ", "),
                                                  keys.isEmpty ? nil : "shortcuts: " + keys.joined(separator: ", ")].compactMap { $0 }.joined(separator: "; ")) + "\n"
            }
        }
        let tips = tips(profile).prefix(10)
        if !tips.isEmpty {
            out += "\n## Faster ways\n\n"
            for t in tips {
                let item = [t.path, t.item].compactMap { $0 }.joined(separator: " › ")
                out += "- \(t.place): you chose **\(item)** from the menu \(t.clicks)×" + (t.presses > 0 ? " (pressed its shortcut \(t.presses)×)" : "")
                    + " — **\(display(t.shortcut))** does it in one keystroke.\n"
            }
        }
        return out
    }
}
