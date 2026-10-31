import Foundation
import Testing
@testable import Navi

/// A paused run's multiple-choice question (2026-10-31): the writer returns clickable answers with
/// its question, the run waits for the reply instead of ending, and the panel / voice island answer
/// it from a click, the bar's text or a spoken reply. Pure logic only.
@MainActor
struct AgentQuestionTests {

    static let size = AgentQuestion(question: "Which size?", detail: "The Big Mac comes in three sizes.",
                                    choices: ["Small", "Medium", "Large"])

    // MARK: The question

    @Test func choicesAreTidied() {
        let q = AgentQuestion(question: " Which one? ", detail: "Which one?",
                              choices: ["  Small ", "small", "", "• Medium", "Large", "Extra large", "Huge"])
        #expect(q.question == "Which one?")
        #expect(q.detail.isEmpty)                    // the same words twice are shown once
        #expect(q.choices == ["Small", "Medium", "Large", "Extra large"])
    }

    @Test func aReplyNamesAChoiceByNumberOrWords() {
        let q = Self.size
        #expect(q.choice(matching: "2") == "Medium")
        #expect(q.choice(matching: "the third one") == "Large")
        #expect(q.choice(matching: "Large.") == "Large")
        #expect(q.choice(matching: "the large one please") == "Large")
        #expect(q.choice(matching: "5") == nil)
        #expect(q.choice(matching: "no pickles") == nil)
        // Two choices share the words said: neither is meant.
        let d = AgentQuestion(question: "Which?", choices: ["Big Mac meal", "Big Mac"])
        #expect(d.choice(matching: "big mac") == "Big Mac")       // exact words win
        #expect(d.choice(matching: "the mac") == nil)
    }

    @Test func aGoAheadPicksTheOnlyAnswerToDoItYourself() {
        let q = AgentQuestion(question: AgentRun.yourTurn("Stopped: the site wants you to sign in"),
                              choices: [AgentRun.didItChoice], allowsOther: false)
        #expect(q.question == "The site wants you to sign in. Do it on screen, then tell Navi to keep going.")
        for r in ["done", "ok I signed in", "keep going", "yes"] { #expect(q.choice(matching: r) == AgentRun.didItChoice, "\(r)") }
        #expect(q.choice(matching: "open spotify") == nil)
        // A real question never takes "ok" as one of its answers.
        #expect(Self.size.choice(matching: "ok") == nil)
    }

    // MARK: The writer

    @Test func theWriterAsksWithClickableAnswers() {
        let a = CUWriter.parseAnswer(["verdict": "not_achieved", "answer": "The menu lists three sizes.", "focus": "",
                                      "question": "Which size?", "question_choices": ["Small", "Medium", "Large", "medium"]])
        #expect(a?.question == "Which size?")
        #expect(a?.choices == ["Small", "Medium", "Large"])
        // No question ⇒ no choices, whatever came back.
        let b = CUWriter.parseAnswer(["verdict": "not_achieved", "answer": "x", "focus": "Click 'Menu'", "question": "",
                                      "question_choices": ["a"]])
        #expect(b?.choices == [])
        // Older replies without the field still parse.
        #expect(CUWriter.parseAnswer(["verdict": "partial", "answer": "x", "focus": "", "question": "Which?"])?.choices == [])
        let props = CUWriter.answerSchema["properties"] as? [String: [String: Any]]
        #expect(props?["question_choices"]?["type"] as? String == "array")
        #expect((CUWriter.answerSchema["required"] as? [String])?.contains("question_choices") == true)
    }

    @Test func aReplyCountsAsNewGround() {
        var run = CURunState()
        run.stalls = 2; run.idle = 2; run.repeats = 1
        run.afterReply(question: "Which size?", reply: "Large")
        #expect(run.stalls == 0 && run.idle == 0 && run.repeats == 0)
        #expect(run.guidance.exchanges == [.init(question: "Which size?", reply: "Large")])
        #expect((run.guidance.state()["user_said"] as? [[String: String]])?.first?["replied"] == "Large")
        #expect(run.history.last?.contains("Large") == true)
    }

    // MARK: Voice

    @Test func aSpokenReplyAnswersTheQuestion() {
        typealias D = VoiceDecider
        let q = Self.size
        #expect(D.questionReply(head: "the second one", silenceMs: 0, question: q) == .answer("Medium"))
        // Its own words wait for the user to finish, then answer.
        if case .wait = D.questionReply(head: "make it a large with no pickles", silenceMs: 200, question: q) {} else { Issue.record("should wait") }
        #expect(D.questionReply(head: "make it a large with no pickles", silenceMs: D.pauseMs, question: q) == .answer("make it a large with no pickles"))
        #expect(D.questionReply(head: "No pickles.", silenceMs: D.sentencePauseMs, question: q) == .answer("No pickles"))
        // "Stop" is never an answer: it stops the task.
        #expect(D.questionReply(head: "stop", silenceMs: 2000, question: q) == .notAReply)
        // "Do it yourself" questions take only a go-ahead.
        let mine = AgentQuestion(question: "Sign in.", choices: [AgentRun.didItChoice], allowsOther: false)
        #expect(D.questionReply(head: "okay done", silenceMs: 0, question: mine) == .answer(AgentRun.didItChoice))
        #expect(D.questionReply(head: "open spotify", silenceMs: D.pauseMs, question: mine) == .notAReply)
    }

    // MARK: Panel

    @Test func whatIsTypedSelectsAnAnswer() {
        let q = Self.size
        #expect(PanelViewModel.questionSelection(for: "", question: q) == 0)
        #expect(PanelViewModel.questionSelection(for: "large", question: q) == 2)
        #expect(PanelViewModel.questionSelection(for: "no pickles", question: q) == 3)        // the typed answer
        let mine = AgentQuestion(question: "Sign in.", choices: [AgentRun.didItChoice], allowsOther: false)
        #expect(PanelViewModel.questionSelection(for: "hmm", question: mine) == 0)
    }

    @Test func typingWhileAQuestionIsUpAnswersInsteadOfSearching() {
        let vm = PanelViewModel.preview(mode: .agent, agentTask: "order a big mac", pendingQuestion: Self.size)
        vm.query = "large"
        #expect(vm.mode == .agent)                    // the task stays; the bar is the reply box
        #expect(vm.questionSelection == 2)
        vm.query = "no pickles"
        #expect(vm.mode == .agent && vm.questionSelection == 3)
        vm.escape()                                    // ⎋ clears the half-typed answer first
        #expect(vm.query.isEmpty && vm.mode == .agent && vm.pendingQuestion != nil)
    }

    @Test func answeringSendsTheReplyToTheRun() {
        let vm = PanelViewModel.preview(mode: .agent, agentTask: "order a big mac", pendingQuestion: Self.size)
        final class Box: @unchecked Sendable { var got: AgentApproval? }
        let box = Box()
        let handle = AgentRunHandle(task: "order a big mac", cancel: {}, respond: { box.got = $0 })
        vm.replaceRunForTesting(handle)
        vm.moveSelection(1)
        vm.performSelected()
        guard case .answer(let id, let reply)? = box.got else { Issue.record("no answer sent"); return }
        #expect(id == Self.size.id && reply == "Medium")
        #expect(vm.pendingQuestion == nil)
    }
}
