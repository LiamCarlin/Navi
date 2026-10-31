import AppKit
import Foundation

/// Carries out decided voice commands, strictly one at a time and in the order
/// they were spoken — "open notes" must have finished before "make hello the
/// title" runs in Notes. The user keeps talking meanwhile; later instructions
/// queue up behind the current one.
///
/// Each command kind takes the fastest path that exists: app launches go
/// straight to LaunchServices, URLs and web searches to the default browser,
/// system actions to `SystemCommands`, questions to `AnswerService`, and
/// everything that needs the screen to the Jev-first `ComputerAgent` with the
/// surface Jev already decided (no planner round trip, no overlay pill).
@MainActor
final class VoiceCommandExecutor {
    struct Item: Identifiable, Equatable {
        let id: UUID
        let command: VoiceCommand
        let enqueuedAt: Date
        static func == (a: Item, b: Item) -> Bool { a.id == b.id }
    }

    enum Outcome: Equatable, Sendable {
        case done(String)
        case failed(String)
        /// The run stopped on something only the user can do or answer (verdict `.needsUser`).
        case needsYou(String)
        case cancelled
    }

    enum Event {
        case started(Item)
        /// A step or status line from the agent while a task runs.
        case progress(Item, String)
        /// A chunk of a streamed answer.
        case answer(Item, delta: String)
        case needsApproval(Item, description: String, risk: String)
        case approvalResolved(Item)
        case finished(Item, Outcome)
        case queueChanged
    }

    var onEvent: ((Event) -> Void)?

    private let services: NaviServices
    /// Bring apps forward and use the real cursor (voice control's default), or
    /// drive them behind the user's windows like a typed task does.
    var foreground = true

    private(set) var queue: [Item] = []
    private(set) var current: Item?
    private var currentTask: Task<Void, Never>?
    private var currentRun: AgentRunHandle?
    /// The run the idle watchdog stopped, so its cancellation reads as "stalled" rather than "stop".
    private var timedOutRun: UUID?
    private var lastRunEventAt = Date()
    /// Approval the current command is waiting for: the agent's or a system action's.
    private(set) var pendingApproval: (description: String, risk: String, respond: (Bool) -> Void)?
    /// The app the last command opened or worked in, for follow-up clauses.
    private(set) var lastApp: (bundleID: String?, name: String)?
    /// The last command was on the web (opened a URL, searched, ran a browser
    /// task): a follow-up on the page in front continues on that tab.
    private(set) var lastWasBrowser = false
    /// What was asked and what came of it, most recent last — the conversation
    /// every later command and question is given (`QueryContext.conversation`).
    private(set) var recent: [String] = []
    /// The app in front when a quit ran (best guess at what was quit), to forget its working surface.
    private var lastQuitBundle: String?
    private let input = InputController()

    static let maxRecent = 8
    /// A task may run as long as it keeps working — minutes, if that's what it
    /// takes — but one that reports nothing at all for this long has stalled,
    /// and a stall here would freeze every instruction behind it.
    static let taskIdleMs = 120_000
    /// Bounded Claude vision turns per spoken task. Jev decides nearly every step;
    /// when it truly can't, one look is worth having — a loop of them is not,
    /// because the user is right there and can say the next thing.
    static let voiceClaudeFallbacks = 2

    init(services: NaviServices) { self.services = services }

    var isBusy: Bool { current != nil }
    var busyLabel: String? { current?.command.label }

    // MARK: Queue

    func enqueue(_ command: VoiceCommand) {
        let item = Item(id: UUID(), command: command, enqueuedAt: Date())
        queue.append(item)
        onEvent?(.queueChanged)
        pump()
    }

    /// "Stop": abort the current command and forget the rest.
    func stopAll() {
        queue.removeAll()
        stopCurrent()
        onEvent?(.queueChanged)
    }

    /// Abort only what is running now; the queue continues.
    func stopCurrent() {
        if let p = pendingApproval { pendingApproval = nil; p.respond(false) }
        currentRun?.cancel()
        currentTask?.cancel()
    }

    /// The user corrected or restated what Navi is busy with ("no, I mean…"):
    /// abort it and run `command` next, ahead of anything queued.
    func replaceCurrent(with command: VoiceCommand) {
        let item = Item(id: UUID(), command: command, enqueuedAt: Date())
        queue.insert(item, at: 0)
        onEvent?(.queueChanged)
        if current != nil { stopCurrent() } else { pump() }
    }

