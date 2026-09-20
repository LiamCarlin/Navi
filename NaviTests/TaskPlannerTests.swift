import Foundation
import Testing
@testable import Navi

@Suite struct TaskPlannerTests {
    @Test func parsesTwoStepPlanWithResultHandoff() {
        let raw = """
        ```json
        {"steps":[
          {"surface":"browser","goal":"Find the current weather forecast","query":"current weather","needs_result":true},
          {"surface":"app","app":"Messages","goal":"Send Bella a text message with the weather: {{result}}"}
        ]}
        ```
        """
        let plan = TaskPlanner.parse(raw)
        #expect(plan?.steps.count == 2)
        #expect(plan?.steps[0].surface == .browser && plan?.steps[0].query == "current weather" && plan?.steps[0].needsResult == true)
        #expect(plan?.steps[1].surface == .app && plan?.steps[1].app == "Messages")
        #expect(plan?.isMultiStep == true)
        #expect(TaskPlanner.resolve(plan!.steps[1].goal, result: "72°F and sunny") == "Send Bella a text message with the weather: 72°F and sunny")
    }

    @Test func browserStepWithoutGoalUsesQuery() {
        let plan = TaskPlanner.parse(#"{"steps":[{"surface":"browser","query":"weather"}]}"#)
        #expect(plan?.steps.first?.goal == "Find: weather")
    }

    @Test func rejectsPlaceholderWithoutProducer() {
        let plan = TaskPlanner.parse(#"{"steps":[{"surface":"browser","goal":"find x"},{"surface":"app","app":"Notes","goal":"write {{result}}"}]}"#)
        #expect(plan == nil)
    }

    @Test func rejectsGarbageAndUnknownSurfaces() {
        #expect(TaskPlanner.parse("I can't help with that.") == nil)
        #expect(TaskPlanner.parse(#"{"steps":[]}"#) == nil)
        #expect(TaskPlanner.parse(#"{"steps":[{"surface":"terminal","goal":"rm -rf /"}]}"#) == nil)
    }

    @Test func startURLPrefersExplicitThenKnownSiteThenQuery() {
        let front = FrontmostProbe.Info(bundleID: "com.apple.finder", appName: "Finder", windowTitle: nil, url: nil)
        var s = TaskPlanner.Step(surface: .browser, goal: "Find flights on google flights", query: "flights zurich london")
        #expect(TaskPlanner.startURL(for: s, frontmost: front) == "https://www.google.com/travel/flights?hl=en")
        s.goal = "Find the population of Iceland"
        #expect(TaskPlanner.startURL(for: s, frontmost: front) == "https://www.google.com/search?hl=en&q=flights%20zurich%20london")
        s.url = "https://en.wikipedia.org/wiki/Iceland"
        #expect(TaskPlanner.startURL(for: s, frontmost: front) == "https://en.wikipedia.org/wiki/Iceland")
        // "url" without a scheme gets https.
        #expect(TaskPlanner.parse(#"{"steps":[{"surface":"browser","goal":"g","url":"apple.com"}]}"#)?.steps[0].url == "https://apple.com")
    }

    @Test func currentTabOnlyWhenABrowserIsFrontmost() {
        let s = TaskPlanner.Step(surface: .browser, goal: "Summarize this page", useCurrentTab: true)
        let chrome = FrontmostProbe.Info(bundleID: "com.google.Chrome", appName: "Google Chrome", windowTitle: "arXiv", url: "https://arxiv.org/abs/1")
        #expect(TaskPlanner.startURL(for: s, frontmost: chrome) == "https://arxiv.org/abs/1")
        let finder = FrontmostProbe.Info(bundleID: "com.apple.finder", appName: "Finder", windowTitle: nil, url: nil)
        #expect(TaskPlanner.startURL(for: s, frontmost: finder).hasPrefix("https://www.google.com/search"))
    }

    @Test func prefillContinuationIsRestored() {
        // The model continues `{"steps":[` — the prefix is not in its reply.
        let cont = #"{"surface":"browser","goal":"Find the driving time from Olin to Northeastern leaving at 6pm","query":"directions Olin to Northeastern"}]}"#
        let plan = TaskPlanner.parse(TaskPlanner.completePrefilled(cont))
        #expect(plan?.steps.count == 1 && plan?.steps[0].query == "directions Olin to Northeastern")
        // A model that repeats the prefill anyway still parses.
        #expect(TaskPlanner.parse(TaskPlanner.completePrefilled(#"{"steps":[{"surface":"app","app":"Notes","goal":"g"}]}"#))?.steps.count == 1)
        // Prose in the continuation is still garbage.
        #expect(TaskPlanner.parse(TaskPlanner.completePrefilled("I need to clarify the task")) == nil)
    }

    @Test func pruneDropsReportingStepsAndUnnamedAssistants() {
        let task = "i want to leave olin at 6pm today to drive to northeastern can you go to maps and get the time it is going to take"
        let plan = TaskPlanner.parse(#"{"steps":[{"surface":"browser","goal":"Find the driving time from Olin to Northeastern leaving at 6pm","needs_result":true},{"surface":"app","app":"ChatGPT","goal":"Tell me the driving time: {{result}}"}]}"#)!
        let pruned = TaskPlanner.prune(plan, task: task)
        #expect(pruned.steps.count == 1 && pruned.steps[0].surface == .browser)
        // A real hand-off (Messages) survives.
        let text = TaskPlanner.parse(#"{"steps":[{"surface":"browser","goal":"Find the score","needs_result":true},{"surface":"app","app":"Messages","goal":"Text Bella: {{result}}"}]}"#)!
        #expect(TaskPlanner.prune(text, task: "get the score and text bella").steps.count == 2)
        // An assistant the user asked for is kept.
        let asked = TaskPlanner.parse(#"{"steps":[{"surface":"browser","goal":"Find x","needs_result":true},{"surface":"browser","goal":"Ask ChatGPT to summarise: {{result}}","url":"https://chatgpt.com"}]}"#)!
        #expect(TaskPlanner.prune(asked, task: "find x then ask chatgpt to summarise it").steps.count == 2)
        // A single step is never pruned.
        let one = TaskPlanner.parse(#"{"steps":[{"surface":"app","app":"ChatGPT","goal":"Tell me a joke"}]}"#)!
        #expect(TaskPlanner.prune(one, task: "tell me a joke").steps.count == 1)
    }
}
