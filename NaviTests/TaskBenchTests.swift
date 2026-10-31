import Testing
import Foundation
import AppKit
@testable import Navi

/// Task bench, offline: runs Navi's *decision layer* — the voice loop (segmenter + Jev's
/// VoiceDecider), the executor's surface rules, TaskSurface / start URLs, AppSkills app
/// inference, and with a copy of screen memory also TaskGrounding, UserKnowledge contacts and
/// UserRoutines — on every task in `scripts/taskbench/tasks.json`, and checks where each task
/// would start and how it was understood. Nothing drives the screen.
///
///     scripts/taskbench/offline.sh            # keys from the Keychain, a fresh copy of memory.sqlite
///
/// or by hand: `TEST_RUNNER_NAVI_TEST_NETWORK=1 TEST_RUNNER_TYPESAFE_API_KEY=… xcodebuild … test
/// -only-testing:NaviTests/TaskBenchTests`. Env (via TEST_RUNNER_ prefixes):
///   NAVI_BENCH_DB       path to a COPY of memory.sqlite (never the live one; it is copied again here)
///   NAVI_BENCH_OUT      where to write results (JSON; a .md table next to it)
///   NAVI_BENCH_TASKS    another tasks.json
///   NAVI_BENCH_ONLY     comma-separated task ids
///   NAVI_BENCH_PLANNER  1 ⇒ also ask TaskPlanner (Claude) where each task starts (typed ⌘Space path)
///   NAVI_BENCH_STRICT   1 ⇒ the test fails when any task fails (default: it only measures)
///   NAVI_BENCH_REPEAT   N ⇒ run every task N times (Jev's voice decisions are sampled fresh each time)
///
/// The harness only calls public entry points and decodes tasks.json leniently, so other
/// workstreams can add fields and rules without breaking it; a check it cannot make is "skipped".
@MainActor @Suite(.serialized) struct TaskBenchTests {

    // MARK: Task file

    struct Context: Decodable {
        var front_app: String?
        var front_bundle: String?
        var url: String?
        var title: String?
        var recent: [String]?
        var last_was_browser: Bool?
        /// Where the earlier tasks of this context worked (`WorkingSurface`), most recent first.
        var recent_work: [RecentWork]?
    }

    struct RecentWork: Decodable {
        var task: String
        var url: String?
        var bundle: String?
        var app: String?
        var title: String?
        var minutes_ago: Double?
        var outcome: String?
    }

    /// The working-surface store the live app would hold for this context.
    static func seedWork(_ ctx: Context, now: Date = Date()) -> [WorkingSurface] {
        (ctx.recent_work ?? []).map { w in
            let at = now.addingTimeInterval(-(w.minutes_ago ?? 0) * 60)
            if let u = w.url {
                return WorkingSurface(kind: .browserTab, task: w.task, outcome: .completed, summary: w.outcome, bundleID: "com.google.Chrome",
                                      appName: "Google Chrome", url: u, title: w.title, viaRunner: true, at: at)
            }
            return WorkingSurface(kind: .app, task: w.task, outcome: .completed, summary: w.outcome, bundleID: w.bundle, appName: w.app, title: w.title, at: at)
        }
    }

    /// `WorkingSurface.Store.record`: newest first, one per place.
    static func record(_ s: WorkingSurface, into work: inout [WorkingSurface]) {
        work.removeAll { $0.placeKey == s.placeKey }
        work.insert(s, at: 0)
    }

    struct MemoryExpect: Decodable {
        var grounds: Bool?
        var start_hosts: [String]?
        var app: [String?]?
        var routine: String?
    }

    struct Expect: Decodable {
        var commands: Int?
        var max_commands: Int?
        var kind: [String]?
        var surface: [String]?
        var start_hosts: [String]?
        var app: [String?]?
        var current_tab: Bool?
        var continues: Bool?
        var memory: MemoryExpect?
    }

    struct BenchTask: Decodable {
        var id: String
        var family: String
        var utterance: String
        var context: String?
        var expect: Expect
    }

    struct TaskFile: Decodable {
        var contexts: [String: Context]
        var tasks: [BenchTask]
    }

    static let env = ProcessInfo.processInfo.environment

