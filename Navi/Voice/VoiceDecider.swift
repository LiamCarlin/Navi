import Foundation

/// The System One decision behind live voice control: *is what the user just
/// said a complete instruction, and what kind?*
///
/// One Jev call per pending clause (re-asked as words arrive, ~150–250 ms warm)
/// with a speculative fan-out, exactly like the router: a `boundary` head
/// decides whether the clause is complete now, and several other heads are
/// answered in the same call so that acting needs no second round trip —
/// what kind of instruction it is, which installed app it names, which
/// surface (browser / native app) a task belongs on, whether it is risky, and
/// whether it continues the previous instruction. Only the heads the chosen
/// `kind` needs are read; the rest are discarded.
///
/// `decide` is pure and unit-tested; `VoiceSession` owns timing and I/O.
enum VoiceDecider {
    // MARK: Vocabulary

    enum Boundary: String, CaseIterable {
        /// The head is a complete instruction Navi can carry out right now.
        case complete
        /// The words after the head (or still to come) belong to the same instruction.
        case continues
        /// The head is not an instruction for Navi.
        case notACommand = "not_a_command"

        var criteria: String {
            switch self {
            case .complete:
                return "HEAD is a complete instruction or question Navi can act on right now, exactly as said — a follow-up that leans on recent_instructions_already_carried_out for context ('how many people were on board' after a question about Apollo 11) still counts. If FOLLOWING has words, they begin a separate instruction or are unrelated chatter — nothing in FOLLOWING is needed for HEAD. A CONNECTOR of '?', '.' or '!' means the recognizer heard the sentence end there, which almost always makes HEAD complete."
            case .continues:
                return "HEAD is not finished: FOLLOWING (or words still to come) belongs to the same instruction, e.g. an object, a search query, the text to type, a recipient, or a place to do it. Also pick this when HEAD ends mid-phrase ('open', 'open up the', 'search for', 'and make the title', 'what year did')."
            case .notACommand:
                return "HEAD is not something Navi should act on: thinking aloud, filler, a reaction ('oh nice', 'hmm okay'), talking to someone else, or a fragment that will never become an instruction."
            }
        }
    }

    enum Kind: String, CaseIterable {
        case openApp = "open_app"
        case doInApp = "do_in_app"
        case browse = "browse_or_search"
        case answer
        case system = "system_setting"
        case control = "control_navi"
        case none

        var criteria: String {
            switch self {
            case .openApp: return "Only launch or switch to an application ('open notes', 'go to chrome', 'switch to slack') — nothing else is asked for in HEAD."
            case .doInApp: return "Do something inside an app or on the screen: type, write, click, create, send, select, scroll, fill in, rename, move, close a window, use a menu, change a setting in an app — including 'open X and…' phrasings where the head itself asks for an action beyond opening."
            case .browse: return "Web only: open a website or URL, search the web / Google something, look something up online, do something on a web page."
            case .answer: return "A question or request Navi should answer in words (facts, explanations, math, what was I doing earlier, summarize, translate, write a draft to show me) — no app needs to be touched."
            case .system: return "A macOS system action: sleep, lock, dark mode, volume, mute, wifi, bluetooth, empty trash, screenshot, quit an app, hide windows, do not disturb."
            case .control: return "Talking to Navi itself: stop / cancel / wait / never mind / undo that / yes / no / go ahead / stop listening / pause / start over / repeat that / what did you do."
            case .none: return "None of these fits."
            }
        }
    }

    enum Control: String, CaseIterable {
        case stop, undo, confirm, deny, cancelAll = "cancel_everything", stopListening = "stop_listening", pause, resume, none

        var criteria: String {
            switch self {
            case .stop: return "Stop / cancel / wait / hold on / never mind — abort what Navi is doing right now."
            case .undo: return "Undo the last thing Navi did (undo, take that back, revert)."
            case .confirm: return "Yes / go ahead / do it / confirm / sure — approve the action Navi is asking about."
            case .deny: return "No / don't / cancel that — refuse the action Navi is asking about."
            case .cancelAll: return "Forget everything, start over, clear the queue."
            case .stopListening: return "Stop listening / go to sleep / goodbye / close voice control / that's all."
            case .pause: return "Pause listening for a moment / hold on, I'm talking to someone."
            case .resume: return "Resume / keep listening / I'm back."
            case .none: return "Not a control instruction."
            }
        }
    }

