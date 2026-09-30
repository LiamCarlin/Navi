import Testing
import Foundation
import CoreGraphics
@testable import Navi

/// What the native driver stands on besides its decision core (`TypesafeCUTests`):
/// text candidates, the AX walk's ranking and diff, action descriptions, typing checks.
/// No network, no live Accessibility.
struct AgentSupportTests {

    // MARK: Fixtures

    static func el(_ id: String, _ role: String, _ label: String, x: CGFloat = 0, y: CGFloat = 0,
                   w: CGFloat = 100, h: CGFloat = 20, value: String? = nil, focused: Bool = false,
                   path: String = "", options: [String] = []) -> AXElement {
        AXElement(id: id, role: role, label: label, value: value, frame: CGRect(x: x, y: y, width: w, height: h),
                  isFocused: focused, path: path, actions: ["AXPress"], pid: 42, options: options)
    }

    static var snapshot: AXSnapshot {
        AXSnapshot(elements: [
            el("e1", "AXTextField", "Search", x: 10, y: 10, value: "", focused: true, path: "Toolbar"),
            el("e2", "AXButton", "Sign in", x: 200, y: 10),
            el("e3", "AXPopUpButton", "Size", x: 10, y: 50, value: "Medium", options: ["Small", "Medium", "Large"]),
            el("e4", "AXSecureTextField", "Password", x: 10, y: 90, value: "••••"),
            el("e5", "AXMenuBarItem", "File", x: 40, y: 0, path: "Menu bar"),
        ], windowTitle: "Acme — Home", url: "https://acme.test/", focused: "e1",
        visibleText: "Welcome back\nSign in to continue", pid: 42, bundleID: "com.apple.Safari", appName: "Safari",
        windowFrame: CGRect(x: 0, y: 0, width: 1200, height: 800))
    }


    @Test func typingNotesOnlyWhenKeystrokesWentNowhere() {
        typealias F = AXSnapshotter.FocusedField
        // Landed: the field changed.
        #expect(AXSnapshotter.typingNote(before: F(role: "AXTextArea", value: ""), after: F(role: "AXTextArea", value: "good night"), text: "good night") == nil)
        // Landed: the value is unreadable (no evidence) — assume fine.
        #expect(AXSnapshotter.typingNote(before: F(role: "AXTextArea", value: nil), after: F(role: "AXTextArea", value: nil), text: "hi") == nil)
        // Landed: focus was created by the typing (a search field appearing).
        #expect(AXSnapshotter.typingNote(before: nil, after: F(role: "AXTextField", value: "hi"), text: "hi") == nil)
        // Not landed: a text field that didn't change.
        #expect(AXSnapshotter.typingNote(before: F(role: "AXTextArea", value: "old"), after: F(role: "AXTextArea", value: "old"), text: "new words") != nil)
        // Not landed: nothing focused, or a button.
        #expect(AXSnapshotter.typingNote(before: nil, after: nil, text: "hi") != nil)
        #expect(AXSnapshotter.typingNote(before: F(role: "AXButton", value: nil), after: F(role: "AXButton", value: nil), text: "hi") != nil)
        // Unknown roles (web areas, custom editors) get the benefit of the doubt.
        #expect(AXSnapshotter.typingNote(before: F(role: "AXWebArea", value: nil), after: F(role: "AXWebArea", value: nil), text: "hi") == nil)
        #expect(ActionExecutor.textLanded("good night", before: "", after: "good night"))
        #expect(ActionExecutor.textLanded("good night", before: "good night", after: "good night"))   // ⌘A + retype of the same text
        #expect(!ActionExecutor.textLanded("good night", before: "draft", after: "draft"))
    }

    @Test func aLookOnlyClaudeTurnIsRecordedAsSuch() {
        #expect(AgentRun.lookedOnly("Done: the message is already visible as a sent bubble") == "Looked only, took no action — observed: the message is already visible as a sent bubble")
        #expect(AgentRun.lookedOnly("Did: nothing (took a screenshot only)") == "Looked only, took no action — observed: nothing (took a screenshot only)")
        #expect(AgentRun.lookedOnly("") == "Looked only, took no action.")
    }