    static func tasksURL(file: String = #filePath) -> URL {
        if let p = env["NAVI_BENCH_TASKS"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/taskbench/tasks.json")
    }

    // MARK: Results

    struct Command {
        var kind: String
        var spoken: String
        var goal: String?
        var surface: String?          // the decider's surface for a task
        var useCurrentTab = false
        var url: String?
        var app: String?
        var verdict: VoiceDecider.Verdict?
        var silenceAtCommitMs = 0
        /// Jev's `work_where`, as the decider applied it.
        var place: WorkingSurface.Choice?
        var cmd: VoiceCommand?
    }

    struct Route {
        var surface: String = "?"     // browser | native_app
        var start: String?            // browser start page
        var app: String?              // native app to open; nil = stays in the app in front
        var currentTab = false
        var planner = false           // a compound goal: the live path asks TaskPlanner
        var grounded: String?
        var routine: String?
        var notes: [String] = []
        var jevMs = 0
        /// Started in an earlier task's place (`RunOptions.continueOn`).
        var continued: String?
    }

    struct Outcome {
        var id: String
        var family: String
        var utterance: String
        var commands: [Command] = []
        var dropped: [String] = []
        var route: Route?
        var plannerStart: String?
        var plannerOK: Bool?
        var checks: [(name: String, ok: Bool?, detail: String)] = []
        var voiceJevCalls = 0
        var voiceJevMs = 0
        var rep = 0
        var passed: Bool { !checks.isEmpty && checks.allSatisfy { $0.ok != false } }
    }

    // MARK: Memory (a copy of memory.sqlite)

    struct Memory {
        var store: MemoryStore
        var knowledge: UserKnowledge
        var habits: UserHabits
        var profile: UserHabits.Profile
        var routines: [Routine]
    }

    static func openMemory() throws -> Memory? {
        guard let src = env["NAVI_BENCH_DB"], !src.isEmpty else { return nil }
        let real = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Navi/memory.sqlite").standardizedFileURL.path
        let given = URL(fileURLWithPath: src).standardizedFileURL
        // Never the live database — only a copy (`sqlite3 memory.sqlite ".backup copy.sqlite"`).
        guard given.path != real else {
            Issue.record("NAVI_BENCH_DB points at the live memory.sqlite; pass a .backup copy")
            return nil
        }
        let dir = TestHost.scratchDirectory.appendingPathComponent("bench-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: given, to: dir.appendingPathComponent("memory.sqlite"))
        let store = try MemoryStore(directory: dir)
        let habits = UserHabits(store: store)
        let routines = UserRoutines(store: store).routines()
        return Memory(store: store, knowledge: UserKnowledge(store: store), habits: habits, profile: habits.profile(), routines: routines)
    }

    // MARK: Voice loop (UtteranceSegmenter + VoiceDecider, as VoiceSession runs it)

    static func voiceContext(_ ctx: Context, clause: UtteranceSegmenter.Clause, index: AppIndex, recent: [String],
                             busy: String?, memory: Memory?, work: [WorkingSurface] = [], previous: String? = nil,
                             amendable: VoiceCommand? = nil, terms: [VoiceVocabulary.Term] = []) -> VoiceDecider.Context {
        var c = VoiceDecider.Context()
        c.frontmostApp = ctx.front_app
        c.frontmostBundle = ctx.front_bundle
        c.windowTitle = ctx.title
        if let b = ctx.front_bundle, AXSnapshotter.isBrowser(b) { c.browserURL = ctx.url }
        c.busyWith = busy
        c.recentDone = Array(recent.suffix(3))
        c.appCandidates = VoiceAppMatcher.candidates(in: clause.head, index: index, running: [])
        c.runningApps = [ctx.front_app].compactMap { $0 }
        if let m = memory { c.userUsuallyUses = UserHabits.surfaceHint(task: clause.head, profile: m.profile) }
        c.headMayContinueAppName = !clause.hasBoundary && VoiceAppMatcher.mayContinueAppName(clause.head, index: index)
        // As `VoiceSession.context(for:)`: where recent tasks worked, what is still running/queued,
        // the user's own words the head may have misheard.
        c.recentWork = Array(work.prefix(WorkingSurface.maxOffered))
        c.previousInstruction = previous
        c.amendable = amendable
        c.soundAlikes = VoiceVocabulary.soundAlikes(in: clause.head, terms: terms)
        c.namesOwnDocument = memoryStartURL(clause.head, memory) != nil
        return c
    }

    /// `VoiceVocabulary.liveTerms` on the memory copy (the live one reads the installed store).
    static func vocabulary(index: AppIndex, memory: Memory?) -> [VoiceVocabulary.Term] {
        VoiceVocabulary.terms(skills: AppSkills.all, appNames: index.entries.prefix(300).map(\.name),
                              things: memory.map { Array($0.knowledge.things().prefix(150)) } ?? [])
    }

    /// The whole utterance is heard at once; decisions on a clause with words after it happen
    /// while the user talks (silence 0), the last clause waits through real silence: each
    /// `.wait` advances the clock by its retry, as the session's scheduler would.
    static func simulateVoice(_ task: BenchTask, ctx: Context, index: AppIndex, jev: JevClient, memory: Memory?,
                              terms: [VoiceVocabulary.Term] = [], into out: inout Outcome) async {
        // Every clause is decided while the ones before it still run (the executor is serial): the
        // working-surface store holds only what happened before the utterance, and the command just
        // committed is the "previous instruction" (queued, so a sentence tail may still join it).
        let work = seedWork(ctx)
        var seg = UtteranceSegmenter()
        seg.update(finalized: task.utterance)
        var recent = ctx.recent ?? []
        var busy: String?
        var guardN = 0
        while let clause = seg.pending(), guardN < 10 {
            guardN += 1
            var silence = clause.following.isEmpty ? NaviSettings.shared.voiceReactionMs : 0
            var settled: VoiceDecider.Verdict?
            var resolved = false
            for _ in 0..<12 {
                let previous = out.commands.last?.spoken
                // The first command starts at once; later ones wait in the queue and can still be amended.
                let amendable = out.commands.count >= 2 ? out.commands.last?.cmd : nil
                let input = VoiceDecider.Input(clause: clause, silenceMs: silence,
                                               context: voiceContext(ctx, clause: clause, index: index, recent: recent, busy: busy, memory: memory,
                                                                     work: work, previous: previous, amendable: amendable, terms: terms))
                var verdict: VoiceDecider.Verdict?
                let decision: VoiceDecider.Decision
                if let instant = VoiceDecider.instantDecision(input) {
                    decision = instant
                } else if let s = settled {
                    verdict = s
                    decision = VoiceDecider.decide(s, input: input)
                } else {
                    do {
                        let r = try await jev.ask(state: JevClient.JSONValue(any: VoiceDecider.stateJSON(input)),
                                                  questions: VoiceDecider.questions(input), cacheable: false)
                        out.voiceJevCalls += 1
                        out.voiceJevMs += r.latencyMs
                        let v = VoiceDecider.verdict(from: r)
                        verdict = v
                        decision = VoiceDecider.decide(v, input: input)
                        if case .wait = decision, let b = v.boundary, b.p(VoiceDecider.Boundary.complete.rawValue) >= VoiceDecider.commitP { settled = v }
                    } catch {
                        decision = VoiceDecider.heuristicDecision(input)
                    }
                }
                switch decision {
                case .commit(let cmd), .replace(let cmd):
                    var c = describe(cmd)
                    c.verdict = verdict ?? settled
                    c.silenceAtCommitMs = silence
                    out.commands.append(c)
                    seg.commit(clause)
                    recent.append("“\(clause.head)” → (running)")
                    busy = cmd.label
                    resolved = true
                case .merge:
                    seg.acceptContinuation(clause)
                    resolved = true
                case .drop(let why):
                    out.dropped.append("“\(clause.head)”: \(why)")
                    seg.drop(clause)
                    resolved = true
                case .giveUp(let why):
                    out.dropped.append("“\(clause.head)”: gave up (\(why))")
                    seg.drop(clause)
                    resolved = true
                case .amend(let cmd):
                    // The tail joins the instruction still waiting in the queue.
                    var c = describe(cmd)
                    c.verdict = out.commands.last?.verdict
                    c.silenceAtCommitMs = silence
                    if !out.commands.isEmpty { out.commands[out.commands.count - 1] = c } else { out.commands.append(c) }
                    out.dropped.append("“\(clause.head)”: joined the queued instruction")
                    seg.commit(clause)
                    resolved = true
                case .wait(_, let retry):
                    silence += max(100, retry ?? VoiceDecider.pauseMs)
                }
                if resolved { break }
            }
            if !resolved {
                out.dropped.append("“\(clause.head)”: still waiting after \(silence) ms of silence")
                seg.drop(clause)
            }
        }
    }

    static func describe(_ cmd: VoiceCommand) -> Command {
        var c = describeKind(cmd)
        c.cmd = cmd
        if case .task(_, _, _, _, let place) = cmd { c.place = place }
        return c
    }

    static func describeKind(_ cmd: VoiceCommand) -> Command {
        switch cmd {
        case .openApp(let e, let t): return Command(kind: "open_app", spoken: t, app: e.bundleID)
        case .openAppNamed(let n, let t): return Command(kind: "open_app", spoken: t, app: "name:" + n)
        case .task(let g, let s, let cur, _, _): return Command(kind: "task", spoken: g, goal: g, surface: s.rawValue, useCurrentTab: cur)
        case .openURL(let u, let t): return Command(kind: "open_url", spoken: t, url: u.absoluteString)
        case .webSearch(let q, let t): return Command(kind: "web_search", spoken: t, url: UltrafastBridge.searchURL(for: q))
        case .answer(let q, _): return Command(kind: "answer", spoken: q)
        case .system(_, let title, let t, _): return Command(kind: "system", spoken: t, goal: title)
        case .control(let c, let t): return Command(kind: "control", spoken: t, goal: c.rawValue)
        case .browser(let b, let t): return Command(kind: "browser", spoken: t, goal: b.title)
        case .window(let w, let t): return Command(kind: "window", spoken: t, goal: w.title)
        }
    }

    // MARK: Route (VoiceCommandExecutor.runTask + ComputerAgent.resolvePlanWithoutPlanner)

    static func isInstalled(_ b: String) -> Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) != nil }