    // MARK: Input

    struct Context: Sendable, Equatable {
        var frontmostApp: String?
        var frontmostBundle: String?
        var windowTitle: String?
        var browserURL: String?
        var busyWith: String?
        var queued: Int = 0
        var awaitingApproval: String?
        var lastResult: String?
        /// Recent instructions with what came of them, most recent last.
        var recentDone: [String] = []
        var appCandidates: [VoiceAppMatcher.Candidate] = []
        var isPaused = false
    }

    struct Input: Sendable {
        var clause: UtteranceSegmenter.Clause
        var silenceMs: Int
        var context: Context
    }

    // MARK: State

    static func stateJSON(_ input: Input) -> [String: Any] {
        let c = input.clause
        let ctx = input.context
        var transcript: [String: Any] = [
            "HEAD": c.head,
            "CONNECTOR": c.connector,
            "FOLLOWING": c.following,
            "silence_ms_since_last_word": input.silenceMs,
            "recent_instructions_already_carried_out": ctx.recentDone,
        ]
        if c.following.isEmpty { transcript["note"] = "FOLLOWING is empty: the user may still be speaking." }
        var screen: [String: Any] = ["frontmost_app": ctx.frontmostApp ?? "unknown"]
        if let t = ctx.windowTitle, !t.isEmpty { screen["window_title"] = t }
        if let u = ctx.browserURL, !u.isEmpty { screen["browser_url"] = u }
        var navi: [String: Any] = ["queued_instructions": ctx.queued, "listening_paused": ctx.isPaused]
        if let b = ctx.busyWith { navi["busy_with"] = b }
        if let a = ctx.awaitingApproval { navi["awaiting_user_approval_for"] = a }
        if let r = ctx.lastResult { navi["last_result"] = r }
        var state: [String: Any] = [
            "mode": "Live voice control. The user talks continuously; Navi carries out each instruction the moment it is complete, without waiting for the user to finish talking.",
            "transcript": transcript,
            "screen": screen,
            "navi": navi,
        ]
        if !ctx.appCandidates.isEmpty {
            state["installed_apps_possibly_named_in_HEAD"] = ctx.appCandidates.map { ["id": $0.id, "app": $0.entry.name] }
        }
        return state
    }

    // MARK: Questions

