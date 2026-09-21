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
    /// The run the deadline timer stopped, so its cancellation reads as "too long" rather than "stop".
    private var timedOutRun: UUID?
    /// Approval the current command is waiting for: the agent's or a system action's.
    private(set) var pendingApproval: (description: String, risk: String, respond: (Bool) -> Void)?
    /// The app the last command opened or worked in, for follow-up clauses.
    private(set) var lastApp: (bundleID: String?, name: String)?
    /// What was asked and what came of it, most recent last — the conversation
    /// every later command and question is given (`QueryContext.conversation`).
    private(set) var recent: [String] = []
    private let input = InputController()

    static let maxRecent = 5
    /// A spoken instruction never occupies the queue longer than this: the
    /// agent's own step budget and coaching normally end a run well before, but
    /// a stall here would freeze every instruction behind it.
    static let taskDeadlineMs = 45_000

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
        onEvent?(.finished(item, outcome))
        pump()
    }

    private func remember(_ item: Item, _ outcome: Outcome) {
        if item.command.isControl { return }
        let result: String
        switch outcome {
        case .done(let s): result = s.isEmpty ? "done" : s
        case .failed(let m): result = "failed: \(m)"
        case .cancelled: result = "stopped by the user"
        }
        recent.append("“\(item.command.spoken)” → \(Self.oneLine(result, max: 220))")
        if recent.count > Self.maxRecent { recent.removeFirst(recent.count - Self.maxRecent) }
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
            return await runTask(item, goal: text, surface: .nativeApp, useCurrentTab: false, continues: false)
        case .task(let goal, let surface, let useCurrentTab, _, let continues):
            return await runTask(item, goal: goal, surface: surface, useCurrentTab: useCurrentTab, continues: continues)
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

    private func runTask(_ item: Item, goal: String, surface: TaskSurface.Surface, useCurrentTab: Bool, continues: Bool) async -> Outcome {
        var context = self.context()
        var task = goal
        // A follow-up meant for the app the previous instruction used, when that app isn't in front (background mode).
        if continues, let last = lastApp, let bid = last.bundleID, context.frontmostApp != bid,
           !goal.lowercased().contains(last.name.lowercased()) {
            task = "In \(last.name): \(goal)"
            context.frontmostApp = bid
            context.frontmostAppName = last.name
        }
        let maxSteps = min(max(NaviSettings.shared.agentMaxSteps, 4), 20)
        let options = ComputerAgent.RunOptions(background: !foreground, showOverlay: false, maxSteps: maxSteps,
                                               planWithClaude: false, surface: surface, useCurrentTab: useCurrentTab)
        let handle = services.agent.run(task: task, context: context, options: options)
        currentRun = handle
        var outcome: Outcome = .failed("The task ended without a result")
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.taskDeadlineMs))
            guard !Task.isCancelled, let self else { return }
            Log.voice.warning("voice task exceeded \(Self.taskDeadlineMs) ms — cancelling: \(task.prefix(80), privacy: .public)")
            self.timedOutRun = handle.id
            handle.cancel()
        }
        defer { deadline.cancel() }
        for await ev in handle.events {
            switch ev {
            case .step(_, let d): onEvent?(.progress(item, d))
            case .status(let s): onEvent?(.progress(item, s))
            case .planned: break
            case .screenshot: break
            case .needsApproval(let id, let d, let r):
                pendingApproval = (d, r, { approve in handle.respond(approve ? .approve(id) : .deny(id)) })
                onEvent?(.needsApproval(item, description: d, risk: r))
            case .completed(let s): outcome = .done(s)
            case .failed(let m): outcome = .failed(m)
            case .cancelled: outcome = timedOutRun == handle.id ? .failed("Took too long and was stopped") : .cancelled
            }
        }
        if case .done = outcome, let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != AgentTarget.selfPID {
            lastApp = (app.bundleIdentifier, app.localizedName ?? "the app")
        }
        return outcome
    }

    private func answer(_ item: Item, question: String, wantsMemory: Bool) async -> Outcome {
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
