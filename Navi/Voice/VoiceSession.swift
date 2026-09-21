import AppKit
import Combine
import Foundation

/// One live voice-control session: microphone → transcript → clauses → Jev
/// decisions → commands, plus everything the island renders.
///
/// Timing lives here and nowhere else:
///   - every transcript change restarts a short debounce (`reactionMs`); when it
///     fires, the pending clause goes to Jev (`VoiceDecider`) with the silence so far;
///   - a `wait` verdict schedules a re-ask after the delay Jev's answer implies
///     (a bare "and" needs a word or a pause; a trailing clause needs a pause);
///   - only one decision is in flight; new words cancel it unless the clause
///     head is unchanged (then the answer is still valid and is kept);
///   - `commit` hands the command to `VoiceCommandExecutor` (serial) and
///     immediately decides on whatever the user said after it.
///
/// Jev is asked about *text*, never audio; nothing here waits on Claude.
@MainActor
final class VoiceSession: ObservableObject {
    enum Phase: Equatable {
        case off
        case starting
        case downloadingModel(Double)
        case listening
        case paused
        case error(String)

        var isActive: Bool { self != .off && !isError }
        var isError: Bool { if case .error = self { return true }; return false }
    }

    struct Activity: Equatable {
        var label: String
        var detail: String?
        var isRisky: Bool
        var isAnswer: Bool
    }

    // MARK: Published state (the island renders this)

    @Published private(set) var phase: Phase = .off
    @Published private(set) var level: Float = 0
    /// Recent instructions that were acted on (most recent last).
    @Published private(set) var committed: [String] = []
    /// What the user is saying right now and Navi hasn't acted on yet.
    @Published private(set) var pendingText = ""
    @Published private(set) var activity: Activity?
    @Published private(set) var answerText = ""
    @Published private(set) var isAnswering = false
    @Published private(set) var approval: (description: String, risk: String)?
    @Published private(set) var queueCount = 0
    @Published private(set) var lastOutcome: (text: String, ok: Bool)?
    /// Why Navi is waiting ("waiting for the rest…"), or empty.
    @Published private(set) var hint = ""
    /// "Jev · complete 91% · 180 ms" for the footer.
    @Published private(set) var jevStatus = ""

    let services: NaviServices
    let executor: VoiceCommandExecutor
    private let listener = SpeechListener()
    private var segmenter = UtteranceSegmenter()
    private var startTask: Task<Void, Never>?
    private var decideTask: Task<Void, Never>?
    private var inflightHead: String?
    private var restarts = 0
    private var outcomeTimer: Task<Void, Never>?
    private var browserURL: (bundle: String, title: String, url: String?)?
    private var browserURLTask: Task<Void, Never>?
    private var audioFile: URL?
    // Acoustic pause detection. The recognizer delivers words in ~1 s windows,
    // so "time since the last word" says little about whether the user is
    // still talking; the microphone level does. A short real pause also
    // triggers a recognizer flush so the last words arrive right away.
    private var lastLoudAt = Date.distantPast
    private var noiseFloor: Float = 0.06
    private var heardSpeech = false
    private var flushTask: Task<Void, Never>?
    private var spokeSinceFlush = false

    static let maxCommittedShown = 3
    static let jevTimeoutMs = 1800
    static let flushAfterMs = 350
    /// Level above the running noise floor that counts as speech.
    static let speechAboveFloor: Float = 0.16

    init(services: NaviServices) {
        self.services = services
        self.executor = VoiceCommandExecutor(services: services)
        executor.onEvent = { [weak self] ev in self?.handle(ev) }
    }

    var isBusy: Bool { executor.isBusy || queueCount > 0 }

    // MARK: Lifecycle

