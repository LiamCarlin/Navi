import Testing
import Foundation
import CoreGraphics
@testable import Navi

/// Jev-first computer-use driver: state/question construction, decision rules,
/// text candidates, AX ranking. No network, no live Accessibility.
struct JevDriverTests {

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

    static func input(history: [JevDriver.HistoryEntry] = [], apps: [String] = [], urls: [String] = []) -> JevDriver.StepInput {
        JevDriver.StepInput(task: "search for \"jev\" then sign in", step: 2, maxSteps: 40, snapshot: snapshot,
                            history: history, appCandidates: apps, urlCandidates: urls)
    }

    static func head(_ choice: String, over ids: [String], confidence: Double = 0.9) -> JevDriver.Head {
        var probs: [String: Double] = [:]
        let rest = ids.count > 1 ? (1 - confidence) / Double(ids.count - 1) : 0
        for id in ids { probs[id] = id == choice ? (ids.count > 1 ? confidence : 1) : rest }
        return JevDriver.Head(choice: choice, probabilities: probs, confidence: confidence)
    }

    static func verdict(op: String, confidence: Double = 0.9, request: JevDriver.Request,
                        target: (head: String, choice: String)? = nil, taskComplete: Double = 0,
                        irreversible: Double = 0, prohibited: Double = 0) -> JevDriver.Verdict {
        var v = JevDriver.Verdict()
        v.operation = head(op, over: request.operations, confidence: confidence)
        if let t = target { v.targets[t.head] = head(t.choice, over: request.heads[t.head] ?? []) }
        v.taskComplete = taskComplete; v.isIrreversible = irreversible; v.isProhibited = prohibited
        return v
    }

    // MARK: State

    @Test func stateIsStructuredJSON() throws {
        let hist = [JevDriver.HistoryEntry(action: "Click ‘Search’", kind: "click", text: nil, pageChanged: true)]
        let s = JevDriver.formatState(Self.input(history: hist))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
        #expect(json["app"] as? String == "Safari")
        #expect(json["window"] as? String == "Acme — Home")
        #expect(json["url"] as? String == "https://acme.test/")
        #expect(json["text"] as? String == "Welcome back\nSign in to continue")
        let elements = try #require(json["elements"] as? [[String: Any]])
        #expect(elements.count == 5)
        #expect(elements[0]["index"] as? Int == 1)
        #expect(elements[0]["role"] as? String == "AXTextField")
        #expect(elements[0]["label"] as? String == "Search")
        #expect(elements[0]["focused"] as? Bool == true)
        #expect(elements[0]["operations"] as? [String] == ["CLICK", "TYPE_TEXT"])
        #expect(elements[2]["operations"] as? [String] == ["CLICK", "SELECT"])
        #expect(elements[2]["options"] as? [String] == ["Small", "Medium", "Large"])
        #expect(elements[3]["operations"] as? [String] == ["CLICK"])          // secure field: never TYPE_TEXT
        let actions = try #require(json["recent_actions"] as? [[String: Any]])
        #expect(actions.count == 1)
        #expect(actions[0]["action"] as? String == "Click ‘Search’")
        #expect(actions[0]["kind"] as? String == "click")
        #expect(actions[0]["page_changed"] as? Bool == true)
        #expect(actions[0]["text"] is NSNull)
        // Deterministic (sorted keys) so JevClient's cache can hit.
        #expect(s == JevDriver.formatState(Self.input(history: hist)))
    }

    // MARK: Questions