    /// `previousSurface`: where the command before this one (in the same utterance) worked.
    static func route(goal: String, surface hint: TaskSurface.Surface, useCurrentTab cur0: Bool, place: WorkingSurface.Choice?,
                      work: [WorkingSurface], previousSurface: WorkingSurface?,
                      ctx: Context, jev: JevClient, memory: Memory?) async -> Route {
        var r = Route()
        var front = FrontmostProbe.Info(bundleID: ctx.front_bundle, appName: ctx.front_app, windowTitle: ctx.title, url: ctx.url)
        if !(ctx.front_bundle.map(AXSnapshotter.isBrowser) ?? false) { front.url = nil }
        // `VoiceCommandExecutor.runTask`: Jev's place first, the local rules when it had none.
        let compound = VoiceCommandExecutor.isCompound(goal)
        let last = work.first
        let lastWorkedHere = last?.isShown(by: front) ?? (ctx.last_was_browser ?? false)
        let p = VoiceCommandExecutor.placement(goal: goal, surface: hint, useCurrentTab: cur0, place: place, frontmostBundle: ctx.front_bundle,
                                               compound: compound, lastWorkedHere: lastWorkedHere, hereSurface: lastWorkedHere ? last : nil,
                                               previousSurface: previousSurface,
                                               namesPage: { g in VoiceCommandExecutor.namesPage(g) || memoryStartURL(g, memory) != nil })
        var surface = p.surface
        let useCurrentTab = p.useCurrentTab
        r.planner = compound && p.continueOn == nil
        r.currentTab = useCurrentTab
        if r.planner { r.notes.append("compound goal → TaskPlanner on the live path") }

        // `resolvePlanWithoutPlanner`: an earlier task's place is continued before grounding,
        // routines or the screen in front get a say (and grounding is not run at all).
        if let s = p.continueOn {
            r.continued = s.placeDescription
            switch WorkingSurface.start(for: s, front: front) {
            case .page(let url, _) where !url.isEmpty:
                r.surface = "browser"; r.start = url; r.currentTab = url == ctx.url
                r.notes.append("continues where “\(s.task)” worked")
                return r
            case .app(let bundle, let name) where bundle != nil || name != nil:
                r.surface = "native_app"; r.app = bundle != nil && front.bundleID == bundle ? nil : (bundle ?? name)
                r.notes.append("continues in \(name ?? bundle ?? "?")")
                return r
            default: break
            }
        }

        // Screen memory: what the task points at, and the user's own routine for it.
        if let m = memory {
            let t0 = Date()
            if let g = await ground(goal, memory: m, jev: jev) {
                r.grounded = "\(g.thing.name) (\(Int(g.confidence * 100))%) \(g.thing.url ?? g.thing.bundleID ?? "")"
                if !useCurrentTab, !TaskGrounding.isCommunication(goal), TaskGrounding.reopensOwnWork(goal) {
                    let named = AppSkills.mentioned(in: goal)
                    let inNamed = named.map { n in g.thing.bundleID.map(n.bundleIDs.contains) ?? (AppSkills.skill(url: g.thing.url)?.name == n.name) } ?? true
                    if inNamed, let u = g.thing.url {
                        r.surface = "browser"; r.start = u; r.notes.append("started on the grounded page")
                        r.jevMs += Int(Date().timeIntervalSince(t0) * 1000)
                        return r
                    }
                    if inNamed, let b = g.thing.bundleID, isInstalled(b) {
                        r.surface = "native_app"; r.app = b; r.notes.append("opened the grounded app")
                        return r
                    }
                }
            }
            if let match = await routineMatch(goal, memory: m, jev: jev) {
                r.routine = "\(match.routine.template) (\(Int(match.confidence * 100))%)"
                if match.confidence >= 0.6, !useCurrentTab, let start = AgentRun.routineStart(match, task: goal) {
                    switch start {
                    case .page(let u) where surface != .nativeApp:
                        r.surface = "browser"; r.start = u; r.notes.append("started where the routine starts")
                        return r
                    case .app(let b) where surface != .browser:
                        r.surface = "native_app"; r.app = front.bundleID == b ? nil : b; r.notes.append("opened the routine's app")
                        return r
                    default: break
                    }
                }
            }
            r.jevMs += Int(Date().timeIntervalSince(t0) * 1000)
        }

        if surface == .unsure {
            let t0 = Date()
            let cls = await TaskSurface.classify(task: goal, frontmost: front, jev: jev)
            r.jevMs += Int(Date().timeIntervalSince(t0) * 1000)
            surface = cls.surface
            r.notes.append("TaskSurface: \(cls.surface.rawValue) \(Int(cls.confidence * 100))%")
            if surface == .browser {
                r.surface = "browser"
                r.start = startURL(goal, front: front, start: useCurrentTab ? .currentTab : cls.start, memory: memory)
                r.currentTab = r.start == ctx.url && ctx.url != nil
                return r
            }
        }
        if surface == .browser, !useCurrentTab, let m = memory, let app = UserHabits.namedNativeApp(in: goal, profile: m.profile),
           let b = app.bundleIDs.first(where: isInstalled) {
            r.surface = "native_app"; r.app = b; r.notes.append("UserHabits: \(app.name) is the app this user uses")
            return r
        }
        guard surface == .browser else {
            r.surface = "native_app"
            r.app = inferredApp(goal, front: front, memory: memory)
            return r
        }
        if useCurrentTab, !(ctx.front_bundle.map(AXSnapshotter.isBrowser) ?? false) { front.url = nil }
        r.surface = "browser"
        r.start = startURL(goal, front: front, start: useCurrentTab ? .currentTab : nil, memory: memory)
        r.currentTab = r.currentTab || (r.start != nil && r.start == ctx.url)
        return r
    }