    static func questions(_ input: Input) -> [String: JevClient.Question] {
        let ctx = input.context
        var q: [String: JevClient.Question] = [:]
        q["boundary"] = .choice(
            instructions: "Look at HEAD, with CONNECTOR, FOLLOWING and recent_instructions_already_carried_out as context. Is HEAD a complete instruction or question Navi should act on now? Instructions are usually short and imperative ('open notes', 'make hello the title', 'search for cats', 'what's the weather'). Do not wait for politeness or a full sentence.",
            criteria: Dictionary(uniqueKeysWithValues: Boundary.allCases.map { ($0.rawValue, $0.criteria) }))
        q["kind"] = .choice(
            instructions: "If HEAD is an instruction, what kind is it?",
            criteria: Dictionary(uniqueKeysWithValues: Kind.allCases.map { ($0.rawValue, $0.criteria) }))
        q["control"] = .choice(
            instructions: "If HEAD is addressed to Navi itself (kind = control_navi), which control is it? Otherwise 'none'."
                + (ctx.awaitingApproval != nil ? " Navi is currently asking the user to approve an action, so a bare yes/no answers that." : ""),
            criteria: Dictionary(uniqueKeysWithValues: Control.allCases.map { ($0.rawValue, $0.criteria) }))
        if !ctx.appCandidates.isEmpty {
            var crit: [String: String] = ["none": "HEAD does not ask to open or switch to any of these apps."]
            for c in ctx.appCandidates { crit[c.id] = "The user means the app “\(c.entry.name)” (matched the words “\(c.phrase)”)." }
            q["app_target"] = .choice(instructions: "Which installed app does HEAD ask to open or switch to?", criteria: crit)
        }
        q["surface"] = .choice(
            instructions: "If HEAD is a task Navi must carry out on the computer, where does it happen?",
            criteria: TaskSurface.criteria)
        if let u = ctx.browserURL, !u.isEmpty {
            q["start_from"] = .choice(
                instructions: "If the task happens in the browser: continue on the tab that is open now, or start from a fresh web search?",
                criteria: [
                    TaskSurface.Start.currentTab.rawValue: "HEAD is about, or continues work on, the page currently open: “\(ctx.windowTitle ?? "")” (\(u))",
                    TaskSurface.Start.webSearch.rawValue: "HEAD needs something elsewhere on the web; the open page is unrelated",
                ])
        }
        if ctx.busyWith != nil {
            q["replaces_current"] = .noul(instructions: "HEAD corrects, restates or replaces the instruction Navi is busy with right now (navi.busy_with) — 'no, I mean…', 'actually…', 'not that one…', the same request in other words — rather than a new instruction to carry out after it finishes")
        }
        q["is_risky"] = .noul(instructions: "Carrying out HEAD would send a message or email, post something, spend money, delete or overwrite data, or otherwise be hard to undo")
        q["continues_previous"] = .noul(instructions: "HEAD should be carried out in the same app or on the same thing as the most recent entry of recent_instructions_already_carried_out (e.g. 'make the title hello' right after 'open notes'), rather than somewhere new")
        q["wants_memory"] = .noul(instructions: "Answering HEAD well requires knowing what the user was doing, reading or writing earlier on this computer")
        return q
    }

    // MARK: Verdict

    struct Head: Equatable, Sendable {
        var choice: String
        var probabilities: [String: Double]
        var confidence: Double
        func p(_ key: String) -> Double { probabilities[key] ?? (choice == key ? confidence : 0) }
    }

    struct Verdict: Equatable, Sendable {
        var boundary: Head?
        var kind: Head?
        var control: Head?
        var appTarget: Head?
        var surface: Head?
        var startFrom: Head?
        var isRisky: Double = 0
        var continuesPrevious: Double = 0
        var wantsMemory: Double = 0
        var replacesCurrent: Double = 0
        var latencyMs = 0
        var source: RouteDecision.Source = .jev
    }

    static func verdict(from r: JevClient.Response) -> Verdict {
        func head(_ name: String) -> Head? {
            guard let a = r[name], let c = a.choice else { return nil }
            return Head(choice: c, probabilities: a.probabilities ?? [:], confidence: a.confidence)
        }
        var v = Verdict()
        v.boundary = head("boundary")
        v.kind = head("kind")
        v.control = head("control")
        v.appTarget = head("app_target")
        v.surface = head("surface")
        v.startFrom = head("start_from")
        v.isRisky = r["is_risky"]?.noul ?? 0
        v.continuesPrevious = r["continues_previous"]?.noul ?? 0
        v.wantsMemory = r["wants_memory"]?.noul ?? 0
        v.replacesCurrent = r["replaces_current"]?.noul ?? 0
        v.latencyMs = r.latencyMs
        return v
    }

    // MARK: Decision

    enum Decision: Equatable, Sendable {
        /// Not enough said yet; ask again when more words arrive or after `retryAfterMs`.
        case wait(reason: String, retryAfterMs: Int?)
        /// The head is done: act on it, move the cursor past the connector.
        case commit(VoiceCommand)
        /// The head corrects what Navi is busy with: stop that, run this next.
        case replace(VoiceCommand)
        /// The boundary after the head was false: merge and keep listening.
        case merge
        /// The head is noise: skip it.
        case drop(reason: String)
    }