    @Test func questionsOfferOperationsOnlyWithTargets() throws {
        let req = JevDriver.request(for: Self.input(apps: ["Safari"]))
        #expect(Set(req.operations) == ["CLICK", "TYPE_TEXT", "SELECT", "KEY", "OPEN_APP", "SCROLL_UP", "SCROLL_DOWN", "WAIT", "DONE", "BLOCKED", "NEED_VISION"])
        #expect(!req.operations.contains("OPEN_URL"))                              // no url candidate offered
        #expect(req.heads["click_target"] == ["1", "2", "3", "4", "5"])
        #expect(req.heads["type_text_target"] == ["1"])                            // only the non-secure text field
        #expect(req.heads["select_target"] == ["3:1", "3:2", "3:3"])
        #expect(req.selectTargets["3:3"]?.element == "e3")
        #expect(req.selectTargets["3:3"]?.option == "Large")
        #expect(req.heads["open_app_target"] == ["a1"])
        #expect(req.appTargets["a1"] == "Safari")
        #expect(req.heads["key_target"]?.contains("cmd+l") == true)
        #expect(req.heads["key_target"]?.count == JevDriver.keyCombos.count)
        let q = req.questions
        #expect(q["operation"] != nil && q["click_target"] != nil && q["type_text_target"] != nil && q["select_target"] != nil)
        #expect(q["task_complete"] != nil && q["is_irreversible"] != nil && q["is_prohibited"] != nil)
        #expect(q["open_url_target"] == nil)
        // Structured criteria carry the element table row and the repo's TARGET rules.
        let data = try JSONEncoder().encode(q["click_target"]!)
        let enc = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let crit = try #require(enc["criteria"] as? [String: String])
        #expect(crit["2"]?.contains("\"element\":\"[2] Sign in\"") == true)
        #expect(crit["3"]?.contains("\"current_value\":\"Medium\"") == true)
        #expect((enc["instructions"] as? String)?.contains("Choose only an offered element index") == true)
        let opData = try JSONEncoder().encode(q["operation"]!)
        let opEnc = try #require(try JSONSerialization.jsonObject(with: opData) as? [String: Any])
        #expect((opEnc["instructions"] as? String)?.contains("BLOCKED means no supported operation can make progress") == true)
    }