    /// What was said just before a new clause and is still being carried out or waiting: the last
    /// queued command, else the running one (controls and answers excluded).
    var previousInstruction: String? {
        let cmd = queue.last?.command ?? current?.command
        switch cmd {
        case .some(.control), .some(.answer), .none: return nil
        case .some(let c): return c.spoken
        }
    }

    /// The last queued command, when it was queued less than `amendWindow` ago and hasn't started.
    func amendableCommand(now: Date = Date()) -> VoiceCommand? {
        guard let last = queue.last, now.timeIntervalSince(last.enqueuedAt) < Self.amendWindow else { return nil }
        return last.command
    }

    static let amendWindow: TimeInterval = 8

    /// Replaces the last queued command (still not started) with its amended version.
    @discardableResult
    func amendLastQueued(with command: VoiceCommand) -> Bool {
        guard let last = queue.last else { return false }
        queue[queue.count - 1] = Item(id: last.id, command: command, enqueuedAt: last.enqueuedAt)
        onEvent?(.queueChanged)
        return true
    }

    func respondToApproval(_ approve: Bool) {
        guard let p = pendingApproval else { return }
        pendingApproval = nil
        p.respond(approve)
        if let current { onEvent?(.approvalResolved(current)) }
    }

    /// ⌘Z in whatever app is in front.
    func undo() async {
        await input.press(KeyCombo(keyCode: 6, flags: .maskCommand, keyName: "z"))
    }