    /// Starts listening. `audioFile` replaces the microphone (debug probe).
    func start(audioFile: URL? = nil) {
        guard !phase.isActive else { return }
        let settings = NaviSettings.shared
        self.audioFile = audioFile
        phase = .starting
        hint = "Starting…"
        segmenter.reset()
        committed = []; pendingText = ""; lastOutcome = nil; answerText = ""; isAnswering = false; activity = nil; approval = nil
        jevStatus = ""
        restarts = 0
        lastLoudAt = .distantPast; heardSpeech = false; noiseFloor = 0.06; spokeSinceFlush = false
        flushTask?.cancel(); flushTask = nil
        executor.foreground = settings.voiceBringsAppsForward
        // Open the model connections now, so the first decision skips the TLS handshake.
        services.jev.warm()
        services.claude.warm()
        listener.contextualStrings = ["Navi", "Jev"] + AppIndex.shared.entries.prefix(300).map(\.name)
        listener.onEvent = { [weak self] ev in self?.handle(ev) }
        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }
            let locale = await SpeechListener.resolveLocale(preferred: settings.voiceLocale)
            do {
                try await self.listener.start(locale: locale, audioFile: audioFile)
            } catch {
                guard !Task.isCancelled else { return }
                let msg = (error as? NaviError)?.errorDescription ?? error.localizedDescription
                Log.voice.error("voice start failed: \(msg, privacy: .public)")
                self.phase = .error(msg)
                self.hint = ""
            }
        }
        Log.voice.info("voice session starting")
    }

    /// Stops the microphone. A command that is already running finishes;
    /// queued ones are dropped.
    func stop() {
        guard phase != .off else { return }
        startTask?.cancel(); startTask = nil
        decideTask?.cancel(); decideTask = nil
        flushTask?.cancel(); flushTask = nil
        browserURLTask?.cancel()
        phase = .off
        hint = ""
        pendingText = ""
        level = 0
        let l = listener
        Task { await l.stop() }
        if executor.isBusy { executor.stopAll() }
        Log.voice.info("voice session stopped")
    }

    /// The island's Yes / No buttons (the spoken "yes"/"no" arrive through Jev).
    func approve(_ yes: Bool) {
        guard executor.pendingApproval != nil else { return }
        executor.respondToApproval(yes)
    }

    func togglePause() {
        switch phase {
        case .listening: pause()
        case .paused: resume()
        default: break
        }
    }

    private func pause() {
        guard phase == .listening else { return }
        phase = .paused
        segmenter.discardPending()
        pendingText = ""
        hint = "Paused — say “resume” or click to continue"
    }

    private func resume() {
        guard phase == .paused else { return }
        phase = .listening
        segmenter.discardPending()
        pendingText = ""
        hint = ""
    }

    // MARK: Listener events

    private func handle(_ ev: SpeechListener.Event) {
        switch ev {
        case .downloading(let p):
            phase = .downloadingModel(p)
            hint = "Downloading the speech model…"
        case .ready:
            phase = .listening
            hint = ""
            restarts = 0
        case .transcript(let finalized, let volatile):
            transcriptChanged(finalized: finalized, volatile: volatile)
        case .level(let l):
            level = l
            heard(level: l)
        case .failed(let msg):
            guard phase.isActive else { return }
            // One automatic restart (device change, model hiccup); then give up visibly.
            let l = listener
            Task { [weak self] in
                await l.stop()
                guard let self, self.phase.isActive else { return }
                if self.restarts < 2 {
                    self.restarts += 1
                    try? await Task.sleep(for: .milliseconds(300))
                    do {
                        let locale = await SpeechListener.resolveLocale(preferred: NaviSettings.shared.voiceLocale)
                        try await l.start(locale: locale, audioFile: self.audioFile)
                    } catch {
                        self.phase = .error((error as? NaviError)?.errorDescription ?? error.localizedDescription)
                    }
                } else {
                    self.phase = .error(msg)
                }
            }
        }
    }

    // MARK: Acoustic pauses

    private func heard(level l: Float) {
        // Track the quiet level slowly (fast down, slow up) so the gate follows the room.
        noiseFloor = l < noiseFloor ? noiseFloor * 0.85 + l * 0.15 : min(0.4, noiseFloor + 0.0004)
        if l >= noiseFloor + Self.speechAboveFloor {
            lastLoudAt = Date()
            heardSpeech = true
            spokeSinceFlush = true
            flushTask?.cancel(); flushTask = nil
        } else if heardSpeech, spokeSinceFlush, flushTask == nil, phase == .listening {
            // The user went quiet: after a short pause ask the recognizer for the words it is holding.
            let wait = max(0, Self.flushAfterMs - Int(Date().timeIntervalSince(lastLoudAt) * 1000))
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(wait))
                guard !Task.isCancelled, let self else { return }
                self.spokeSinceFlush = false
                self.flushTask = nil
                await self.listener.flush()
            }
        }
    }

    /// Milliseconds since the user last made a sound (or, before any speech
    /// was heard, since the transcript last changed).
    private var silenceMs: Int {
        let sinceWords = Int(Date().timeIntervalSince(segmenter.lastChangeAt) * 1000)
        guard heardSpeech else { return sinceWords }
        return Int(Date().timeIntervalSince(lastLoudAt) * 1000)
    }

    // MARK: Transcript → decision

    private func transcriptChanged(finalized: String, volatile: String) {
        guard segmenter.update(finalized: finalized, volatile: volatile) else { return }
        pendingText = segmenter.pendingText
        #if DEBUG
        DebugTrace.log("voice transcript | final=“\(finalized.suffix(60))” volatile=“\(volatile)” pending=“\(pendingText)”")
        #endif
        if phase == .paused {
            // Only "resume" / "stop listening" get through while paused.
            let head = segmenter.pending()?.head.lowercased() ?? ""
            if let ctl = VoiceDecider.heuristicControl(head), ctl == .resume || ctl == .stopListening {
                segmenter.discardPending()
                ctl == .resume ? resume() : stop()
            }
            return
        }
        // New words: keep an in-flight decision only if it is about the same head.
        if let inflight = inflightHead, segmenter.pending()?.head == inflight { return }
        scheduleDecision(after: NaviSettings.shared.voiceReactionMs)
    }

    private func scheduleDecision(after ms: Int) {
        decideTask?.cancel()
        inflightHead = nil
        decideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(max(0, ms)))
            guard !Task.isCancelled, let self else { return }
            await self.decideNow()
        }
    }

    private func decideNow() async {
        guard phase == .listening, let clause = segmenter.pending() else {
            if phase == .listening { hint = "" }
            return
        }
        let silence = silenceMs
        let input = VoiceDecider.Input(clause: clause, silenceMs: silence, context: context(for: clause))
        var decision: VoiceDecider.Decision
        if services.jev.isConfigured {
            inflightHead = clause.head
            defer { inflightHead = nil }
            let jev = services.jev
            let state = JevClient.JSONValue(any: VoiceDecider.stateJSON(input))
            let questions = VoiceDecider.questions(input)
            do {
                let resp = try await QueryRouter.withTimeout(ms: Self.jevTimeoutMs) {
                    try await jev.ask(state: state, questions: questions, cacheable: false)
                }
                guard !Task.isCancelled else { return }
                let v = VoiceDecider.verdict(from: resp)
                if let b = v.boundary {
                    jevStatus = "Jev · \(b.choice) \(Int(b.confidence * 100))%" + (v.kind.map { " · \($0.choice)" } ?? "") + " · \(v.latencyMs) ms"
                }
                decision = VoiceDecider.decide(v, input: input)
                Log.voice.debug("decide “\(clause.head, privacy: .public)” | “\(clause.following.prefix(40), privacy: .public)” → \(String(describing: decision), privacy: .public)")
                #if DEBUG
                DebugTrace.log("voice decide | head=“\(clause.head)” conn=“\(clause.connector)” following=“\(clause.following)” silence=\(silence)ms → \(v.boundary?.choice ?? "?") \(Int((v.boundary?.confidence ?? 0) * 100))% kind=\(v.kind?.choice ?? "?") \(v.latencyMs)ms ⇒ \(decision)")
                #endif
            } catch {
                guard !Task.isCancelled else { return }
                let msg = (error as? NaviError)?.errorDescription ?? error.localizedDescription
                Log.voice.warning("jev voice decision failed (\(msg, privacy: .public)); using heuristics")
                jevStatus = "Jev unavailable · local rules"
                decision = VoiceDecider.heuristicDecision(input)
            }
        } else {
            jevStatus = "No Jev key · local rules"
            decision = VoiceDecider.heuristicDecision(input)
        }
        // The user kept talking: the answer only applies if the head is unchanged.
        guard phase == .listening, let now = segmenter.pending(), now.head == clause.head, now.start == clause.start else { return }
        apply(decision, to: now)
    }

    private func apply(_ decision: VoiceDecider.Decision, to clause: UtteranceSegmenter.Clause) {
        switch decision {
        case .commit(let command):
            #if DEBUG
            DebugTrace.log("voice commit | “\(clause.head)” → \(command)")
            #endif
            segmenter.commit(clause)
            pendingText = segmenter.pendingText
            hint = ""
            committed.append(clause.head)
            if committed.count > Self.maxCommittedShown { committed.removeFirst(committed.count - Self.maxCommittedShown) }
            Log.voice.info("commit “\(clause.head, privacy: .public)” → \(command.label, privacy: .public)")
            dispatch(command)
            if segmenter.pending() != nil { scheduleDecision(after: 60) }
        case .merge:
            segmenter.acceptContinuation(clause)
            hint = "…"
            scheduleDecision(after: 60)
        case .drop(let reason):
            Log.voice.debug("drop “\(clause.head, privacy: .public)”: \(reason, privacy: .public)")
            segmenter.drop(clause)
            pendingText = segmenter.pendingText
            hint = ""
            if segmenter.pending() != nil { scheduleDecision(after: 60) }
        case .wait(let reason, let retry):
            hint = reason
            if let retry { scheduleDecision(after: retry) }
        }
    }

    // MARK: Commands

    private func dispatch(_ command: VoiceCommand) {
        VoiceSounds.play(.commit)
        guard case .control(let c, _) = command else {
            executor.enqueue(command)
            return
        }
        switch c {
        case .stop:
            executor.stopAll()
            showOutcome("Stopped", ok: true)
        case .cancelAll:
            executor.stopAll()
            segmenter.discardPending()
            pendingText = ""
            showOutcome("Cleared", ok: true)
        case .confirm:
            if executor.pendingApproval != nil { executor.respondToApproval(true) }
        case .deny:
            if executor.pendingApproval != nil { executor.respondToApproval(false) }
        case .undo:
            executor.enqueue(command)
        case .stopListening:
            stop()
        case .pause:
            pause()
        case .resume:
            resume()
        case .none:
            break
        }
    }

    // MARK: Executor events

    private func handle(_ ev: VoiceCommandExecutor.Event) {
        switch ev {
        case .started(let item):
            let risky: Bool = { if case .task(_, _, _, let r, _) = item.command { return r }; return false }()
            let isAnswer: Bool = { if case .answer = item.command { return true }; return false }()
            activity = Activity(label: item.command.label, detail: nil, isRisky: risky, isAnswer: isAnswer)
            if isAnswer { answerText = ""; isAnswering = true } else if !answerText.isEmpty { answerText = "" }
            lastOutcome = nil
        case .progress(_, let text):
            activity?.detail = text
        case .answer(_, let delta):
            answerText += delta
        case .needsApproval(_, let d, let r):
            approval = (d, r)
            VoiceSounds.play(.attention)
        case .approvalResolved:
            approval = nil
        case .finished(let item, let outcome):
            activity = nil
            approval = nil
            isAnswering = false
            switch outcome {
            case .done(let s):
                if case .answer = item.command { showOutcome("", ok: true) } else { showOutcome(s, ok: true) }
                VoiceSounds.play(.done)
            case .failed(let m):
                showOutcome(m, ok: false)
                VoiceSounds.play(.failed)
            case .cancelled:
                showOutcome("Stopped", ok: true)
            }
        case .queueChanged:
            queueCount = executor.queue.count
        }
        // The island closes itself once a stopped session has nothing left to do.
        if phase == .off, !isBusy { NotificationCenter.default.post(name: .naviVoiceIdle, object: nil) }
    }

    private func showOutcome(_ text: String, ok: Bool) {
        lastOutcome = text.isEmpty ? nil : (text, ok)
        outcomeTimer?.cancel()
        outcomeTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ok ? 5 : 9))
            guard !Task.isCancelled, let self, self.lastOutcome?.text == text else { return }
            self.lastOutcome = nil
        }
    }

    // MARK: Context for Jev

    private func context(for clause: UtteranceSegmenter.Clause) -> VoiceDecider.Context {
        var ctx = VoiceDecider.Context()
        let front = NSWorkspace.shared.frontmostApplication
        ctx.frontmostApp = front?.localizedName
        ctx.frontmostBundle = front?.bundleIdentifier
        ctx.windowTitle = ContextProbe.current(recent: []).frontmostWindowTitle
        if let b = front?.bundleIdentifier, AXSnapshotter.isBrowser(b) {
            ctx.browserURL = cachedBrowserURL(bundle: b, title: ctx.windowTitle ?? "")
        }
        ctx.busyWith = executor.busyLabel
        ctx.queued = executor.queue.count
        ctx.awaitingApproval = executor.pendingApproval?.description
        ctx.lastResult = lastOutcome?.text
        ctx.recentDone = Array(segmenter.history.suffix(3))
        ctx.appCandidates = VoiceAppMatcher.candidates(in: clause.head, index: AppIndex.shared, running: AppIndex.runningBundleIDs())
        ctx.isPaused = phase == .paused
        return ctx
    }

    /// The frontmost browser's tab URL comes from an Apple Event (tens of ms,
    /// sometimes more); fetched off the main thread and reused while the
    /// window title is unchanged.
    private func cachedBrowserURL(bundle: String, title: String) -> String? {
        if let c = browserURL, c.bundle == bundle, c.title == title { return c.url }
        guard browserURLTask == nil else { return browserURL?.url }
        browserURLTask = Task.detached(priority: .userInitiated) { [weak self] in
            let url = FrontmostProbe.browserURL(bundleID: bundle)
            await self?.storeBrowserURL(bundle: bundle, title: title, url: url)
        }
        return nil
    }

    private func storeBrowserURL(bundle: String, title: String, url: String?) {
        browserURL = (bundle, title, url)
        browserURLTask = nil
    }
}

extension Notification.Name {
    /// Posted when a stopped voice session has finished its last command.
    static let naviVoiceIdle = Notification.Name("navi.voiceIdle")
    /// Posted when voice control starts or stops (menu bar label).
    static let naviVoiceStateChanged = Notification.Name("navi.voiceStateChanged")
}

// MARK: - Sounds

/// Tiny system-sound cues so the user hears that Navi took an instruction
/// without looking up at the island. Off with `NaviSettings.voiceSounds`.
@MainActor
enum VoiceSounds {
    enum Cue { case commit, done, failed, attention }

    static func play(_ cue: Cue) {
        guard NaviSettings.shared.voiceSounds else { return }
        let (name, volume): (String, Float) = {
            switch cue {
            case .commit: return ("Tink", 0.22)
            case .done: return ("Pop", 0.18)
            case .failed: return ("Basso", 0.2)
            case .attention: return ("Glass", 0.3)
            }
        }()
        guard let s = NSSound(named: NSSound.Name(name)) else { return }
        s.volume = volume
        s.play()
    }
}