    @Test func humanDescriptions() {
        let s = Self.snapshot
        #expect(AgentAction.click(elementID: "e2").human(in: s) == "Click ‘Sign in’")
        #expect(AgentAction.typeText(elementID: "e1").human(in: s, text: "jev") == "Type ‘jev’ into ‘Search’")
        #expect(AgentAction.key("cmd+l").human(in: s) == "Press ⌘L")
        #expect(AgentAction.select(elementID: "e3", option: "Large").human(in: s) == "Select ‘Large’ in ‘Size’")
        #expect(AgentAction.openApp("Notes").human(in: s) == "Open Notes")
        #expect(AgentAction.clickPoint(x: 10, y: 20, label: "Oct 13 · Coldplay").human(in: s) == "Click ‘Oct 13 · Coldplay’")
        #expect(AgentAction.press(elementID: "o1").human(in: s) == "Press o1 (off screen)")
        #expect(AgentAction.key("Return").settleMs == 500 && AgentAction.click(elementID: "e1").settleMs == 250)
        #expect(AgentRun.summary(["Open Safari", "Click ‘Search’"]) == "Completed in 2 steps: Open Safari · Click ‘Search’")
    }

    @Test func menuBarWalkOnlyWhenTaskMentionsMenus() {
        #expect(AXSnapshot.taskMentionsMenu("File → Export as PDF"))
        #expect(AXSnapshot.taskMentionsMenu("open the view menu"))
        #expect(AXSnapshot.taskMentionsMenu("save as budget.numbers"))
        #expect(!AXSnapshot.taskMentionsMenu("search for jev and click the first result"))
        #expect(!AXSnapshot.taskMentionsMenu("reply to bob"))
    }

    @Test func extractsDoubleQuoted() {
        let c = TextCandidates.extract(task: "search for \"typesafe jev\" on google")
        #expect(c.first?.text == "typesafe jev" && c.first?.source == "quoted")
        #expect(c.first?.id == "t1")
    }

    @Test func extractsCurlyAndSingleQuotes() {
        let c = TextCandidates.extract(task: "name it “Q3 plan” and reply with 'sounds good'")
        let texts = c.map(\.text)
        #expect(texts.contains("Q3 plan") && texts.contains("sounds good"))
    }

    @Test func apostrophesAreNotQuotes() {
        let c = TextCandidates.extract(task: "don't open Bob's file, open 'notes'")
        #expect(c.filter { $0.source == "quoted" }.map(\.text) == ["notes"])
    }

    @Test func extractsVerbPhrases() {
        #expect(TextCandidates.verbPhrases(in: "open chrome and search for funny cats, then click the first one") == ["funny cats"])
        #expect(TextCandidates.verbPhrases(in: "type hello world in notes") == ["hello world"])   // "in" ends the phrase
        #expect(TextCandidates.verbPhrases(in: "rename to Budget 2026") == ["Budget 2026"])
    }

    @Test func extractsURLsAndDomains() {
        let c = TextCandidates.extract(task: "go to https://github.com/browser-use/jev-ultrafast and star it")
        #expect(c.contains { $0.text == "https://github.com/browser-use/jev-ultrafast" && $0.source == "url" })
        #expect(c.contains { $0.text == "github.com" && $0.source == "domain" })
        #expect(TextCandidates.urls(in: "open apple.com").first == "apple.com")
        #expect(TextCandidates.domain(of: "https://x.y.com/a/b") == "x.y.com")
    }

    @Test func obviousFieldIsTheOnlyEmptyTextField() {
        let snap = AXSnapshot(elements: [
            Self.el("e1", "AXButton", "Search"),
            Self.el("e2", "AXTextField", "Where from?"),
        ])
        #expect(FieldText.obviousField(in: snap)?.id == "e2")
    }

    @Test func obviousFieldPrefersTheFocusedOne() {
        var from = Self.el("e1", "AXTextField", "Where from?")
        var to = Self.el("e2", "AXTextField", "Where to?")
        #expect(FieldText.obviousField(in: AXSnapshot(elements: [from, to])) == nil)   // two candidates: don't guess
        to.isFocused = true
        #expect(FieldText.obviousField(in: AXSnapshot(elements: [from, to]))?.id == "e2")
        from.value = "Zurich"; to.isFocused = false
        #expect(FieldText.obviousField(in: AXSnapshot(elements: [from, to]))?.id == "e2")   // filled fields drop out
    }

