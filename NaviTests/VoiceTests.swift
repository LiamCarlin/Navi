import Foundation
import Testing
@testable import Navi

// MARK: - Segmenter

@Suite struct UtteranceSegmenterTests {
    private func seg(_ finalized: String, _ volatile: String = "") -> UtteranceSegmenter {
        var s = UtteranceSegmenter()
        s.update(finalized: finalized, volatile: volatile)
        return s
    }

    @Test func splitsAtConnectorAndKeepsFollowing() {
        let s = seg("", "open up the notes app and make hello the title")
        let c = try! #require(s.pending())
        #expect(c.head == "open up the notes app")
        #expect(c.connector == "and")
        #expect(c.following == "make hello the title")
        #expect(c.hasBoundary)
    }

    @Test func twoWordConnectorsWinOverAnd() {
        let s = seg("open chrome and then search for cats")
        let c = try! #require(s.pending())
        #expect(c.head == "open chrome")
        #expect(c.connector == "and then")
        #expect(c.following == "search for cats")
    }

    @Test func punctuationEndsAClauseAndSwallowsAFollowingConnector() {
        let s = seg("Open Notes, and make the title hello.")
        let c = try! #require(s.pending())
        #expect(c.head == "Open Notes")
        #expect(c.connector == "and")
        #expect(c.following == "make the title hello")
    }

    @Test func trailingPeriodIsASignalNotAWord() {
        let s = seg("Open Notes.")
        let c = try! #require(s.pending())
        #expect(c.head == "Open Notes")
        #expect(c.connector == ".")
        #expect(c.following.isEmpty)
        #expect(c.hasBoundary)
    }

    @Test func fillersAreStrippedFrontAndBack() {
        let s = seg("um okay navi open chrome please")
        let c = try! #require(s.pending())
        #expect(c.head == "open chrome")
        #expect(!c.hasBoundary)
        #expect(seg("hey navi").pending() == nil)
    }

    @Test func commitAdvancesPastTheConnector() {
        var s = seg("open notes and make hello the title")
        let first = try! #require(s.pending())
        s.commit(first)
        let second = try! #require(s.pending())
        #expect(second.head == "make hello the title")
        #expect(!second.hasBoundary)
        #expect(s.history == ["open notes"])
        s.commit(second)
        #expect(s.pending() == nil)
        #expect(s.isEmpty)
    }

    @Test func acceptedContinuationIsNeverSplitThereAgain() {
        var s = seg("search for cats and dogs")
        let c = try! #require(s.pending())
        #expect(c.head == "search for cats")
        s.acceptContinuation(c)
        let merged = try! #require(s.pending())
        #expect(merged.head == "search for cats and dogs")
        #expect(!merged.hasBoundary)
        // A later, real boundary is still found.
        s.update(finalized: "search for cats and dogs and then open notes")
        let next = try! #require(s.pending())
        #expect(next.head == "search for cats and dogs")
        #expect(next.following == "open notes")
    }

    @Test func dropSkipsNoise() {
        var s = seg("oh nice. open notes")
        let noise = try! #require(s.pending())
        #expect(noise.head == "oh nice")
        s.drop(noise)
        #expect(s.pending()?.head == "open notes")
        #expect(s.history.isEmpty)
    }

    @Test func updateReportsChangesAndSurvivesRevisions() {
        var s = UtteranceSegmenter()
        let first = s.update(finalized: "", volatile: "open")
        let same = s.update(finalized: "", volatile: "open")
        let grown = s.update(finalized: "", volatile: "open notes")
        #expect(first && !same && grown)
        s.commit(s.pending()!)
        #expect(s.isEmpty)
        // The recognizer revises the tail away: the cursor clamps, nothing crashes.
        s.update(finalized: "", volatile: "open")
        #expect(s.pending() == nil)
        s.update(finalized: "open notes", volatile: "and type hi")
        #expect(s.pending()?.head == "type hi")
    }

