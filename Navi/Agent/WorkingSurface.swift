import Foundation

/// Where Navi's recent tasks did their work — the *working surface* — so a
/// follow-up continues there instead of on whatever happens to be in front.
///
/// Live (2026-10-30): after "order me a burger" filled a DoorDash cart, "open my
/// cart to see where I'm gonna pay" opened the *Amazon* cart (screen memory's
/// newest cart), "I meant in DoorDash where we just were" ran on the Amazon tab,
/// and on 10-29 "order me a burger" ran on the Canvas tab that was in front. The
/// words alone never said where; the last run did.
///
/// Every run records the place it worked in (the browser tab the runner drove —
/// its final URL and title —, the app the native driver drove, or the page/app a
/// voice command opened) and stamps it with the task and outcome when the run
/// ends. A new task then asks Jev, in the same call it already makes, one choice:
/// `work_where` — the screen in front (`here`), one of the recent places
/// (`last_1`…), or a place of its own (`new_place`). Code turns the answer into
/// where the run starts; no keyword lists decide it.
///
/// In memory only (a follow-up is minutes, not days): places older than
/// `maxAge` are never offered.
struct WorkingSurface: Sendable, Equatable {
    enum Kind: String, Sendable { case browserTab = "browser_tab", app }
    enum Outcome: String, Sendable { case running, completed, failed, cancelled }

    var kind: Kind
    /// The task that worked here, in the user's words.
    var task: String
    var outcome: Outcome = .running
    /// What came of it (one line, for Jev and the writer).
    var summary: String?
    var bundleID: String?
    var appName: String?
    /// Browser tabs: the page the run ended on.
    var url: String?
    /// The page's or window's title.
    var title: String?
    /// The Chrome runner drove this tab over CDP (it can attach to it again by URL).
    var viaRunner = false
    var at: Date

    static let maxAge: TimeInterval = 20 * 60
    static let maxOffered = 3

    // MARK: Identity

    /// "doordash.com" for a tab; nil for an app.
    var site: String? { url.flatMap(Self.site(of:)) }

    static func site(of url: String) -> String? {
        guard let host = URL(string: url)?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Two records are the same place: the same site (tabs) or the same app.
    var placeKey: String {
        switch kind {
        case .browserTab: return "tab:" + (site ?? url ?? "")
        case .app: return "app:" + (bundleID ?? appName ?? "").lowercased()
        }
    }

    /// Is this place what `front` shows right now (the same site in a browser, or the same app)?
    func isShown(by front: FrontmostProbe.Info) -> Bool {
        switch kind {
        case .browserTab:
            guard let b = front.bundleID, AXSnapshotter.isBrowser(b), let u = front.url, let s = Self.site(of: u) else { return false }
            return s == site
        case .app:
            guard let b = front.bundleID else { return false }
            return b == bundleID && !AXSnapshotter.isBrowser(b)
        }
    }

    /// How the place reads for Jev and logs: "Google Chrome tab · doordash.com/store/7th-street… · “Order 7th Street Burger”".
    var placeDescription: String {
        var parts: [String] = []
        switch kind {
        case .browserTab:
            parts.append("\(appName ?? "browser") tab")
            if let u = url { parts.append(Self.shortURL(u)) }
        case .app:
            parts.append("\(appName ?? bundleID ?? "an app") app")
        }
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { parts.append("“\(Self.clip(t, 70))”") }
        return parts.joined(separator: " · ")
    }

    /// Host + path, no scheme, query or fragment, clipped: what a person would read off the address bar.
    static func shortURL(_ u: String) -> String {
        guard let c = URLComponents(string: u), let host = c.host else { return clip(u, 60) }
        let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = c.path == "/" ? "" : c.path
        return clip(h + path, 60)
    }

    static func clip(_ s: String, _ n: Int) -> String { s.count <= n ? s : String(s.prefix(n - 1)) + "…" }

    /// One line for `recent_work` / the conversation: where, what, how it went.
    func stateEntry(id: String, now: Date) -> [String: Any] {
        var e: [String: Any] = ["id": id, "where": placeDescription, "task": task,
                                "minutes_ago": max(0, Int(now.timeIntervalSince(at) / 60))]
        var how = outcome.rawValue
        if let s = summary, !s.isEmpty { how += ": " + Self.clip(s.replacingOccurrences(of: "\n", with: " "), 160) }
        e["outcome"] = how
        return e
    }
}

// MARK: - Store

extension WorkingSurface {
    /// Thread-safe: runs note places from their worker tasks, the voice session
    /// and the panel read them on the main actor.
    final class Store: @unchecked Sendable {
        private let lock = NSLock()
        /// Finished places, most recent first, one per place (a newer run there replaces the older).
        private var finished: [WorkingSurface] = []
        /// Places noted by runs still going (newest last).
        private var notes: [WorkingSurface] = []

        static let shared = Store()
        static let maxKept = 6

        init() {}

        /// A run is working here now (the runner's page after a step, the app a native step drove).
        func note(_ s: WorkingSurface) {
            lock.lock(); defer { lock.unlock() }
            notes.append(s)
            if notes.count > 20 { notes.removeFirst(notes.count - 20) }
        }