    @Test func obviousFieldNeverPicksSecureOrFilledFields() {
        let secure = AXElement(id: "e1", role: "AXSecureTextField", label: "Password", frame: CGRect(x: 0, y: 0, width: 100, height: 20), isFocused: true)
        #expect(FieldText.obviousField(in: AXSnapshot(elements: [secure])) == nil)
        #expect(FieldText.obviousField(in: AXSnapshot(elements: [Self.el("e1", "AXTextField", "Search", value: "jev")])) == nil)
    }

    @Test func extractsAppNames() {
        #expect(TextCandidates.appNames(in: "open chrome, search for jev") == ["chrome"])
        #expect(TextCandidates.appNames(in: "switch to Google Chrome and go to github.com").contains("Google Chrome"))
        let c = TextCandidates.extract(task: "launch Notes and write hi")
        #expect(c.contains { $0.text == "Notes" && $0.source == "app" })
    }

    @Test func extractsEmailsNumbersAndSegments() {
        let c = TextCandidates.extract(task: "email bob@acme.com, set quantity to 12 and then save")
        let texts = c.map(\.text)
        #expect(texts.contains("bob@acme.com") && texts.contains("12"))
        #expect(texts.contains("set quantity to 12"))
    }

    @Test func includesContextSourcesDedupesAndCaps() {
        let c = TextCandidates.extract(task: "paste it", clipboard: "  hello clip  ", windowTitle: "Untitled", url: "https://a.test", focusedValue: "draft")
        #expect(c.contains { $0.text == "hello clip" && $0.source == "clipboard" })
        #expect(c.contains { $0.text == "Untitled" && $0.source == "window" })
        #expect(c.contains { $0.text == "https://a.test" })
        #expect(c.contains { $0.text == "draft" && $0.source == "focused" })
        let dup = TextCandidates.extract(task: "type \"x\" then type \"x\"")
        #expect(dup.filter { $0.text == "x" }.count == 1)
        let big = TextCandidates.extract(task: (1...40).map { "\"item \($0)\"" }.joined(separator: ", "))
        #expect(big.count == TextCandidates.cap)
        #expect(big.last?.id == "t\(TextCandidates.cap)")
        #expect(Set(big.map(\.id)).count == big.count)
    }

    @Test func obviousTextOnlyWhenExactlyOneQuote() {
        #expect(TextCandidates.obviousText(in: "type \"hello\" into the note") == "hello")
        #expect(TextCandidates.obviousText(in: "type \"a\" then \"b\"") == nil)
        #expect(TextCandidates.obviousText(in: "type hello") == nil)
    }

    @Test func rankingDedupesOrdersAndAssignsIDs() {
        let els = [
            Self.el("", "AXButton", "B", x: 300, y: 100),
            Self.el("", "AXButton", "A", x: 10, y: 100),
            Self.el("", "AXButton", "A", x: 10, y: 100),           // duplicate
            Self.el("", "AXTextField", "Focused", x: 500, y: 400, focused: true),
            Self.el("", "AXLink", "Top", x: 900, y: 5),
        ]
        let r = AXSnapshot.rank(els, windowFrame: nil, near: nil)
        #expect(r.map(\.label) == ["Focused", "Top", "A", "B"])
        #expect(r.map(\.id) == ["e1", "e2", "e3", "e4"])
        #expect(r[0].index == 1)
    }

    @Test func rankingCapsPreferringWindowAndProximity() {
        var els: [AXElement] = []
        for i in 0..<150 { els.append(Self.el("", "AXButton", "in\(i)", x: CGFloat(i % 10) * 50, y: CGFloat(i / 10) * 40)) }
        for i in 0..<30 { els.append(Self.el("", "AXButton", "out\(i)", x: 5000, y: CGFloat(i) * 40)) }
        let window = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let r = AXSnapshot.rank(els, windowFrame: window, near: CGRect(x: 0, y: 0, width: 10, height: 10), cap: 100)
        #expect(r.count == 100)
        #expect(r.allSatisfy { $0.label.hasPrefix("in") })
        #expect(r.contains { $0.label == "in0" })                // closest to the anchor survives
        #expect(!r.contains { $0.label == "in149" })             // farthest is dropped
        // Reading order among the kept ones.
        #expect(r.first?.label == "in0")
    }