    @Test func cursorFollowsRevisedWords() {
        // Committed "open notes" + "and"; the recognizer then rewrites the start as one word fewer.
        var s = seg("", "open notes and make the title hello")
        s.commit(s.pending()!)
        #expect(s.pending()?.head == "make the title hello")
        s.update(finalized: "", volatile: "opened notes and make the title hello")     // same count, first word revised
        #expect(s.pending()?.head == "make the title hello")
        s.update(finalized: "", volatile: "open the notes and make the title hello")  // one word more before the cursor
        #expect(s.pending()?.head == "make the title hello")
        s.update(finalized: "open the notes and make the title hello", volatile: "")  // finalized
        #expect(s.pending()?.head == "make the title hello")
    }

    /// Straight from a trace: after a flush the recognizer finalized the audio of
    /// "Make a new document." as "....." — a punctuation-only word at the cursor
    /// left `pending()` nil for good, and every later instruction piled up behind it.
    @Test func punctuationOnlyFinalNeverJamsTheCursor() {
        var s = UtteranceSegmenter()
        s.update(finalized: "Navi, open text edit.")
        s.commit(s.pending()!)
        s.update(finalized: "Navi, open text edit. .....")
        #expect(s.pending() == nil)
        s.update(finalized: "Navi, open text edit. .....", volatile: "Type hello world")
        let c = s.pending()
        #expect(c?.head == "Type hello world")
        s.update(finalized: "Navi, open text edit. ..... , you. Type goodbye, on a new line. . Now, type one more line that says done.")
        #expect(s.pending()?.head == "you")
        s.drop(s.pending()!)
        #expect(s.pending()?.head == "Type goodbye")
        s.commit(s.pending()!)
        #expect(s.pending()?.head == "on a new line")
        s.commit(s.pending()!)
        #expect(s.pending()?.head == "type one more line that says done")
    }

    @Test func strayPunctuationGluesOntoThePreviousWord() {
        #expect(UtteranceSegmenter.tokenize("open notes . and then , type hi .....") == ["open", "notes.", "and", "then,", "type", "hi....."])
        #expect(UtteranceSegmenter.tokenize("..... hello") == ["hello"])
        #expect(UtteranceSegmenter.tokenize("...") == [])
        var s = UtteranceSegmenter()
        s.update(finalized: "make a new document", volatile: ".")
        let c = s.pending()
        #expect(c?.head == "make a new document")
        #expect(c?.connector == ".")
    }

    @Test func restartForgetsTheTranscriptButNotTheHistory() {
        var s = UtteranceSegmenter()
        s.update(finalized: "open notes and then write hello")
        s.commit(s.pending()!)
        s.restartTranscript()
        #expect(s.pending() == nil)
        #expect(s.history == ["open notes"])
        s.update(finalized: "", volatile: "type goodbye")
        #expect(s.pending()?.head == "type goodbye")
    }

    @Test func trimAndTailKeepTheLastWordsWhilePaused() {
        var s = UtteranceSegmenter()
        s.update(finalized: "one two three four five six seven eight")
        s.trimPending(keepLast: 3)
        #expect(s.pendingText == "six seven eight")
        #expect(s.tailWords(2) == ["seven", "eight"])
        s.update(finalized: "one two three four five six seven eight", volatile: "resume.")
        #expect(s.tailWords(1) == ["resume"])
    }

    @Test func leadingConnectorAfterACommitIsSkipped() {
        var s = seg("", "open notes")
        s.commit(s.pending()!)
        s.update(finalized: "", volatile: "open notes and")
        #expect(s.pending() == nil)
        s.update(finalized: "", volatile: "open notes and make the title hello")
        #expect(s.pending()?.head == "make the title hello")
    }
}

// MARK: - Decider

@Suite struct VoiceDeciderTests {
    private func clause(_ head: String, following: String = "", connector: String = "") -> UtteranceSegmenter.Clause {
        let hasBoundary = !connector.isEmpty
        return UtteranceSegmenter.Clause(head: head, following: following, connector: connector,
                                         start: 0, end: 3, resume: hasBoundary ? 4 : 3)
    }

