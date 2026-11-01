import Foundation

/// The screen in front, for a task typed into ⌘Space: what the user is looking at wins over older
/// places — the last run's tab (`WorkingSurface`), their usual site (`UserHabits`/`UserPaths`), a
/// screen-memory guess (`TaskGrounding`) — whenever the task points at it ("this/these/here/this
/// page/the video/page 2"), acts on the page ("pause", "skip the ad", "click…"), or asks for a page of
/// the site in front without naming another place ("open my cart", "checkout", "add fries too").
///
/// The planner is told the same (`TaskPlanner.systemPrompt`, `screen_in_front`); `anchor` makes it a
/// rule, because Haiku followed `recent_work` instead (bench 2026-11-01: "add 2 of these to my cart" on
/// an Amazon servo page became "add 2 of the cheapest toilet paper", "open my cart" on DoorDash the
/// Amazon cart, "add fries too" a McDonald's order, "this course" another course). Pure: unit-tested.
enum ScreenInFront {

    // MARK: What the task's words point at

    /// Lowercased, apostrophes kept, everything else a single space, padded with spaces.
    static func normalized(_ task: String) -> String {
        " " + task.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[^a-z0-9' ]"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ") + " "
    }

    /// "this" / "these" / "those" that is not a time ("this week", "this friday", "this morning").
    private static let demonstrative = try! NSRegularExpression(
        pattern: #"\b(this|these|those)\b(?! (week|weekend|weekends|morning|afternoon|evening|night|tonight|month|year|time|semester|term|quarter|summer|fall|autumn|winter|spring|monday|tuesday|wednesday|thursday|friday|saturday|sunday|coming|past|last|next)\b)"#)
    /// A thing on screen named by its kind: "the video", "skip the ad", "this page", "the current tab".
    private static let screenThing = try! NSRegularExpression(
        pattern: #"\b(the|this|current|open|opened) (page|tab|site|website|video|ad|ads|song|track|article|post|pdf|window)\b(?! (for|of|about|on|called|named)\b)"#)
    /// A page of the document in front: "the scores on page 2".
    private static let documentPage = try! NSRegularExpression(pattern: #"\bpages? ([0-9]+|one|two|three|four|five|six|seven|eight|nine|ten)\b"#)

    private static func has(_ re: NSRegularExpression, _ t: String) -> Bool {
        re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }

    /// Does the task point at what is on screen — deixis, a thing named by its on-screen kind, a page of
    /// the document in front?
    static func pointsAtScreen(_ task: String) -> Bool {
        let t = normalized(task)
        if t.contains(" here ") || t.contains(" right here ") { return true }
        return has(demonstrative, t) || has(screenThing, t) || has(documentPage, t)
    }

    /// Verbs that only make sense on the page in front — a stricter list than `TaskSurface.isPageAction`
    /// ("check the weather" or "play lofi beats" over a YouTube tab is not about that tab).
    static let pageVerbs = ["click", "tap", "press", "scroll", "pause", "unpause", "resume the video", "mute", "unmute", "skip",
                            "like", "dislike", "unlike", "subscribe", "unsubscribe", "reload", "refresh", "zoom", "highlight",
                            "select", "fill in", "fill out", "dismiss", "expand", "collapse", "bookmark", "close the popup",
                            "close the pop up", "accept the cookies", "go back", "go forward", "full screen", "fullscreen"]

    /// An action on the page in front ("pause the video", "skip the ad", "click Add to cart") — never one
    /// that asks for something to be found or opened elsewhere ("scroll down and search for X").
    static func isPageAction(_ task: String) -> Bool {
        let t = normalized(task)
        if t.range(of: #" (search for|search the web|search google|google|look up|lookup|look for|find me|go to|navigate to|visit|browse to|pull up|bring up) "#,
                   options: .regularExpression) != nil { return false }
        var s = t.trimmingCharacters(in: .whitespaces)
        var stripped = true
        while stripped {
            stripped = false
            for l in ["please ", "can you ", "could you ", "now ", "then ", "and ", "just ", "also ", "navi "] where s.hasPrefix(l) {
                s = String(s.dropFirst(l.count)); stripped = true
            }
        }
        return pageVerbs.contains { s == $0 || s.hasPrefix($0 + " ") }
    }

    private static let sitePage = try! NSRegularExpression(
        pattern: #"\b(my|the|our) (cart|shopping cart|bag|basket|checkout|order|orders|wishlist|wish list|favorites|favourites|saved items|watch later|playlist|queue)\b|\bcheck ?out\b"#)
    private static let addMore = try! NSRegularExpression(
        pattern: #"\b(add|get|grab|include|throw in|put in|order)\b.*\b(too|also|as well)\b|\b(add|get|grab|order) (another|one more|more|a second|two more)\b"#)

    /// A page or a continuation of the site in front, named without a site: "open my cart", "to my
    /// cart", "checkout", "add fries too", "add another one".
    static func continuesOnPage(_ task: String) -> Bool {
        let t = normalized(task)
        return has(sitePage, t) || has(addMore, t)
    }

    // MARK: Places

    static func host(_ url: String?) -> String? {
        guard let url, let h = URL(string: url.contains("://") ? url : "https://" + url)?.host?.lowercased() else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    static func sameSite(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.hasSuffix("." + b) || b.hasSuffix("." + a)
    }

    /// A search engine's page (home or results): "open my cart" there has no cart to open.
    static func isSearchEngine(_ url: String) -> Bool {
        guard let h = host(url) else { return false }
        let engines = ["google.com", "bing.com", "duckduckgo.com", "search.yahoo.com", "ecosia.org", "search.brave.com"]
        guard engines.contains(where: { sameSite(h, $0) }) else { return false }
        let path = URL(string: url)?.path ?? ""
        return path.isEmpty || path == "/" || path.hasPrefix("/search") || path.hasPrefix("/webhp")
    }

    /// Does the task name a web place other than the tab in front — a URL, a well-known site, a web app,
    /// a business ("from kfc")? A native app it names ("…into a note") is not one: the browser step is
    /// still about the page, the app gets its own step.
    static func namesOtherWebPlace(_ task: String, frontURL: String?) -> Bool {
        let front = host(frontURL)
        for u in TextCandidates.urls(in: task) where !sameSite(host(u), front) { return true }
        if let site = UltrafastBridge.knownSiteURL(in: task), !sameSite(host(site), front) {
            // "flights" names Google Flights; on the Flights tab it names the tab.
            return true
        }
        if let skill = AppSkills.mentioned(in: task), !skill.hosts.isEmpty {
            let frontSkill = AppSkills.skill(url: frontURL)
            let word = skill.name.lowercased().filter { $0.isLetter || $0.isNumber }
            // The user's own instance of a web app counts as it ("canvas" on canvas.olin.edu).
            let carries = !word.isEmpty && (front ?? "").split(separator: ".").contains { $0.filter { $0.isLetter || $0.isNumber } == word }
            if frontSkill?.name != skill.name, !carries { return true }
        }
        if let business = TaskPlanner.errandName(for: task) {
            let letters = business.filter { $0.isLetter || $0.isNumber }
            if !(front.map { TaskPlanner.siteCarries($0, name: letters) } ?? false) { return true }
        }
        return false
    }

    // MARK: The rule

    /// Is a task typed over this browser tab about that tab?
    static func anchorsToTab(_ task: String, url: String) -> Bool {
        guard url.hasPrefix("http"), !namesOtherWebPlace(task, frontURL: url) else { return false }
        if pointsAtScreen(task) || isPageAction(task) { return true }
        return continuesOnPage(task) && !isSearchEngine(url)
    }

    /// The http(s) tab of the browser in front, if a browser is in front.
    static func frontTab(_ front: FrontmostProbe.Info) -> String? {
        guard let b = front.bundleID, AXSnapshotter.isBrowser(b), let u = front.url, u.hasPrefix("http") else { return nil }
        return u
    }

    /// The user's words as the goal of a step anchored to the screen: "to my cart" (the recognizer, or
    /// the user, dropped the verb) is "Go to my cart".
    static func userGoal(_ task: String) -> String {
        let t = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = t.lowercased()
        if l.hasPrefix("to my ") || l.hasPrefix("to the ") { return "Go " + t }
        return t
    }

    /// The plan, with its first step moved onto the screen in front when the task is about it:
    ///   - a browser tab in front: the first (browser) step continues on that tab (`useCurrentTab`, no
    ///     URL, no search); a one-step plan keeps the user's own words as its goal — the planner's
    ///     rewrite carried the old place's item ("the cheapest toilet paper");
    ///   - an app in front (a PDF in Preview, a document): a first step that would Google the words
    ///     pointing at it ("Find the scores on page 2") becomes a step in that app.
    /// Anything else is returned unchanged.
    static func anchor(_ plan: TaskPlanner.Plan, task: String, frontmost: FrontmostProbe.Info) -> TaskPlanner.Plan {
        guard let first = plan.steps.first else { return plan }
        var p = plan
        if let tab = frontTab(frontmost) {
            guard first.surface == .browser, anchorsToTab(task, url: tab) else { return plan }
            p.steps[0].useCurrentTab = true
            p.steps[0].url = nil
            p.steps[0].query = nil
            if !plan.isMultiStep { p.steps[0].goal = userGoal(task) }
        } else if let b = frontmost.bundleID, !b.isEmpty, !AXSnapshotter.isBrowser(b), b != Bundle.main.bundleIdentifier,
                  b != "com.liamcarlin.navi", pointsAtScreen(task), first.surface == .browser,
                  first.url == nil || TaskPlanner.isWebSearch(first.url!), !namesOtherWebPlace(task, frontURL: nil) {
            p.steps[0] = TaskPlanner.Step(surface: .app, app: b, goal: plan.isMultiStep ? first.goal : userGoal(task),
                                          needsResult: first.needsResult)
        } else {
            return plan
        }
        if p != plan { p.source = plan.source + "+front" }
        return p
    }
}