        /// A run that started at `startedAt` ended: the last place it noted becomes a recent
        /// place, carrying the task and what came of it. A run that noted nothing leaves nothing.
        @discardableResult
        func finish(task: String, startedAt: Date, outcome: Outcome, summary: String?, now: Date = Date()) -> WorkingSurface? {
            lock.lock(); defer { lock.unlock() }
            guard let i = notes.lastIndex(where: { $0.at >= startedAt }) else { return nil }
            var s = notes[i]
            notes.removeAll { $0.at >= startedAt }
            s.task = task
            s.outcome = outcome
            s.summary = summary
            s.at = now
            insertLocked(s)
            return s
        }

        /// A place a command reached directly (a voice "go to youtube", "open notes").
        func record(_ s: WorkingSurface) {
            lock.lock(); defer { lock.unlock() }
            insertLocked(s)
        }

        private func insertLocked(_ s: WorkingSurface) {
            finished.removeAll { $0.placeKey == s.placeKey }
            finished.insert(s, at: 0)
            if finished.count > Self.maxKept { finished.removeLast(finished.count - Self.maxKept) }
        }

        /// The app was quit: nothing more can continue there.
        func forget(bundleID: String) {
            lock.lock(); defer { lock.unlock() }
            finished.removeAll { $0.kind == .app && $0.bundleID == bundleID }
        }

        /// Recent places worth offering, most recent first: fresh, and not cancelled before they did anything.
        func recent(now: Date = Date(), limit: Int = WorkingSurface.maxOffered) -> [WorkingSurface] {
            lock.lock(); defer { lock.unlock() }
            return Array(finished.filter { now.timeIntervalSince($0.at) <= WorkingSurface.maxAge }.prefix(limit))
        }

        /// A page one of the recent runs ended on (the runner may attach to its tab again).
        func isRecentPage(_ url: String, now: Date = Date()) -> Bool {
            recent(now: now, limit: Self.maxKept).contains { $0.kind == .browserTab && $0.url.map { WorkingSurface.samePage($0, url) } ?? false }
        }

        func reset() {
            lock.lock(); finished = []; notes = []; lock.unlock()
        }
    }

    /// Scheme, "www.", fragment and a trailing slash don't make a different page (the runner's `same_page`).
    static func samePage(_ a: String, _ b: String) -> Bool {
        func norm(_ u: String) -> String {
            var s = u.trimmingCharacters(in: .whitespaces)
            if let h = s.firstIndex(of: "#") { s = String(s[..<h]) }
            for p in ["https://", "http://"] where s.hasPrefix(p) { s = String(s.dropFirst(p.count)) }
            if s.hasPrefix("www.") { s = String(s.dropFirst(4)) }
            while s.hasSuffix("/") { s.removeLast() }
            return s.lowercased()
        }
        let x = norm(a)
        return !x.isEmpty && x == norm(b)
    }

    // MARK: Recording (hooks call these)

    /// The browser runner reported its page (after a step, or at the end).
    static func noteBrowserPage(task: String, url: String, title: String?, browserName: String = "Google Chrome",
                                bundleID: String? = "com.google.Chrome", viaRunner: Bool = true, store: Store = .shared) {
        guard url.hasPrefix("http") else { return }
        store.note(WorkingSurface(kind: .browserTab, task: task, bundleID: bundleID, appName: browserName, url: url,
                                  title: title, viaRunner: viaRunner, at: Date()))
    }

    /// A native step drove this app (and, for a browser driven natively, this page).
    static func noteApp(task: String, bundleID: String?, appName: String?, url: String? = nil, title: String? = nil, store: Store = .shared) {
        guard bundleID != nil || appName != nil, bundleID != Bundle.main.bundleIdentifier else { return }
        if let b = bundleID, AXSnapshotter.isBrowser(b), let u = url, u.hasPrefix("http") {
            store.note(WorkingSurface(kind: .browserTab, task: task, bundleID: b, appName: appName, url: u, title: title, at: Date()))
        } else {
            store.note(WorkingSurface(kind: .app, task: task, bundleID: bundleID, appName: appName, title: title, at: Date()))
        }
    }

    /// Feeds a run's events: the terminal one turns the run's last noted place into a recent place.
    static func observe(_ event: AgentEvent, task: String, startedAt: Date, store: Store = .shared) {
        let outcome: Outcome
        let summary: String?
        switch event {
        case .completed(let s): outcome = .completed; summary = s
        case .failed(let m): outcome = .failed; summary = m
        case .cancelled: outcome = .cancelled; summary = nil
        default: return
        }
        if let s = store.finish(task: task, startedAt: startedAt, outcome: outcome, summary: summary) {
            Log.agent.debug("WorkingSurface: \(s.placeDescription, privacy: .private) ← \(outcome.rawValue, privacy: .public)")
        }
    }
}

// MARK: - Where a new task works (one Jev head)

extension WorkingSurface {
    enum Choice: Equatable, Sendable {
        /// The screen in front (it may also be where the last task worked).
        case here
        /// Continue in this recent place.
        case last(WorkingSurface)
        /// A place of the task's own: never the page in front.
        case newPlace
        /// Where the instruction just before it (still running or queued) ends up working —
        /// resolved when this one starts ("open chrome and go to canvas" | "open my assignments").
        case previous
    }

