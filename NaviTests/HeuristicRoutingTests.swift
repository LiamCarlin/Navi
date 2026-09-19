import Testing
import Foundation
@testable import Navi

struct HeuristicRoutingTests {
    let router = RouterFakes.router()

    private func intent(_ q: String) -> Intent { router.heuristicRoute(query: q).intent }

    @Test func appName() { #expect(intent("maps") == .openApp); #expect(intent("open slack") == .openApp) }
    @Test func url() { #expect(intent("github.com") == .openURL); #expect(intent("go to localhost:3000") == .openURL) }
    @Test func math() { #expect(intent("12*34") == .calculate); #expect(intent("5 km in miles") == .calculate); #expect(intent("20 usd in eur") == .calculate) }
    @Test func systemCommand() { #expect(intent("sleep") == .systemCommand); #expect(intent("toggle dark mode") == .systemCommand); #expect(intent("quit slack") == .systemCommand) }
    @Test func memory() {
        #expect(intent("what was i working on yesterday") == .recallMemory)
        #expect(intent("that article about jev i read earlier") == .recallMemory)
    }
    @Test func computerTask() {
        #expect(intent("open chrome and search for cats") == .computerTask)
        #expect(intent("go to amazon then add headphones to cart") == .computerTask)
        #expect(intent("send an email to bob about lunch") == .computerTask)
        #expect(intent("book a table for two tonight") == .computerTask)
    }
    @Test func question() {
        #expect(intent("what's the capital of peru") == .askQuestion)
        #expect(intent("explain dns") == .askQuestion)
        #expect(intent("is it going to rain") == .askQuestion)
        #expect(intent("ramen?") == .askQuestion)
    }
    @Test func longTextIsQuestion() { #expect(intent("write a haiku about the ocean at dusk") == .askQuestion) }
    @Test func shortPhraseIsWebSearch() { #expect(intent("best ramen in sf") == .webSearch) }
    @Test func file() { #expect(intent("budget.xlsx") == .openFile); #expect(intent("find the tax pdf") == .openFile) }
    @Test func settings() { #expect(intent("navi settings") == .settings); #expect(intent("settings for navi") == .settings) }
    @Test func settingsAliasStillOpensSystemSettings() { #expect(intent("settings") == .openApp) }
    @Test func decisionShape() {
        let d = router.heuristicRoute(query: "maps")
        #expect(d.source == .heuristic)
        #expect(d.probabilities[.openApp] == d.confidence)
        #expect(!d.needsClarification && !d.isRisky)
    }

    @Test func jevDecisionMappingAndGating() throws {
        let json = """
        {"model":"jev-latest","answers":{
          "intent":{"type":"choice","choice":"webSearch","probabilities":{"webSearch":0.4,"openApp":0.35,"askQuestion":0.25},"confidence":0.3},
          "is_risky":{"type":"noul","noul":0.1},
          "needs_clarification":{"type":"noul","noul":0.8},
          "wants_memory":{"type":"noul","noul":0.9}},
         "usage":{"input_tokens":100,"output_tokens":10}}
        """
        let resp = try JevClient.parse(Data(json.utf8), latencyMs: 120)
        let local = router.localSignals(for: "maps")
        let r = try #require(QueryRouter.decision(from: resp, local: local, threshold: 0.55, latencyMs: 120))
        #expect(r.0.intent == .openApp)               // gated: low confidence + strong local app match
        #expect(r.0.source == .jev)
        #expect(r.0.needsClarification)
        #expect(!r.0.isRisky)
        #expect(r.0.probabilities[.webSearch] == 0.4)
        #expect(r.1.wantsMemory == 0.9)

        let noApp = router.localSignals(for: "best ramen in sf")
        let r2 = try #require(QueryRouter.decision(from: resp, local: noApp, threshold: 0.55, latencyMs: 120))
        #expect(r2.0.intent == .webSearch)             // nothing to gate to
    }

    @Test func instantResultsShapeAndOrder() async {
        await MainActor.run {
            let rows = router.instantResults(for: "maps", context: .empty)
            #expect(rows.first?.id == "app:com.apple.Maps")
            #expect(rows.first?.kind == .app)
            #expect(rows.dropLast().last?.id == "ask:maps")
            #expect(rows.last?.id == "web:maps")
            let calc = router.instantResults(for: "12*34", context: .empty)
            #expect(calc.first?.kind == .calculation && calc.first?.title == "408")
            #expect(router.instantResults(for: "   ", context: .empty).isEmpty)
        }
    }
}