    @Test func questionsNeverExceed255Options() throws {
        var many: [AXElement] = []
        for i in 0..<400 {
            many.append(Self.el("e\(i + 1)", "AXTextField", "Field \(i)", x: CGFloat(i % 20) * 50, y: CGFloat(i / 20) * 30))
        }
        // Real snapshots are ranked (and capped) before reaching the driver.
        let ranked = AXSnapshot.rank(many, windowFrame: CGRect(x: 0, y: 0, width: 2000, height: 2000), near: nil)
        #expect(ranked.count == AXSnapshot.cap)
        var snap = Self.snapshot
        snap.elements = ranked
        let req = JevDriver.request(for: JevDriver.StepInput(task: "t", step: 1, maxSteps: 5, snapshot: snap, history: []))
        for (name, q) in req.questions {
            let data = try JSONEncoder().encode(q)
            let enc = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            if let crit = enc["criteria"] as? [String: Any] { #expect(crit.count <= 255, "\(name) has \(crit.count) options") }
        }
        #expect(req.heads["click_target"]?.count == AXSnapshot.cap)
        // Popup with an absurd option list is capped per element too.
        var popup = Self.snapshot
        popup.elements = [Self.el("e1", "AXPopUpButton", "Country", options: (0..<300).map { "C\($0)" })]
        let r2 = JevDriver.request(for: JevDriver.StepInput(task: "t", step: 1, maxSteps: 5, snapshot: popup, history: []))
        #expect((r2.heads["select_target"]?.count ?? 999) <= 255)
    }

    // MARK: validate_choice

    @Test func validateChoiceMatchesRepoRules() {
        let ids = ["CLICK", "WAIT", "DONE"]
        #expect(JevDriver.validate(JevDriver.Head(choice: "CLICK", probabilities: ["CLICK": 0.7, "WAIT": 0.2, "DONE": 0.1], confidence: 0.6), ids: ids))
        #expect(!JevDriver.validate(nil, ids: ids))
        #expect(!JevDriver.validate(JevDriver.Head(choice: "SELECT", probabilities: ["CLICK": 0.7, "WAIT": 0.2, "DONE": 0.1], confidence: 0.6), ids: ids))          // not offered
        #expect(!JevDriver.validate(JevDriver.Head(choice: "CLICK", probabilities: ["CLICK": 0.7, "WAIT": 0.3], confidence: 0.6), ids: ids))                        // missing id
        #expect(!JevDriver.validate(JevDriver.Head(choice: "CLICK", probabilities: ["CLICK": 0.5, "WAIT": 0.5, "DONE": 0.5], confidence: 0.6), ids: ids))           // sum ≠ 1
        #expect(!JevDriver.validate(JevDriver.Head(choice: "CLICK", probabilities: ["CLICK": 0.2, "WAIT": 0.7, "DONE": 0.1], confidence: 0.6), ids: ids))           // not argmax
        #expect(!JevDriver.validate(JevDriver.Head(choice: "CLICK", probabilities: ["CLICK": 0.7, "WAIT": 0.2, "DONE": 0.1], confidence: 1.4), ids: ids))           // out of range
        #expect(!JevDriver.validate(JevDriver.Head(choice: "CLICK", probabilities: ["CLICK": .nan, "WAIT": 0.2, "DONE": 0.1], confidence: 0.6), ids: ids))          // non-finite
    }

    // MARK: Decision matrix

    @Test func decideDoneAndTaskComplete() {
        let req = JevDriver.request(for: Self.input())
        if case .finish = JevDriver.decide(Self.verdict(op: "DONE", request: req), request: req, threshold: 0.5) {} else { Issue.record("DONE should finish") }
        let v = Self.verdict(op: "CLICK", request: req, target: ("click_target", "2"), taskComplete: 0.95)
        if case .finish = JevDriver.decide(v, request: req, threshold: 0.5) {} else { Issue.record("task_complete > 0.8 should finish") }
    }

    @Test func decideLowConfidenceFallsBack() {
        let req = JevDriver.request(for: Self.input())
        let v = Self.verdict(op: "CLICK", confidence: 0.3, request: req, target: ("click_target", "2"))
        if case .fallbackToClaude(let r) = JevDriver.decide(v, request: req, threshold: 0.5) { #expect(r.contains("30%")) } else { Issue.record("low confidence should fall back") }
        // Same verdict clears a lower bar.
        #expect(JevDriver.decide(v, request: req, threshold: 0.25) == .act(.click(elementID: "e2")))
    }

    @Test func decideNeedVisionAndInvalidHeadsFallBack() {
        let req = JevDriver.request(for: Self.input())
        if case .fallbackToClaude = JevDriver.decide(Self.verdict(op: "NEED_VISION", request: req), request: req, threshold: 0.5) {} else { Issue.record("NEED_VISION should fall back") }
        // CLICK with no target head answered → invalid → fallback (not a click on nothing).
        if case .fallbackToClaude(let r) = JevDriver.decide(Self.verdict(op: "CLICK", request: req), request: req, threshold: 0.5) {
            #expect(r.contains("click_target"))
        } else { Issue.record("missing target should fall back") }
        // Operation head that isn't a valid distribution → fallback.
        var v = Self.verdict(op: "CLICK", request: req, target: ("click_target", "2"))
        v.operation = JevDriver.Head(choice: "CLICK", probabilities: ["CLICK": 1.0], confidence: 1)
        if case .fallbackToClaude = JevDriver.decide(v, request: req, threshold: 0.5) {} else { Issue.record("invalid operation head should fall back") }
        // Unoffered operation → fallback.
        var v2 = Self.verdict(op: "CLICK", request: req, target: ("click_target", "2"))
        v2.operation = Self.head("OPEN_URL", over: req.operations + ["OPEN_URL"])
        if case .fallbackToClaude = JevDriver.decide(v2, request: req, threshold: 0.5) {} else { Issue.record("unoffered op should fall back") }
    }

    @Test func decideResolvesEachOperation() {
        let req = JevDriver.request(for: Self.input(apps: ["Notes"], urls: ["github.com"]))
        #expect(JevDriver.decide(Self.verdict(op: "TYPE_TEXT", request: req, target: ("type_text_target", "1")), request: req, threshold: 0.5) == .act(.typeText(elementID: "e1")))
        #expect(JevDriver.decide(Self.verdict(op: "SELECT", request: req, target: ("select_target", "3:3")), request: req, threshold: 0.5) == .act(.select(elementID: "e3", option: "Large")))
        #expect(JevDriver.decide(Self.verdict(op: "KEY", request: req, target: ("key_target", "cmd+l")), request: req, threshold: 0.5) == .act(.key("cmd+l")))
        #expect(JevDriver.decide(Self.verdict(op: "OPEN_APP", request: req, target: ("open_app_target", "a1")), request: req, threshold: 0.5) == .act(.openApp("Notes")))
        #expect(JevDriver.decide(Self.verdict(op: "OPEN_URL", request: req, target: ("open_url_target", "u1")), request: req, threshold: 0.5) == .act(.openURL("github.com")))
        #expect(JevDriver.decide(Self.verdict(op: "SCROLL_DOWN", request: req), request: req, threshold: 0.5) == .act(.scroll(up: false)))
        #expect(JevDriver.decide(Self.verdict(op: "SCROLL_UP", request: req), request: req, threshold: 0.5) == .act(.scroll(up: true)))
        #expect(JevDriver.decide(Self.verdict(op: "WAIT", request: req), request: req, threshold: 0.5) == .act(.wait))
        if case .blocked = JevDriver.decide(Self.verdict(op: "BLOCKED", request: req), request: req, threshold: 0.5) {} else { Issue.record("BLOCKED should be reported as blocked") }
        // The secure field is never a TYPE_TEXT target even if Jev names it.
        var v = Self.verdict(op: "TYPE_TEXT", request: req)
        v.targets["type_text_target"] = JevDriver.Head(choice: "4", probabilities: ["4": 1], confidence: 1)
        if case .fallbackToClaude = JevDriver.decide(v, request: req, threshold: 0.5) {} else { Issue.record("secure field must not be typed into") }
    }

    @Test func stuckRuleNeedsThreeUnchangedNonWaitActions() {
        func h(_ kind: String, _ changed: Bool?) -> JevDriver.HistoryEntry { .init(action: kind, kind: kind, text: nil, pageChanged: changed) }
        #expect(!JevDriver.isStuck([]))
        #expect(!JevDriver.isStuck([h("click", false), h("click", false)]))
        #expect(JevDriver.isStuck([h("click", false), h("key", false), h("click", false)]))
        #expect(!JevDriver.isStuck([h("click", false), h("wait", false), h("click", false)]))     // WAIT doesn't count
        #expect(!JevDriver.isStuck([h("click", false), h("click", true), h("click", false)]))
        #expect(!JevDriver.isStuck([h("click", false), h("click", false), h("click", nil)]))      // unobserved isn't "no change"
        #expect(JevDriver.isStuck([h("click", true), h("click", false), h("click", false), h("click", false)]))
    }

    @Test func prohibitedAndIrreversibleGoThroughJevGate() {
        let req = JevDriver.request(for: Self.input())
        let v = Self.verdict(op: "CLICK", request: req, target: ("click_target", "2"), prohibited: 0.9)
        let g = JevDriver.gateVerdict(v, actionText: "Click ‘Sign in’")
        #expect(g.source == .jev && g.isProhibited == 0.9)
        if case .askApproval(let risk) = JevGate.decide(g, mode: .autonomous, readOnlyTurn: false) {
            #expect(risk.hasPrefix("Prohibited category"))
        } else { Issue.record("prohibited must ask even when autonomous") }
        // Keyword heuristic still applies to the human action text.
        let g2 = JevDriver.gateVerdict(Self.verdict(op: "CLICK", request: req), actionText: "Click ‘Buy now’")
        #expect(g2.keywordHit == "buy" && g2.isProhibited == 1)
        // Irreversible + askForRisky → approval; read-only scroll never asks.
        let g3 = JevDriver.gateVerdict(Self.verdict(op: "CLICK", request: req, irreversible: 0.8), actionText: "Click ‘Send’")
        if case .askApproval = JevGate.decide(g3, mode: .askForRisky, readOnlyTurn: false) {} else { Issue.record("irreversible should ask") }
        #expect(JevGate.decide(g3, mode: .alwaysAsk, readOnlyTurn: AgentAction.scroll(up: true).isReadOnly) == .proceed)
    }

    @Test func humanDescriptions() {
        let s = Self.snapshot
        #expect(AgentAction.click(elementID: "e2").human(in: s) == "Click ‘Sign in’")
        #expect(AgentAction.typeText(elementID: "e1").human(in: s, text: "jev") == "Type ‘jev’ into ‘Search’")
        #expect(AgentAction.key("cmd+l").human(in: s) == "Press ⌘L")
        #expect(AgentAction.select(elementID: "e3", option: "Large").human(in: s) == "Select ‘Large’ in ‘Size’")
        #expect(AgentAction.openApp("Notes").human(in: s) == "Open Notes")
        #expect(AgentAction.key("Return").settleMs == 500 && AgentAction.click(elementID: "e1").settleMs == 250)
        #expect(AgentRun.summary(["Open Safari", "Click ‘Search’"]) == "Completed in 2 steps: Open Safari · Click ‘Search’")
    }

    @Test func statusLineShowsOperationTargetConfidenceAndLatency() {
        let req = JevDriver.request(for: Self.input())
        var v = Self.verdict(op: "CLICK", confidence: 0.91, request: req, target: ("click_target", "2"))
        v.latencyMs = 118
        #expect(JevDriver.statusLine(v) == "Jev · CLICK [2] 91% · 118 ms")
        var w = Self.verdict(op: "WAIT", confidence: 0.6, request: req)
        w.latencyMs = 240
        #expect(JevDriver.statusLine(w) == "Jev · WAIT 60% · 240 ms")
        #expect(JevDriver.statusLine(JevDriver.Verdict()) == "Jev · no answer · 0 ms")
    }

    @Test func menuBarWalkOnlyWhenTaskMentionsMenus() {
        #expect(AXSnapshot.taskMentionsMenu("File → Export as PDF"))
        #expect(AXSnapshot.taskMentionsMenu("open the view menu"))
        #expect(AXSnapshot.taskMentionsMenu("save as budget.numbers"))
        #expect(!AXSnapshot.taskMentionsMenu("search for jev and click the first result"))
        #expect(!AXSnapshot.taskMentionsMenu("reply to bob"))
    }

    // MARK: TextCandidates

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

    // MARK: FieldText (Haiku helper contract)

    @Test func fieldTextParsesStrictJSON() {
        #expect(FieldText.parse("{\"text\": \"jev\"}") == "jev")
        #expect(FieldText.parse("```json\n{\"text\":\"hi there\"}\n```") == "hi there")
        #expect(FieldText.parse("Sure: {\"text\":\"x\"}") == "x")
        #expect(FieldText.parse("{\"text\": null}") == nil)
        #expect(FieldText.parse("{\"text\": \"\"}") == nil)
        #expect(FieldText.parse("{\"text\": \"a\", \"note\": \"b\"}") == nil)     // exactly one key
        #expect(FieldText.parse("{\"value\": \"a\"}") == nil)
        #expect(FieldText.parse("hello") == nil)
        #expect(FieldText.parse("{\"text\": \"\(String(repeating: "x", count: 2001))\"}") == nil)
        let ctx = FieldText.context(goal: "g", field: Self.snapshot.elements[0], pageTitle: "T", pageText: String(repeating: "p", count: 7000), recentActions: [])
        #expect(((ctx["page"] as? [String: Any])?["text"] as? String)?.count == 6000)
        #expect(JSONSerialization.isValidJSONObject(ctx))
    }

    // MARK: AXSnapshot ranking

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

    // MARK: TaskSurface

    @Test func taskSurfaceStateAndStartURL() throws {
        let front = FrontmostProbe.Info(bundleID: "com.google.Chrome", appName: "Google Chrome", windowTitle: "Inbox", url: "https://mail.google.com/")
        let s = TaskSurface.formatState(task: "archive all", frontmost: front)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
        #expect(json["task"] as? String == "archive all")
        #expect(json["frontmost_is_browser"] as? Bool == true)
        #expect(Set(TaskSurface.criteria.keys) == ["browser", "native_app", "unsure"])
        #expect(TaskSurface.startURL(task: "open github.com and star it", frontmost: front) == "https://github.com")
        #expect(TaskSurface.startURL(task: "archive all", frontmost: front) == "https://mail.google.com/")
        let native = FrontmostProbe.Info(bundleID: "com.apple.finder", appName: "Finder", windowTitle: nil, url: nil)
        #expect(TaskSurface.startURL(task: "make a folder", frontmost: native) == nil)
    }
}
