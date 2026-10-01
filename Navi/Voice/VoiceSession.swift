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
    /// The second echo layer: transcribes what the Mac plays (see `EchoFilter`).
    private let echoListener = SpeechListener()
    private var echoFilter = EchoFilter()
    /// When the clause starting at this word was first held for the Mac's transcript.
    private var echoHold: (start: Int, since: Date)?
    /// When the Mac last made a sound, and when the current stretch of sound
    /// began (the Mac-audio recognizer needs ~2 s before its first words).
    private var macSoundAt = Date.distantPast
    private var macSoundSince = Date.distantPast
    private var lastEchoDropAt = Date.distantPast
    private var segmenter = UtteranceSegmenter()
    private var startTask: Task<Void, Never>?
    private var decideTask: Task<Void, Never>?
    /// Bumped by every `scheduleDecision`; a decision only applies (and only
    /// clears `inflightHead` / `decideTask`) if it is still the latest one.
    private var decideGeneration = 0
    private var inflightHead: String?
    /// The pending text a decision last answered "wait" for with nothing to
    /// retry — the watchdog leaves that alone until the words change.
    private var waitedForText: String?
    private var watchdog: Task<Void, Never>?
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
    private var activityDetector = SpeechActivity()
    private var heardSpeech = false
    private var flushTask: Task<Void, Never>?
    private var spokeSinceFlush = false
    /// Jev's last verdict for a head it called complete but that still had to
    /// wait for the pause: when the pause arrives with the words unchanged, it
    /// is decided on again locally instead of paying a second round trip.
    private var settled: (key: String, verdict: VoiceDecider.Verdict, at: Date)?
    private var lastWarmAt = Date.distantPast

    static let maxCommittedShown = 3
    static let jevTimeoutMs = 1800
    /// How often the watchdog checks that pending words have a decision coming.
    static let watchdogMs = 500
    /// Pending words older than this with no decision in flight get one, whatever
    /// the bookkeeping says — nothing the user said may sit there for good.
    static let watchdogStaleMs = 1200
    /// While paused, only the last few words are kept (enough for "resume").
    static let pausedTailWords = 6
    static let flushAfterMs = 350
    /// A settled verdict is reused for this long.
    static let settledReuseMs = 3000
    /// While the Mac is talking, a clause waits (at most this long) for the
    /// Mac's own transcript to catch up, so its words can be recognised as echo.
    static let echoHoldMaxMs = 1200
    /// The Mac's transcript counts as caught up once it changed this long after the clause did.
    static let echoCatchUpMs = 300
    /// A new stretch of the Mac's sound holds clauses even before its words arrive, this long.
    static let macWarmUpMs = 3000
    /// Keep Jev's connection warm while listening: a cold call costs ~2×.
    static let keepWarmSeconds: TimeInterval = 20

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
        lastLoudAt = .distantPast; heardSpeech = false; activityDetector.reset(); spokeSinceFlush = false
        settled = nil
        flushTask?.cancel(); flushTask = nil
        waitedForText = nil
        executor.foreground = settings.voiceBringsAppsForward
        startWatchdog()
        // Open the model connections now, so the first decision skips the TLS handshake.
        services.jev.warm()
        services.claude.warm()
        listener.contextualStrings = ["Navi", "Jev"] + AppIndex.shared.entries.prefix(300).map(\.name)
        listener.echoCancellation = settings.voiceEchoCancellation
        listener.onEvent = { [weak self] ev in self?.handle(ev) }
        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }
            let locale = await SpeechListener.resolveLocale(preferred: settings.voiceLocale)
            do {
                try await self.listener.start(locale: locale, audioFile: audioFile)
                if settings.voiceEchoCancellation { await self.startEchoListener(locale: locale) }
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
        decideGeneration &+= 1
        inflightHead = nil
        flushTask?.cancel(); flushTask = nil
        watchdog?.cancel(); watchdog = nil
        browserURLTask?.cancel()
        phase = .off
        hint = ""
        pendingText = ""
        level = 0
        let l = listener, e = echoListener
        Task { await l.stop(); await e.stop() }
        echoFilter.reset()
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
                        // The new recognizer's transcript starts from nothing: the cursor must too.
                        self.decideTask?.cancel(); self.decideTask = nil
                        self.decideGeneration &+= 1
                        self.inflightHead = nil
                        self.segmenter.restartTranscript()
                        self.pendingText = ""
                        self.waitedForText = nil
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

    // MARK: The Mac's own audio

    /// The Mac has said words recently, or has just started making sound and
    /// its recognizer hasn't caught up yet.
    private var macIsTalking: Bool {
        let now = Date()
        if echoFilter.isActive(at: now) { return true }
        let playing = now.timeIntervalSince(macSoundAt) < 0.5
        return playing && now.timeIntervalSince(macSoundSince) * 1000 < Double(Self.macWarmUpMs)
    }

    /// Starts transcribing what the Mac plays. Optional: without Screen
    /// Recording, or if capture fails, voice control works as before.
    private func startEchoListener(locale: Locale) async {
        guard phase.isActive, ScreenCapture.hasPermission else {
            Log.voice.info("second echo layer off (no Screen Recording permission)")
            return
        }
        echoFilter.reset()
        echoListener.capturesSystemAudio = true
        echoListener.echoCancellation = false
        echoListener.onEvent = { [weak self] ev in
            guard let self else { return }
            switch ev {
            case .transcript(let finalized, let volatile):
                self.echoFilter.update(finalized: finalized, volatile: volatile)
                Log.voice.debug("mac-audio | final=…\(String(finalized.suffix(50)), privacy: .private) | volatile=\(volatile, privacy: .private)")
                #if DEBUG
                DebugTrace.log("voice mac-audio | final=“\(finalized.suffix(60))” volatile=“\(volatile)”")
                #endif
            case .failed(let msg):
                Log.voice.error("mac audio transcription stopped: \(msg, privacy: .public)")
                let e = self.echoListener
                Task { await e.stop() }
            case .level:
                // Levels only arrive while the Mac is making sound (silence isn't transcribed).
                let now = Date()
                if now.timeIntervalSince(self.macSoundAt) > 2 { self.macSoundSince = now }
                self.macSoundAt = now
            case .ready, .downloading:
                break
            }
        }
        do {
            try await echoListener.start(locale: locale)
            // Voice control may have been stopped while this was starting.
            if !phase.isActive { await echoListener.stop() }
        } catch {
            Log.voice.error("second echo layer failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Acoustic pauses

    private func heard(level l: Float) {
        if activityDetector.isSpeech(l, at: ProcessInfo.processInfo.systemUptime) {
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
                await self.echoListener.flush()
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
            // Only "resume" / "stop listening" get through while paused — looked for
            // in the last few words, so it is heard however much was said before it.
            let tail = segmenter.tailWords(4)
            var ctl: VoiceDecider.Control?
            for n in stride(from: min(4, tail.count), through: 1, by: -1) {
                if let c = VoiceDecider.heuristicControl(tail.suffix(n).joined(separator: " ")), c == .resume || c == .stopListening { ctl = c; break }
            }
            if let ctl {
                segmenter.discardPending()
                pendingText = ""
                ctl == .resume ? resume() : stop()
            } else {
                // Don't let the transcript pile up behind the cursor while paused.
                segmenter.trimPending(keepLast: Self.pausedTailWords)
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
        decideGeneration &+= 1
        let gen = decideGeneration
        decideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(max(0, ms)))
            guard !Task.isCancelled, let self, gen == self.decideGeneration else { return }
            await self.decideNow(generation: gen)
        }
    }

    /// Nothing the user said may sit behind the cursor with no decision on the
    /// way. Every bookkeeping path above tries to guarantee that; this is the
    /// backstop for the ones that don't (a decision discarded because the
    /// recognizer revised the clause under it, a cancelled task racing a new
    /// one, an unexpected throw). It leaves a clause alone only while a decision
    /// is in flight or scheduled, or when the last answer for exactly these
    /// words was "wait for more words".
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Self.watchdogMs))
                guard !Task.isCancelled, let self else { return }
                self.watchdogTick()
            }
        }
    }

    private func watchdogTick() {
        if phase == .listening, Date().timeIntervalSince(lastWarmAt) >= Self.keepWarmSeconds {
            lastWarmAt = Date()
            services.jev.warm()   // no-op while the connection is in use
        }
        guard phase == .listening, decideTask == nil, let clause = segmenter.pending() else { return }
        let text = segmenter.pendingText
        let age = Int(Date().timeIntervalSince(segmenter.lastChangeAt) * 1000)
        // "Wait for more words" is honoured only until the give-up point.
        if let waited = waitedForText, waited == text, age < VoiceDecider.giveUpMs { return }
        guard age >= Self.watchdogStaleMs else { return }
        Log.voice.warning("watchdog: “\(clause.head, privacy: .private)” had no decision for \(age) ms — deciding now")
        #if DEBUG
        DebugTrace.log("voice watchdog | head=“\(clause.head)” idle \(age)ms → decide")
        #endif
        scheduleDecision(after: 0)
    }

    private func decideNow(generation gen: Int) async {
        defer {
            // Only the latest decision owns the bookkeeping; a superseded one must
            // not clear the state of the one that replaced it.
            if gen == decideGeneration { inflightHead = nil; decideTask = nil }
        }
        guard phase == .listening, let clause = segmenter.pending() else {
            if phase == .listening { hint = "" }
            return
        }
        // The Mac is talking (a video, music): give its transcript a moment to
        // catch up with these words, then cut out whatever it said too.
        // One word ("stop") is never echo, so it never waits.
        if clause.headWordCount > 1, macIsTalking, echoFilter.lastUpdateAt < segmenter.lastChangeAt.addingTimeInterval(Double(Self.echoCatchUpMs) / 1000) {
            if echoHold?.start != clause.start { echoHold = (clause.start, Date()) }
            if let h = echoHold, Date().timeIntervalSince(h.since) * 1000 < Double(Self.echoHoldMaxMs) {
                hint = "…"
                scheduleDecision(after: 150)
                return
            }
        }
        echoHold = nil
        let heardClause = clause
        var echoDecision: VoiceDecider.Decision?
        let trailing = EchoFilter.isTrailingEcho(clause.head, secondsSinceEchoDrop: Date().timeIntervalSince(lastEchoDropAt),
                                                  macTalking: macIsTalking)
        if trailing || echoFilter.classify(clause.head) == .echo {
            echoDecision = .drop(reason: "the Mac's own audio")
            lastEchoDropAt = Date()
            Log.voice.info("echo: dropped “\(clause.head, privacy: .private)” (\(trailing ? "tail of what the Mac said" : "the Mac said it", privacy: .public))")
            #if DEBUG
            DebugTrace.log("voice echo | dropped “\(clause.head)” | mac said “\(self.echoFilter.recentWords().suffix(20).joined(separator: " "))”")
            #endif
        }
        let silence = silenceMs
        var input = VoiceDecider.Input(clause: heardClause, silenceMs: silence, context: context(for: heardClause))
        var decision: VoiceDecider.Decision
        let key = [heardClause.head, clause.connector, clause.following, clause.soft ? "soft" : "", executor.busyLabel ?? ""].joined(separator: "|")
        if let echoDecision {
            decision = echoDecision
        } else if let instant = VoiceDecider.instantDecision(input) {
            jevStatus = "Instant · no Jev call"
            decision = instant
            #if DEBUG
            DebugTrace.log("voice decide | head=“\(clause.head)” instant ⇒ \(decision)")
            #endif
        } else if let s = settled, s.key == key, Date().timeIntervalSince(s.at) * 1000 < Double(Self.settledReuseMs) {
            // Jev already called these exact words complete; only the pause was missing.
            decision = VoiceDecider.decide(s.verdict, input: input)
            #if DEBUG
            DebugTrace.log("voice decide | head=“\(clause.head)” reused verdict silence=\(silence)ms ⇒ \(decision)")
            #endif
        } else if services.jev.isConfigured {
            inflightHead = clause.head
            let jev = services.jev
            let state = JevClient.JSONValue(any: VoiceDecider.stateJSON(input))
            let questions = VoiceDecider.questions(input)
            do {
                // Integration hook (account workstream): the decider call is metered as `voice`.
                let resp = try await CloudRun.$current.withValue(CloudRun(feature: .voice)) {
                    try await QueryRouter.withTimeout(ms: Self.jevTimeoutMs) {
                        try await jev.ask(state: state, questions: questions, cacheable: false)
                    }
                }
                guard !Task.isCancelled else { return }
                let v = VoiceDecider.verdict(from: resp)
                // The pause kept growing during the round trip: judge it as it is now.
                input.silenceMs = silenceMs
                if let b = v.boundary {
                    jevStatus = "Jev · \(b.choice) \(Int(b.confidence * 100))%" + (v.kind.map { " · \($0.choice)" } ?? "") + " · \(v.latencyMs) ms"
                }
                decision = VoiceDecider.decide(v, input: input)
                if case .wait = decision, let b = v.boundary, b.p(VoiceDecider.Boundary.complete.rawValue) >= VoiceDecider.commitP {
                    settled = (key, v, Date())
                }
                Log.voice.debug("decide “\(clause.head, privacy: .private)” | “\(clause.following.prefix(40), privacy: .private)” → \(String(describing: decision), privacy: .private)")
                #if DEBUG
                DebugTrace.log("voice decide | head=“\(clause.head)” conn=“\(clause.soft ? "(soft)" : clause.connector)” following=“\(clause.following)” silence=\(silence)→\(input.silenceMs)ms → \(v.boundary?.choice ?? "?") \(Int((v.boundary?.confidence ?? 0) * 100))% kind=\(v.kind?.choice ?? "?") \(v.latencyMs)ms ⇒ \(decision)")
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
        guard gen == decideGeneration, phase == .listening else { return }
        // The user kept talking: the answer only applies if the head is unchanged.
        // Otherwise the new clause needs a decision of its own — right away.
        guard let now = segmenter.pending() else { return }
        guard now.head == clause.head, now.start == clause.start else {
            scheduleDecision(after: 60)
            return
        }
        apply(decision, to: now)
    }

    private func apply(_ decision: VoiceDecider.Decision, to clause: UtteranceSegmenter.Clause) {
        waitedForText = nil
        if case .wait = decision {} else { settled = nil }
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
            Log.voice.info("commit “\(clause.head, privacy: .private)” → \(command.label, privacy: .private)")
            dispatch(command)
            if segmenter.pending() != nil { scheduleDecision(after: 60) }
        case .replace(let command):
            #if DEBUG
            DebugTrace.log("voice replace | “\(clause.head)” → \(command) (stops \(self.executor.busyLabel ?? "?"))")
            #endif
            segmenter.commit(clause)
            pendingText = segmenter.pendingText
            hint = ""
            committed.append(clause.head)
            if committed.count > Self.maxCommittedShown { committed.removeFirst(committed.count - Self.maxCommittedShown) }
            let busy = executor.busyLabel ?? ""
            Log.voice.info("replace “\(busy, privacy: .private)” with “\(clause.head, privacy: .private)” → \(command.label, privacy: .private)")
            VoiceSounds.play(.commit)
            executor.replaceCurrent(with: command)
            if segmenter.pending() != nil { scheduleDecision(after: 60) }
        case .merge:
            segmenter.acceptContinuation(clause)
            hint = "…"
            scheduleDecision(after: 60)
        case .drop(let reason):
            Log.voice.debug("drop “\(clause.head, privacy: .private)”: \(reason, privacy: .private)")
            segmenter.drop(clause)
            pendingText = segmenter.pendingText
            hint = ""
            if segmenter.pending() != nil { scheduleDecision(after: 60) }
        case .giveUp(let reason):
            Log.voice.info("give up on “\(clause.head, privacy: .private)”: \(reason, privacy: .private)")
            #if DEBUG
            DebugTrace.log("voice give up | “\(clause.head)” — \(reason)")
            #endif
            segmenter.drop(clause)
            pendingText = segmenter.pendingText
            hint = ""
            showOutcome("Didn’t catch an instruction in “\(clause.head)” — say it again", ok: false)
            if segmenter.pending() != nil { scheduleDecision(after: 60) }
        case .wait(let reason, let retry):
            hint = reason
            if let retry { scheduleDecision(after: retry) } else { waitedForText = segmenter.pendingText }
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
            #if DEBUG
            DebugTrace.log("voice finished | “\(item.command.spoken)” → \(outcome)")
            #endif
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
        ctx.recentDone = executor.recent.isEmpty ? Array(segmenter.history.suffix(3)) : Array(executor.recent.suffix(3))
        ctx.appCandidates = VoiceAppMatcher.candidates(in: clause.head, index: AppIndex.shared, running: AppIndex.runningBundleIDs())
        ctx.isPaused = phase == .paused
        ctx.userUsuallyUses = UserHabits.current?.cachedProfile().flatMap { UserHabits.surfaceHint(task: clause.head, profile: $0) }
        ctx.headMayContinueAppName = !clause.hasBoundary && VoiceAppMatcher.mayContinueAppName(clause.head, index: AppIndex.shared)
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
