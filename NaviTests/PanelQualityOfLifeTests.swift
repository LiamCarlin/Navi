import Foundation
import Testing
@testable import Navi

/// The ⌘Space panel's keyboard niceties (2026-10-31, after Spotlight / Raycast / the chat apps):
/// ⎋ clears before it closes, ↑ on an empty bar walks saved searches, the footer names the
/// selected row's action, and a finished answer takes a follow-up (⇥) that carries the thread.
@MainActor
struct PanelQualityOfLifeTests {

    private static func row(_ kind: ResultKind, hint: String?) -> SearchResult {
        SearchResult(id: UUID().uuidString, kind: kind, title: "x", subtitle: nil, icon: .system("sparkle"),
                     shortcutHint: hint) { .dismiss }
    }

    // MARK: Footer verb

    @Test func footerVerbIsTheSelectedRowsAction() {
        #expect(PanelWording.primaryVerb(Self.row(.app, hint: "⏎ Switch to")) == "switch to")
        #expect(PanelWording.primaryVerb(Self.row(.calculation, hint: "⏎ Copy")) == "copy")
        #expect(PanelWording.primaryVerb(Self.row(.answer, hint: "⏎ Ask")) == "ask")
    }

    @Test func footerVerbFallsBackByKind() {
        #expect(PanelWording.primaryVerb(nil) == "ask")
        #expect(PanelWording.primaryVerb(Self.row(.task, hint: nil)) == "run")
        #expect(PanelWording.primaryVerb(Self.row(.webSearch, hint: nil)) == "search")
        #expect(PanelWording.primaryVerb(Self.row(.file, hint: "⌘⏎ Reveal")) == "open")
    }

    // MARK: ⎋

    @Test func escapeClearsTheQueryBeforeClosing() {
        let vm = PanelViewModel.preview(query: "maps", results: PanelViewModel.sampleResults)
        var dismissed = false
        vm.onDismiss = { dismissed = true }
        vm.escape()
        #expect(vm.query.isEmpty)
        #expect(!dismissed)
        vm.escape()
        #expect(dismissed)
    }

    // MARK: ↑ history

    @Test func upOnAnEmptyBarWalksSavedSearches() {
        let saved = UserDefaults.navi.stringArray(forKey: QueryRouter.recentQueriesKey)
        defer { UserDefaults.navi.set(saved, forKey: QueryRouter.recentQueriesKey) }
        UserDefaults.navi.set(["newest", "older"], forKey: QueryRouter.recentQueriesKey)

        let vm = PanelViewModel.preview()
        vm.moveSelection(-1)
        #expect(vm.query == "newest")
        vm.moveSelection(-1)
        #expect(vm.query == "older")
        vm.moveSelection(-1)                 // nothing further back: stays
        #expect(vm.query == "older")
        vm.query = "older!"                  // an edit ends the walk: ↑ moves in the results again
        vm.moveSelection(-1)
        #expect(vm.query == "older!")
    }

    // MARK: Follow-ups

    @Test func threadTurnQuotesTheQuestionAndCutsLongAnswers() {
        #expect(PanelViewModel.threadTurn(question: "why", answer: " because \n") == "“why” → because")
        let long = PanelViewModel.threadTurn(question: "q", answer: String(repeating: "a", count: 2000))
        #expect(long.hasSuffix("…"))
        #expect(long.count < 1520)
    }

    @Test func tabTurnsTheBarIntoAFollowUpBoxAndEscapeComesBack() {
        let vm = PanelViewModel.preview(query: "explain dns", mode: .answer, answer: "DNS turns names into addresses.")
        #expect(vm.canFollowUp)
        vm.beginFollowUp()
        #expect(vm.isFollowingUp)
        #expect(vm.query.isEmpty)
        #expect(vm.answerThread == ["“explain dns” → DNS turns names into addresses."])

        vm.query = "and what is a TTL"       // typing stays on the answer
        #expect(vm.mode == .answer)
        #expect(!vm.canFollowUp)

        vm.escape()
        #expect(!vm.isFollowingUp)
        #expect(vm.query == "explain dns")
        #expect(vm.answerThread.isEmpty)
        #expect(vm.mode == .answer)
    }

    @Test func noFollowUpWhileStreamingOrWithoutAnAnswer() {
        #expect(!PanelViewModel.preview(query: "q", mode: .answer, answer: "partial", isAnswering: true).canFollowUp)
        #expect(!PanelViewModel.preview(query: "q", mode: .answer, answer: "").canFollowUp)
        #expect(!PanelViewModel.preview(query: "q", results: PanelViewModel.sampleResults).canFollowUp)
    }
}