    /// `TaskSurface.startURL`, with the screen-memory lookups the live app makes through
    /// `UserKnowledge.liveStartURL` / `UserHabits.personalized` (nil under the test host).
    static func startURL(_ task: String, front: FrontmostProbe.Info, start: TaskSurface.Start?, memory: Memory?) -> String? {
        if TextCandidates.urls(in: task).isEmpty, let mine = memoryStartURL(task, memory) { return mine }
        guard let u = TaskSurface.startURL(task: task, frontmost: front, start: start) else { return nil }
        if let m = memory, u != front.url { return UserHabits.personalize(u, profile: m.profile) }
        return u
    }

    static func memoryStartURL(_ task: String, _ memory: Memory?) -> String? {
        guard let m = memory else { return nil }
        return UserKnowledge.startURL(task: task, matches: m.knowledge.matches(for: task))
    }

    /// `ComputerAgent.inferredApp`, with usage and contacts from the memory copy.
    static func inferredApp(_ task: String, front: FrontmostProbe.Info, memory: Memory?) -> String? {
        guard let hit = AppSkills.inferApp(for: task, frontmostBundleID: front.bundleID, isInstalled: isInstalled, isRunning: { _ in false },
                                           usage: { s in memory.map { UserHabits.usage(of: s, in: $0.profile).app?.screens ?? 0 } ?? 0 }) else { return nil }
        if let f = front.bundleID, hit.skill.bundleIDs.contains(f) { return nil }
        if let m = memory, AppSkills.mentioned(in: task) == nil,
           let chat = UserKnowledge.channelApp(task: task, matches: m.knowledge.matches(for: task)), chat != hit.bundleID,
           let s = AppSkills.skill(bundleID: hit.bundleID),
           UserHabits.kinds.contains(where: { UserContacts.channelKinds.contains($0.kind) && $0.skills.contains(s.name) }),
           isInstalled(chat) {
            return front.bundleID == chat ? nil : chat
        }
        return hit.bundleID
    }

