import CoreGraphics
import Foundation
import Testing
@testable import Navi

/// Fast paths for spoken commands and the agent loop (2026-10-01): window/app commands without
/// the agent, local math, compound goals, the voice surface rule, one-click goals, copies of one
/// target, new-item marks, the replay cache. Cases are the utterances from the run logs that
/// went wrong. Pure logic; no network, no live Accessibility.
struct VoiceSpeedTests {
    static let running = ["Messages", "FaceTime", "Claude", "Superwhisper", "Calculator", "QuickTime Player", "Google Chrome", "Finder"]
    static func resolve(_ s: String) -> String? { WindowControls.bestName(s, in: running) }

    // MARK: Window controls

    @Test func windowCommandsFromTheRunLogs() {
        func m(_ s: String) -> WindowControls.Command? { WindowControls.match(s, resolveApp: Self.resolve) }
        #expect(m("close out of messages") == .init(verb: .quit, target: .app("Messages")))
        #expect(m("close out a FaceTime") == .init(verb: .quit, target: .app("FaceTime")))
        #expect(m("Close that a Claude") == .init(verb: .quit, target: .app("Claude")))
        #expect(m("Wait, close out of Super Whisper") == .init(verb: .quit, target: .app("Superwhisper")))
        #expect(m("close out of the calculator") == .init(verb: .quit, target: .app("Calculator")))
        #expect(m("No, quit") == .init(verb: .quit, target: .front))
        #expect(m("Close out of this") == .init(verb: .closeWindow, target: .front))
        #expect(m("I can you close out of that") == .init(verb: .closeWindow, target: .front))
        #expect(m("quit quicktime player") == .init(verb: .quit, target: .app("QuickTime Player")))
        #expect(m("hide chrome") == .init(verb: .hide, target: .app("Google Chrome")))
        #expect(m("minimize this window") == .init(verb: .minimize, target: .front))
        #expect(m("make it full screen") == .init(verb: .fullScreen, target: .front))
        #expect(m("exit full screen") == .init(verb: .fullScreen, target: .front))
    }

    @Test func windowCommandsLeaveEverythingElseToTheAgent() {
        func m(_ s: String) -> WindowControls.Command? { WindowControls.match(s, resolveApp: Self.resolve) }
        // Parts of an app, apps that aren't running, more than one instruction, other verbs.
        #expect(m("close the sidebar") == nil)
        #expect(m("close this tab") == nil)
        #expect(m("close the draft in mail") == nil)
        #expect(m("close photoshop") == nil)
        #expect(m("close messages and open notes") == nil)
        #expect(m("kill") == nil)
        #expect(m("open messages") == nil)
        #expect(m("closed captions on") == nil)
        #expect(m("") == nil)
    }

    @Test func runningAppNamesMatchLoosely() {
        #expect(WindowControls.bestName("super whisper", in: Self.running) == "Superwhisper")
        #expect(WindowControls.bestName("quicktime", in: Self.running) == "QuickTime Player")
        //expect(WindowControls.bestName("chrome", in: Self.running) == "Google Chrome")
        //expect(WindowControls.bestName("player", in: Self.running) == "QuickTime Player")
        //expect(WindowControls.bestName("time", in: Self.running) == nil)   // inside a word is too loose
        #expect(WindowControls.bestName("google chrome", in: Self.running) == "Google Chrome")
        #expect(WindowControls.bestName("ca", in: Self.running) == nil)
    }

    private func clause(_ head: String) -> UtteranceSegmenter.Clause {
        let n = head.split(separator: " ").count
        return .init(head: head, following: "", connector: ".", start: 0, end: n, resume: n)
    }

    private func verdict(kind: String, surface: String = "native_app") -> VoiceDecider.Verdict {
        var v = VoiceDecider.Verdict()
        v.boundary = .init(choice: "complete", probabilities: ["complete": 0.95], confidence: 0.95)
        v.kind = .init(choice: kind, probabilities: [kind: 0.9], confidence: 0.9)
        v.control = .init(choice: "none", probabilities: ["none": 0.9], confidence: 0.9)
        v.surface = .init(choice: surface, probabilities: [surface: 0.8], confidence: 0.8)
        return v
    }