    private func pump() {
        guard current == nil, !queue.isEmpty else { return }
        let item = queue.removeFirst()
        current = item
        onEvent?(.queueChanged)
        onEvent?(.started(item))
        currentTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.perform(item)
            self.finish(item, outcome)
        }
    }

    private func finish(_ item: Item, _ outcome: Outcome) {
        guard current?.id == item.id else { return }
        current = nil
        currentRun = nil
        currentTask = nil
        pendingApproval = nil
        remember(item, outcome)
        if case .done = outcome { recordPlace(item.command) }
        onEvent?(.finished(item, outcome))
        pump()
    }

    private func remember(_ item: Item, _ outcome: Outcome) {
        if item.command.isControl { return }
        switch item.command {
        case .openURL, .webSearch, .browser: lastWasBrowser = true
        case .task(_, let surface, _, _, _): lastWasBrowser = surface == .browser
        case .openApp, .openAppNamed, .system: lastWasBrowser = false
        case .window(let w, _): if w.verb == .quit { lastWasBrowser = false }
        case .answer, .control: break
        }
        let result: String
        switch outcome {
        case .done(let s): result = s.isEmpty ? "done" : s
        case .failed(let m): result = "failed: \(m)"
        case .needsYou(let m): result = "waiting for the user: \(m)"
        case .cancelled: result = "stopped by the user"
        }
        recent.append("“\(item.command.spoken)” → \(Self.oneLine(result, max: 220))")
        if recent.count > Self.maxRecent { recent.removeFirst(recent.count - Self.maxRecent) }
    }

    /// Commands that reach a place without the agent ("go to youtube", "open notes") leave it as
    /// the working surface a follow-up continues in; agent runs record theirs themselves.
    private func recordPlace(_ command: VoiceCommand) {
        let now = Date()
        switch command {
        case .openURL(_, let text), .webSearch(_, let text):
            let page: URL
            switch command {
            case .webSearch(let q, _): page = URLAndWeb.googleURL(for: q)
            case .openURL(let u, _): page = u
            default: return
            }
            let browser = NSWorkspace.shared.urlForApplication(toOpen: page)
            let bid = browser.flatMap { Bundle(url: $0)?.bundleIdentifier }
            let name = browser.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            WorkingSurface.Store.shared.record(WorkingSurface(kind: .browserTab, task: text, outcome: .completed, summary: "opened \(page.host ?? "the page")",
                                                              bundleID: bid, appName: name, url: page.absoluteString, at: now))
        case .openApp(let e, let text):
            WorkingSurface.Store.shared.record(WorkingSurface(kind: .app, task: text, outcome: .completed, summary: "opened \(e.name)",
                                                              bundleID: e.bundleID, appName: e.name, at: now))
        case .openAppNamed(_, let text):
            guard let last = lastApp else { return }
            WorkingSurface.Store.shared.record(WorkingSurface(kind: .app, task: text, outcome: .completed, summary: "opened \(last.name)",
                                                              bundleID: last.bundleID, appName: last.name, at: now))
        case .window(let w, _):
            if w.verb == .quit, let b = lastQuitBundle { WorkingSurface.Store.shared.forget(bundleID: b) }
        default:
            break
        }
    }

    static func oneLine(_ s: String, max: Int) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " · ").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= max ? t : String(t.prefix(max - 1)) + "…"
    }

    /// The context every command and question runs with.
    private func context() -> QueryContext {
        var c = ContextProbe.current(recent: [])
        c.conversation = recent
        c.spoken = true
        return c
    }

    // MARK: Perform

    private func perform(_ item: Item) async -> Outcome {
        switch item.command {
        case .openApp(let entry, _):
            return await openApp(entry)
        case .openAppNamed(let name, let text):
            // LaunchServices knows apps the index doesn't (odd folders, aliases); else let the agent figure it out.
            if let opened = try? await AgentCustomTools.openApp(named: name, activate: foreground) {
                let t = AgentTarget.running(bundleIDOrName: opened)
                lastApp = (t?.bundleID ?? opened, t?.appName ?? name.capitalized)
                if foreground, let bid = t?.bundleID { await Self.waitForFrontmost(bundleID: bid) }
                return Task.isCancelled ? .cancelled : .done("Opened \(t?.appName ?? name.capitalized)")
            }
            return await runTask(item, goal: text, surface: .nativeApp, useCurrentTab: false, place: nil)
        case .task(let goal, let surface, let useCurrentTab, _, let place):
            return await runTask(item, goal: goal, surface: surface, useCurrentTab: useCurrentTab, place: place)
        case .openURL(let url, _):
            let ok = NSWorkspace.shared.open(url)
            try? await Task.sleep(for: .milliseconds(300))
            return ok ? .done("Opened \(url.host ?? url.absoluteString)") : .failed("macOS refused to open \(url.absoluteString)")
        case .webSearch(let q, _):
            NSWorkspace.shared.open(URLAndWeb.googleURL(for: q))
            try? await Task.sleep(for: .milliseconds(300))
            return .done("Searched for “\(q)”")
        case .answer(let question, let wantsMemory):
            return await answer(item, question: question, wantsMemory: wantsMemory)
        case .system(let action, let title, _, let confirm):
            if confirm {
                let approved = await askApproval(item, description: title, risk: "This is hard to undo.")
                if Task.isCancelled { return .cancelled }
                guard approved else { return .failed("Declined") }
            }
            switch await SystemCommands.run(action, context: context()) {
            case .error(let m): return .failed(m)
            default: return .done(title)
            }
        case .control(let c, _):
            switch c {
            case .undo: await undo(); return .done("Undone")
            default: return .done(item.command.label)   // stop / confirm / … are handled by the session before queueing
            }
        case .browser(let b, _):
            guard let done = await BrowserControls.perform(b, input: input) else { return .failed("No browser is open") }
            if let app = Self.userFrontApp() {
                lastApp = (app.bundleIdentifier, app.localizedName ?? "the browser")
            }
            return Task.isCancelled ? .cancelled : .done(done)
        case .window(let w, _):
            lastQuitBundle = w.verb == .quit ? Self.userFrontApp()?.bundleIdentifier : nil
            switch await WindowControls.perform(w, fallbackApp: lastApp?.bundleID ?? lastApp?.name, input: input) {
            case .success(let done):
                if w.verb == .quit || w.verb == .hide, let f = Self.userFrontApp() {
                    lastApp = (f.bundleIdentifier, f.localizedName ?? "the app")
                }
                return .done(done)
            case .failure(let e): return .failed(e.errorDescription ?? "\(e)")
            }
        }
    }

    private func openApp(_ entry: AppEntry) async -> Outcome {
        let url = URL(fileURLWithPath: entry.path)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = foreground
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        } catch {
            return .failed("Couldn't open \(entry.name): \(error.localizedDescription)")
        }
        AppIndex.recordLaunch(entry.key)
        lastApp = (entry.bundleID, entry.name)
        if foreground, let bid = entry.bundleID { await Self.waitForFrontmost(bundleID: bid) }
        if Task.isCancelled { return .cancelled }
        return .done("Opened \(entry.name)")
    }

    /// The app in front, when it is one the user works in: never Navi, and never the lock screen or
    /// screen saver — live (2026-10-01) a run that ended while the Mac was locked made the next
    /// spoken command "In loginwindow: click on displays".
    static func userFrontApp() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != AgentTarget.selfPID,
              isUserApp(bundleID: app.bundleIdentifier, regular: app.activationPolicy == .regular) else { return nil }
        return app
    }

    nonisolated static func isUserApp(bundleID: String?, regular: Bool) -> Bool {
        guard regular, let b = bundleID else { return false }
        return !["com.apple.loginwindow", "com.apple.ScreenSaver.Engine", "com.apple.SecurityAgent", "com.apple.UserNotificationCenter"].contains(b)
    }

    /// Without Jev's `work_where` (offline, or unsure): a browser task continues on the tab in
    /// front when it acts on that page ("click …", "scroll …"), or when the last task worked on
    /// that very tab — not merely because the last task was on the web: "order me a burger"
    /// after "open my canvas" once ran on the Canvas tab.
    nonisolated static func continuesOnCurrentTab(goal: String, surface: TaskSurface.Surface, frontmostApp: String?, lastWorkedHere: Bool) -> Bool {
        guard surface != .nativeApp, let bid = frontmostApp, AXSnapshotter.isBrowser(bid) else { return false }
        guard TextCandidates.urls(in: goal).isEmpty, UltrafastBridge.knownSiteURL(in: goal) == nil, AppSkills.startURL(for: goal) == nil else { return false }
        // The page in front is where "click …", "type …", "scroll …" happen, whatever came before.
        return TaskSurface.isPageAction(goal) || (lastWorkedHere && !wantsElsewhere(goal))
    }

    /// An errand or a named place of its own ("order me a burger", "go to McDonald's", "text mom").
    nonisolated static func wantsElsewhere(_ goal: String) -> Bool {
        goal.lowercased().range(of: #"\b(go to|navigate to|take me to|head to|visit|order|buy|purchase|shop|book|reserve|deliver|delivery|tickets?|text|message|email|call)\b"#,
                                options: .regularExpression) != nil
    }

    struct Placement: Equatable {
        var surface: TaskSurface.Surface
        var useCurrentTab: Bool
        var continueOn: WorkingSurface?
    }

    /// Where a spoken task runs. Jev's `work_where` decides when it answered: an earlier task's
    /// place is continued (its tab or app), the screen in front is the open tab, a place of the
    /// task's own never starts on the open tab. Undecided ⇒ the local rules (`voiceSurface`,
    /// `continuesOnCurrentTab`).
    nonisolated static func placement(goal: String, surface: TaskSurface.Surface, useCurrentTab: Bool, place: WorkingSurface.Choice?,
                                      frontmostBundle: String?, compound: Bool, lastWorkedHere: Bool,
                                      hereSurface: WorkingSurface? = nil, previousSurface: WorkingSurface? = nil,
                                      namesPage: (String) -> Bool) -> Placement {
        // "Open Chrome" left Chrome itself as the place: continuing there is its tab in front, not a native step.
        func browserApp(_ s: WorkingSurface) -> Placement? {
            guard s.kind == .app, let b = s.bundleID, AXSnapshotter.isBrowser(b) else { return nil }
            return Placement(surface: .browser, useCurrentTab: frontmostBundle == b, continueOn: nil)
        }
        switch place {
        case .last(let s)?:
            if let p = browserApp(s) { return p }
            return Placement(surface: s.kind == .browserTab ? .browser : .nativeApp, useCurrentTab: false, continueOn: s)
        case .here?:
            // The screen in front is where the last task worked: continuing that task, so screen
            // memory's guess at what the words mean ("my cart" → an old Amazon cart) stays out of it.
            if let s = hereSurface { return Placement(surface: s.kind == .browserTab ? .browser : .nativeApp, useCurrentTab: false, continueOn: s) }
            return Placement(surface: surface, useCurrentTab: useCurrentTab, continueOn: nil)
        case .newPlace?:
            return Placement(surface: surface, useCurrentTab: false, continueOn: nil)
        case .previous?:
            // The instruction before it has finished by now: its place is the latest recent place.
            if let s = previousSurface, let p = browserApp(s) { return p }
            if let s = previousSurface { return Placement(surface: s.kind == .browserTab ? .browser : .nativeApp, useCurrentTab: false, continueOn: s) }
            return placement(goal: goal, surface: surface, useCurrentTab: useCurrentTab, place: nil, frontmostBundle: frontmostBundle,
                             compound: compound, lastWorkedHere: lastWorkedHere, namesPage: namesPage)
        case nil:
            var p = Placement(surface: surface, useCurrentTab: useCurrentTab, continueOn: nil)
            if !compound, !p.useCurrentTab {
                let r = voiceSurface(goal: goal, surface: surface, frontmostBundle: frontmostBundle, namesPage: namesPage)
                p.surface = r.surface
                p.useCurrentTab = r.currentTab
            }
            p.useCurrentTab = p.useCurrentTab
                || continuesOnCurrentTab(goal: goal, surface: p.surface, frontmostApp: frontmostBundle, lastWorkedHere: lastWorkedHere)
            return p
        }
    }

    /// Two or more instructions in one goal — "open chrome, find the newest Patriots score, and
    /// text it to Jack" — when the segmenter kept them together. Run as one step, the whole
    /// sentence used to be typed into Google; these get the planner's steps (and the found
    /// score carried into the text). A goal that dictates text ("text mom open the garage")
    /// is one instruction, whatever verbs the text holds.
    nonisolated static func isCompound(_ goal: String) -> Bool {
        let lower = " " + goal.lowercased() + " "
        let parts = lower.replacingOccurrences(of: #"\s+(and then|and also|after that|then|and)\s+|[,;]"#, with: "|", options: .regularExpression)
            .split(separator: "|")
            .map { $0.split(separator: " ").map { String($0).trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty } }
            .filter { !$0.isEmpty }
        var instructions = 0
        for words in parts {
            let first = words.drop { UtteranceSegmenter.leadingFillers.contains($0) || ["can", "you", "please", "i", "want", "to"].contains($0) }.first
            guard let first, UtteranceSegmenter.imperativeVerbs.contains(first) else { continue }
            instructions += 1
            // Text being dictated swallows everything after it.
            if UtteranceSegmenter.dictationVerbs.contains(first) { break }
        }
        return instructions >= 2
    }

    /// Where a spoken task the decider sent to the browser really runs. One that names a page,
    /// asks for something to be found, or is an errand somewhere else ("go to McDonald's",
    /// "order me a burger", "book a table") stays a web task; anything else ("change it to
    /// cloud", "select local") is about what is on screen: the open tab when a browser is in
    /// front, otherwise the app in front — never a Google search for the sentence.
    nonisolated static func voiceSurface(goal: String, surface: TaskSurface.Surface, frontmostBundle: String?,
                             namesPage: (String) -> Bool) -> (surface: TaskSurface.Surface, currentTab: Bool) {
        guard surface == .browser, !namesPage(goal) else { return (surface, false) }
        let lower = goal.lowercased()
        let wantsWeb = AgentRun.isLookup(goal)
            || lower.range(of: #"\b(search|google|look up|lookup|find|browse|website|web|online|internet|site|page|tab|link|url)\b"#, options: .regularExpression) != nil
            || lower.range(of: #"\b(go to|navigate to|take me to|head to|visit|order|buy|purchase|shop|book|reserve|get me|deliver|delivery|tickets?)\b"#, options: .regularExpression) != nil
        if wantsWeb { return (surface, false) }
        if let b = frontmostBundle, AXSnapshotter.isBrowser(b) { return (.browser, true) }
        return (.nativeApp, false)
    }

    static func namesPage(_ goal: String) -> Bool {
        !TextCandidates.urls(in: goal).isEmpty || UltrafastBridge.knownSiteURL(in: goal) != nil || AppSkills.startURL(for: goal) != nil
            || UserKnowledge.liveStartURL(for: goal) != nil
    }

    /// A freshly launched app takes a moment to come forward and put up a
    /// window; a follow-up like "make the title hello" must not run against
    /// whatever was in front before.
    static func waitForFrontmost(bundleID: String, maxMs: Int = 3000) async {
        let start = Date()
        var pid: pid_t?
        while Date().timeIntervalSince(start) * 1000 < Double(maxMs) {
            if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == bundleID { pid = app.processIdentifier; break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let pid else { return }
        let windowStart = Date()
        while Date().timeIntervalSince(windowStart) * 1000 < 1500 {
            if await AXQueue.run({ AgentTarget.axWindow(pid: pid) != nil }) { break }
            try? await Task.sleep(for: .milliseconds(80))
        }
        try? await Task.sleep(for: .milliseconds(120))
    }

    private func runTask(_ item: Item, goal: String, surface: TaskSurface.Surface, useCurrentTab: Bool, place: WorkingSurface.Choice?) async -> Outcome {
        let context = self.context()
        let task = goal
        let compound = Self.isCompound(goal) && services.claude.isConfigured
        // Did the last task work on what is in front now (the same tab's site / the same app)?
        var front = FrontmostProbe.Info(bundleID: context.frontmostApp, appName: context.frontmostAppName, windowTitle: context.frontmostWindowTitle)
        if let b = front.bundleID, AXSnapshotter.isBrowser(b) { front.url = await Task.detached { FrontmostProbe.browserURL(bundleID: b) }.value }
        let last = WorkingSurface.Store.shared.recent(limit: 1).first
        let lastWorkedHere = last?.isShown(by: front) ?? lastWasBrowser
        let p = Self.placement(goal: goal, surface: surface, useCurrentTab: useCurrentTab, place: place, frontmostBundle: context.frontmostApp,
                               compound: compound, lastWorkedHere: lastWorkedHere, hereSurface: lastWorkedHere ? last : nil,
                               previousSurface: last.flatMap { $0.at >= item.enqueuedAt.addingTimeInterval(-5) ? $0 : nil }, namesPage: Self.namesPage)
        if let s = p.continueOn { Log.voice.info("voice task continues in \(s.placeDescription, privacy: .private)") }
        // "order … from kfc": find KFC's own page first (≤ 1.5 s), so the run starts there rather than on a redirect.
        if p.continueOn == nil, !p.useCurrentTab { await TaskPlanner.resolveErrandLanding(for: goal) }
        // The full step budget from Settings: a spoken task can be as long as a typed one.
        let maxSteps = max(NaviSettings.shared.agentMaxSteps, 4)
        let options = ComputerAgent.RunOptions(background: !foreground, showOverlay: false, maxSteps: maxSteps,
                                               planWithClaude: compound && p.continueOn == nil, surface: p.surface, useCurrentTab: p.useCurrentTab,
                                               maxClaudeFallbacks: Self.voiceClaudeFallbacks, continueOn: p.continueOn)
        let handle = services.agent.run(task: task, context: context, options: options)
        currentRun = handle
        var outcome: Outcome = .failed("The task ended without a result")
        lastRunEventAt = Date()
        let idleWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                let idle = Int(Date().timeIntervalSince(self.lastRunEventAt) * 1000)
                guard idle >= Self.taskIdleMs else { continue }
                Log.voice.warning("voice task silent for \(idle) ms — cancelling: \(task.prefix(80), privacy: .private)")
                self.timedOutRun = handle.id
                handle.cancel()
                return
            }
        }
        defer { idleWatch.cancel() }
        for await ev in handle.events {
            lastRunEventAt = Date()
            switch ev {
            case .step(_, let d): onEvent?(.progress(item, d))
            case .status(let s): onEvent?(.progress(item, s))
            case .planned: break
            case .screenshot: break
            case .needsApproval(let id, let d, let r):
                pendingApproval = (d, r, { approve in handle.respond(approve ? .approve(id) : .deny(id)) })
                onEvent?(.needsApproval(item, description: d, risk: r))
            case .completed(let s): outcome = .done(s)
            case .failed(let m): outcome = handle.verdict == .needsUser ? .needsYou(m) : .failed(m)
            case .cancelled: outcome = timedOutRun == handle.id ? .failed("Stalled with no progress for \(Self.taskIdleMs / 1000) s and was stopped") : .cancelled
            }
        }
        if case .done = outcome, let app = Self.userFrontApp() {
            lastApp = (app.bundleIdentifier, app.localizedName ?? "the app")
        }
        return outcome
    }

    private func answer(_ item: Item, question: String, wantsMemory: Bool) async -> Outcome {
        // Math and conversions need no model: the answer is ready before the island finishes animating.
        if !wantsMemory, let r = VoiceDecider.localMath(question) {
            let line = r.kind == .arithmetic ? "\(r.expression.trimmingCharacters(in: CharacterSet(charactersIn: "=? "))) = \(r.answer)" : r.answer
            onEvent?(.answer(item, delta: line))
            return .done(line)
        }
        var hits: [MemoryHit] = []
        if wantsMemory { hits = await services.memory.search(query: question, limit: 6) }
        let stream = services.answers.streamAnswer(query: question, context: context(), memory: hits)
        var text = ""
        do {
            for try await chunk in stream {
                if Task.isCancelled { return .cancelled }
                text += chunk
                onEvent?(.answer(item, delta: chunk))
            }
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
        return .done(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func askApproval(_ item: Item, description: String, risk: String) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var resumed = false
            pendingApproval = (description, risk, { approve in
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: approve)
            })
            onEvent?(.needsApproval(item, description: description, risk: risk))
        }
    }
}
