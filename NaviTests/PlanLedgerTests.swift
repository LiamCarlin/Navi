import Testing
import Foundation
@testable import Navi

/// Plans with checks: each step's visible completion evidence, the ledger every model call
/// reads, the `step_done` gate on Jev's own "done", and what a re-plan is told. Pure logic.
struct PlanLedgerTests {
    static func plan() -> TaskPlanner.Plan {
        TaskPlanner.parse("""
        {"steps":[
          {"surface":"browser","goal":"Find the forecast for Boston","query":"boston weather","needs_result":true,"done_when":"the forecast for Boston is visible"},
          {"surface":"app","app":"Notes","goal":"Make a note with {{result}}","done_when":"a new note shows the forecast text","must_not":"do not edit an existing note"},
          {"surface":"app","app":"Messages","goal":"Text Bella the note"}
        ]}
        """)!
    }

    @Test func plannerStepsCarryEvidenceAndWrongPaths() {
        let p = Self.plan()
        #expect(p.steps[0].doneWhen == "the forecast for Boston is visible" && p.steps[0].mustNot == nil)
        #expect(p.steps[1].doneWhen == "a new note shows the forecast text" && p.steps[1].mustNot == "do not edit an existing note")
        #expect(p.steps[2].doneWhen == nil)
        // Blank strings are nothing.
        let blank = TaskPlanner.parse(#"{"steps":[{"surface":"app","app":"Notes","goal":"x","done_when":"  ","must_not":""}]}"#)
        #expect(blank?.steps[0].doneWhen == nil && blank?.steps[0].mustNot == nil)
    }

    @Test func theLedgerMarksDoneCurrentAndPending() throws {
        let l = PlanLedger(task: "find the boston forecast, note it and text bella", plan: Self.plan(), current: 1, results: [0: "72°F and sunny"])
        #expect(l.lines == ["✓ 1. Find the forecast for Boston (browser) — produced: 72°F and sunny",
                            "→ 2. Make a note with {{result}} (Notes) — done when: a new note shows the forecast text",
                            "3. Text Bella the note (Messages)"])
        #expect(l.currentDoneWhen == "a new note shows the forecast text" && l.currentMustNot == "do not edit an existing note")
        let state = try #require(l.state)
        #expect(state["current_step_done_when"] as? String == "a new note shows the forecast text")
        #expect(state["current_step_must_not"] as? String == "do not edit an existing note")
        #expect((state["steps"] as? [String])?.count == 3)
        // The last step has no evidence: the ledger still shows the plan, with no gate.
        let last = PlanLedger(task: "t", plan: Self.plan(), current: 2, results: [0: "72°F", 1: "Made the note"])
        #expect(last.currentDoneWhen == nil && last.state != nil)
        // A one-step plan with no evidence has nothing to say.
        let one = PlanLedger(task: "open notes", plan: TaskPlanner.fallback(task: "open notes", surface: .app, app: "Notes"), current: 0, results: [:])
        #expect(one.state == nil && one.currentDoneWhen == nil)
        // A one-step plan with evidence gates `done` and says so.
        let gated = TaskPlanner.parse(#"{"steps":[{"surface":"app","app":"Notes","goal":"make a note","done_when":"a new empty note is open"}]}"#)!
        let g = PlanLedger(task: "make a note", plan: gated, current: 0, results: [:])
        #expect(g.state?["current_step_done_when"] as? String == "a new empty note is open" && g.lines.count == 1)
        // Long findings are cut for the state.
        let long = PlanLedger(task: "t", plan: Self.plan(), current: 1, results: [0: String(repeating: "x", count: 500)])
        #expect(long.lines[0].count < 260)
    }

    @Test func jevsDoneNeedsTheEvidenceWhenAStepHasSome() {
        #expect(PlanLedger.acceptsDone(doneWhen: nil, stepDone: nil))
        #expect(PlanLedger.acceptsDone(doneWhen: nil, stepDone: 0.1))
        #expect(!PlanLedger.acceptsDone(doneWhen: "a note shows", stepDone: nil))
        #expect(!PlanLedger.acceptsDone(doneWhen: "a note shows", stepDone: 0.5))
        #expect(PlanLedger.acceptsDone(doneWhen: "a note shows", stepDone: 0.7))
        // The request asks `step_done` only for a step with evidence, and says what the plan means.
        var input = TypesafeCUTests.input()
        let l = PlanLedger(task: "t", plan: Self.plan(), current: 1, results: [0: "72°F"])
        input.plan = l.state
        input.stepDoneWhen = l.currentDoneWhen
        let req = CUDecide.request(input)
        #expect(req.questions["step_done"] != nil)
        #expect((req.state["plan"] as? [String: Any])?["current_step_done_when"] as? String == "a new note shows the forecast text")
        if case .choice(let instructions, _)? = req.questions["kind"] { #expect(instructions.contains("current_step_done_when")) } else { Issue.record("no kind question") }
        let plain = CUDecide.request(TypesafeCUTests.input())
        #expect(plain.questions["step_done"] == nil && plain.state["plan"] == nil)
        if case .choice(let instructions, _)? = plain.questions["kind"] { #expect(!instructions.contains("current_step_done_when")) }
        // The verdict carries it.
        let r = JevClient.Response(model: "jev", answers: ["step_done": .noul(0.83), "kind": .choice(choice: "done", probabilities: ["done": 0.9], confidence: 0.9)],
                                   inputTokens: 0, outputTokens: 0, latencyMs: 120)
        #expect(CUDecide.Verdict.from(r).stepDone == 0.83)
        #expect(CUDecide.Verdict.from(JevClient.Response(model: "jev", answers: [:], inputTokens: 0, outputTokens: 0, latencyMs: 1)).stepDone == nil)
    }

    @Test func aReplanIsToldWhatIsDoneAndWhatFailed() throws {
        let l = PlanLedger(task: "t", plan: Self.plan(), current: 1, results: [0: "72°F and sunny"])
        let r = l.replanSection(failure: "Jev clicked the folder list three times; no note was made.", verdict: .notAchieved)
        let done = try #require(r["steps_done"] as? [[String: Any]])
        #expect(done.count == 1 && done[0]["produced"] as? String == "72°F and sunny")
        let failed = try #require(r["step_that_failed"] as? [String: Any])
        #expect(failed["step"] as? Int == 2 && failed["verdict"] as? String == "not_achieved" && failed["was_to_end_when"] as? String == "a new note shows the forecast text")
        #expect(r["steps_that_were_still_planned"] as? [String] == ["Text Bella the note"])
        #expect(TaskPlanner.maxReplans == 1 && TaskPlanner.replanInstruction.contains("REMAINING"))
    }
}
