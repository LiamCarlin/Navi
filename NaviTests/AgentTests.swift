import Testing
import Foundation
import CoreGraphics
@testable import Navi

struct AgentTests {

    // MARK: Coordinate mapping

    @Test func screenshotPixelsMapToScreenPoints() {
        // Retina display (2×), 2880×1800 px capture downscaled by 0.5 → 1440×900 image.
        let m = ScreenMap(bounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
                          scaleFactor: 2.0, downscale: 0.5, imageSize: CGSize(width: 1440, height: 900))
        let p = m.point(fromScreenshot: 720, 450)
        #expect(p.x == 720)   // 720 / 0.5 = 1440 px → / 2.0 = 720 pt
        #expect(p.y == 450)
        // Inverse round-trips.
        let back = m.screenshotPoint(fromScreen: p)
        #expect(back.x == 720 && back.y == 450)
    }

    @Test func mappingHonoursDisplayOriginAndClamps() {
        // Secondary display to the right of the main one.
        let m = ScreenMap(bounds: CGRect(x: 1440, y: 100, width: 1000, height: 800),
                          scaleFactor: 2.0, downscale: 0.5, imageSize: CGSize(width: 1000, height: 800))
        let p = m.point(fromScreenshot: 100, 200)
        #expect(abs(p.x - 1540) < 1e-9)   // 100 px / 0.5 / 2.0 = 100 pt, offset by the display origin
        #expect(abs(p.y - 300) < 1e-9)
        let clamped = m.point(fromScreenshot: 99_999, -50)
        #expect(clamped.x == m.bounds.maxX - 1)
        #expect(clamped.y == m.bounds.minY)
    }

    @Test func zoomRegionMapsToFullResolution() {
        let m = ScreenMap(bounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
                          scaleFactor: 2.0, downscale: 0.5, imageSize: CGSize(width: 1440, height: 900))
        let r = m.fullResRect(fromScreenshot: CGRect(x: 10, y: 20, width: 30, height: 40))
        #expect(r == CGRect(x: 20, y: 40, width: 60, height: 80))
    }

    // MARK: Key combo parsing

    @Test func parsesCmdShiftS() throws {
        let c = try KeyCombo.parse("cmd+shift+s")
        #expect(c.keyCode == 1)
        #expect(c.flags.contains(.maskCommand))
        #expect(c.flags.contains(.maskShift))
        #expect(!c.flags.contains(.maskControl))
        #expect(c.displayLabel == "⇧⌘S")
    }

    @Test func parsesReturn() throws {
        let c = try KeyCombo.parse("Return")
        #expect(c.keyCode == 36)
        #expect(c.flags.isEmpty)
        #expect(try KeyCombo.parse("Enter").keyCode == 36)
    }

    @Test func parsesCtrlAltDelete() throws {
        let c = try KeyCombo.parse("ctrl+alt+Delete")
        #expect(c.keyCode == 117)          // forward delete
        #expect(c.flags.contains(.maskControl))
        #expect(c.flags.contains(.maskAlternate))
        #expect(!c.flags.contains(.maskCommand))
        #expect(try KeyCombo.parse("BackSpace").keyCode == 51)
    }

    @Test func parsesAliasesAndSpecialKeys() throws {
        #expect(try KeyCombo.parse("super+space").flags.contains(.maskCommand))
        #expect(try KeyCombo.parse("super+space").keyCode == 49)
        #expect(try KeyCombo.parse("option+Left").flags.contains(.maskAlternate))
        #expect(try KeyCombo.parse("Page_Up").keyCode == 116)
        #expect(try KeyCombo.parse("F12").keyCode == 111)
        #expect(try KeyCombo.parse("Escape").keyCode == 53)
        #expect(try KeyCombo.parse("cmd++").keyCode == 24)                 // "+" key
        #expect(try KeyCombo.parse("cmd++").flags.contains(.maskShift))
        #expect(try KeyCombo.parse("?").flags.contains(.maskShift))        // shifted slash
        #expect(try KeyCombo.parse("?").keyCode == 44)
        #expect(try KeyCombo.parse("cmd").keyCode == 55)                   // bare modifier (hold_key)
    }

    @Test func rejectsUnknownKeys() {
        #expect(throws: (any Error).self) { try KeyCombo.parse("cmd+bogus") }
        #expect(throws: (any Error).self) { try KeyCombo.parse("hyper+a") }
        #expect(throws: (any Error).self) { try KeyCombo.parse("") }
    }

    // MARK: tool_result construction

    @Test func computerResultsCarryToolsetName() {
        let r = AgentToolResult.computer(id: "toolu_1")
        #expect(r["type"] as? String == "tool_result")
        #expect(r["tool_use_id"] as? String == "toolu_1")
        #expect(r["toolset_name"] as? String == "computer")
        #expect(r["is_error"] == nil)
        let content = r["content"] as? [[String: Any]]
        #expect(content?.first?["text"] as? String == "OK")

        let img = AgentToolResult.computerImage(id: "toolu_2", pngBase64: "AAAA")
        #expect(img["toolset_name"] as? String == "computer")
        let src = ((img["content"] as? [[String: Any]])?.first?["source"] as? [String: Any])
        #expect(src?["type"] as? String == "base64")
        #expect(src?["media_type"] as? String == "image/png")
        #expect(src?["data"] as? String == "AAAA")

        let err = AgentToolResult.computer(id: "toolu_3", text: "boom", isError: true)
        #expect(err["is_error"] as? Bool == true)
    }

    @Test func customResultsOmitToolsetName() {
        let r = AgentToolResult.custom(id: "toolu_9", text: "com.apple.Safari")
        #expect(r["toolset_name"] == nil)
        #expect(r["tool_use_id"] as? String == "toolu_9")
        let err = AgentToolResult.custom(id: "toolu_9", text: "nope", isError: true)
        #expect(err["is_error"] as? Bool == true)
        #expect(err["toolset_name"] == nil)
    }

