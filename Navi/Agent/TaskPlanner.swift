import Foundation

/// System Two, once per task: Claude splits the user's request into the
/// fewest sequential steps that each happen in ONE place — a browser tab or
/// one macOS app — and gives every browser step a clean search query (or
/// URL). Jev then drives each step on the matching fast driver.
///
/// "find the weather in boston and text it to bella" →
///   1. browser · query "weather in Boston" · needs_result
///   2. app "Messages" · "Send Bella an iMessage saying: {{result}}"
///
/// The plan is prefetched while the user is still typing (`prefetch`), so it
/// normally costs nothing after ⏎. Without an Anthropic key, or if the model
/// answers with something unparseable, `fallback` makes a one-step plan and
/// the older Jev `TaskSurface` classification decides the surface.
enum TaskPlanner {
    static let model = "claude-haiku-4-5"
    static let maxSteps = 6
    /// Where a step's `{{result}}` placeholder receives the previous result.
    static let resultPlaceholder = "{{result}}"

    struct Step: Equatable, Sendable {
        enum Surface: String, Sendable { case browser, app }
        var surface: Surface
        /// App name for `.app` steps ("Messages", "Finder"); nil ⇒ whatever is frontmost.
        var app: String?
        /// Self-contained goal for this step. May contain `{{result}}`.
        var goal: String
        /// Browser steps: an explicit page to start on (from the task or a well-known site).
        var url: String?
        /// Browser steps: the web search to start from when `url` is nil.
        var query: String?
        /// Browser steps: continue on the tab that is open right now.
        var useCurrentTab: Bool = false
        /// A later step needs information gathered in this one.
        var needsResult: Bool = false
    }

    struct Plan: Equatable, Sendable {
        var steps: [Step]
        var source: String      // "claude" | "fallback"
        var isMultiStep: Bool { steps.count > 1 }
    }

    // MARK: Prompt

    static let systemPrompt = """
    You plan computer tasks for Navi, a macOS launcher. Split the user's task into the FEWEST sequential steps where each step happens entirely in ONE place: a browser tab ("browser") or one macOS application ("app"). Most tasks are exactly one step. Add another step only when the task moves to a different app (e.g. look something up online, then send it in Messages).

    Return ONLY a JSON object: {"steps":[{...}]}. EVERY step has:
    - "surface": "browser" | "app"
    - "goal" (required on every step): a self-contained instruction for that step, in the user's words, with everything it needs — for a browser step, what to find or do and, when a later step needs it, what information to gather (e.g. "Find the current weather forecast"). If the step needs information found by an earlier step, write {{result}} exactly where that information goes (e.g. "Send Bella an iMessage saying: {{result}}").
    - "app": for "app" steps only, the application name (e.g. "Messages", "Finder", "Mail", "Notes", "Safari")
    - "needs_result": true on a step whose findings a later step uses (only then)
    - for "browser" steps also: "query": the best web search for the goal (short, no launcher chatter like "open chrome" or "go to the browser"), or "url": an exact page to open when the task names a site or URL, or "use_current_tab": true when the task refers to the page that is open now.

    Rules: never invent details the user did not give; keep the user's names, places and dates verbatim; searching, reading, comparing and browsing all belong to one browser step; a message or email is sent in its app, not in the browser (unless the task names a web app like Gmail); do not add verification or "confirm" steps.
    Navi itself shows the user what the last step found, so a task that only asks to find, look up, get or check something is ONE step ending when the information is visible — never add a step to tell, report, show, say or explain the answer, and never route through an assistant app or site (ChatGPT, Claude, Siri, …) unless the user named it. A goal for the user's own reading ("leaving at 6pm", "for tomorrow") stays in the step's goal verbatim.
    When the user names where to do it ("go to maps", "in chrome", "on Outlook"), the work happens there and only there: one step on that surface (a named website or web app is a "browser" step with its "url"; a named macOS app is an "app" step) — never a second step that repeats or double-checks the same work elsewhere.
    {{result}} always receives the findings of the most recent step marked "needs_result": mark exactly the step that gathers what a later step uses (e.g. the step that reads the event details, not a search for the site).
    The state's "reference" lists the macOS apps Navi knows well ("known_apps": use these exact names for "app" steps when they fit — by default a calendar task goes to "Calendar" and a text to "Messages", unless the user names another app or "user_habits" shows they use another one) and "deep_links": pages of web apps that can be opened directly (e.g. "Google Drive: shared with me", "Google Docs: new document"). When a browser step is about one of them, set that step's "url" to the deep link (append the query for links ending in "=" or "/") instead of inventing a URL or starting from a search. Dictated tasks arrive with speech-recognition slips ("dock" for "Doc", "calculatorcul" for "Calculator"): plan the obvious intent.
    The state's "user_habits" (when present) comes from this user's own screen history: plan the task the way THEY do it, not the generic way. "apps_for_this_kind_of_task" lists the apps and sites that could do this kind of work, most used first: use the user's most used one (an "app" step when it is a mac app — e.g. Outlook for email when they read mail in the Outlook app, never a web mail site they have not used; a "browser" step on their own site when it is a website, with "url" on that host — e.g. their school's Canvas host instead of canvas.instructure.com). A web app with "user_sites" is reached on those hosts: change a deep link's host to the user's. "seen_for_this_task" lists where the task's own words (a person, a document, a course) appeared: when one of them is clearly the thing the task means, go there — its "url" as the step's "url", or its "app" as the step's app (a person the user texts in WhatsApp is messaged in WhatsApp). "most_used_apps"/"most_used_sites" break any remaining tie. An app or site the task names outright always wins over habits; never let habits add steps.
    Never ask for clarification, refuse, or explain: if the task is incomplete, typo-ridden or ambiguous, plan its most likely reading with what was given. Output is only the JSON object.
    """