    @Test func snapshotDiffDescribesChanges() {
        let a = Self.snapshot
        #expect(a.diff(previous: a) == "no visible change")
        #expect(a.diff(previous: nil) == "first snapshot")
        var b = a
        b.windowTitle = "Acme — Results"
        b.elements.append(Self.el("e6", "AXLink", "Result 1", x: 10, y: 200))
        b.elements.append(Self.el("e7", "AXLink", "Result 2", x: 10, y: 230))
        let d = b.diff(previous: a)
        #expect(d.contains("title changed") && d.contains("2 new elements"))
        var c = a
        c.url = "https://acme.test/search?q=jev"
        c.visibleText = "Results for jev"
        #expect(c.diff(previous: a).contains("url changed"))
        var e = a
        e.elements[0].value = "jev"
        #expect(e.diff(previous: a) == "focused value changed")
    }

    @Test func taskSurfaceStateAndStartURL() throws {
        let front = FrontmostProbe.Info(bundleID: "com.google.Chrome", appName: "Google Chrome", windowTitle: "Inbox", url: "https://mail.google.com/")
        let s = TaskSurface.formatState(task: "archive all", frontmost: front)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
        #expect(json["task"] as? String == "archive all")
        #expect(json["frontmost_is_browser"] as? Bool == true)
        #expect(Set(TaskSurface.criteria.keys) == ["browser", "native_app", "unsure"])
        #expect(TaskSurface.startURL(task: "open github.com and star it", frontmost: front) == "https://github.com")
        // Jev's start_from head decides between the open tab and a fresh search.
        #expect(TaskSurface.startURL(task: "archive all", frontmost: front, start: .currentTab) == "https://mail.google.com/")
        #expect(TaskSurface.startURL(task: "find the cheapest john summit tickets", frontmost: front, start: .webSearch)
                == "https://www.google.com/search?hl=en&q=the%20cheapest%20john%20summit%20tickets")
        // Without a Jev answer: the tab only when the task refers to it or names its domain.
        #expect(TaskSurface.startURL(task: "archive everything on this page", frontmost: front) == "https://mail.google.com/")
        #expect(TaskSurface.startURL(task: "find the cheapest tickets", frontmost: front)?.hasPrefix("https://www.google.com/search?") == true)
        // Named sites and launcher chatter.
        #expect(TaskSurface.startURL(task: "go to google flights and book zurich to london", frontmost: front) == "https://www.google.com/travel/flights?hl=en")
        #expect(UltrafastBridge.searchQuery(for: "go to browser and find the cheapest john summit tickets in boston")
                == "the cheapest john summit tickets in boston")
        #expect(UltrafastBridge.searchQuery(for: "open chrome, search for the weather in boston and click the first result")
                == "the weather in boston")
        #expect(UltrafastBridge.searchQuery(for: "Search Google for best ramen in sf") == "best ramen in sf")
        #expect(UltrafastBridge.searchQuery(for: "in safari look up how tall is mount fuji") == "how tall is mount fuji")
        #expect(UltrafastBridge.searchQuery(for: "book a table at nopa for 2 tonight") == "book a table at nopa for 2 tonight")
        #expect(UltrafastBridge.searchURL(for: "open chrome and search for jev then click the first result")
                == "https://www.google.com/search?hl=en&q=jev")
        // No browser open → a search page, never nil (the runner needs somewhere to start).
        let native = FrontmostProbe.Info(bundleID: "com.apple.finder", appName: "Finder", windowTitle: nil, url: nil)
        #expect(TaskSurface.startURL(task: "make a folder", frontmost: native)?.hasPrefix("https://www.google.com/search?") == true)
        // start_from head is only added when a tab is open.
        #expect(TaskSurface.questions(currentTab: nil)["start_from"] == nil)
        #expect(TaskSurface.questions(currentTab: ("Inbox", "https://mail.google.com/"))["start_from"] != nil)
    }
}