    @Test func errorHelperPicksShapeFromCall() throws {
        let computer = try #require(AgentToolCall(block: [
            "type": "tool_use", "id": "a", "toolset_name": "computer", "name": "left_click",
            "input": ["coordinate": [512, 384]],
        ]))
        let custom = try #require(AgentToolCall(block: [
            "type": "tool_use", "id": "b", "name": "open_app", "input": ["name": "Safari"],
        ]))
        #expect(computer.isComputer && !custom.isComputer)
        #expect(AgentToolResult.error(for: computer, AgentToolResult.notExecuted)["toolset_name"] as? String == "computer")
        #expect(AgentToolResult.error(for: custom, "x")["toolset_name"] == nil)
        #expect(AgentActionDescriber.human(computer) == "Click at (512, 384)")
        #expect(AgentActionDescriber.human(custom) == "Open Safari")
        #expect(AgentActionDescriber.technical(computer) == "left_click at (512,384)")
    }

    @Test func pruneKeepsOnlyRecentImages() {
        func shot(_ id: String) -> [String: Any] {
            ["role": "user", "content": [AgentToolResult.computerImage(id: id, pngBase64: "x")]]
        }
        var msgs: [[String: Any]] = [shot("1"), ["role": "assistant", "content": []], shot("2"), shot("3")]
        AgentToolResult.pruneImages(in: &msgs, keep: 2)
        func hasImage(_ m: [String: Any]) -> Bool {
            let blocks = m["content"] as? [[String: Any]] ?? []
            return blocks.contains { ($0["content"] as? [[String: Any]])?.contains { $0["type"] as? String == "image" } ?? false }
        }
        #expect(!hasImage(msgs[0]))
        #expect(hasImage(msgs[2]) && hasImage(msgs[3]))
        // toolset_name survives pruning.
        #expect(((msgs[0]["content"] as? [[String: Any]])?.first?["toolset_name"] as? String) == "computer")
    }

    // MARK: Jev state formatting

    @Test func formatsJevState() {
        let s = JevGate.formatState(task: "Open Notes and write hi", step: 3, maxSteps: 40,
                                    claudeSays: "I'll click the new note button.",
                                    proposedActions: ["left_click at (512,384)", "type \"hi\""],
                                    recentActions: ["screenshot", "open_app \"Notes\""],
                                    app: "Notes", windowTitle: "Untitled")
        let expected = """
        [TASK] Open Notes and write hi
        [STEP] 3 of 40
        [CLAUDE_SAYS] I'll click the new note button.
        [PROPOSED_ACTIONS]
        1. left_click at (512,384)
        2. type "hi"
        [RECENT_ACTIONS]
        - screenshot
        - open_app "Notes"
        [SCREEN] app=Notes title=Untitled
        """
        #expect(s == expected)
    }

    @Test func jevStateLimitsRecentActionsToSix() {
        let s = JevGate.formatState(task: "t", step: 1, maxSteps: 2, claudeSays: "",
                                    proposedActions: [], recentActions: (1...9).map { "a\($0)" },
                                    app: nil, windowTitle: nil)
        #expect(!s.contains("- a3\n"))
        #expect(s.contains("- a4\n") && s.contains("- a9\n"))
        #expect(s.contains("[CLAUDE_SAYS] (none)"))
        #expect(s.hasSuffix("[SCREEN] app=unknown title="))
    }

    // MARK: Prohibited keyword heuristic

    @Test func prohibitedKeywordHeuristic() {
        #expect(JevGate.prohibitedKeyword(in: "type \"hunter2\" into the password field") == "password")
        #expect(JevGate.prohibitedKeyword(in: "Enter the credit card number") == "credit card")
        #expect(JevGate.prohibitedKeyword(in: "Fill CVV") == "cvv")
        #expect(JevGate.prohibitedKeyword(in: "click Buy now") == "buy")
        #expect(JevGate.prohibitedKeyword(in: "Confirm the purchase") == "purchase")
        #expect(JevGate.prohibitedKeyword(in: "transfer $200 to savings") == "transfer")
        #expect(JevGate.prohibitedKeyword(in: "send $50 to Bob") == "send $")
        #expect(JevGate.prohibitedKeyword(in: "click the buyer's guide link") == nil)   // word boundary
        #expect(JevGate.prohibitedKeyword(in: "open Notes and type hello") == nil)
    }

    @Test func decisionRespectsApprovalMode() {
        var v = JevGate.Verdict()
        #expect(JevGate.decide(v, mode: .askForRisky, readOnlyTurn: false) == .proceed)
        #expect(JevGate.decide(v, mode: .autonomous, readOnlyTurn: false) == .proceed)
        if case .askApproval = JevGate.decide(v, mode: .alwaysAsk, readOnlyTurn: false) {} else { Issue.record("alwaysAsk should ask") }
        #expect(JevGate.decide(v, mode: .alwaysAsk, readOnlyTurn: true) == .proceed)

        v.isIrreversible = 0.8
        if case .askApproval = JevGate.decide(v, mode: .askForRisky, readOnlyTurn: false) {} else { Issue.record("risky should ask") }
        #expect(JevGate.decide(v, mode: .autonomous, readOnlyTurn: false) == .proceed)

        v = JevGate.Verdict(); v.isProhibited = 0.9; v.keywordHit = "cvv"
        if case .askApproval(let risk) = JevGate.decide(v, mode: .autonomous, readOnlyTurn: true) {
            #expect(risk.hasPrefix("Prohibited category"))
            #expect(risk.contains("cvv"))
        } else { Issue.record("prohibited must always ask") }
    }
}