    private func input(_ head: String) -> VoiceDecider.Input {
        var ctx = VoiceDecider.Context()
        ctx.runningApps = Self.running
        ctx.frontmostBundle = "com.apple.MobileSMS"
        return .init(clause: clause(head), silenceMs: 800, context: ctx)
    }

    @Test func spokenWindowCommandsSkipTheAgent() {
        guard case .window(let w, _) = VoiceDecider.command(verdict(kind: "do_in_app"), input: input("close out of messages")) else {
            Issue.record("expected a window command"); return
        }
        #expect(w.verb == .quit)
        guard case .window = VoiceDecider.command(verdict(kind: "system_setting"), input: input("quit facetime")) else {
            Issue.record("expected a window command"); return
        }
        // A browser tab is still the browser's: "close this tab" stays a browser command.
        guard case .browser = VoiceDecider.command(verdict(kind: "do_in_app"), input: input("close this tab")) else {
            Issue.record("expected a browser command"); return
        }
        // A question about quitting is a question.
        guard case .answer = VoiceDecider.command(verdict(kind: "answer"), input: input("how do I quit vim")) else {
            Issue.record("expected an answer"); return
        }
    }

    // MARK: Local math

    @Test func mathIsAnsweredLocally() {
        #expect(VoiceDecider.localMath("calculate 22+34")?.answer == "56")
        #expect(VoiceDecider.localMath("compute 12 times 34")?.answer == "408")
        #expect(VoiceDecider.localMath("what's 15% of 340")?.answer == "51")
        #expect(VoiceDecider.localMath("open calculator and add 2 and 2") == nil)
        #expect(VoiceDecider.localMath("type 500") == nil)
        #expect(VoiceDecider.localMath("make a 2x3 table") == nil)
        #expect(VoiceDecider.localMath("set volume to 50") == nil)
        for phrase in ["meeting with jilles tomorrow at 3", "text mom I'll be there in 10 minutes", "go to page 2",
                       "remind me to call mom tomorrow at 5", "open the 2 pm meeting", "play the top 10 songs", "click on interviewing",
                       "set a timer for 5 minutes", "move it 2 down"] {
            #expect(VoiceDecider.localMath(phrase) == nil, "\(phrase)")
        }
        guard case .answer(let q, _) = VoiceDecider.command(verdict(kind: "do_in_app"), input: input("calculate 22+34")) else {
            Issue.record("expected an answer"); return
        }
        #expect(q == "calculate 22+34")
    }

    // MARK: Compound goals and the voice surface

    @Test func compoundGoalsAreRecognised() {
        #expect(VoiceCommandExecutor.isCompound("Open up Chrome, find me the newest Patriots game score, and text it to Jack Wei"))
        #expect(VoiceCommandExecutor.isCompound("open notes and make a new note"))
        #expect(VoiceCommandExecutor.isCompound("search for flights to denver then open the cheapest"))
        #expect(!VoiceCommandExecutor.isCompound("go to Bella and say I love her"))
        #expect(!VoiceCommandExecutor.isCompound("text mom open the garage and feed the dog"))
        #expect(!VoiceCommandExecutor.isCompound("search for cats and dogs"))
        #expect(!VoiceCommandExecutor.isCompound("click on interviewing"))
    }