    /// `TaskGrounding.ground`, on the memory copy (the live entry point reads the installed store).
    /// Local (no-network) time spent building screen-memory snapshots, for the report.
    static var localMs = 0

    static func ground(_ task: String, memory m: Memory, jev: JevClient) async -> TaskGrounding.Grounded? {
        let now = Date()
        let snap = m.knowledge.snapshot(now: now)
        let sc = TaskGrounding.scope(of: task, now: now)
        let people = UserKnowledge.matches(task: task, in: snap.things.filter { $0.type == "person" })
        let peopleWords = Set(people.flatMap(\.matched))
        let recipients = TaskGrounding.recipientWords(task: task, people: peopleWords)
        let named = UserKnowledge.matches(task: task, in: snap.things.filter { $0.type != "person" }).contains { !$0.matched.isSubset(of: recipients) }
        localMs += Int(Date().timeIntervalSince(now) * 1000)
        guard TaskGrounding.shouldGround(task: task, scope: sc, words: TaskGrounding.words(of: task, exclude: recipients), named: named) else { return nil }
        let cs = TaskGrounding.candidates(task: task, scope: sc, sessions: snap.sessions, pageTitles: snap.pageTitles,
                                          things: snap.things, people: peopleWords, now: now)
        guard !cs.isEmpty else { return nil }
        let (state, questions) = TaskGrounding.request(task: task, candidates: cs, screen: nil, now: now)
        guard let r = try? await jev.ask(state: JevClient.JSONValue(any: state), questions: questions),
              let (c, p) = TaskGrounding.pick(r["refers_to"], among: cs) else {
            return TaskGrounding.localPick(cs, scope: sc).map { TaskGrounding.Grounded(task: task, thing: $0, confidence: 0.6, source: "local", alternatives: []) }
        }
        return TaskGrounding.Grounded(task: task, thing: c, confidence: p, source: "jev", alternatives: [])
    }

    /// `UserRoutines.match`, on the memory copy.
    static func routineMatch(_ task: String, memory m: Memory, jev: JevClient) async -> UserRoutines.Match? {
        var places = Set<String>()
        if let s = AppSkills.mentioned(in: task) { places.formUnion(s.bundleIDs); if let h = s.hosts.first { places.insert(h) } }
        for s in AppSkills.inferApps(for: task, frontmostBundleID: nil).prefix(2) { places.formUnion(s.bundleIDs) }
        if let chat = UserKnowledge.channelApp(task: task, matches: m.knowledge.matches(for: task)) { places.insert(chat) }
        let cs = UserRoutines.candidates(task: task, routines: m.routines, places: places)
        guard !cs.isEmpty else { return nil }
        let (state, questions) = UserRoutines.request(task: task, candidates: cs)
        guard let r = try? await jev.ask(state: JevClient.JSONValue(any: state), questions: questions) else {
            return UserRoutines.localPick(cs).map { UserRoutines.Match(routine: $0.routine, fills: $0.fills, confidence: 0.6, source: "local") }
        }
        guard let (c, p) = UserRoutines.pick(r["same_task"], among: cs) else { return nil }
        return UserRoutines.Match(routine: c.routine, fills: c.fills, confidence: p, source: "jev")
    }

    // MARK: Checks

    static func hostMatch(_ url: String?, _ hosts: [String]) -> Bool {
        guard let u = url?.lowercased() else { return false }
        return hosts.contains { u.contains($0.lowercased()) }
    }

    static func appMatch(_ app: String?, _ wanted: [String?]) -> Bool {
        wanted.contains { w in
            guard let w else { return app == nil }
            guard let a = app else { return false }
            if a == w { return true }
            if a.hasPrefix("name:") { return AppSkills.skill(appName: String(a.dropFirst(5)))?.bundleIDs.contains(w) ?? false }
            return false
        }
    }

    /// What the live app would record as the command's working surface (the agent's hook for tasks,
    /// the executor's `recordPlace` for opened pages and apps).
    static func surface(after c: Command, route r: Route?, screen: Context) -> WorkingSurface? {
        let now = Date()
        switch c.kind {
        case "open_url", "web_search":
            guard let u = c.url else { return nil }
            return WorkingSurface(kind: .browserTab, task: c.spoken, outcome: .completed, bundleID: "com.google.Chrome", appName: "Google Chrome", url: u, at: now)
        case "open_app":
            guard let a = c.app, !a.hasPrefix("name:") else { return nil }
            return WorkingSurface(kind: .app, task: c.spoken, outcome: .completed, bundleID: a, appName: AppSkills.skill(bundleID: a)?.name ?? a, at: now)
        case "task":
            guard let r else { return nil }
            if r.surface == "browser", let u = r.start {
                return WorkingSurface(kind: .browserTab, task: c.spoken, outcome: .completed, bundleID: "com.google.Chrome", appName: "Google Chrome", url: u, at: now)
            }
            let bundle = r.app ?? screen.front_bundle
            guard let b = bundle, !b.hasPrefix("name:") else { return nil }
            return WorkingSurface(kind: .app, task: c.spoken, outcome: .completed, bundleID: b, appName: AppSkills.skill(bundleID: b)?.name ?? screen.front_app, at: now)
        default:
            return nil
        }
    }