    private func verdict(boundary: (String, Double), kind: String = "do_in_app", control: String = "none",
                         app: (String, Double)? = nil, surface: String = "unsure", risky: Double = 0) -> VoiceDecider.Verdict {
        var v = VoiceDecider.Verdict()
        let (b, p) = boundary
        var probs = ["complete": 0.0, "continues": 0.0, "not_a_command": 0.0]
        probs[b] = p
        let rest = (1 - p) / 2
        for k in probs.keys where k != b { probs[k] = rest }
        v.boundary = .init(choice: b, probabilities: probs, confidence: p)
        v.kind = .init(choice: kind, probabilities: [kind: 0.9], confidence: 0.9)
        v.control = .init(choice: control, probabilities: [control: 0.9], confidence: 0.9)
        if let app { v.appTarget = .init(choice: app.0, probabilities: [app.0: app.1], confidence: app.1) }
        v.surface = .init(choice: surface, probabilities: [surface: 0.8], confidence: 0.8)
        v.isRisky = risky
        return v
    }

    private func input(_ c: UtteranceSegmenter.Clause, silence: Int = 300, apps: [VoiceAppMatcher.Candidate] = []) -> VoiceDecider.Input {
        var ctx = VoiceDecider.Context()
        ctx.appCandidates = apps
        return VoiceDecider.Input(clause: c, silenceMs: silence, context: ctx)
    }

    private var notes: VoiceAppMatcher.Candidate {
        .init(id: "a1", entry: AppEntry(name: "Notes", path: "/System/Applications/Notes.app", bundleID: "com.apple.Notes"), score: 1, phrase: "notes")
    }

    @Test func completeWithFollowingWordsCommitsImmediately() {
        let c = clause("open notes", following: "make hello the title", connector: "and")
        let d = VoiceDecider.decide(verdict(boundary: ("complete", 0.9), kind: "open_app", app: ("a1", 0.95)), input: input(c, apps: [notes]))
        guard case .commit(let cmd) = d, case .openApp(let e, _) = cmd else { Issue.record("expected openApp commit, got \(d)"); return }
        #expect(e.name == "Notes")
    }

    @Test func bareConnectorWaitsForAWordOrAPause() {
        let c = clause("open notes", following: "", connector: "and")
        let early = VoiceDecider.decide(verdict(boundary: ("complete", 0.9)), input: input(c, silence: 100))
        guard case .wait(_, let retry) = early else { Issue.record("expected wait, got \(early)"); return }
        #expect((retry ?? 0) > 0)
        let later = VoiceDecider.decide(verdict(boundary: ("complete", 0.9)), input: input(c, silence: 600))
        guard case .commit = later else { Issue.record("expected commit after the pause, got \(later)"); return }
    }

    @Test func headWithoutBoundaryWaitsForThePauseToProveIt() {
        // "compute 12" can be the front of "compute 12 times 34": complete, but nothing marks the end yet.
        let c = clause("compute 12")
        let sure = verdict(boundary: ("complete", 0.9))
        guard case .wait(_, let retry) = VoiceDecider.decide(sure, input: input(c, silence: 150)) else { Issue.record("expected wait"); return }
        #expect(retry == VoiceDecider.settleFastMs - 150)
        guard case .commit = VoiceDecider.decide(sure, input: input(c, silence: 450)) else { Issue.record("expected commit"); return }
        let lessSure = verdict(boundary: ("complete", 0.55))
        guard case .wait = VoiceDecider.decide(lessSure, input: input(c, silence: 450)) else { Issue.record("expected wait"); return }
        guard case .commit = VoiceDecider.decide(lessSure, input: input(c, silence: 700)) else { Issue.record("expected commit"); return }
        // A sentence mark from the recognizer is a boundary: no wait.
        guard case .commit = VoiceDecider.decide(lessSure, input: input(clause("compute 12 times 34", connector: "."), silence: 100)) else { Issue.record("expected commit"); return }
    }

    @Test func strongConnectorsCommitWithoutWaitingForTheNextWord() {
        let c = clause("open the calculator app", following: "", connector: "and then")
        guard case .commit = VoiceDecider.decide(verdict(boundary: ("complete", 0.86)), input: input(c, silence: 60)) else {
            Issue.record("expected an immediate commit after ‘and then’"); return
        }
    }