    /// The reply is prefilled with this so the model can only continue the JSON
    /// object — no prose, no clarification questions, no code fences.
    static let assistantPrefill = "{\"steps\":["

    /// `habits`: `UserHabits.plannerSection` for this task (nil ⇒ no screen memory, or turned off).
    static func stateJSON(task: String, frontmost: FrontmostProbe.Info, habits: [String: Any]? = nil) -> [String: Any] {
        var s: [String: Any] = ["task": task,
                                "frontmost_app": frontmost.appName ?? frontmost.bundleID ?? "unknown"]
        if let b = frontmost.bundleID, AXSnapshotter.isBrowser(b), let u = frontmost.url, u.hasPrefix("http") {
            s["open_browser_tab"] = ["title": frontmost.windowTitle ?? "", "url": u]
        }
        s["reference"] = AppSkills.plannerReference()
        if let habits { s["user_habits"] = habits }
        return s
    }

    // MARK: Parse

    /// The model's continuation of `assistantPrefill`, restored to a full
    /// document. Tolerates a model that repeats the prefill anyway (the reply
    /// then already is a `{"steps": …}` object).
    static func completePrefilled(_ continuation: String) -> String {
        let t = continuation.trimmingCharacters(in: .whitespacesAndNewlines)
        func isPlanObject(_ s: String) -> Bool {
            var body = s
            if body.hasPrefix("```") {
                body = body.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let d = body.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
            return o["steps"] != nil
        }
        return isPlanObject(t) ? t : assistantPrefill + t
    }

    /// Parses the model's reply. Returns nil for anything malformed — the
    /// caller then falls back to a one-step plan. Never trusts free text:
    /// only the fields above are read, everything else is dropped.
    static func parse(_ raw: String) -> Plan? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !s.hasPrefix("{"), let open = s.firstIndex(of: "{"), let close = s.lastIndex(of: "}") {
            s = String(s[open...close])
        }
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawSteps = obj["steps"] as? [[String: Any]], !rawSteps.isEmpty, rawSteps.count <= maxSteps else { return nil }
        var steps: [Step] = []
        for r in rawSteps {
            guard let surface = (r["surface"] as? String).flatMap({ Step.Surface(rawValue: $0.lowercased()) }) else { return nil }
            var goal = (r["goal"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if goal.isEmpty, surface == .browser, let q = (r["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
                goal = "Find: \(q)"     // the model sometimes treats the query as the goal
            }
            guard !goal.isEmpty else { return nil }
            var step = Step(surface: surface, goal: goal)
            if surface == .app {
                step.app = (r["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if step.app?.isEmpty == true { step.app = nil }
            } else {
                if let u = (r["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !u.isEmpty {
                    step.url = u.contains("://") ? u : "https://" + u
                }
                if let q = (r["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty { step.query = q }
                step.useCurrentTab = (r["use_current_tab"] as? Bool) ?? false
            }
            step.needsResult = (r["needs_result"] as? Bool) ?? false
            steps.append(step)
        }
        // A placeholder without a producer is a hallucinated dependency: refuse the plan.
        for (i, step) in steps.enumerated() where step.goal.contains(resultPlaceholder) {
            guard steps[..<i].contains(where: \.needsResult) else { return nil }
        }
        return Plan(steps: steps, source: "claude")
    }

    /// Assistant apps/sites a plan must not route through unless the task names them.
    static let assistantApps = ["chatgpt", "claude", "siri", "gemini", "perplexity", "copilot"]

    /// Removes a trailing "tell the user the answer" step: the model sometimes
    /// appends an app step to ChatGPT/Siri/… to *report* what a browser step
    /// found. Navi shows the result itself, so the plan ends at the finding.
    static func prune(_ plan: Plan, task: String) -> Plan {
        var steps = plan.steps
        let lowerTask = task.lowercased()
        while steps.count > 1, let last = steps.last {
            let app = (last.app ?? "").lowercased()
            let goal = last.goal.lowercased()
            let assistant = assistantApps.contains { app.contains($0) || (last.surface == .browser && goal.contains($0)) }
            let named = assistantApps.contains { lowerTask.contains($0) }
            let reports = last.goal.contains(resultPlaceholder)
                && ["tell", "report", "show", "say", "explain", "give me", "answer"].contains { goal.hasPrefix($0) || goal.contains(" \($0) ") }
                && !["send", "text", "message", "email", "mail", "note", "write", "paste", "type", "add"].contains { goal.contains($0) }
            guard (assistant && !named) || reports else { break }
            steps.removeLast()
        }
        return Plan(steps: steps, source: plan.source)
    }

    /// One-step plan used when Claude is unavailable or unparseable.
    static func fallback(task: String, surface: Step.Surface, app: String? = nil) -> Plan {
        Plan(steps: [Step(surface: surface, app: app, goal: task)], source: "fallback")
    }

    /// Substitutes the previous step's result into a goal.
    static func resolve(_ goal: String, result: String?) -> String {
        goal.replacingOccurrences(of: resultPlaceholder, with: result ?? "(no result from the previous step)")
    }

    /// Start URL for a browser step: explicit URL → current tab → search for
    /// the query (or, lacking one, the goal with launcher chatter stripped).
    /// Library defaults (a deep link, a well-known site — also when the planner copied
    /// one into `url`) move to the host this user really uses (`UserHabits.personalize`);
    /// the open tab never does.
    static func startURL(for step: Step, frontmost: FrontmostProbe.Info) -> String {
        if let u = step.url {
            let typed = UserHabits.host(of: u).map { step.goal.lowercased().contains($0) } ?? false   // a URL the user spelled out stays
            return u == frontmost.url || typed ? u : UserHabits.personalized(u)
        }
        if step.useCurrentTab, let b = frontmost.bundleID, AXSnapshotter.isBrowser(b), let u = frontmost.url, u.hasPrefix("http") { return u }
        if let deep = AppSkills.startURL(for: step.goal) { return UserHabits.personalized(deep) }            // "on youtube: lofi beats" → results page
        if let site = UltrafastBridge.knownSiteURL(in: step.goal) { return UserHabits.personalized(site) }  // "google flights", "youtube", …
        if let q = step.query { return UltrafastBridge.searchURL(for: q) }
        return TaskSurface.startURL(task: step.goal, frontmost: frontmost) ?? UltrafastBridge.searchURL(for: step.goal)
    }

    // MARK: Call

    static func plan(task: String, frontmost: FrontmostProbe.Info, claude: ClaudeClient) async throws -> (Plan?, Int) {
        let (plan, ms, _) = try await planRaw(task: task, frontmost: frontmost, claude: claude)
        return (plan, ms)
    }

    /// Same, plus the model's raw reply (for the debug probe).
    static func planRaw(task: String, frontmost: FrontmostProbe.Info, claude: ClaudeClient) async throws -> (Plan?, Int, String) {
        let habits = UserHabits.current?.plannerSection(task: task)
        let data = try JSONSerialization.data(withJSONObject: stateJSON(task: task, frontmost: frontmost, habits: habits), options: [.sortedKeys])
        let start = Date()
        // Assistant prefill: Haiku continues `{"steps":[` instead of answering in
        // prose ("I need to clarify…"), which used to throw the whole plan away.
        let m = try await claude.create(model: model, system: systemPrompt,
                                        messages: [["role": "user", "content": String(decoding: data, as: UTF8.self)],
                                                   ["role": "assistant", "content": assistantPrefill]],
                                        maxTokens: 700, effort: "low", thinking: nil)
        let reply = completePrefilled(m.text)
        let plan = parse(reply).map { prune($0, task: task) }
        if plan == nil { Log.agent.warning("TaskPlanner: unparseable reply: \(reply.prefix(300), privacy: .public)") }
        if habits != nil { Log.agent.debug("TaskPlanner: planned with user habits") }
        return (plan, Int(Date().timeIntervalSince(start) * 1000), reply)
    }

    // MARK: Prefetch (router → agent, before ⏎)

    private struct Prefetched: Sendable {
        var task: String
        var frontmost: FrontmostProbe.Info
        var plan: Plan?
        var at: Date
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var prefetched: Prefetched?
    nonisolated(unsafe) private static var inflight: Task<Void, Never>?
    static let prefetchTTL: TimeInterval = 120

    @MainActor
    static func prefetch(task: String, claude: ClaudeClient) {
        lock.lock()
        if let p = prefetched, p.task == task, Date().timeIntervalSince(p.at) < prefetchTTL { lock.unlock(); return }
        inflight?.cancel()
        lock.unlock()
        // App/window on the main thread (cheap); the browser-URL Apple Event off it,
        // so typing never waits on Chrome.
        var front = FrontmostProbe.current(includeURL: false)
        let t = Task.detached(priority: .userInitiated) {
            if let b = front.bundleID, AXSnapshotter.isBrowser(b) { front.url = FrontmostProbe.browserURL(bundleID: b) }
            let plan = (try? await self.plan(task: task, frontmost: front, claude: claude))?.0
            guard !Task.isCancelled else { return }
            lock.lock()
            prefetched = Prefetched(task: task, frontmost: front, plan: plan, at: Date())
            lock.unlock()
            Log.agent.debug("TaskPlanner: prefetched \(plan?.steps.count ?? 0) step(s)")
        }
        lock.lock(); inflight = t; lock.unlock()
    }

    /// The prefetched plan for `task` when there is a fresh one (waiting for an
    /// in-flight prefetch if needed); otherwise plans now. `nil` plan ⇒ use `fallback`.
    static func planUsingPrefetch(task: String, claude: ClaudeClient) async -> (FrontmostProbe.Info, Plan?) {
        lock.lock(); let t = inflight; lock.unlock()
        if let t { await t.value }
        lock.lock(); let hit = prefetched; lock.unlock()
        if let hit, hit.task == task, Date().timeIntervalSince(hit.at) < prefetchTTL {
            return (hit.frontmost, hit.plan)
        }
        let front = await MainActor.run { FrontmostProbe.current(includeURL: true) }
        let plan = (try? await self.plan(task: task, frontmost: front, claude: claude))?.0
        return (front, plan)
    }
}
