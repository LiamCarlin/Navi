import Testing
import Foundation
@testable import Navi

struct ClarificationTests {
    @Test func parsesPlainJSON() throws {
        let p = try #require(AnswerService.parseClarification(
            #"{"question":"Send what, and to whom?","options":["Email Bob the link","Text Bob the link"]}"#,
            query: "send it to him"))
        #expect(p.originalQuery == "send it to him")
        #expect(p.question == "Send what, and to whom?")
        #expect(p.options == ["Email Bob the link", "Text Bob the link"])
    }

    @Test func toleratesFencesAndProse() throws {
        let text = """
        Sure — here you go:
        ```json
        {"question": " Which Bob? ", "options": [" Email Bob Smith ", "Email Bob Jones", "email bob smith", "", 42]}
        ```
        """
        let p = try #require(AnswerService.parseClarification(text, query: "email bob"))
        #expect(p.question == "Which Bob?")
        #expect(p.options == ["Email Bob Smith", "Email Bob Jones"])   // trimmed, de-duplicated case-insensitively, junk dropped
    }

    @Test func capsOptions() throws {
        let opts = (1...7).map { "\"Option \($0)\"" }.joined(separator: ",")
        let p = try #require(AnswerService.parseClarification(#"{"question":"Which?","options":[\#(opts)]}"#, query: "q"))
        #expect(p.options.count == ClarificationPrompt.maxOptions)
        #expect(p.options.first == "Option 1")
    }

    @Test func rejectsGarbage() {
        #expect(AnswerService.parseClarification("I'm not sure what you mean.", query: "q") == nil)
        #expect(AnswerService.parseClarification(#"{"options":["a"]}"#, query: "q") == nil)
        #expect(AnswerService.parseClarification(#"{"question":"   "}"#, query: "q") == nil)
        #expect(AnswerService.parseClarification("{not json}", query: "q") == nil)
    }

    @Test func refinedQueries() {
        let p = ClarificationPrompt(originalQuery: "send it to him", question: "To whom?", options: ["Email Bob the link"])
        #expect(p.refinedQuery(option: 0) == "Email Bob the link")
        #expect(p.refinedQuery(option: 1) == nil)
        #expect(p.refinedQuery(typed: "  ") == nil)
        #expect(p.refinedQuery(typed: " to Alice, the pdf ") == "send it to him — to Alice, the pdf")
    }

    @Test func instructionsDemandJSONAndFullRequests() {
        let i = AnswerService.clarificationInstructions
        #expect(i.contains("\"question\"") && i.contains("\"options\""))
        #expect(i.contains("COMPLETE"))
        #expect(i.contains("2 to 4"))
    }
}