    @Test func continuesWithFollowingMergesTheFalseBoundary() {
        let c = clause("search for cats", following: "dogs", connector: "and")
        let d = VoiceDecider.decide(verdict(boundary: ("continues", 0.8)), input: input(c))
        #expect(d == .merge)
    }

    @Test func continuesWithoutFollowingWaitsThenCommitsOnALongPause() {
        let c = clause("make the title")
        let d = VoiceDecider.decide(verdict(boundary: ("continues", 0.7)), input: input(c, silence: 200))
        guard case .wait = d else { Issue.record("expected wait, got \(d)"); return }
        // 8% complete is below even the long-pause threshold: keep waiting.
        var confident = verdict(boundary: ("continues", 0.84))
        confident.boundary?.probabilities = ["complete": 0.08, "continues": 0.9, "not_a_command": 0.02]
        let stillWaiting = VoiceDecider.decide(confident, input: input(c, silence: 4000))
        guard case .wait = stillWaiting else { Issue.record("expected wait, got \(stillWaiting)"); return }
        // 40% complete + a long pause: the user trailed off, act.
        var v = verdict(boundary: ("continues", 0.6))
        v.boundary?.probabilities = ["complete": 0.4, "continues": 0.6, "not_a_command": 0]
        let d2 = VoiceDecider.decide(v, input: input(c, silence: 4000))
        guard case .commit = d2 else { Issue.record("expected commit, got \(d2)"); return }
    }

    @Test func closedSentenceCommitsAfterAShortPauseEvenWhenJevHesitates() {
        // "how many people were on board?" — Jev leaned `continues`, but the recognizer closed the sentence.
        var v = verdict(boundary: ("continues", 0.57), kind: "answer")
        v.boundary?.probabilities = ["complete": 0.25, "continues": 0.71, "not_a_command": 0.04]
        let c = clause("how many people were on board", connector: "?")
        let soon = VoiceDecider.decide(v, input: input(c, silence: 300))
        guard case .wait(_, let retry) = soon else { Issue.record("expected wait, got \(soon)"); return }
        #expect((retry ?? 0) > 0 && (retry ?? 0) <= VoiceDecider.sentencePauseMs)
        let later = VoiceDecider.decide(v, input: input(c, silence: 800))
        guard case .commit(let cmd) = later, case .answer = cmd else { Issue.record("expected an answer commit, got \(later)"); return }
    }

    @Test func longSilenceActsOnAnythingThatIsNotNoise() {
        var v = verdict(boundary: ("continues", 0.6))
        v.boundary?.probabilities = ["complete": 0.18, "continues": 0.72, "not_a_command": 0.10]
        let c = clause("make the title hello")
        guard case .wait = VoiceDecider.decide(v, input: input(c, silence: 2000)) else { Issue.record("expected wait"); return }
        guard case .commit = VoiceDecider.decide(v, input: input(c, silence: 3500)) else { Issue.record("expected commit"); return }
        v.boundary?.probabilities = ["complete": 0.05, "continues": 0.9, "not_a_command": 0.05]
        guard case .wait(_, let retry) = VoiceDecider.decide(v, input: input(c, silence: 3500)) else { Issue.record("expected wait"); return }
        #expect(retry == nil)
    }

    @Test func noiseIsDroppedOnceStable() {
        let c = clause("oh nice")
        let soon = VoiceDecider.decide(verdict(boundary: ("not_a_command", 0.85)), input: input(c, silence: 200))
        guard case .wait = soon else { Issue.record("expected wait, got \(soon)"); return }
        let later = VoiceDecider.decide(verdict(boundary: ("not_a_command", 0.85)), input: input(c, silence: 2000))
        guard case .drop = later else { Issue.record("expected drop, got \(later)"); return }
        let withFollowing = VoiceDecider.decide(verdict(boundary: ("not_a_command", 0.85)),
                                                input: input(clause("oh nice", following: "open notes", connector: "."), silence: 100))
        guard case .drop = withFollowing else { Issue.record("expected drop, got \(withFollowing)"); return }
    }