    // Thresholds. Complete below `commitP` still commits once the user has
    // clearly paused; noise is dropped only once it is clearly noise. A
    // sentence the recognizer closed with '?', '.' or '!' needs only a short
    // pause; after a long silence anything that isn't noise is acted on —
    // leaving an instruction hanging is worse than acting on a stray one, which
    // "stop" or "never mind" fixes.
    static let commitP = 0.5
    static let commitOnPauseP = 0.3
    static let pauseMs = 1600
    static let sentencePauseMs = 700
    static let longPauseMs = 3200
    static let commitOnLongPauseP = 0.12
    static let dropP = 0.6
    static let dropAfterMs = 1500
    /// P(replaces_current) above which a clause aborts the running command.
    static let replaceP = 0.6
    /// Heads made only of these are never an instruction ("you", "to the", "and it").
    static let fragmentWords: Set<String> = ["you", "to", "the", "it", "that", "this", "so", "and", "then", "a", "an", "of", "in", "on",
                                             "at", "for", "with", "me", "my", "i", "is", "was", "are", "these", "those", "just", "like",
                                             "um", "uh", "okay", "ok", "yeah", "well", "oh", "hmm", "he", "she", "they", "we", "him", "her", "them"]
    static let appTargetP = 0.4
    /// A bare connector with no words after it yet ("open notes and") is not
    /// evidence either way; wait for a word or a pause before committing.
    static let bareConnectorWaitMs = 450
    /// A head with no boundary after it may still be mid-phrase: the recognizer
    /// delivers words in ~1 s windows, so "compute 12" can be the front of
    /// "compute 12 times 34". Without a boundary Navi waits for this much
    /// acoustic silence (the session flushes the recognizer at ~350 ms of
    /// silence, so the tail has arrived by then) — unless Jev is very sure.
    /// Connectors that can only start a new instruction.
    static let strongConnectors: Set<String> = ["and then", "then", "after that", "and now", "next", "afterwards"]
    static let settleMs = 650
    static let settleFastMs = 400
    static let settleFastConfidence = 0.8

    static func decide(_ v: Verdict, input: Input) -> Decision {
        let c = input.clause
        guard let b = v.boundary, Boundary(rawValue: b.choice) != nil else {
            return heuristicDecision(input)
        }
        let pComplete = b.p(Boundary.complete.rawValue)
        let pContinues = b.p(Boundary.continues.rawValue)
        let pNoise = b.p(Boundary.notACommand.rawValue)
        let silence = input.silenceMs
        // "and" alone may still be joining the object ("cats and dogs"); "and then" / "then" / "after that" never do.
        let bareConnector = c.hasBoundary && c.following.isEmpty && !c.connector.isEmpty && !Self.isSentenceMark(c.connector)
            && !Self.strongConnectors.contains(c.connector)

        // Noise: drop once it's stable noise (a pause, or words already following it).
        if pNoise >= dropP, pNoise >= pComplete {
            if !c.following.isEmpty || silence >= dropAfterMs { return .drop(reason: "not an instruction (\(pct(pNoise)))") }
            return .wait(reason: "sounds like chatter, waiting", retryAfterMs: dropAfterMs - silence)
        }
        // Complete.
        if pComplete >= commitP, pComplete >= pContinues {
            if bareConnector, silence < bareConnectorWaitMs {
                return .wait(reason: "connector with nothing after it yet", retryAfterMs: bareConnectorWaitMs - silence)
            }
            if !c.hasBoundary {
                // Nothing marks the end yet: let the pause prove it (or a very sure Jev after a shorter one).
                let need = b.confidence >= settleFastConfidence ? settleFastMs : settleMs
                if silence < need { return .wait(reason: "…", retryAfterMs: need - silence) }
            }
            return act(v, input: input)
        }
        // Continues: merge a false boundary, otherwise keep listening — unless the user has stopped talking.
        if pContinues >= pComplete || pComplete < commitP {
            if !c.following.isEmpty { return .merge }
            let sentenceEnded = Self.isSentenceMark(c.connector) && c.connector != ","
            if sentenceEnded, silence >= sentencePauseMs { return act(v, input: input) }
            // A long pause acts on anything that isn't noise — but not on what is more likely noise.
            if pNoise > pComplete, pNoise >= 0.4, silence >= dropAfterMs { return .drop(reason: "more likely chatter (\(pct(pNoise)))") }
            if silence >= longPauseMs, pComplete >= commitOnLongPauseP { return act(v, input: input) }
            if silence >= pauseMs, pComplete >= commitOnPauseP { return act(v, input: input) }
            let retry: Int?
            if sentenceEnded { retry = max(100, sentencePauseMs - silence) }
            else if pComplete >= commitOnPauseP { retry = max(100, pauseMs - silence) }
            else if pComplete >= commitOnLongPauseP { retry = max(100, longPauseMs - silence) }
            else { retry = nil }
            return .wait(reason: "waiting for the rest (\(pct(pContinues)) continues)", retryAfterMs: retry)
        }
        return .wait(reason: "undecided", retryAfterMs: pauseMs)
    }

