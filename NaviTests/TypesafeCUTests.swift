import CoreGraphics
import Foundation
import Testing
@testable import Navi

/// The native driver's decision core, ported from typesafe-computer-use
/// (vendor/typesafe-computer-use). Where upstream has a test, the case here is the same case
/// (tests/test_dates.py, test_signature.py, test_perception.py, test_decide.py), converted from
/// capture pixels at scale 2 to screen points. No network, no live Accessibility.
struct TypesafeCUTests {

    // MARK: Fixtures

    static let today = CUFacts.Day(year: 2026, month: 9, day: 16)
    static let window = CGRect(x: 0, y: 0, width: 1000, height: 600)

    static func item(_ i: Int, _ text: String, x1: CGFloat = 50, y1: CGFloat = 50, x2: CGFloat = 150, y2: CGFloat = 65,
                     role: String = "", source: CUItem.Source = .ocr, confidence: Double = 0.9) -> CUItem {
        CUItem(index: i, text: text, confidence: confidence, box: CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1), role: role, source: source)
    }

    static func el(_ id: String, _ role: String, _ label: String, x: CGFloat, y: CGFloat, w: CGFloat = 100, h: CGFloat = 20,
                   value: String? = nil, focused: Bool = false, options: [String] = []) -> AXElement {
        AXElement(id: id, role: role, label: label, value: value, frame: CGRect(x: x, y: y, width: w, height: h),
                  isFocused: focused, actions: ["AXPress"], pid: 42, options: options)
    }

    static var snapshot: AXSnapshot {
        var s = AXSnapshot(elements: [
            el("e1", "AXTextField", "Search", x: 10, y: 10, value: "", focused: true),
            el("e2", "AXButton", "Sign in", x: 800, y: 10),
            el("e3", "AXPopUpButton", "Size", x: 10, y: 60, value: "Medium", options: ["Small", "Medium", "Large"]),
            el("e4", "AXSecureTextField", "Password", x: 10, y: 100, value: "••••"),
            el("e5", "AXButton", "Buy", x: 800, y: 300, w: 40),
            el("e6", "AXButton", "Buy", x: 800, y: 400, w: 40),
        ], windowTitle: "Acme — Tickets", url: "https://acme.test/", focused: "e1",
        visibleText: "Coldplay\nOct 2\nBruno Mars", pid: 42, bundleID: "com.apple.Safari", appName: "Safari", windowFrame: window)
        s.texts = [AXTextLine(text: "Coldplay", frame: CGRect(x: 100, y: 300, width: 100, height: 20)),
                   AXTextLine(text: "Oct 2", frame: CGRect(x: 300, y: 300, width: 60, height: 20)),
                   AXTextLine(text: "Bruno Mars", frame: CGRect(x: 100, y: 400, width: 100, height: 20)),
                   AXTextLine(text: "Sep 25", frame: CGRect(x: 300, y: 400, width: 60, height: 20))]
        s.offscreen = [AXElement(id: "o1", role: "AXRow", label: "Groceries", frame: CGRect(x: 0, y: 9000, width: 200, height: 20), actions: ["AXPress"], pid: 42)]
        return s
    }

    static var screen: CUScreen { CUPerception.perceive(snapshot, ocr: nil, goal: "buy a ticket to Coldplay") }

    static func input(writer: Bool = true) -> CUDecide.Input {
        var i = CUDecide.Input(goal: "buy a ticket to Coldplay", screen: screen, history: ["opened https://acme.test/"])
        i.writerAvailable = writer
        i.today = today
        i.now = CUFacts.nowContext()
        i.apps = ["Notes"]
        i.sites = ["https://acme.test/"]
        return i
    }

    static func head(_ choice: String, _ confidence: Double) -> CUDecide.Head {
        CUDecide.Head(choice: choice, probabilities: [choice: confidence], confidence: confidence)
    }

    // MARK: Dates (test_dates.py)

    @Test func parsesCommonDateForms() {
        func d(_ s: String) -> String? { CUFacts.firstDate(in: s, today: Self.today)?.iso }
        #expect(d("October 13 - 15, 2026") == "2026-10-13")
        #expect(d("November 4, 2026") == "2026-11-04")
        #expect(d("Last day to book Sept 18") == "2026-09-18")
        #expect(d("Posted 9/1/2026") == "2026-09-01")
        #expect(d("2026-12-01 release") == "2026-12-01")
        #expect(d("4 Nov 2026") == "2026-11-04")
        #expect(d("Register Now") == nil)
        #expect(d("Feb 30") == nil)
        // A missing year rolls forward only when this year's date is well past.
        #expect(d("Jan 5") == "2027-01-05")
        #expect(d("Sep 1") == "2026-09-01")
    }

    @Test func describesOffsets() {
        #expect(CUFacts.describeOffset(.init(year: 2026, month: 9, day: 16), today: Self.today) == "2026-09-16 (today)")
        #expect(CUFacts.describeOffset(.init(year: 2026, month: 10, day: 13), today: Self.today) == "2026-10-13 (in 27 days)")
        #expect(CUFacts.describeOffset(.init(year: 2026, month: 9, day: 1), today: Self.today) == "2026-09-01 (15 days ago)")
    }

    @Test func neighboursInheritTheNearestDate() {
        let items = [
            Self.item(0, "TechCrunch Disrupt 2026 | October 13 - 15, 2026", y1: 662.5, y2: 677.5),
            Self.item(1, "Register Now", y1: 679.5, y2: 694.5),
            Self.item(2, "Founder Summit | November 4, 2026", y1: 800.5, y2: 815.5),
            Self.item(3, "Register Now", y1: 815.5, y2: 830.5),
            Self.item(4, "Footer", y1: 1200, y2: 1215),
        ]
        let hints = CUFacts.dateHints(items, today: Self.today)
        #expect(hints[0]?.hasPrefix("dated 2026-10-13") == true)
        #expect(hints[1] == "near a line dated 2026-10-13 (in 27 days)")
        #expect(hints[3] == "near a line dated 2026-11-04 (in 49 days)")
        #expect(hints[4] == nil)
    }

    @Test func theMenuBarClockDatesNothing() {
        let items = [
            Self.item(0, "Sep 16 01:54", x1: 475, y1: 4, x2: 520, y2: 15, role: "menu", source: .ax),
            Self.item(1, "Settings - Memory usage", y1: 33, y2: 54),
            Self.item(2, "Coldplay | Oct 2", y1: 300, y2: 315),
            Self.item(3, "Buy", y1: 320, y2: 335),
        ]
        #expect(CUFacts.dateHints(items, today: Self.today) == [2: "dated 2026-10-02 (in 16 days)", 3: "near a line dated 2026-10-02 (in 16 days)"])
    }

    // MARK: Screen identity (test_signature.py)

    static func sig(_ words: [String]) -> CUSignature { sig("Google Chrome", nil, nil, words) }
    static func sig(_ app: String, _ url: String?, _ focus: String?, _ words: [String]) -> CUSignature {
        CUSignature(app: app, url: url, focused: focus, lines: words.enumerated().map { .init(text: $0.element, row: $0.offset) })
    }

    @Test func aSignatureNamesTheAppThePageTheFocusAndTheTextInRows() {
        let field = CUField(role: "AXTextField", label: "Search", placeholder: "", value: "", frame: .zero)
        let s = CUSignature.of(app: "Google Chrome", url: "https://example.com/", field: field,
                               items: [Self.item(0, "Search", y1: 50, y2: 65), Self.item(1, "Go", y1: 150, y2: 170)])
        #expect(s.focused == "AXTextField:Search")
        #expect(s.lines == [.init(text: "Search", row: 3), .init(text: "Go", row: 8)])
    }

    @Test func sameScreenFollowsUpstreamRules() {
        let here = Self.sig("Google Chrome", "https://a/", nil, ["Home", "Tickets"])
        #expect(here.same(as: here))
        #expect(!here.same(as: Self.sig("Finder", "https://a/", nil, ["Home", "Tickets"])))
        #expect(!here.same(as: Self.sig("Google Chrome", "https://b/", nil, ["Home", "Tickets"])))
        #expect(!here.same(as: Self.sig("Google Chrome", "https://a/", "AXTextField:Search", ["Home", "Tickets"])))
        // A clock or a ticker is no new screen.
        let gates = (0..<9).map { "Gate \($0)" }
        #expect(Self.sig(gates + ["12:00"]).same(as: Self.sig(gates + ["12:01"])))
        // A small modal on a dense page is.
        let rows = (0..<40).map { "Row \($0)" }
        #expect(!Self.sig(rows).same(as: Self.sig(rows + ["Sign up for news", "Close"])))
        // One changed line on a short page is.
        #expect(!Self.sig("Notes", nil, nil, ["Next", "Step 1 of 3"]).same(as: Self.sig("Notes", nil, nil, ["Next", "Step 2 of 3"])))
        // A page that gained a section is.
        #expect(!Self.sig(["Home", "Tickets"]).same(as: Self.sig(["Home", "Tickets", "Buy", "Terms", "Dates"])))
        // A dense page scrolled by a tenth is: every line moved.
        let thirty = (0..<30).map { "Row \($0)" }
        #expect(!Self.sig(thirty).same(as: Self.sig(Array(thirty[3...]) + ["Row 30", "Row 31", "Row 32"])))
    }

    @Test func oneChangedLineOfTreeTextIsAChangeButOneOCRSlipIsNot() {
        func calc(_ display: String, _ source: CUItem.Source) -> CUSignature {
            let keys = (0..<20).map { Self.item($0 + 1, "key \($0)", y1: 100 + 20 * CGFloat($0), y2: 115 + 20 * CGFloat($0), role: "button", source: .ax) }
            return .of(app: "Calculator", url: nil, field: nil, items: [Self.item(0, display, y1: 50, y2: 65, source: source)] + keys)
        }
        #expect(!calc("57", .text).same(as: calc("57×2", .text)))   // a digit typed into the display
        #expect(calc("57", .ocr).same(as: calc("57x", .ocr)))        // an OCR slip on a busy screen
        #expect(AgentRun.asksForResult("open Calculator and compute 57 times 23"))
        #expect(AgentRun.asksForResult("open Finder and tell me how many files are in Downloads"))
        #expect(!AgentRun.asksForResult("make a new note titled groceries"))
    }

    @Test func aTabsMemoryFigureDoesNotMakeANewScreen() {
        func capture(_ tab: String, _ clock: String) -> CUSignature {
            let lines = [tab, clock] + (0..<9).map { "Setting \($0)" }
            return .of(app: "Google Chrome", url: nil, field: nil,
                       items: lines.enumerated().map { Self.item($0.offset, $0.element, y1: 50 + 20 * CGFloat($0.offset), y2: 65 + 20 * CGFloat($0.offset)) })
        }
        let before = capture("Settings - Memory usage - 56.0 MB", "Sep 29 03:07")
        #expect(before.same(as: capture("Settings - Memory usage - 57.3 MB", "Sep 29 03:08")))
        #expect(before.same(as: capture("Settings - High memory usage - 1.2 GB", "Sep 29 03:08")))
        #expect(before.lines[0].text == "Settings")
        #expect(!before.same(as: capture("Downloads - Memory usage - 56.0 MB", "Sep 29 03:08")))
    }

    // MARK: Stop rules (runner.py)

    @Test func triedHereListsWhatWasTakenOnThisScreen() {
        let home = Self.sig("Google Chrome", "https://a/", nil, ["Home", "Tickets", "Blog"])
        let blog = Self.sig("Google Chrome", "https://a/blog", nil, ["Blog", "Posts"])
        var run = CURunState()
        run.last = home
        run.seen = [(home, "clicked 'Blog'"), (blog, "went back"), (home, "clicked 'Tickets'")]
        #expect(run.triedHere() == ["clicked 'Blog'", "clicked 'Tickets'"])
        #expect(CURunState().triedHere().isEmpty)
    }

    @Test func aWaitIsNeverARepeatAndTwoRepeatsStall() {
        var run = CURunState()
        _ = run.screenMoved(Self.sig(["Loading..."]))
        var stalled: [Bool] = []
        for _ in 0...CURunState.maxRepeats { stalled.append(run.recordAction("waited", waiting: true)) }
        #expect(stalled == [false, false, false])
        #expect(run.triedHere().isEmpty)
        let first = run.recordAction("clicked 'Buy'", waiting: false)    // the first time on this screen
        let second = run.recordAction("clicked 'Buy'", waiting: false)   // one repeat is a warning shot
        let third = run.recordAction("clicked 'Buy'", waiting: false)    // the second in a row stalls
        #expect(!first && !second && third)
        #expect(run.history.count == CURunState.maxRepeats + 4)
    }

    @Test func threeUnchangedScreensStallAndANewPageResetsTheStallCount() {
        var run = CURunState()
        let page = Self.sig("Google Chrome", "https://a/", nil, ["Home"])
        var moved: [Bool] = []
        for _ in 0..<4 { moved.append(run.screenMoved(page)) }
        #expect(moved == [true, true, true, false])          // the third action that changed nothing stalls
        var outcomes: [CURunState.Outcome] = []
        for _ in 0..<3 { outcomes.append(run.countStall(.stalled)) }
        #expect(outcomes == [.stalled, .stalled, .stuck])    // third stall with no new page: final
        let done = run.countStall(.done)
        #expect(done == .done)
        let fresh = run.screenMoved(Self.sig("Google Chrome", "https://b/", nil, ["Checkout"]))
        #expect(fresh && run.stalls == 0)
        run.refocus(.init(step: 3, outcome: .stalled, focus: "Click 'Buy'", actions: 2))
        #expect(run.guidance.focus == "Click 'Buy'" && run.idle == 0 && run.repeats == 0)
        #expect((run.earlierStops.first?["focus_given"] as? String) == "Click 'Buy'")
    }

    @Test func earlierScreensAreTheDistinctOnesBeforeTheLast() {
        let home = Self.sig("Google Chrome", "https://a/", nil, ["Home", "Tickets"])
        let rows = (0..<9).map { "Row \($0)" }
        let tickets = Self.sig("Google Chrome", "https://a/tickets", nil, ["Standard $45"] + rows + ["12:00"])
        let later = Self.sig("Google Chrome", "https://a/tickets", nil, ["Standard $45"] + rows + ["12:01"])
        let checkout = Self.sig("Google Chrome", "https://a/checkout", nil, ["Order summary", "Pay now"])
        var run = CURunState()
        run.seen = [(home, "clicked 'Tickets'"), (tickets, "waited"), (later, "clicked 'Buy'")]
        let all = run.earlierScreens(final: checkout)
        #expect(all.map { $0["url"] as? String } == ["https://a/", "https://a/tickets"])
        #expect((all.last?["text"] as? [String])?.last == "12:01")
        #expect(run.earlierScreens(final: checkout, budget: 12).map { $0["url"] as? String } == ["https://a/tickets"])
        #expect(run.earlierScreens(final: tickets).map { $0["url"] as? String } == ["https://a/"])
    }

    // MARK: Perception (test_perception.py)

    @Test func stackedLinesMergeIntoBlocks() {
        func line(_ t: String, _ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ c: Double = 1) -> CUOCRLine {
            CUOCRLine(text: t, confidence: c, box: CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1))
        }
        let merged = CUPerception.mergeBlocks([
            line("Kash Patel defends", 1080, 1531, 1300, 1561), line("Two House Democrats", 1400, 1531, 1600, 1561),
            line("removing bestiality as", 1075, 1571, 1300, 1601), line("defect again on key vote", 1400, 1571, 1600, 1601),
            line("FBI applicants", 1080, 1606, 1300, 1636),
        ]).map(\.text).sorted()
        #expect(merged == ["Kash Patel defends removing bestiality as FBI applicants", "Two House Democrats defect again on key vote"])
        #expect(CUPerception.mergeBlocks([line("Home", 100, 100, 200, 130), line("World", 400, 100, 500, 130), line("Footer", 100, 900, 200, 930)]).count == 3)
        let one = CUPerception.mergeBlocks([line("a", 100, 100, 200, 130), line("b", 102, 140, 260, 170, 0.5)])
        #expect(one.count == 1 && one[0].text == "a b" && one[0].confidence == 0.5 && one[0].box == CGRect(x: 100, y: 100, width: 160, height: 70))
    }

    @Test func goalEchoMatchesWrappedCommandLines() {
        let echoes = CUFacts.goalEchoes("go to cnn and click onto something related to AI on the homepage")
        #expect(CUFacts.isEcho("clear && uv run clicker \"go to cnn and click onto something", echoes: echoes))
        #expect(CUFacts.isEcho("related to AI on the homepage\" --act", echoes: echoes))
        #expect(!CUFacts.isEcho("Trending: Trump and AI warnings", echoes: echoes))
    }

    static func merge(_ plain: [CUItem], _ controls: [CUItem], budget: Int = 255) -> [CUItem] {
        CUPerception.mergeWithOrigins(plain: plain, controls: controls.map { ($0, "e\($0.index)") }, budget: budget).map(\.0)
    }

    @Test func mergeFoldsAControlOntoTheTextThatNamesIt() {
        let block = Self.item(0, "Register Now", x1: 100, y1: 100, x2: 300, y2: 130)
        let control = Self.item(0, "Register Now for Disrupt", x1: 110, y1: 102, x2: 290, y2: 128, role: "link", source: .ax)
        let merged = Self.merge([block], [control])
        #expect(merged.count == 1 && merged[0].source == .axOCR && merged[0].role == "link")
        #expect(merged[0].text == "Register Now for Disrupt")
        #expect(merged[0].box == block.box)
        // Shared words count, not only containment.
        #expect(Self.merge([Self.item(0, "Buy tickets now", x1: 100, y1: 100, x2: 300, y2: 130)],
                           [Self.item(0, "Buy tickets", x1: 100, y1: 100, x2: 300, y2: 130, role: "button", source: .ax)]).map(\.source) == [.axOCR])
        // Overlapping boxes, disagreeing text: both stay. Agreeing text, boxes apart: both stay.
        #expect(Self.merge([Self.item(0, "Search the docs", x1: 100, y1: 100, x2: 300, y2: 130)],
                           [Self.item(0, "Clear input", x1: 100, y1: 100, x2: 300, y2: 130, role: "button", source: .ax)]).count == 2)
        #expect(Self.merge([Self.item(0, "Share", x1: 100, y1: 100, x2: 200, y2: 130)],
                           [Self.item(0, "Share", x1: 900, y1: 600, x2: 960, y2: 630, role: "button", source: .ax)]).count == 2)
        // Each block is consumed once.
        let sends = Self.merge([Self.item(0, "Send", x1: 100, y1: 100, x2: 200, y2: 130)],
                               [Self.item(0, "Send", x1: 100, y1: 100, x2: 200, y2: 130, role: "button", source: .ax),
                                Self.item(1, "Send", x1: 104, y1: 104, x2: 196, y2: 126, role: "button", source: .ax)])
        #expect(sends.map(\.source.rawValue).sorted() == ["ax", "ax+ocr"])
    }

    @Test func aButtonOrLinkStandsForTheSymbolReadOffItsIcon() {
        let icons = Self.merge([Self.item(0, "\u{00d7}", x1: 1893, y1: 43, x2: 1901, y2: 51), Self.item(1, "▶", x1: 1305, y1: 458, x2: 1309, y2: 466)],
                               [Self.item(0, "Close", x1: 1882, y1: 27, x2: 1920, y2: 62, role: "button", source: .ax),
                                Self.item(1, "Security", x1: 1291, y1: 446, x2: 1323, y2: 479, role: "link", source: .ax)])
        #expect(icons.map(\.text) == ["Close", "Security"])
        // A symbol on a tab or a row, and anything with a letter or digit, stays.
        let kept = Self.merge([Self.item(0, "\u{00d7}", x1: 300, y1: 40, x2: 310, y2: 50), Self.item(1, "+", x1: 100, y1: 240, x2: 110, y2: 250),
                               Self.item(2, "C", x1: 164, y1: 84, x2: 170, y2: 96), Self.item(3, "25", x1: 1300, y1: 500, x2: 1320, y2: 520)],
                              [Self.item(0, "Settings", x1: 130, y1: 30, x2: 320, y2: 60, role: "tab", source: .ax),
                               Self.item(1, "Downloads", x1: 90, y1: 230, x2: 1000, y2: 260, role: "cell", source: .ax),
                               Self.item(2, "Reload", x1: 147, y1: 73, x2: 181, y2: 107, role: "button", source: .ax),
                               Self.item(3, "Show per page", x1: 1290, y1: 490, x2: 1400, y2: 530, role: "field", source: .ax)])
        #expect(kept.count == 8)
    }

    @Test func mergeNumbersInReadingOrderAndTheBudgetDropsFaintTextFirst() {
        let ordered = Self.merge([Self.item(0, "below", x1: 100, y1: 300, x2: 200, y2: 330), Self.item(1, "right", x1: 800, y1: 100, x2: 900, y2: 130)],
                                 [Self.item(0, "left", x1: 100, y1: 105, x2: 200, y2: 135, role: "button", source: .ax)])
        #expect(ordered.map { "\($0.index) \($0.text)" } == ["0 left", "1 right", "2 below"])
        let faint = (0..<3).map { i in Self.item(i, "text \(i)", x1: 100, y1: 100 + 40 * CGFloat(i), x2: 200, y2: 130 + 40 * CGFloat(i), confidence: 0.3 + 0.1 * Double(i)) }
        #expect(Self.merge(faint, [Self.item(0, "Send", x1: 800, y1: 100, x2: 900, y2: 130, role: "button", source: .ax)], budget: 2).map(\.text).sorted() == ["Send", "text 2"])
        let controls = (0..<4).map { i in Self.item(i, "control \(i)", x1: 100, y1: 100 + 40 * CGFloat(i), x2: 200, y2: 130 + 40 * CGFloat(i), role: "button", source: .ax) }
        #expect(Self.merge([], controls, budget: 2).count == 2)
    }

    @Test func perceptionTurnsTheTreeIntoOneItemList() {
        let s = Self.screen
        // Controls and static text lines are items; the secure field keeps its role but is never editable.
        #expect(s.items.contains { $0.text == "Coldplay" && $0.source == .text })
        #expect(s.items.contains { $0.text == "Sign in" && $0.fromAX })
        #expect(s.editableItems.map(\.text) == ["Search"])
        #expect(s.selectableItems.map(\.text) == ["Size"])
        #expect(s.field?.label == "Search")
        // A list row's name field (Notes' "Quick Notes" folder) is clickable but never typed into…
        var rows = Self.snapshot
        rows.elements.append(AXElement(id: "e7", role: "AXTextField", label: "Quick Notes", value: "Quick Notes",
                                       frame: CGRect(x: 10, y: 200, width: 150, height: 20), actions: ["AXPress"], inRow: true))
        let listed = CUPerception.perceive(rows, ocr: nil, goal: "x")
        #expect(listed.items.contains { $0.text == "Quick Notes" })
        #expect(!listed.editableItems.contains { $0.text == "Quick Notes" })
        // …unless it is being edited.
        rows.elements[6].isFocused = true
        #expect(CUPerception.perceive(rows, ocr: nil, goal: "x").editableItems.contains { $0.text == "Quick Notes" })
        // Text inside the focused one-line field is the field's, not an item of its own.
        var snap = Self.snapshot
        snap.texts.append(AXTextLine(text: "jev", frame: CGRect(x: 20, y: 12, width: 30, height: 16)))
        #expect(!CUPerception.perceive(snap, ocr: nil, goal: "x").items.contains { $0.text == "jev" })
        // An OCR block the tree already carries is not a second item; one it lacks is.
        let ocr = [CUOCRLine(text: "Coldplay", confidence: 0.9, box: CGRect(x: 101, y: 301, width: 98, height: 18)),
                   CUOCRLine(text: "Sold out", confidence: 0.9, box: CGRect(x: 700, y: 500, width: 80, height: 18))]
        let withOCR = CUPerception.perceive(Self.snapshot, ocr: ocr, goal: "x")
        #expect(withOCR.items.filter { $0.text == "Coldplay" }.count == 1)
        #expect(withOCR.items.contains { $0.text == "Sold out" && $0.source == .ocr })
        #expect(withOCR.usedOCR)
    }

    @Test func ocrRunsWhereTheTreeIsThin() {
        #expect(!CUOCRPolicy.wantsOCR(Self.snapshot))
        #expect(CUOCRPolicy.wantsOCR(AXSnapshot(elements: [], bundleID: "com.apple.Notes")))
        #expect(CUOCRPolicy.wantsOCR(AXSnapshot(elements: Self.snapshot.elements, bundleID: "com.spotify.client")))
        let a = [UInt8](repeating: 10, count: 64 * 64), b = a
        var c = a
        for i in 0..<32 { c[i * 64 + 5] = 250; c[i * 64 + 6] = 250; c[i * 64 + 7] = 250 }
        #expect(!CUOCRReader.changed(a, b, w: 64, h: 64))
        #expect(CUOCRReader.changed(a, c, w: 64, h: 64))
    }

    // MARK: Rows and criteria (test_decide.py)

    @Test func aDuplicatedLabelNamesItsRowAndAUniqueOneDoesNot() {
        let items = [
            Self.item(0, "Bruno Mars", x1: 50, x2: 150), Self.item(1, "Sep 25", x1: 160, x2: 200), Self.item(2, "Buy", x1: 210, x2: 240),
            Self.item(3, "Coldplay", x1: 50, y1: 100, x2: 150, y2: 115), Self.item(4, "Oct 2", x1: 160, y1: 100, x2: 200, y2: 115),
            Self.item(5, "Buy", x1: 210, y1: 100, x2: 240, y2: 115), Self.item(6, "Terms", y1: 150, y2: 165),
        ]
        #expect(CUFacts.rowMates(items) == [2: ["Bruno Mars", "Sep 25"], 5: ["Coldplay", "Oct 2"]])
        let wide = (0..<5).map { Self.item($0, "Col \($0)", x1: 50 + 30 * CGFloat($0), x2: 75 + 30 * CGFloat($0)) }
            + [Self.item(5, "Buy", x1: 210, x2: 240), Self.item(6, "Buy", x1: 210, y1: 100, x2: 240, y2: 115)]
        #expect(CUFacts.rowMates(wide)[5] == ["Col 0", "Col 1", "Col 2"])
        #expect(CUFacts.rowMates(wide, limit: nil)[5] == (0..<5).map { "Col \($0)" })
    }

    @Test func itemCriteriaCarryRoleRegionRowDateAndState() throws {
        let input = Self.input()
        let crit = CUDecide.itemCriteria(input)
        let items = input.screen.items
        let buyInColdplayRow = try #require(items.first { $0.text == "Buy" && abs($0.center.y - 310) < 5 })
        #expect(crit["\(buyInColdplayRow.index)"] == "button 'Buy' (middle-right; near a line dated 2026-10-02 (in 16 days); in the row of 'Coldplay', 'Oct 2')")
        let search = try #require(items.first { $0.text == "Search" })
        #expect(crit["\(search.index)"] == "field 'Search' (top-left; focused)")
        let oct = try #require(items.first { $0.text == "Oct 2" })
        #expect(crit["\(oct.index)"]?.hasPrefix("'Oct 2' (") == true)   // plain text carries no role
        let state = CUDecide.state(input)
        let rows = try #require(state["screen_items_in_reading_order"] as? [[String: Any]])
        #expect((rows[buyInColdplayRow.index]["beside"] as? [String]) == ["Coldplay", "Oct 2"])
        #expect(state["previous_actions"] as? [String] == ["opened https://acme.test/"])
        #expect((state["focused_field"] as? [String: Any])?["label"] as? String == "Search")
        #expect(state["current_focus"] == nil)
        #expect((state["offscreen_controls"] as? [[String: Any]])?.first?["label"] as? String == "Groceries")
    }

    // MARK: The request

    @Test func theRequestOffersOnlyWhatCanBeDone() throws {
        let req = CUDecide.request(Self.input())
        let kinds = try #require(req.offered["kind"])
        for k in ["click_item", "press_offscreen", "type_text", "choose_option", "press_shortcut", "open_app", "use_browser",
                  "press_enter", "press_escape", "go_back", "scroll_down", "scroll_up", "wait", "done", "none"] {
            #expect(kinds.contains(k), "missing \(k)")
        }
        #expect(req.offered["field"]?.count == 1)
        #expect(req.offered["option"] == ["\(Self.screen.selectableItems[0].index):1", "\(Self.screen.selectableItems[0].index):2", "\(Self.screen.selectableItems[0].index):3"])
        #expect(req.offered["site"]?.sorted() == ["none", "other", "u1"])
        #expect(!req.shortcutTargets.values.contains { ["return", "escape", "enter"].contains($0.lowercased()) })
        #expect(req.questions["is_irreversible"] != nil && req.questions["is_prohibited"] != nil)
        for (name, ids) in req.offered { #expect(ids.count <= 255, "\(name) offers \(ids.count)") }

        // No writer: nothing to type with, and no site the goal does not name.
        let bare = CUDecide.request(Self.input(writer: false))
        #expect(bare.offered["kind"]?.contains("type_text") == false)
        #expect(bare.offered["field"] == nil)
        #expect(bare.offered["site"]?.contains("other") == false)
        var quoted = Self.input(writer: false)
        quoted.goalSpellsText = true                          // "type 'hello' in the search box"
        #expect(CUDecide.request(quoted).offered["kind"]?.contains("type_text") == true)

        // No off-screen controls: no press_offscreen.
        var input = Self.input()
        input.screen.snapshot.offscreen = []
        #expect(CUDecide.request(input).offered["kind"]?.contains("press_offscreen") == false)
    }

    @Test func theFocusRuleIsSaidOnlyWhileAFocusIsSet() throws {
        var input = Self.input()
        func kindInstructions(_ r: CUDecide.Request) throws -> String {
            guard case .choice(let i, _) = try #require(r.questions["kind"]) else { throw CancellationError() }
            return i
        }
        #expect(try !kindInstructions(CUDecide.request(input)).contains("current focus"))
        input.guidance = CUGuidance(focus: "Click the 'Arrives in 2-4 days' filter")
        let req = CUDecide.request(input)
        #expect(try kindInstructions(req).contains("current focus"))
        #expect(req.state["current_focus"] as? String == "Click the 'Arrives in 2-4 days' filter")
    }

    // MARK: Decisions (test_decide.py `Decision`)

    static func verdict(_ heads: [String: CUDecide.Head]) -> CUDecide.Verdict { CUDecide.Verdict(heads: heads) }

    @Test func aClickTakesTheLowerOfTheKindAndTheItem() throws {
        let req = CUDecide.request(Self.input())
        let item = try #require(req.offered["item"]?.first)
        let d = try #require(CUDecide.decision(Self.verdict(["kind": Self.head("click_item", 0.9), "item": Self.head(item, 0.6)]), request: req))
        #expect(d.confidence == 0.6 && d.chosen == "click_item \(item)" && !d.stops)
        // A fixed action ignores any item answer.
        let s = try #require(CUDecide.decision(Self.verdict(["kind": Self.head("scroll_down", 0.8), "item": Self.head(item, 0.1)]), request: req))
        #expect(s.confidence == 0.8 && s.target == nil)
        // use_browser reads the site but a split there does not lower the confidence.
        let b = try #require(CUDecide.decision(Self.verdict(["kind": Self.head("use_browser", 0.88), "site": Self.head("other", 0.45)]), request: req))
        #expect(b.confidence == 0.88)
        // press_offscreen takes the offscreen answer.
        let o = try #require(CUDecide.decision(Self.verdict(["kind": Self.head("press_offscreen", 0.9), "offscreen": Self.head("0", 0.5)]), request: req))
        #expect(o.confidence == 0.5)
        // done and none stop.
        #expect(CUDecide.decision(Self.verdict(["kind": Self.head("done", 0.9)]), request: req)?.stops == true)
        #expect(CUDecide.decision(Self.verdict(["kind": Self.head("none", 0.9)]), request: req)?.stops == true)
        // An answer the loop cannot execute is no decision: unoffered kind, missing or unoffered target.
        #expect(CUDecide.decision(Self.verdict(["kind": Self.head("right_click", 0.9)]), request: req) == nil)
        #expect(CUDecide.decision(Self.verdict(["kind": Self.head("click_item", 0.9)]), request: req) == nil)
        #expect(CUDecide.decision(Self.verdict(["kind": Self.head("click_item", 0.9), "item": Self.head("999", 0.9)]), request: req) == nil)
    }

    @Test func movesMapEachKindToAnAction() throws {
        let input = Self.input()
        let req = CUDecide.request(input)
        let screen = input.screen
        func move(_ kind: String, _ target: (String, String)? = nil) -> CUDecide.Move? {
            var heads = ["kind": Self.head(kind, 0.9)]
            if let target { heads[target.0] = Self.head(target.1, 0.9) }
            return CUDecide.decision(Self.verdict(heads), request: req).flatMap { CUDecide.move($0, request: req, screen: screen, browserName: "Safari") }
        }
        let signIn = try #require(screen.items.first { $0.text == "Sign in" })
        #expect(move("click_item", ("item", "\(signIn.index)")) == .act(.click(elementID: "e2")))
        let text = try #require(screen.items.first { $0.text == "Coldplay" })
        #expect(move("click_item", ("item", "\(text.index)")) == .act(.clickPoint(x: 150, y: 310, label: "Coldplay")))
        #expect(move("press_offscreen", ("offscreen", "0")) == .act(.press(elementID: "o1")))
        #expect(move("type_text", ("field", "\(screen.editableItems[0].index)")) == .act(.typeText(elementID: "e1")))
        #expect(move("choose_option", ("option", "\(screen.selectableItems[0].index):3")) == .act(.select(elementID: "e3", option: "Large")))
        #expect(move("open_app", ("app", "a1")) == .act(.openApp("Notes")))
        #expect(move("use_browser", ("site", "u1")) == .act(.openURL("https://acme.test/")))
        #expect(move("use_browser", ("site", "other")) == .proposeURL)
        #expect(move("use_browser", ("site", "none")) == .act(.openApp("Safari")))
        #expect(move("press_enter") == .act(.key("Return")))
        #expect(move("press_escape") == .act(.key("Escape")))
        #expect(move("go_back") == .act(.key("cmd+[")))
        #expect(move("scroll_down") == .act(.scroll(up: false)))
        #expect(move("wait") == .act(.wait))
        #expect(move("done") == .stop(.done))
        let shortcut = try #require(req.shortcutTargets.first { $0.value == "cmd+n" }?.key)
        #expect(move("press_shortcut", ("shortcut", shortcut)) == .act(.key("cmd+n")))
    }

    @Test func historyLinesTellRowsApart() throws {
        let screen = Self.screen
        let buy = try #require(screen.items.first { $0.text == "Buy" && abs($0.center.y - 410) < 5 })
        let d = CUDecide.Decision(kind: .clickItem, kindHead: Self.head("click_item", 0.9), target: Self.head("\(buy.index)", 0.9))
        let id = try #require(screen.elementForItem[buy.index])
        #expect(AgentRun.historyLine(.click(elementID: id), decision: d, screen: screen, text: nil) == "clicked 'Buy' beside 'Bruno Mars', 'Sep 25'")
        let w = CUDecide.Decision(kind: .goBack, kindHead: Self.head("go_back", 0.9))
        #expect(AgentRun.historyLine(.key("cmd+["), decision: w, screen: screen, text: nil) == "went back")
        #expect(AgentRun.historyLine(.key("Return"), decision: w, screen: screen, text: nil) == "pressed Return")
    }

    @Test func approvalsStillGoThroughJevGate() {
        var v = CUDecide.Verdict()
        v.isProhibited = 0.9
        let g = CUDecide.gateVerdict(v, actionText: "Click ‘Sign in’")
        #expect(g.source == .jev && g.isProhibited == 0.9)
        if case .askApproval = JevGate.decide(g, mode: .autonomous, readOnlyTurn: false) {} else { Issue.record("prohibited must ask even when autonomous") }
        let g2 = CUDecide.gateVerdict(CUDecide.Verdict(), actionText: "Click ‘Buy now’")
        #expect(g2.keywordHit == "buy" && g2.isProhibited == 1)
        var irr = CUDecide.Verdict()
        irr.isIrreversible = 0.8
        if case .askApproval = JevGate.decide(CUDecide.gateVerdict(irr, actionText: "Click ‘Send’"), mode: .askForRisky, readOnlyTurn: false) {} else {
            Issue.record("irreversible should ask")
        }
        #expect(CUDecide.statusLine(nil, latencyMs: 12) == "Jev · no usable answer · 12 ms")
        let d = CUDecide.Decision(kind: .clickItem, kindHead: Self.head("click_item", 0.91), target: Self.head("2", 0.95))
        #expect(CUDecide.statusLine(d, latencyMs: 118) == "Jev · click_item [2] 91% · 118 ms")
    }

    // MARK: The writer (writer.py)

    @Test func theWriterNeverTypesACredentialAndNeverSubmitsATextArea() {
        #expect(CUWriter.looksCredential("Password"))
        #expect(CUWriter.looksCredential("Enter your PIN"))
        #expect(CUWriter.looksCredential("Card number"))
        #expect(!CUWriter.looksCredential("Spinner speed"))
        #expect(!CUWriter.looksCredential("Search"))
        #expect(CUWriter.parseFill(["fill": true, "text": " hello ", "reason": "", "submit": true], role: "AXTextField") == .init(text: "hello", submit: true))
        #expect(CUWriter.parseFill(["fill": true, "text": "line", "reason": "", "submit": true], role: "AXTextArea") == .init(text: "line", submit: false))
        #expect(CUWriter.parseFill(["fill": false, "text": "x", "reason": "credential", "submit": true], role: "AXTextField") == .init(text: "", submit: false))
        #expect(CUWriter.parseFill(["text": "x"], role: "AXTextField") == nil)
    }

    @Test func onlyACleanHTTPSURLIsOpened() {
        #expect(CUWriter.validURL("https://www.youtube.com/results?search_query=lofi"))
        #expect(!CUWriter.validURL("http://example.com"))
        #expect(!CUWriter.validURL("https://localhost"))
        #expect(!CUWriter.validURL("https://exa mple.com"))
        #expect(!CUWriter.validURL("javascript:alert(1)"))
    }

    @Test func theAnswerCarriesAchievedFocusAndQuestion() {
        #expect(CUWriter.parseAnswer(["achieved": false, "answer": " Not yet. ", "focus": "Click 'Filters'", "question": ""])
                == .init(text: "Not yet.", achieved: false, focus: "Click 'Filters'", question: ""))
        #expect(CUWriter.parseAnswer(["answer": "x"]) == nil)
        #expect(ClaudeClient.firstJSONObject(in: "Sure — {\"achieved\": true, \"answer\": \"a {b}\"} trailing")?["answer"] as? String == "a {b}")
        #expect(ClaudeClient.firstJSONObject(in: "{\"cut\": ") == nil)
        let packet = CUWriter.answerPacket(goal: "g", screen: Self.screen, history: ["clicked 'Buy'"], stopped: CURunState.Outcome.done.told,
                                           earlier: [], guidance: CUGuidance(focus: "f"), earlierStops: [], canAsk: true, spoken: true, conversation: [])
        #expect(packet["current_focus"] as? String == "f" && packet["user_can_be_asked"] as? Bool == true && packet["spoken"] as? Bool == true)
        #expect(packet["earlier_screens"] == nil)
        #expect(JSONSerialization.isValidJSONObject(CURunFolder.jsonSafe(packet)))
        #expect(CUCalls(jev: 14, jevMs: 3900, writer: 3, writerMs: 21400).line(handoffs: 1) == "calls: jev 14 (82%, 3.9s)  writer 3 (17%, 21.4s)  handoffs 1")
    }
}