    @Test func fragmentsAreDroppedInsteadOfBecomingTasks() {
        // From a real session: "you", "to YouTube" each became a 2 s agent run that did nothing.
        let you = VoiceDecider.decide(verdict(boundary: ("complete", 0.7), kind: "do_in_app"), input: input(clause("you", connector: "."), silence: 900))
        #expect({ if case .drop = you { return true }; return false }())
        let tiny = VoiceDecider.decide(verdict(boundary: ("complete", 0.7), kind: "none"), input: input(clause("to youtube", connector: "."), silence: 900))
        #expect({ if case .drop = tiny { return true }; return false }())
        // Two words Jev *could* classify are a task; a question is never a fragment.
        let sendIt = VoiceDecider.decide(verdict(boundary: ("complete", 0.7), kind: "do_in_app"), input: input(clause("send it", connector: "."), silence: 900))
        #expect({ if case .commit(.task) = sendIt { return true }; return false }())
        let q = VoiceDecider.decide(verdict(boundary: ("complete", 0.7), kind: "none"), input: input(clause("why?", connector: "?"), silence: 900))
        #expect({ if case .commit = q { return true }; return false }())
        // A long pause acts on what isn't noise — but not on what is more likely noise.
        var v = verdict(boundary: ("not_a_command", 0.5))
        v.boundary?.probabilities = ["complete": 0.3, "continues": 0.2, "not_a_command": 0.5]
        let chatter = VoiceDecider.decide(v, input: input(clause("that was pretty funny honestly"), silence: 4000))
        #expect({ if case .drop = chatter { return true }; return false }())
    }

    @Test func correctionsReplaceTheRunningCommand() {
        var ctx = VoiceDecider.Context()
        ctx.busyWith = "Open a new Google Doc"
        let c = clause("I mean open a new Google Doc in Drive", connector: ".")
        var v = verdict(boundary: ("complete", 0.9), kind: "do_in_app")
        v.replacesCurrent = 0.85
        let d = VoiceDecider.decide(v, input: VoiceDecider.Input(clause: c, silenceMs: 900, context: ctx))
        #expect({ if case .replace(.task) = d { return true }; return false }())
        // Not busy: the same answer just commits. Low probability: queued as usual. Controls never replace.
        v.replacesCurrent = 0.85
        let idle = VoiceDecider.decide(v, input: input(c, silence: 900))
        #expect({ if case .commit = idle { return true }; return false }())
        v.replacesCurrent = 0.2
        let later = VoiceDecider.decide(v, input: VoiceDecider.Input(clause: c, silenceMs: 900, context: ctx))
        #expect({ if case .commit = later { return true }; return false }())
        var stop = verdict(boundary: ("complete", 0.9), kind: "control_navi", control: "stop")
        stop.replacesCurrent = 0.95
        let s = VoiceDecider.decide(stop, input: VoiceDecider.Input(clause: clause("stop", connector: "."), silenceMs: 900, context: ctx))
        #expect(s == .commit(.control(.stop, text: "stop")))
        // The question is only asked while Navi is busy.
        #expect(VoiceDecider.questions(VoiceDecider.Input(clause: c, silenceMs: 0, context: ctx))["replaces_current"] != nil)
        #expect(VoiceDecider.questions(input(c))["replaces_current"] == nil)
    }