    /// No Jev (no key, timeout): connectors and pauses decide, everything is a task.
    static func heuristicDecision(_ input: Input) -> Decision {
        let c = input.clause
        let words = c.head.split(separator: " ").count
        if c.hasBoundary, !c.following.isEmpty, words >= 2 { return .commit(heuristicCommand(input)) }
        if input.silenceMs >= pauseMs, words >= 1 { return .commit(heuristicCommand(input)) }
        return .wait(reason: "offline: waiting for a pause", retryAfterMs: max(100, pauseMs - input.silenceMs))
    }

    /// Commit — unless the head is a fragment that could never be an instruction
    /// (each one used to cost a 2 s agent run that did nothing), or it corrects
    /// what Navi is busy with (then the running command is replaced, not queued
    /// behind). Control words ("stop", "yes") are never replacements.
    static func act(_ v: Verdict, input: Input) -> Decision {
        let cmd = command(v, input: input)
        if case .task = cmd, isFragment(input.clause.head, v: v, input: input) {
            return .drop(reason: "fragment, nothing to do")
        }
        if !cmd.isControl, input.context.busyWith != nil, v.replacesCurrent >= replaceP { return .replace(cmd) }
        return .commit(cmd)
    }

    /// "you", "to the", "and it": all filler/function words, or one or two
    /// words Jev could not classify with no app or question in them.
    static func isFragment(_ head: String, v: Verdict, input: Input) -> Bool {
        let words = head.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
        guard !words.isEmpty else { return true }
        if words.allSatisfy({ fragmentWords.contains($0) }) { return true }
        let unclassified = (v.kind?.choice).map { $0 == Kind.none.rawValue || Kind(rawValue: $0) == nil } ?? true
        return words.count <= 2 && unclassified && appChoice(v, input: input) == nil && !head.contains("?")
    }

    // MARK: Kind → command