    /// The head plus what its ids mean. nil when there is nothing to choose between.
    struct Question {
        var question: JevClient.Question
        var places: [String: WorkingSurface]
        /// `recent_work` for the state.
        var state: [[String: Any]]
    }

    static let questionName = "work_where"
    /// Below this, Jev's pick is not acted on (the old local rules decide).
    static let minConfidence = 0.5

    /// `front`: what is in front (app, window title, tab URL). `subject`: how the task is named
    /// in the criteria ("HEAD" for voice, "the task" for the planner).
    static func question(recent: [WorkingSurface], front: FrontmostProbe.Info?, subject: String = "HEAD",
                         previousInstruction: String? = nil, now: Date = Date()) -> Question? {
        var crit: [String: String] = [:]
        var places: [String: WorkingSurface] = [:]
        var state: [[String: Any]] = []
        let frontDesc = front.map(describeFront)
        // A recent place that is the screen in front is offered once, as `here`.
        var hereNote = ""
        var n = 0
        for s in recent.prefix(maxOffered) {
            if let f = front, s.isShown(by: f) {
                hereNote = " — where the earlier task “\(clip(s.task, 60))” worked"
                state.append(s.stateEntry(id: "here", now: now))
                continue
            }
            n += 1
            let id = "last_\(n)"
            places[id] = s
            state.append(s.stateEntry(id: id, now: now))
            let ago = max(0, Int(now.timeIntervalSince(s.at) / 60))
            crit[id] = "Carry \(subject) out where the earlier task “\(clip(s.task, 60))” worked (\(ago) min ago): \(s.placeDescription). Pick this when \(subject) continues that task or refers back to it ('where we just were', 'the cart', 'it', 'go back', 'now add…', 'I meant in …', a correction), or when what \(subject) asks belongs on that site or app."
        }
        if let p = previousInstruction?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            crit["previous"] = "Carry \(subject) out wherever the instruction said just before it ends up working — Navi is still carrying it out or about to: “\(clip(p, 80))”. Pick this when \(subject) is the next part of that instruction (its next step, on the page or app it opens), e.g. 'open my assignments' right after 'go to canvas'."
        }
        guard !places.isEmpty || frontDesc != nil || crit["previous"] != nil else { return nil }
        if let d = frontDesc {
            crit["here"] = "Carry \(subject) out on the screen in front right now (\(d)\(hereNote)): \(subject) acts on what is visible there — click, type, scroll, read, select, close on that page or app — or says 'this page', 'this tab', 'here'\(hereNote.isEmpty ? "" : ", or continues that task")."
        }
        crit["new_place"] = "\(subject) names or implies a place of its own — another website or app, or an errand (order food, book, buy, look something up, message someone) that the screen in front and the recent work have nothing to do with: start there fresh, never on the page in front."
        let q = JevClient.Question.choice(
            instructions: "Where should \(subject) be carried out? recent_work lists where Navi's last tasks worked, most recent first.",
            criteria: crit)
        return Question(question: q, places: places, state: state)
    }

    static func describeFront(_ f: FrontmostProbe.Info) -> String {
        var d = f.appName ?? f.bundleID ?? "unknown app"
        if let t = f.windowTitle, !t.isEmpty { d += " · “\(clip(t, 70))”" }
        if let b = f.bundleID, AXSnapshotter.isBrowser(b), let u = f.url, u.hasPrefix("http") { d += " (\(shortURL(u)))" }
        return d
    }

    /// Jev's answer → a choice, or nil when it is unsure (or answered something unknown).
    static func choice(answer: String?, confidence: Double, places: [String: WorkingSurface]) -> Choice? {
        guard let a = answer, confidence >= minConfidence else { return nil }
        switch a {
        case "here": return .here
        case "new_place": return .newPlace
        case "previous": return .previous
        default: return places[a].map(Choice.last)
        }
    }

    // MARK: Turning a place into a start

    enum Start: Equatable, Sendable {
        /// A browser step on this page; `attach` ⇒ work on the tab already showing it.
        case page(url: String, attach: Bool)
        /// A native step in this app.
        case app(bundleID: String?, name: String?)
    }

    /// Where a run that continues in `s` starts. A tab of the same site in front is that tab
    /// (the user may have moved on within the site); otherwise the page the run ended on — the
    /// runner attaches to its tab when it is still open, else opens the page again.
    static func start(for s: WorkingSurface, front: FrontmostProbe.Info) -> Start {
        switch s.kind {
        case .browserTab:
            if s.isShown(by: front), let u = front.url { return .page(url: u, attach: true) }
            return .page(url: s.url ?? "", attach: true)
        case .app:
            return .app(bundleID: s.bundleID, name: s.appName)
        }
    }
}