    @Test func browserTasksThatNameNoPageStayOnScreen() {
        func surface(_ goal: String, front: String?) -> (TaskSurface.Surface, Bool) {
            let r = VoiceCommandExecutor.voiceSurface(goal: goal, surface: .browser, frontmostBundle: front, namesPage: { _ in false })
            return (r.surface, r.currentTab)
        }
        // From the logs: Googled as a sentence. Now the app in front does it.
        #expect(surface("change it to cloud", front: "com.anthropic.claudefordesktop") == (.nativeApp, false))
        #expect(surface("select local", front: "com.google.Chrome") == (.browser, true))
        // Finding something is still a web search.
        #expect(surface("find me the newest Patriots game score", front: nil) == (.browser, false))
        #expect(surface("search for cheap flights", front: nil) == (.browser, false))
        // Naming a page keeps it a web task.
        let named = VoiceCommandExecutor.voiceSurface(goal: "open my canvas calendar", surface: .browser, frontmostBundle: nil, namesPage: { _ in true })
        #expect(named.surface == .browser && !named.currentTab)
        // Native tasks are untouched.
        let native = VoiceCommandExecutor.voiceSurface(goal: "make a note", surface: .nativeApp, frontmostBundle: nil, namesPage: { _ in false })
        #expect(native.surface == .nativeApp)
    }

    // MARK: One-click goals

    @Test func literalTargetsAreOneActionGoals() {
        #expect(CUFacts.literalTarget("click on interviewing") == "interviewing")
        #expect(CUFacts.literalTarget("select local") == "local")
        #expect(CUFacts.literalTarget("Can you press the send button") == "send")
        #expect(CUFacts.literalTarget("tap on New session.") == "new session")
        #expect(CUFacts.literalTarget("In System Settings: click on Bluetooth") == "bluetooth")
        #expect(CUFacts.literalTarget("click it") == nil)
        #expect(CUFacts.literalTarget("select all") == nil)
        #expect(CUFacts.literalTarget("change it from local to cloud") == nil)
        #expect(CUFacts.literalTarget("click on interviewing and then local") == nil)
        #expect(CUFacts.literalTarget("open the downloads folder") == nil)
        #expect(CUFacts.plainLabel("• Local") == "local")
        #expect(CUFacts.plainLabel("  Send… ") == "send")
    }

    static func item(_ i: Int, _ text: String, y: CGFloat, x: CGFloat = 20, role: String = "", source: CUItem.Source = .ocr) -> CUItem {
        CUItem(index: i, text: text, confidence: 1, box: CGRect(x: x, y: y, width: 120, height: 18), role: role, source: source)
    }

    static func screen(_ items: [CUItem], elements: [Int: String] = [:], snapshot: AXSnapshot = AXSnapshot(elements: [])) -> CUScreen {
        CUScreen(snapshot: snapshot, items: items, elementForItem: elements, field: nil, usedOCR: false)
    }

    @Test func literalItemIsOneControlOrNothing() {
        let s = [Self.item(0, "Interviewing", y: 500, role: "button", source: .ax), Self.item(1, "• Interviewing", y: 502, x: 200),
                 Self.item(2, "Navi", y: 300)]
        #expect(CUFacts.literalItem("interviewing", in: s)?.index == 0)
        let twoRows = [Self.item(0, "Buy", y: 300), Self.item(1, "Buy", y: 400)]
        #expect(CUFacts.literalItem("buy", in: twoRows) == nil)
        #expect(CUFacts.literalItem("cloud", in: s) == nil)
    }

    // MARK: Copies of one target

    @Test func copiesOfOneTargetPoolTheirConfidence() {
        // 2026-09-29 step 2: 0.62 on the sidebar line, 0.37 on its bullet copy.
        let items = [Self.item(145, "• Interviewing", y: 500, x: 200), Self.item(146, "Interviewing", y: 501, role: "button", source: .ax),
                     Self.item(99, "Navi action timing", y: 100)]
        let head = CUDecide.Head(choice: "146", probabilities: ["146": 0.62, "145": 0.37, "99": 0.01], confidence: 0.62)
        let merged = CUDecide.mergeCopies(head, screen: Self.screen(items, elements: [146: "e9"]))
        #expect(merged.choice == "146")
        #expect(abs(merged.confidence - 0.99) < 0.001)
        // Three "Buy" buttons in three rows are three targets: nothing pools.
        let buys = [Self.item(1, "Buy", y: 300), Self.item(2, "Buy", y: 400), Self.item(3, "Buy", y: 500)]
        let split = CUDecide.Head(choice: "1", probabilities: ["1": 0.4, "2": 0.35, "3": 0.25], confidence: 0.4)
        #expect(CUDecide.mergeCopies(split, screen: Self.screen(buys)) == split)
        // The pooled group wins over a single item that led alone.
        let copies = [Self.item(1, "Send", y: 300), Self.item(2, "Send", y: 301, x: 30, role: "button", source: .ax), Self.item(3, "Cancel", y: 300, x: 400)]
        let lead = CUDecide.Head(choice: "3", probabilities: ["1": 0.3, "2": 0.3, "3": 0.4], confidence: 0.4)
        let pooled = CUDecide.mergeCopies(lead, screen: Self.screen(copies, elements: [2: "e2"]))
        #expect(pooled.choice == "2")
        #expect(abs(pooled.confidence - 0.6) < 0.001)
    }

