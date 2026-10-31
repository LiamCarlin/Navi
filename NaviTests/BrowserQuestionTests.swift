import Foundation
import Testing
@testable import Navi

/// Chrome runner stops that need the user pause on a question instead of ending (runner adaptation 37):
/// the done event's question becomes an `AgentQuestion`, and the answers so far ride into the rerun.
struct BrowserQuestionTests {

    private func done(_ extra: [String: Any]) -> [String: Any] {
        ["event": "done", "status": "blocked", "outcome": "needs_user", "summary": "Stopped: needs you.",
         "url": "https://www.doordash.com/store/7th-street-burger", "tab": "T1"].merging(extra) { $1 }
    }

    @Test func aChoiceOffersThePagesOptions() throws {
        let q = try #require(UltrafastBridge.question(fromDone: done([
            "question": "Which size do you want?", "question_kind": "choice", "answer": "The burger comes in three sizes.",
            "question_choices": ["Small", "Medium", "Large", "Large", "Extra large", "Huge"]])))
        #expect(q.question == "Which size do you want?")
        #expect(q.detail == "The burger comes in three sizes.")
        #expect(q.choices == ["Small", "Medium", "Large", "Extra large"])
        #expect(q.allowsOther)
    }

    @Test func aSignInAsksTheUserToDoItThenGoOn() throws {
        let q = try #require(UltrafastBridge.question(fromDone: done([
            "question": "Stopped: sign in to DoorDash in this tab", "question_kind": "do_it"])))
        #expect(q.choices == [AgentRun.didItChoice])
        #expect(!q.allowsOther)
        #expect(q.question.hasPrefix("Sign in to DoorDash in this tab."))
        #expect(q.choice(matching: "ok I signed in") == AgentRun.didItChoice)
        // An older runner without a kind: the same "do it, then keep going".
        let old = try #require(UltrafastBridge.question(fromDone: done(["question": "Pick your Google account."])))
        #expect(old.choices == [AgentRun.didItChoice])
    }

    @Test func onlyANeedsUserStopWithAQuestionPauses() {
        #expect(UltrafastBridge.question(fromDone: done([:])) == nil)                                    // no question
        #expect(UltrafastBridge.question(fromDone: done(["question": "  "])) == nil)
        #expect(UltrafastBridge.question(fromDone: done(["question": "Which?", "outcome": "not_achieved"])) == nil)
        #expect(UltrafastBridge.question(fromDone: done(["question": "Which?", "status": "done", "outcome": "achieved"])) == nil)
        #expect(UltrafastBridge.question(fromDone: done(["question": "Which?", "status": "cancelled"])) == nil)
    }

    @Test func navisPurchaseHandOffIsNeverAQuestion() {
        #expect(UltrafastBridge.question(fromDone: done([
            "question": "Place the order?", "summary": "Ready for you to place the order — Navi never pays. Big Mac in the bag."])) == nil)
        #expect(UltrafastBridge.question(fromDone: done([
            "question": "Ready to check out?", "answer": "The burger is in the cart; place the order when you're ready."])) == nil)
    }

    @Test func theAnswersRideIntoTheRerun() throws {
        #expect(UltrafastBridge.userSaidJSON([]) == nil)
        let json = try #require(UltrafastBridge.userSaidJSON([.init(question: "Which size do you want?", reply: "Large")]))
        let list = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: String]])
        #expect(list == [["question": "Which size do you want?", "reply": "Large"]])
    }

    @Test func aPauseIsItsOwnOutcome() {
        let q = AgentQuestion(question: "Which size?", choices: ["Small", "Large"])
        let pause = UltrafastBridge.Pause(question: q, url: "https://x.test", tab: "T1", steps: 4, summary: "Stopped")
        #expect(UltrafastBridge.RunOutcome.paused(pause) != .failed)
        #expect(UltrafastBridge.RunOutcome.paused(pause) == .paused(pause))
    }
}