    @Test func kindsMapToCommands() {
        // control
        let stop = VoiceDecider.command(verdict(boundary: ("complete", 0.9), kind: "control_navi", control: "stop"), input: input(clause("stop")))
        #expect(stop == .control(.stop, text: "stop"))
        // answer
        let ans = VoiceDecider.command(verdict(boundary: ("complete", 0.9), kind: "answer"), input: input(clause("what's the capital of peru")))
        #expect(ans == .answer(question: "what's the capital of peru", wantsMemory: false))
        // browse: URL, plain search, page task
        if case .openURL(let u, _) = VoiceDecider.command(verdict(boundary: ("complete", 0.9), kind: "browse_or_search"), input: input(clause("go to github.com"))) {
            #expect(u.host == "github.com")
        } else { Issue.record("expected openURL") }
        #expect(VoiceDecider.command(verdict(boundary: ("complete", 0.9), kind: "browse_or_search"), input: input(clause("search for cats"))) == .webSearch("cats", text: "search for cats"))
        if case .task(_, let surface, _, _, _) = VoiceDecider.command(verdict(boundary: ("complete", 0.9), kind: "browse_or_search"), input: input(clause("click the first result"))) {
            #expect(surface == .browser)
        } else { Issue.record("expected browser task") }
        // do_in_app carries Jev's surface and risk
        if case .task(let g, let surface, _, let risky, _) = VoiceDecider.command(verdict(boundary: ("complete", 0.9), kind: "do_in_app", surface: "native_app", risky: 0.8), input: input(clause("send it to bella"))) {
            #expect(g == "send it to bella" && surface == .nativeApp && risky)
        } else { Issue.record("expected native task") }
        // open_app without an indexed match: LaunchServices gets the bare name first (the agent is the fallback)
        #expect(VoiceDecider.command(verdict(boundary: ("complete", 0.9), kind: "open_app"), input: input(clause("open the thingy"))) == .openAppNamed("thingy", text: "open the thingy"))
    }

    @Test func destructiveSystemCommandsNeedConfirmation() {
        let v = verdict(boundary: ("complete", 0.9), kind: "system_setting")
        if case .system(_, let title, _, let confirm) = VoiceDecider.command(v, input: input(clause("restart"))) {
            #expect(title == "Restart" && confirm)
        } else { Issue.record("expected a system command") }
        if case .system(_, let title, _, let confirm) = VoiceDecider.command(v, input: input(clause("dark mode"))) {
            #expect(title == "Dark Mode" && !confirm)
        } else { Issue.record("expected a system command") }
    }

    @Test func heuristicsWorkWithoutJev() {
        // Connector with words after it → commit the head as a task.
        let d = VoiceDecider.heuristicDecision(input(clause("open notes", following: "type hi", connector: "and"), apps: [notes]))
        guard case .commit(let cmd) = d else { Issue.record("expected commit, got \(d)"); return }
        #expect(cmd == .openApp(notes.entry, text: "open notes"))
        // Nothing after it and no pause yet → wait.
        guard case .wait = VoiceDecider.heuristicDecision(input(clause("open notes"), silence: 200)) else { Issue.record("expected wait"); return }
        #expect(VoiceDecider.heuristicControl("never mind") == .stop)
        #expect(VoiceDecider.heuristicControl("stop listening") == .stopListening)
        #expect(VoiceDecider.heuristicControl("yes") == .confirm)
        #expect(VoiceDecider.heuristicControl("open the yes app") == nil)
        #expect(VoiceDecider.plainSearchQuery("google the weather in boston") == "the weather in boston")
        #expect(VoiceDecider.plainSearchQuery("search for flights and pick the cheapest") == nil)
        #expect(VoiceDecider.plainSearchQuery("open notes") == nil)
    }

    @Test func stateAndQuestionsAreStructured() {
        var ctx = VoiceDecider.Context()
        ctx.appCandidates = [notes]
        ctx.browserURL = "https://example.com"
        ctx.awaitingApproval = "Send message"
        let inp = VoiceDecider.Input(clause: clause("open notes", following: "make hi the title", connector: "and"), silenceMs: 120, context: ctx)
        let state = VoiceDecider.stateJSON(inp)
        let transcript = state["transcript"] as? [String: Any]
        #expect(transcript?["HEAD"] as? String == "open notes")
        #expect(transcript?["FOLLOWING"] as? String == "make hi the title")
        #expect((state["installed_apps_possibly_named_in_HEAD"] as? [[String: Any]])?.count == 1)
        let q = VoiceDecider.questions(inp)
        #expect(Set(q.keys) == ["boundary", "kind", "control", "app_target", "surface", "start_from", "is_risky", "continues_previous", "wants_memory"])
        // Serialisable for the wire.
        #expect(JSONSerialization.isValidJSONObject(state))
    }
}

// MARK: - App matcher

@Suite struct VoiceAppMatcherTests {
    let index = RouterFakes.appIndex()