    // MARK: New items

    @Test func itemsThatAppearedAreMarkedNew() {
        let base = (0..<10).map { Self.item($0, "Row \($0)", y: CGFloat(20 * $0)) }
        let menu = base + [Self.item(10, "Cloud", y: 50, x: 400), Self.item(11, "Local", y: 70, x: 400)]
        var input = CUDecide.Input(goal: "change it to cloud", screen: Self.screen(menu), history: [])
        input.previousLabels = Set(base.map { CUFacts.plainLabel($0.text) })
        #expect(CUDecide.newItems(input) == [10, 11])
        let rows = (CUDecide.state(input)["screen_items_in_reading_order"] as? [[String: Any]]) ?? []
        #expect(rows.first { $0["i"] as? Int == 10 }?["new"] as? Bool == true)
        #expect(rows.first { $0["i"] as? Int == 0 }?["new"] == nil)
        // A whole new page: nothing is marked.
        input.screen = Self.screen((0..<10).map { Self.item($0, "Other \($0)", y: CGFloat(20 * $0)) })
        #expect(CUDecide.newItems(input).isEmpty)
        input.previousLabels = nil
        #expect(CUDecide.newItems(input).isEmpty)
    }

    // MARK: Replay cache

    static let snapshot = AXSnapshot(elements: [
        TypesafeCUTests.el("e1", "AXButton", "New session", x: 10, y: 10),
        TypesafeCUTests.el("e2", "AXButton", "Code", x: 10, y: 40),
        TypesafeCUTests.el("e3", "AXButton", "Send", x: 10, y: 70),
        TypesafeCUTests.el("e4", "AXPopUpButton", "Mode", x: 10, y: 100, options: ["Local", "Cloud"]),
    ], bundleID: "com.anthropic.claudefordesktop", appName: "Claude")

    @Test func replayKeysIgnorePolitenessNotMeaning() {
        #expect(CUReplay.key(for: "Can you start a new Claude code chat, please?") == "start new claude code chat")
        #expect(CUReplay.key(for: "start a new claude code chat") == "start new claude code chat")
        #expect(CUReplay.key(for: "select local") != CUReplay.key(for: "select cloud"))
    }

    @Test func replayRecordsLooksUpAndForgets() {
        let store = CUReplay(fileURL: nil)
        let steps = [CUReplayStep(kind: .click, role: "AXButton", label: "new session"), CUReplayStep(kind: .key, key: "cmd+n")]
        store.record(bundleID: "com.app", goal: "start a new chat", steps: steps, complete: true, replayed: false)
        #expect(store.lookup(bundleID: "com.app", goal: "Please start a new chat")?.steps == steps)
        #expect(store.lookup(bundleID: "com.other", goal: "start a new chat") == nil)
        store.record(bundleID: "com.app", goal: "start a new chat", steps: steps, complete: true, replayed: true)
        #expect(store.lookup(bundleID: "com.app", goal: "start a new chat")?.replays == 1)
        #expect(store.count == 1)
        store.forget(bundleID: "com.app", goal: "start a new chat")
        #expect(store.lookup(bundleID: "com.app", goal: "start a new chat") == nil)
        // Too long, or nothing to replay: not stored.
        store.record(bundleID: "com.app", goal: "x", steps: [], complete: true, replayed: false)
        #expect(store.count == 0)
    }