    static func command(_ v: Verdict, input: Input) -> VoiceCommand {
        let c = input.clause
        let text = c.head
        let kind = v.kind.flatMap { Kind(rawValue: $0.choice) } ?? .doInApp
        let risky = v.isRisky >= 0.5
        let continues = v.continuesPrevious >= 0.5
        switch kind {
        case .control:
            let ctl = v.control.flatMap { Control(rawValue: $0.choice) } ?? .none
            if ctl != .none { return .control(ctl, text: text) }
            return .control(Self.heuristicControl(text) ?? .stop, text: text)
        case .openApp:
            if let app = appChoice(v, input: input) { return .openApp(app.entry, text: text) }
            // "Go to YouTube" reads as open_app to Jev; with no such app it is a site.
            if let url = Self.knownSiteToOpen(text) { return .openURL(url, text: text) }
            if let name = VoiceAppMatcher.nameGuess(in: text) { return .openAppNamed(name, text: text) }
            return .task(goal: text, surface: .nativeApp, useCurrentTab: false, isRisky: risky, continuesPrevious: continues)
        case .answer:
            return .answer(question: text, wantsMemory: v.wantsMemory >= 0.5)
        case .system:
            if let cmd = SystemCommands.matches(text).first {
                if isConfirmRequired(cmd.action) {
                    // Restart / shut down / log out: run the real action, but only after a spoken "yes".
                    if let real = SystemCommands.matches(text + " now").first, !isConfirmRequired(real.action) {
                        return .system(real.action, title: real.title, text: text, confirm: true)
                    }
                } else {
                    return .system(cmd.action, title: cmd.title, text: text, confirm: false)
                }
            }
            return .task(goal: text, surface: .nativeApp, useCurrentTab: false, isRisky: risky, continuesPrevious: continues)
        case .browse:
            if let url = URLAndWeb.detect(text) { return .openURL(url, text: text) }
            if let url = Self.knownSiteToOpen(text) { return .openURL(url, text: text) }
            if let q = Self.plainSearchQuery(text) { return .webSearch(q, text: text) }
            let tab = v.startFrom?.choice == TaskSurface.Start.currentTab.rawValue
            return .task(goal: text, surface: .browser, useCurrentTab: tab, isRisky: risky, continuesPrevious: continues)
        case .doInApp, .none:
            // A bare app name with an opening verb still counts as open_app even if `kind` wobbled.
            if kind == .none, let app = appChoice(v, input: input), Self.looksLikeOpen(text) { return .openApp(app.entry, text: text) }
            let surface = v.surface.flatMap { TaskSurface.Surface(rawValue: $0.choice) } ?? .unsure
            let tab = surface == .browser && v.startFrom?.choice == TaskSurface.Start.currentTab.rawValue
            return .task(goal: text, surface: surface, useCurrentTab: tab, isRisky: risky, continuesPrevious: continues)
        }
    }

    static func heuristicCommand(_ input: Input) -> VoiceCommand {
        let text = input.clause.head
        if let ctl = heuristicControl(text) { return .control(ctl, text: text) }
        if looksLikeOpen(text), let app = input.context.appCandidates.first, app.score >= 0.9 { return .openApp(app.entry, text: text) }
        if let url = URLAndWeb.detect(text) { return .openURL(url, text: text) }
        if let url = knownSiteToOpen(text) { return .openURL(url, text: text) }
        if let q = plainSearchQuery(text) { return .webSearch(q, text: text) }
        return .task(goal: text, surface: .unsure, useCurrentTab: false, isRisky: false, continuesPrevious: false)
    }

    /// "Go to YouTube", "open reddit and open it": a well-known site with nothing
    /// to do once there opens like a URL does — straight away, in the browser,
    /// and it stays open. Through the agent, the runner's tab used to be closed
    /// again when the run ended with nothing done on it.
    static func knownSiteToOpen(_ text: String) -> URL? {
        guard UltrafastBridge.isNavigationOnly(text), let site = UltrafastBridge.knownSiteURL(in: text) else { return nil }
        return URL(string: site)
    }

    static func appChoice(_ v: Verdict, input: Input) -> VoiceAppMatcher.Candidate? {
        let cands = input.context.appCandidates
        guard !cands.isEmpty else { return nil }
        if let h = v.appTarget, h.choice != "none", h.confidence >= appTargetP, let c = cands.first(where: { $0.id == h.choice }) {
            return c
        }
        // Jev didn't name one: a single strong local match wins for an obvious "open X".
        if v.appTarget == nil, cands.count == 1, cands[0].score >= 0.95 { return cands[0] }
        return nil
    }

    // MARK: Small parsers

    static let controlPhrases: [(String, Control)] = [
        ("stop listening", .stopListening), ("go to sleep", .stopListening), ("goodbye", .stopListening), ("that's all", .stopListening),
        ("never mind", .stop), ("nevermind", .stop), ("cancel everything", .cancelAll), ("start over", .cancelAll),
        ("stop", .stop), ("cancel", .stop), ("wait", .stop), ("hold on", .pause), ("pause", .pause), ("resume", .resume),
        ("undo", .undo), ("take that back", .undo), ("go ahead", .confirm), ("yes", .confirm), ("do it", .confirm), ("no", .deny), ("don't", .deny),
    ]