    /// The screen after a command: the page it opened or the app it brought forward.
    static func advance(_ s: inout Context, after c: Command, route r: Route?) {
        var url: String?
        var app: String?
        switch c.kind {
        case "open_url", "web_search": url = c.url
        case "open_app": app = c.app
        case "task":
            if r?.surface == "browser" { url = r?.start } else { app = r?.app }
        default: break
        }
        if let u = url {
            if !(s.front_bundle.map(AXSnapshotter.isBrowser) ?? false) { s.front_bundle = "com.google.Chrome"; s.front_app = "Google Chrome" }
            s.url = u; s.title = ""; s.last_was_browser = true
        } else if let a = app, !a.hasPrefix("name:") {
            s.front_bundle = a; s.front_app = AppSkills.skill(bundleID: a)?.name ?? a; s.url = nil; s.title = ""; s.last_was_browser = false
        }
        s.recent = (s.recent ?? []) + ["“\(c.spoken)” → done"]
    }

    /// Surface, start page and app of the command that does the work — the last one
    /// ("open finder" + "show me my downloads folder": the second), whatever its kind.
    static func place(_ o: Outcome) -> (surface: String?, url: String?, app: String?, currentTab: Bool) {
        guard let c = o.commands.last else { return (nil, nil, nil, false) }
        switch c.kind {
        case "task": return (o.route?.surface, o.route?.start, o.route?.app, o.route?.currentTab ?? false)
        case "open_url", "web_search": return ("browser", c.url, nil, false)
        case "open_app": return ("native_app", nil, c.app, false)
        default: return (nil, nil, nil, false)
        }
    }

    static func check(_ t: BenchTask, _ o: inout Outcome, hasMemory: Bool) {
        let e = t.expect
        let n = o.commands.count
        if let want = e.commands { o.checks.append(("commands", n == want, "\(n) command\(n == 1 ? "" : "s")" + (o.dropped.isEmpty ? "" : "; dropped \(o.dropped.joined(separator: "; "))"))) }
        if let most = e.max_commands { o.checks.append(("commands", n >= 1 && n <= most, "\(n) commands (≤ \(most))")) }
        let first = o.commands.last   // the command doing the work
        if let kinds = e.kind { o.checks.append(("kind", first.map { kinds.contains($0.kind) } ?? false, first?.kind ?? "nothing committed")) }
        let p = place(o)
        if let s = e.surface { o.checks.append(("surface", p.surface.map(s.contains) ?? false, p.surface ?? "—")) }
        func placeCheck(_ name: String, hosts: [String]?, apps: [String?]?) {
            guard hosts != nil || apps != nil else { return }
            let hostOK = hosts.map { p.surface == "browser" && hostMatch(p.url, $0) } ?? false
            let appOK = apps.map { (p.surface == "native_app" || first?.kind == "open_app") && appMatch(p.app, $0) } ?? false
            let detail = p.surface == "browser" ? (p.url ?? "no start page") : (p.app ?? "stays in \(t.context ?? "front app")")
            o.checks.append((name, hostOK || appOK, detail))
        }
        placeCheck("start", hosts: e.start_hosts, apps: e.app)
        if let cur = e.current_tab { o.checks.append(("current_tab", p.currentTab == cur, p.currentTab ? "current tab" : "new start")) }
        if let cont = e.continues {
            // Continuing = Jev put the work in a recent place or the previous command's place, or the
            // run starts in an earlier task's place (`continueOn`, also for "here" when the last task worked there).
            let place: String = {
                switch first?.place {
                case .last(let s)?: return "work_where last (\(s.site ?? s.appName ?? "?"))"
                case .previous?: return "work_where previous"
                case .here?: return "work_where here"
                case .newPlace?: return "work_where new_place"
                case nil: return "no work_where"
                }
            }()
            let continued: Bool = {
                switch first?.place { case .last?, .previous?: return true; default: return o.route?.continued != nil }
            }()
            let detail = place + (o.route?.continued.map { " → continues in \($0)" } ?? "")
            o.checks.append(("continues", first == nil ? false : continued == cont, detail))
        }
        if let m = e.memory {
            guard hasMemory else { o.checks.append(("memory", nil, "skipped: no NAVI_BENCH_DB")); return }
            if let g = m.grounds { o.checks.append(("grounds", (o.route?.grounded != nil) == g, o.route?.grounded ?? "nothing grounded")) }
            placeCheck("memory.start", hosts: m.start_hosts, apps: m.app)
            if m.routine == "none" { o.checks.append(("routine", o.route?.routine.map { _ in false } ?? true, o.route?.routine ?? "no routine")) }
        }
    }

    // MARK: The bench

