import Foundation
import Testing
@testable import Navi

@Suite struct JevCoachTests {
    @Test func failureTrackerCountsNoChangeRepeatsAndErrorsAndResetsOnProgress() {
        var t = JevCoach.FailureTracker()
        t.record(action: "Click ‘Search’", changed: false, error: nil)
        t.record(action: "Click ‘Search’", changed: true, error: nil)      // same thing again, even if something moved
        #expect(t.failures == 2 && !t.shouldCoach)
        t.record(action: "Click ‘Go’", changed: nil, error: "no frame")
        #expect(t.shouldCoach)
        #expect(t.summary.contains("changed nothing") && t.summary.contains("repeated") && t.summary.contains("failed"))
        t.record(action: "Press Return", changed: true, error: nil)
        #expect(t.failures == 0 && t.summary.isEmpty)
        t.recordBlocked("Jev chose BLOCKED"); t.recordBlocked("Jev chose BLOCKED"); t.recordBlocked("Jev chose BLOCKED")
        #expect(t.shouldCoach)
        t.reset()
        #expect(!t.shouldCoach && t.lastAction == nil)
    }

    @Test func parsesAdviceWithOptionalNextAction() {
        let raw = """
        ```json
        {"diagnosis":"It keeps clicking the search box.","guidance":"Click [7] ‘Search’.\\nStop clicking [4].","next_operation":"click","next_target":7}
        ```
        """
        let a = JevCoach.parse(raw)
        #expect(a?.diagnosis == "It keeps clicking the search box.")
        #expect(a?.guidance.hasPrefix("Click [7]") == true)
        #expect(a?.nextOperation == "CLICK" && a?.nextTarget == "7")
        #expect(JevCoach.parse(#"{"diagnosis":"x"}"#) == nil)       // guidance is mandatory
        #expect(JevCoach.parse("Sorry, I can't.") == nil)
    }

    @Test func coachActionIsValidatedAgainstOfferedTargets() {
        let snap = JevDriverTests.snapshot
        let input = JevDriver.StepInput(task: "search for jev", step: 1, maxSteps: 10, snapshot: snap, history: [],
                                        appCandidates: ["Safari"], urlCandidates: [])
        let req = JevDriver.request(for: input)
        let clickable = req.heads["click_target"]!.first!
        #expect(JevDriver.coachAction(operation: "CLICK", target: clickable, request: req) == .click(elementID: "e\(clickable)"))
        #expect(JevDriver.coachAction(operation: "CLICK", target: "e\(clickable)", request: req) == .click(elementID: "e\(clickable)"))
        #expect(JevDriver.coachAction(operation: "CLICK", target: "999", request: req) == nil)   // not on screen
        #expect(JevDriver.coachAction(operation: "KEY", target: "Return", request: req) == .key("Return"))
        #expect(JevDriver.coachAction(operation: "KEY", target: "cmd+q", request: req) == nil)   // not in the vocabulary
        #expect(JevDriver.coachAction(operation: "OPEN_APP", target: "Safari", request: req) == .openApp("Safari"))
        #expect(JevDriver.coachAction(operation: "SCROLL_DOWN", target: nil, request: req) == .scroll(up: false))
        #expect(JevDriver.coachAction(operation: "BLOCKED", target: nil, request: req) == nil)
        #expect(JevDriver.coachAction(operation: nil, target: nil, request: req) == nil)
    }

    @Test func guidanceRidesAlongInStateAndInstructions() {
        var input = JevDriver.StepInput(task: "t", step: 1, maxSteps: 5, snapshot: JevDriverTests.snapshot, history: [])
        #expect(JevDriver.stateJSON(for: input)["guidance"] == nil)
        input.guidance = "Click [2]."
        #expect(JevDriver.stateJSON(for: input)["guidance"] as? String == "Click [2].")
        let s = JevDriver.serialize(JevDriver.stateJSON(for: input))
        #expect(s.contains("\"guidance\":\"Click [2].\""))
    }
}