    @Test func findsAppsUnderSpokenFiller() {
        let c = VoiceAppMatcher.candidates(in: "can you open up google chrome for me", index: index)
        #expect(c.first?.entry.name == "Google Chrome")
        #expect(c.first?.id == "a1")
        #expect(VoiceAppMatcher.candidates(in: "switch to slack", index: index).first?.entry.name == "Slack")
        #expect(VoiceAppMatcher.candidates(in: "open the maps app", index: index).first?.entry.name == "Maps")
    }

    @Test func commonWordsOnlyCountWithAnOpeningVerb() {
        #expect(VoiceAppMatcher.candidates(in: "send a text in messages", index: index).contains { $0.entry.name == "Messages" })
        #expect(VoiceAppMatcher.candidates(in: "check my messages later", index: index).isEmpty)
        #expect(VoiceAppMatcher.candidates(in: "what is the weather", index: index).isEmpty)
    }

    @Test func toleratesGluedVolatileFragments() {
        // The recognizer's volatile text briefly read "calculatorcul" before settling on "calculator".
        #expect(VoiceAppMatcher.candidates(in: "open the calculatorcul app", index: index).first?.entry.name == "Calculator")
        #expect(VoiceAppMatcher.nameGuess(in: "open the calculatorcul app") == "calculatorcul")
        #expect(VoiceAppMatcher.nameGuess(in: "open it") == nil)
    }

    @Test func spokenCamelCaseNamesMatchExactly() {
        // "text" is a stop word, so "text edit" used to fall through to a fuzzy "edit" → Script Editor.
        let index = AppIndex(entries: RouterFakes.apps + [
            AppEntry(name: "TextEdit", path: "/System/Applications/TextEdit.app", bundleID: "com.apple.TextEdit"),
            AppEntry(name: "Script Editor", path: "/System/Applications/Utilities/Script Editor.app", bundleID: "com.apple.ScriptEditor2"),
        ])
        #expect(VoiceAppMatcher.candidates(in: "navi open text edit", index: index).first?.entry.name == "TextEdit")
        #expect(VoiceAppMatcher.candidates(in: "open x code", index: index).first?.entry.name == "Xcode")
    }

    @Test func dedupesPerAppAndCapsAtFive() {
        let c = VoiceAppMatcher.candidates(in: "open google chrome chrome chrome", index: index)
        #expect(c.filter { $0.entry.name == "Google Chrome" }.count == 1)
        #expect(c.count <= VoiceAppMatcher.maxCandidates)
    }
}
struct VoiceCurrentTabTests {
    @Test @MainActor func followUpsOnABrowserPageStayOnThatTab() {
        let chrome = "com.google.Chrome"
        // After "go to YouTube", "look up Matt Armstrong" continues on the YouTube tab.
        #expect(VoiceCommandExecutor.continuesOnCurrentTab(goal: "look up Matt Armstrong", surface: .browser, frontmostApp: chrome, continues: false, lastWasBrowser: true))
        #expect(VoiceCommandExecutor.continuesOnCurrentTab(goal: "click the first video", surface: .unsure, frontmostApp: chrome, continues: true, lastWasBrowser: false))
        // Naming another site or a URL is a new destination.
        #expect(!VoiceCommandExecutor.continuesOnCurrentTab(goal: "go to reddit", surface: .browser, frontmostApp: chrome, continues: false, lastWasBrowser: true))
        #expect(!VoiceCommandExecutor.continuesOnCurrentTab(goal: "open github.com", surface: .browser, frontmostApp: chrome, continues: true, lastWasBrowser: true))
        // Not in a browser, or nothing browser-related before it, or a native task: no.
        #expect(!VoiceCommandExecutor.continuesOnCurrentTab(goal: "look up Matt Armstrong", surface: .browser, frontmostApp: "com.apple.MobileSMS", continues: true, lastWasBrowser: true))
        #expect(!VoiceCommandExecutor.continuesOnCurrentTab(goal: "look up Matt Armstrong", surface: .browser, frontmostApp: chrome, continues: false, lastWasBrowser: false))
        #expect(!VoiceCommandExecutor.continuesOnCurrentTab(goal: "close this tab", surface: .nativeApp, frontmostApp: chrome, continues: true, lastWasBrowser: true))
    }
}