    @Test(.needsNetwork) func offlineBench() async throws {
        let jev = JevClient()
        try #require(jev.isConfigured, "set TYPESAFE_API_KEY or AI_GATEWAY_API_KEY")
        let file = try JSONDecoder().decode(TaskFile.self, from: Data(contentsOf: Self.tasksURL()))
        let only = Set((Self.env["NAVI_BENCH_ONLY"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        let tasks = file.tasks.filter { only.isEmpty || only.contains($0.id) }
        let memory = try Self.openMemory()
        let index = AppIndex(entries: AppIndex.scanFilesystem())
        let planner = Self.env["NAVI_BENCH_PLANNER"] == "1" ? ClaudeClient() : nil
        let terms = Self.vocabulary(index: index, memory: memory)
        jev.warm()

        // Jev's voice heads are sampled fresh every time (not cached): repeats show how stable each decision is.
        let repeats = max(1, Int(Self.env["NAVI_BENCH_REPEAT"] ?? "") ?? 1)
        var results: [Outcome] = []
        for rep in 0..<repeats {
        for t in tasks {
            let ctx = t.context.flatMap { file.contexts[$0] } ?? Context()
            var o = Outcome(id: t.id, family: t.family, utterance: t.utterance)
            o.rep = rep
            await Self.simulateVoice(t, ctx: ctx, index: index, jev: jev, memory: memory, terms: terms, into: &o)
            // Commands run one after another; each starts on the screen the previous one left
            // ("go to mcdonalds" → that page, then "order me a burger" may continue there).
            var screen = ctx
            // The working-surface store, as the live app holds it: the context's earlier tasks, then
            // each command of this utterance records where it worked before the next one starts.
            var work = Self.seedWork(ctx)
            var previousSurface: WorkingSurface?
            for (i, c) in o.commands.enumerated() {
                var r: Route?
                if c.kind == "task", let g = c.goal {
                    let surface = TaskSurface.Surface(rawValue: c.surface ?? "") ?? .unsure
                    let t0 = Date()
                    r = await Self.route(goal: g, surface: surface, useCurrentTab: c.useCurrentTab, place: c.place,
                                         work: work, previousSurface: previousSurface, ctx: screen, jev: jev, memory: memory)
                    r?.jevMs = Int(Date().timeIntervalSince(t0) * 1000)   // wall time of the whole route decision
                }
                if i == o.commands.count - 1 { o.route = r }
                if let s = Self.surface(after: c, route: r, screen: screen) { Self.record(s, into: &work); previousSurface = s }
                Self.advance(&screen, after: c, route: r)
            }
            if let claude = planner, claude.isConfigured {
                let front = FrontmostProbe.Info(bundleID: ctx.front_bundle, appName: ctx.front_app, windowTitle: ctx.title, url: ctx.url)
                if let (plan, _) = try? await TaskPlanner.plan(task: t.utterance, frontmost: front, claude: claude), let s = plan?.steps.first {
                    o.plannerStart = s.surface == .browser ? TaskPlanner.startURL(for: s, frontmost: front) : "app: \(s.app ?? "front app")"
                }
            }
            Self.check(t, &o, hasMemory: memory != nil)
            if let ps = o.plannerStart, t.expect.start_hosts != nil || t.expect.app != nil {
                // The typed (⌘Space) path: does Claude's plan start where the task belongs? Reported apart from the voice pass.
                if ps.hasPrefix("app: ") {
                    let bundles = AppSkills.skill(appName: String(ps.dropFirst(5)))?.bundleIDs ?? []
                    o.plannerOK = (t.expect.app ?? []).contains { w in w.map(bundles.contains) ?? (ps == "app: front app") }
                } else {
                    o.plannerOK = Self.hostMatch(ps, t.expect.start_hosts ?? [])
                }
            }
            results.append(o)
        }
        }
        let md = Self.report(results, memory: memory != nil)
        print(md)
        if let out = Self.env["NAVI_BENCH_OUT"], !out.isEmpty {
            try? Self.json(results, memory: memory != nil).write(to: URL(fileURLWithPath: out))
            try? Data(md.utf8).write(to: URL(fileURLWithPath: out).deletingPathExtension().appendingPathExtension("md"))
        }
        #expect(results.count == tasks.count * repeats)
        if Self.env["NAVI_BENCH_STRICT"] == "1" {
            for o in results where !o.passed { Issue.record("\(o.id) failed: \(o.checks.filter { $0.ok == false }.map { "\($0.name) (\($0.detail))" }.joined(separator: ", "))") }
        }
    }

    // MARK: Output

    static func report(_ rs: [Outcome], memory: Bool) -> String {
        var L: [String] = []
        let ids = rs.reduce(into: [String]()) { if !$0.contains($1.id) { $0.append($1.id) } }
        let repeats = ids.isEmpty ? 1 : rs.count / ids.count
        L.append("TASKBENCH offline — \(ids.count) tasks × \(repeats) run\(repeats == 1 ? "" : "s"), \(memory ? "with" : "without") a screen-memory copy, \(ISO8601DateFormatter().string(from: Date()))")
        L.append("")
        L.append("| family | runs | pass | rate |")
        L.append("|---|---:|---:|---:|")
        for f in ["errand", "schoolwork", "messaging", "native"] + Array(Set(rs.map(\.family)).subtracting(["errand", "schoolwork", "messaging", "native"])).sorted() {
            let g = rs.filter { $0.family == f }
            guard !g.isEmpty else { continue }
            let p = g.filter(\.passed).count
            L.append("| \(f) | \(g.count) | \(p) | \(100 * p / g.count)% |")
        }
        let p = rs.filter(\.passed).count
        L.append("| **all** | \(rs.count) | \(p) | **\(rs.isEmpty ? 0 : 100 * p / rs.count)%** |")
        let planned = rs.compactMap(\.plannerOK)
        if !planned.isEmpty {
            L.append("")
            L.append("Typed path (TaskPlanner, Claude): \(planned.filter { $0 }.count)/\(planned.count) runs start in the expected place (no screen memory in the planner under the test host).")
        }
        L.append("")
        L.append("| id | passed | heard as | starts | failed checks (first failing run) |")
        L.append("|---|---|---|---|---|")
        for id in ids {
            let runs = rs.filter { $0.id == id }
            let o = runs.first { !$0.passed } ?? runs[0]
            let k = runs.filter(\.passed).count
            let heard = o.commands.map { c in c.kind + (c.surface.map { "/\($0)" } ?? "") + (c.kind == "task" ? "" : " ‘\(c.goal ?? c.app ?? c.url ?? "")’") }.joined(separator: " + ")
            let pl = place(o)
            var starts = String((pl.surface == "browser" ? (pl.url ?? "?") : pl.surface == "native_app" ? (pl.app ?? "front app") : "—").prefix(70))
            if let ps = o.plannerStart { starts += " · planner \(o.plannerOK.map { $0 ? "✓" : "✗" } ?? "") \(ps.prefix(60))" }
            let failed = o.checks.filter { $0.ok == false }.map { "\($0.name): \($0.detail)" }.joined(separator: "; ")
            L.append("| \(o.id) | \(k == runs.count ? "PASS" : "FAIL") \(k)/\(runs.count) | \(heard.isEmpty ? "nothing" : heard) | \(starts) | \(failed.replacingOccurrences(of: "|", with: "/")) |")
        }
        let waits = rs.flatMap { $0.commands.filter { $0.verdict != nil }.map(\.silenceAtCommitMs) }.sorted()
        let jevMs = rs.filter { $0.voiceJevCalls > 0 }.map { $0.voiceJevMs / $0.voiceJevCalls }.sorted()
        if !waits.isEmpty {
            L.append("")
            L.append("Voice decision (simulated): silence the decider waited before committing — median \(waits[waits.count / 2]) ms, " +
                     "p90 \(waits[min(waits.count - 1, Int(Double(waits.count) * 0.9))]) ms; Jev voice call median \(jevMs.isEmpty ? 0 : jevMs[jevMs.count / 2]) ms.")
        }
        let prep = rs.compactMap { $0.route?.jevMs }.sorted()
        if !prep.isEmpty {
            L.append("Route prep (grounding + routine match + surface pick, memory work included): median \(prep[prep.count / 2]) ms, " +
                     "max \(prep.last!) ms; building screen-memory snapshots took \(localMs) ms in all (cold caches).")
        }
        return L.joined(separator: "\n")
    }

    static func json(_ rs: [Outcome], memory: Bool) -> Data {
        let rows: [[String: Any]] = rs.map { o in
            var d: [String: Any] = ["id": o.id, "rep": o.rep, "family": o.family, "utterance": o.utterance, "passed": o.passed,
                                    "voice_jev_calls": o.voiceJevCalls, "voice_jev_ms": o.voiceJevMs, "dropped": o.dropped]
            d["commands"] = o.commands.map { c -> [String: Any] in
                var x: [String: Any] = ["kind": c.kind, "spoken": c.spoken, "silence_at_commit_ms": c.silenceAtCommitMs]
                if let s = c.surface { x["surface"] = s }
                if let u = c.url { x["url"] = u }
                if let a = c.app { x["app"] = a }
                if let v = c.verdict {
                    x["boundary"] = v.boundary?.choice ?? ""; x["kind_head"] = v.kind?.choice ?? ""
                    x["work_where"] = v.workWhere?.choice ?? ""; x["whole_instruction"] = v.whole ?? -1; x["surface_head"] = v.surface?.choice ?? ""
                }
                return x
            }
            if let r = o.route {
                d["route"] = ["surface": r.surface, "start": r.start ?? NSNull(), "app": r.app ?? NSNull(), "current_tab": r.currentTab,
                              "planner": r.planner, "grounded": r.grounded ?? NSNull(), "routine": r.routine ?? NSNull(), "notes": r.notes, "jev_ms": r.jevMs,
                              "continued": r.continued ?? NSNull()] as [String: Any]
            }
            if let ps = o.plannerStart { d["planner_start"] = ps }
            if let ok = o.plannerOK { d["planner_ok"] = ok }
            d["checks"] = o.checks.map { ["name": $0.name, "ok": $0.ok.map { $0 as Any } ?? NSNull(), "detail": $0.detail] as [String: Any] }
            return d
        }
        let doc: [String: Any] = ["generated": ISO8601DateFormatter().string(from: Date()), "memory": memory, "results": rows]
        return (try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// The task file itself stays valid (runs without the network).
    @Test func taskFileIsWellFormed() throws {
        let file = try JSONDecoder().decode(TaskFile.self, from: Data(contentsOf: Self.tasksURL()))
        #expect(file.tasks.count >= 40)
        #expect(Set(file.tasks.map(\.id)).count == file.tasks.count)
        for f in ["errand", "schoolwork", "messaging", "native"] { #expect(file.tasks.filter { $0.family == f }.count >= 10) }
        for t in file.tasks {
            if let c = t.context { #expect(file.contexts[c] != nil, "\(t.id): unknown context \(c)") }
            let e = t.expect
            #expect(e.commands != nil || e.max_commands != nil || e.kind != nil, "\(t.id) checks nothing")
        }
    }
}
