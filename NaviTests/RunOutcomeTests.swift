import Foundation
import Testing
@testable import Navi

/// Truthful, typed outcomes and the stuck → Claude takeover policy (2026-10-30): a run is
/// completed only when the screen reader's verdict is achieved, and a stuck Jev hands the next
/// steps to Claude instead of ending the run. Pure logic only — no network, no Accessibility.
struct RunOutcomeTests {

    // MARK: Verdicts

    @Test func verdictsParseLoosely() {
        #expect(RunVerdict(loose: "achieved") == .achieved)
        #expect(RunVerdict(loose: "Not achieved") == .notAchieved)
        #expect(RunVerdict(loose: "needs-user") == .needsUser)
        #expect(RunVerdict(loose: "not_achieved") == .notAchieved)
        #expect(RunVerdict(loose: "banana") == nil)
        #expect(RunVerdict.achieved.isSuccess && !RunVerdict.partial.isSuccess)
    }

    /// The false "completed" answers in agent-runs.log (2026-10-29/30) all say they were not done.
    @Test func answersThatSayTheyFailedAreNotDone() {
        for t in ["I couldn't open DoorDash from here - the screen is still showing your Amazon cart.",
                  "I cannot complete the \"add to cart\" action as I can only view and report on visible text.",
                  "The song playing isn't confirmed as the newest one.",
                  "I don't see a playlist named Focus in your library.",
                  "The note titled Student Spark hasn't been created yet."] {
            #expect(CUWriter.saysNotDone(t), "\(t)")
        }
        for t in ["Music is playing now: Ain't In LA by Adéla.", "The note Student Spark now says hello class.",
                  "Big Mac is in your bag — ready for you to place the order."] {
            #expect(!CUWriter.saysNotDone(t), "\(t)")
        }
    }

    @Test func theWriterAnswerCarriesATypedVerdict() {
        let a = CUWriter.parseAnswer(["verdict": "needs_user", "answer": "Pick your Google account.", "focus": "", "question": ""])
        #expect(a?.verdict == .needsUser && a?.achieved == false)
        // An "achieved" whose own words say it was not done is not believed.
        let b = CUWriter.parseAnswer(["verdict": "achieved", "answer": "I couldn't add it to the bag.", "focus": "", "question": ""])
        #expect(b?.verdict == .partial && b?.achieved == false)
        // The older boolean still parses.
        #expect(CUWriter.parseAnswer(["achieved": true, "answer": "Done."])?.verdict == .achieved)
        #expect(CUWriter.parseAnswer(["answer": "x"]) == nil)
        // The schema asks for the verdict as an enum, written after the answer.
        let props = CUWriter.answerSchema["properties"] as? [String: [String: Any]]
        #expect((props?["verdict"]?["enum"] as? [String])?.contains("impossible") == true)
        #expect(props?["achieved"] == nil)
    }

    @Test func theRunnersOutcomeMapsToAVerdict() {
        #expect(UltrafastBridge.verdict(status: "done", outcome: "achieved") == .achieved)
        #expect(UltrafastBridge.verdict(status: "done", outcome: nil) == .achieved)            // older runner
        #expect(UltrafastBridge.verdict(status: "blocked", outcome: "needs_user") == .needsUser)
        #expect(UltrafastBridge.verdict(status: "blocked", outcome: "achieved") == .notAchieved) // never success when blocked
        #expect(UltrafastBridge.verdict(status: "blocked", outcome: nil) == .notAchieved)
        #expect(UltrafastBridge.verdict(status: "cancelled", outcome: nil) == nil)
    }

    @Test func navNeverPays() {
        #expect(JevGate.paysKeyword(in: "Place Order · $11.59") == "place order")
        #expect(JevGate.paysKeyword(in: "Buy Now") != nil && JevGate.paysKeyword(in: "Pay $12.40") != nil)
        #expect(JevGate.paysKeyword(in: "Add to cart") == nil && JevGate.paysKeyword(in: "Payment methods") == nil)
    }