    static func heuristicControl(_ text: String) -> Control? {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.split(separator: " ").count <= 4 else { return nil }
        for (p, ctl) in controlPhrases where t == p || t.hasPrefix(p + " ") || t.hasSuffix(" " + p) { return ctl }
        return nil
    }

    static func looksLikeOpen(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["open", "launch", "start", "switch to", "go to", "bring up", "show me"].contains { t.hasPrefix($0 + " ") } || t.split(separator: " ").count <= 2
    }

    /// "search for cats" / "google cats" / "look up cats online" → "cats". nil when the
    /// clause asks for more than a search (click, compare, find the cheapest…).
    static func plainSearchQuery(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        let prefixes = ["search the web for ", "search google for ", "google for ", "search for ", "google ", "search ", "look up ", "lookup ", "web search "]
        guard let p = prefixes.first(where: { lower.hasPrefix($0) }) else { return nil }
        var q = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
        for suffix in [" online", " on google", " on the web", " in chrome", " in safari", " in the browser"] where q.lowercased().hasSuffix(suffix) {
            q = String(q.dropLast(suffix.count))
        }
        q = q.trimmingCharacters(in: .whitespaces)
        let lowerQ = q.lowercased()
        // Anything that asks Navi to *do* something with the results is a task, not a search.
        if ["click", "open the", "pick", "choose", "compare", "cheapest", "best", "buy", "book", "add", "select", "download"].contains(where: { lowerQ.contains($0) }) { return nil }
        return q.isEmpty ? nil : q
    }

    static func isConfirmRequired(_ a: SystemCommands.Action) -> Bool {
        if case .confirmRequired = a { return true }
        return false
    }

    static func isSentenceMark(_ s: String) -> Bool { s.count == 1 && (sentenceEnders.contains(s.first!) || s == ",") }
    static let sentenceEnders: Set<Character> = [".", "?", "!", ";"]
    static func pct(_ p: Double) -> String { "\(Int((p * 100).rounded()))%" }
}

// MARK: - Commands

/// A decided instruction, ready for `VoiceCommandExecutor`.
enum VoiceCommand: Equatable, Sendable {
    case openApp(AppEntry, text: String)
    /// No indexed app matched; LaunchServices gets a try before the agent does.
    case openAppNamed(String, text: String)
    case task(goal: String, surface: TaskSurface.Surface, useCurrentTab: Bool, isRisky: Bool, continuesPrevious: Bool)
    case openURL(URL, text: String)
    case webSearch(String, text: String)
    case answer(question: String, wantsMemory: Bool)
    case system(SystemCommands.Action, title: String, text: String, confirm: Bool)
    case control(VoiceDecider.Control, text: String)

    /// What the user said, for the transcript and logs.
    var spoken: String {
        switch self {
        case .openApp(_, let t), .openAppNamed(_, let t), .openURL(_, let t), .webSearch(_, let t), .system(_, _, let t, _), .control(_, let t): return t
        case .task(let g, _, _, _, _): return g
        case .answer(let q, _): return q
        }
    }

    /// Short label for the island while it runs: "Opening Notes".
    var label: String {
        switch self {
        case .openApp(let e, _): return "Opening \(e.name)"
        case .openAppNamed(let n, _): return "Opening \(n.capitalized)"
        case .task(let g, _, _, _, _): return g.prefix(1).uppercased() + g.dropFirst()
        case .openURL(let u, _): return "Opening \(u.host ?? u.absoluteString)"
        case .webSearch(let q, _): return "Searching for “\(q)”"
        case .answer: return "Thinking"
        case .system(_, let title, _, _): return title
        case .control(let c, _):
            switch c {
            case .stop: return "Stopping"
            case .undo: return "Undoing"
            case .confirm: return "Approved"
            case .deny: return "Declined"
            case .cancelAll: return "Cleared"
            case .stopListening: return "Stopping voice control"
            case .pause: return "Paused"
            case .resume: return "Listening"
            case .none: return ""
            }
        }
    }

    var isControl: Bool { if case .control = self { return true }; return false }
}