    @Test func replayStepsAreFoundAgainInTheLiveTree() {
        let s = CUPerception.perceive(Self.snapshot, ocr: nil, goal: "start a new chat")
        let click = CUReplay.step(for: .click(elementID: "e1"), screen: s, itemText: nil)
        #expect(click == CUReplayStep(kind: .click, role: "AXButton", label: "new session"))
        #expect(CUReplay.step(for: .typeText(elementID: "e1"), screen: s, itemText: nil) == nil)
        #expect(CUReplay.step(for: .openApp("Notes"), screen: s, itemText: nil) == nil)
        #expect(CUReplay.resolve(click!, on: s) == .click(elementID: "e1"))
        let select = CUReplayStep(kind: .select, role: "AXPopUpButton", label: "mode", option: "Cloud")
        #expect(CUReplay.resolve(select, on: s) == .select(elementID: "e4", option: "Cloud"))
        #expect(CUReplay.resolve(CUReplayStep(kind: .select, role: "AXPopUpButton", label: "mode", option: "Remote"), on: s) == nil)
        // Gone from the screen: Jev takes over.
        #expect(CUReplay.resolve(CUReplayStep(kind: .click, role: "AXButton", label: "archive"), on: s) == nil)
        // Two controls with that label and nothing to tell them apart: ambiguous.
        var twin = Self.snapshot
        twin.elements.append(TypesafeCUTests.el("e5", "AXButton", "Code", x: 300, y: 40))
        let twinScreen = CUPerception.perceive(twin, ocr: nil, goal: "x")
        #expect(CUReplay.resolve(CUReplayStep(kind: .click, role: "AXButton", label: "code"), on: twinScreen) == nil)
        #expect(CUReplay.resolve(CUReplayStep(kind: .key, key: "cmd+n"), on: s) == .key("cmd+n"))
    }

    @Test func irreversibleStepsAreNeverReplayed() {
        #expect(CUReplay.looksIrreversible(CUReplayStep(kind: .click, role: "AXButton", label: "send")))
        #expect(CUReplay.looksIrreversible(CUReplayStep(kind: .click, role: "AXButton", label: "move to trash")))
        #expect(!CUReplay.looksIrreversible(CUReplayStep(kind: .click, role: "AXButton", label: "new session")))
        #expect(!CUReplay.looksIrreversible(CUReplayStep(kind: .click, role: "AXButton", label: "sender details")))
    }

    @Test func aClickThatOpensAMenuIsNotTheGoal() {
        let closed = AXSnapshot(elements: [TypesafeCUTests.el("e1", "AXButton", "Local", x: 10, y: 10),
                                           TypesafeCUTests.el("e2", "AXPopUpButton", "Mode", x: 10, y: 40)])
        var open = closed
        open.elements += [TypesafeCUTests.el("m1", "AXMenuItem", "Local", x: 10, y: 60), TypesafeCUTests.el("m2", "AXMenuItem", "Cloud", x: 10, y: 80)]
        #expect(AgentRun.openedMenu(clicked: .click(elementID: "e1"), before: closed, after: open))
        #expect(AgentRun.openedMenu(clicked: .click(elementID: "e2"), before: closed, after: closed))
        #expect(!AgentRun.openedMenu(clicked: .click(elementID: "e1"), before: closed, after: closed))
        #expect(!AgentRun.openedMenu(clicked: .click(elementID: "m1"), before: open, after: closed))
    }

    // MARK: Small facts

    @Test func typedTextVerifiedByReadingItBack() {
        #expect(AgentRun.holdsTyped("hello world ", "hello world"))
        #expect(!AgentRun.holdsTyped("hello", "hello world"))
        #expect(!AgentRun.holdsTyped(nil, "x"))
        #expect(!AgentRun.holdsTyped("", ""))
    }

    @Test func agentActivityCountsRuns() {
        let before = AgentActivity.isBusy
        let end = AgentActivity.begin()
        #expect(AgentActivity.isBusy)
        end(); end()   // a second call does nothing
        #expect(AgentActivity.isBusy == before)
    }
}