    // MARK: Escalation

    static func answer(_ v: RunVerdict, focus: String = "", question: String = "") -> CUWriter.Answer {
        .init(text: "t", achieved: v == .achieved, focus: focus, question: question, verdict: v)
    }

    @Test func aStopLeadsWhereTheVerdictSays() {
        typealias E = CUEscalation
        // Goal already met (Chipotle's full cart while Jev re-saved a field): done, not stuck.
        #expect(E.next(Self.answer(.achieved), outcome: .stuck, mayResume: false, takeoverAvailable: true) == .complete)
        #expect(E.next(Self.answer(.impossible, focus: "x"), outcome: .stalled, mayResume: true, takeoverAvailable: true) == .end)
        #expect(E.next(Self.answer(.notAchieved, question: "Which playlist?"), outcome: .lowConfidence, mayResume: true, takeoverAvailable: true) == .askUser)
        #expect(E.next(Self.answer(.needsUser), outcome: .lowConfidence, mayResume: true, takeoverAvailable: true) == .end)
        // A clear next move: Jev first, while it has hand-offs.
        #expect(E.next(Self.answer(.notAchieved, focus: "Click 'Body'"), outcome: .lowConfidence, mayResume: true, takeoverAvailable: true)
                == .resumeJev("Click 'Body'"))
        // Stuck (focuses did not help), or a focus Jev could not act on: Claude drives.
        #expect(E.next(Self.answer(.notAchieved, focus: "Click 'Body'"), outcome: .stuck, mayResume: false, takeoverAvailable: true) == .takeover)
        #expect(E.next(Self.answer(.partial, focus: "f"), outcome: .stalled, mayResume: true, takeoverAvailable: true, focusWasTried: true) == .takeover)
        // Out of hand-offs or steps, a next move still exists: take over instead of ending with it as prose.
        #expect(E.next(Self.answer(.notAchieved, focus: "Click 'Body'"), outcome: .stepLimit, mayResume: false, takeoverAvailable: true) == .takeover)
        // Nothing left to try.
        #expect(E.next(Self.answer(.notAchieved, focus: "f"), outcome: .stuck, mayResume: false, takeoverAvailable: false) == .end)
        // A screen Jev can't be offered (a sheet with only Close): Claude's eyes, not another Jev guess.
        #expect(E.next(Self.answer(.notAchieved, focus: "Click 'Continue with Google'"), outcome: .perceptionGap, mayResume: true, takeoverAvailable: true) == .takeover)
        #expect(E.next(Self.answer(.notAchieved, focus: "f"), outcome: .perceptionGap, mayResume: true, takeoverAvailable: false) == .resumeJev("f"))
    }

    @Test func aTakeoverHandsBackOnlyOnProgress() {
        typealias E = CUEscalation
        #expect(E.handback(saidDone: true, stoppedFor: nil, screenMoved: false, acted: false) == .verify)
        #expect(E.handback(saidDone: false, stoppedFor: "Sign in with your password", screenMoved: true, acted: true) == .needsUser("Sign in with your password"))
        #expect(E.handback(saidDone: false, stoppedFor: nil, screenMoved: true, acted: true) == .resume)
        #expect(E.handback(saidDone: false, stoppedFor: nil, screenMoved: false, acted: true) == .stop)
        #expect(E.handback(saidDone: false, stoppedFor: nil, screenMoved: true, acted: false) == .stop)
    }

    @Test func afterATakeoverJevStartsClean() {
        var run = CURunState()
        run.idle = 2; run.repeats = 1; run.stalls = 2
        run.afterTakeover("Claude (vision) took over: Did: opened the cart")
        #expect(run.idle == 0 && run.repeats == 0 && run.stalls == 0 && run.last == nil)
        #expect(run.history.last == "Claude (vision) took over: Did: opened the cart")
    }
}
