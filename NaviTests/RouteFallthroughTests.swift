import Testing
import Foundation
@testable import Navi

/// ⏎ does what Jev routed (taskbench overnight-20261101): an action intent must never
/// fall through to the "Ask Navi" answer row, which can only say "I can't open apps".
@MainActor
struct RouteFallthroughTests {
    let router = RouterFakes.router()

    private func row(_ id: String, _ kind: ResultKind, score: Double) -> SearchResult {
        SearchResult(id: id, kind: kind, title: id, icon: .system("circle"), score: score) { .keepOpen }
    }
    private var ask: SearchResult { row("ask:q", .answer, score: 0.05) }
    private var web: SearchResult { row("web:q", .webSearch, score: 0.02) }

    // MARK: Merge order (pure)

    @Test func actionRowBeatsTheEverPresentAskAndWebRows() {
        // web-001 "open youtube": the instant list held only Ask Navi + web search.
        let routed = [row("webapp:https://youtube.com", .url, score: 0.97), row("web:q", .webSearch, score: 0.3)]
        let merged = PanelViewModel.merge(instant: [ask, web], routed: routed, decision: .heuristic(.openApp, confidence: 0.79))
        #expect(merged.map(\.id) == ["webapp:https://youtube.com", "ask:q", "web:q"])
        #expect(PanelViewModel.submitIndex(results: merged, decision: .heuristic(.openApp)) == 0)
    }

    @Test func openFileRoutedRowsLeadAndOpenItIsPinned() {
        // memory-005: 9 rows, TaskGrounding resolved the assignment, yet ⏎ answered.
        let routed = [row("open-it:q", .task, score: 0.97), row("file:/a.pdf", .file, score: 0.7), row("file:/b.pdf", .file, score: 0.69)]
        let merged = PanelViewModel.merge(instant: [ask, web], routed: routed, decision: .heuristic(.openFile, confidence: 0.82))
        #expect(merged.first?.id == "open-it:q")
        #expect(merged.prefix(3).allSatisfy { !QueryRouter.isFallbackRow($0) })
        #expect(merged.suffix(2).map(\.id) == ["ask:q", "web:q"])
    }

    @Test func openItLeadsEvenARecallAnswer() {
        // memory-008 "pull up that video from yesterday" routed recallMemory: the Open-it row was last.
        let routed = [row("ask-memory:q", .answer, score: 0.95), row("memory:1", .memory, score: 0.9), row("open-it:q", .task, score: 0.97)]
        let merged = PanelViewModel.merge(instant: [ask, web], routed: routed, decision: .heuristic(.recallMemory, confidence: 0.47))
        #expect(merged.first?.id == "open-it:q")
        #expect(merged[1].id == "ask-memory:q")
    }

    @Test func strongInstantAppStillLeads() {
        let maps = row("app:com.apple.Maps", .app, score: 1.0)
        let routed = [maps, row("app-switch:com.apple.Maps", .app, score: 0.5)]
        let merged = PanelViewModel.merge(instant: [maps, ask, web], routed: routed, decision: .heuristic(.openApp, confidence: 0.98))
        #expect(merged.map(\.id) == ["app:com.apple.Maps", "app-switch:com.apple.Maps", "ask:q", "web:q"])
    }

    @Test func questionsStillLeadWithTheAnswer() {
        let routed = [row("ask:q", .answer, score: 0.95), row("web:q", .webSearch, score: 0.2)]
        let merged = PanelViewModel.merge(instant: [ask, web], routed: routed, decision: .heuristic(.askQuestion, confidence: 0.9))
        #expect(merged.first?.id == "ask:q")
        #expect(PanelViewModel.submitIndex(results: merged, decision: .heuristic(.askQuestion)) == 0)
    }

    @Test func submitSkipsFallbackRowsForActionsOnly() {
        let rows = [ask, web, row("task:q", .task, score: 0.9)]
        #expect(PanelViewModel.submitIndex(results: rows, decision: .heuristic(.openApp)) == 2)
        #expect(PanelViewModel.submitIndex(results: rows, decision: .heuristic(.systemCommand)) == 2)
        #expect(PanelViewModel.submitIndex(results: rows, decision: .heuristic(.webSearch)) == 0)
        #expect(PanelViewModel.submitIndex(results: [ask, web], decision: .heuristic(.openApp)) == 0)
        // A clarified refinement prefers its kind.
        #expect(PanelViewModel.submitIndex(results: rows, decision: .heuristic(.openApp), preferred: .webSearch) == 1)
    }

    // MARK: Fallback decision (pure)

    @Test func fallbackActionForRowlessActions() {
        #expect(QueryRouter.fallbackAction(for: "open youtube", hasSelection: false) == .openWebApp)
        #expect(QueryRouter.fallbackAction(for: "go to wikipedia", hasSelection: false) == .openWebApp)
        #expect(QueryRouter.fallbackAction(for: "open desmos", hasSelection: false) == .openWebApp)
        #expect(QueryRouter.fallbackAction(for: "go to next week", hasSelection: false) == .task)
        #expect(QueryRouter.fallbackAction(for: "show me the files changed", hasSelection: false) == .task)
        #expect(QueryRouter.fallbackAction(for: "open module 5", hasSelection: false) == .task)
        #expect(QueryRouter.fallbackAction(for: "open it", hasSelection: false) == .clarify)
        #expect(QueryRouter.fallbackAction(for: "open that one", hasSelection: false) == .clarify)
        #expect(QueryRouter.fallbackAction(for: "open it", hasSelection: true) == .task)
        #expect(QueryRouter.fallbackAction(for: "when is my next meeting", hasSelection: false) == .keepAnswer)
        #expect(QueryRouter.fallbackAction(for: "ramen?", hasSelection: false) == .keepAnswer)
    }

    @Test func namesAppToUseNeedsAnOpener() {
        #expect(QueryRouter.namesAppToUse("use the calculator to do 1200 divided by 16")?.name == "Calculator")
        #expect(QueryRouter.namesAppToUse("what's 12*4 in calculator")?.name == "Calculator")
        #expect(QueryRouter.namesAppToUse("calc 2 to the 20th") == nil)
        #expect(QueryRouter.namesAppToUse("5 km in miles") == nil)
        #expect(QueryRouter.namesAppToUse("whats 347 times 29") == nil)
    }

    @Test func noVerbReferenceToOwnWorkReopensOnlyWhenRoutedAsAnOpen() {
        // memory-009 "the doc I was working on yesterday" (Jev: openFile).
        #expect(QueryRouter.reopensOwnWork("the doc I was working on yesterday", intent: .openFile))
        #expect(!QueryRouter.reopensOwnWork("the doc I was working on yesterday", intent: .askQuestion))
        #expect(QueryRouter.reopensOwnWork("open the last assignment I did", intent: .openFile))
        #expect(!QueryRouter.reopensOwnWork("what's the capital of peru", intent: .openFile))
    }

    // MARK: Rows the router builds

    @MainActor @Test func rowlessOpenAppOpensTheNamedWebApp() async {
        for (q, host) in [("open youtube", "youtube.com"), ("open desmos", "desmos.com"), ("open canvas", "instructure.com")] {
            let rows = await router.results(for: q, decision: .heuristic(.openApp, confidence: 0.8), context: .empty)
            #expect(rows.first?.id.hasPrefix("webapp:") == true, "\(q): \(rows.map(\.id))")
            #expect(rows.first?.subtitle?.contains(host) == true, "\(q): \(rows.first?.subtitle ?? "")")
            let merged = PanelViewModel.merge(instant: router.instantResults(for: q, context: .empty), routed: rows,
                                              decision: .heuristic(.openApp, confidence: 0.8))
            #expect(merged.first?.id.hasPrefix("webapp:") == true, "\(q) merged: \(merged.map(\.id))")
        }
        let desmos = await router.results(for: "open desmos", decision: .heuristic(.openApp), context: .empty)
        #expect(desmos.first?.subtitle == "https://www.desmos.com/calculator")
    }

    @MainActor @Test func rowlessOpenURLOpensTheNamedSite() async {
        let rows = await router.results(for: "go to wikipedia", decision: .heuristic(.openURL, confidence: 0.9), context: .empty)
        #expect(rows.first?.subtitle?.contains("en.wikipedia.org") == true, "\(rows.map(\.id))")
    }

    @MainActor @Test func installedAppStillWinsOverAWebApp() async {
        let rows = await router.results(for: "open slack", decision: .heuristic(.openApp, confidence: 0.95), context: .empty)
        #expect(rows.first?.id == "app:com.tinyspeck.slackmacgap")
        #expect(!rows.contains { $0.id.hasPrefix("webapp:") || $0.id.hasPrefix("task:") })
    }

    @MainActor @Test func rowlessActionBecomesATaskNotAnAnswer() async {
        // calendar-005 "go to next week" (Jev: calculate 92%) with Calendar in front.
        let d = RouteDecision.heuristic(.calculate, confidence: 0.92)
        let rows = await router.results(for: "go to next week", decision: d, context: .empty)
        #expect(rows.first?.id == "task:go to next week")
        let merged = PanelViewModel.merge(instant: router.instantResults(for: "go to next week", context: .empty), routed: rows, decision: d)
        #expect(merged[PanelViewModel.submitIndex(results: merged, decision: d)].kind == .task)
    }

    @MainActor @Test func pronounOnlyOpenAsksInsteadOfLaunchingAnApp() async {
        // edge-003 "open it" over Mail launched TextEdit ("it" is a subsequence of it).
        #expect(router.appIndex.search("open it").isEmpty)
        let rows = await router.results(for: "open it", decision: .heuristic(.openApp, confidence: 0.59), context: .empty)
        #expect(rows.first?.id == "clarify:open it")
        #expect(!rows.contains { $0.kind == .app })
    }

    @MainActor @Test func explicitCalculatorAppRunsTheTask() async {
        let q = "use the calculator to do 1200 divided by 16"
        let d = RouteDecision.heuristic(.calculate, confidence: 0.9)
        let rows = await router.results(for: q, decision: d, context: .empty)
        #expect(rows.first?.id == "app-task:\(q)")
        let merged = PanelViewModel.merge(instant: router.instantResults(for: q, context: .empty), routed: rows, decision: d)
        #expect(merged.first?.id == "app-task:\(q)")
        // Plain math stays an instant inline answer.
        let plain = await router.results(for: "whats 347 times 29", decision: d, context: .empty)
        #expect(!plain.contains { $0.kind == .task })
    }

    @MainActor @Test func questionRoutedAsAnActionKeepsTheAnswer() async {
        let rows = await router.results(for: "when is my next meeting", decision: .heuristic(.openApp, confidence: 0.4), context: .empty)
        #expect(!rows.contains { $0.kind == .task || $0.id.hasPrefix("clarify:") })
    }

    @MainActor @Test func browserControlsWithABrowserInFront() {
        var chrome = QueryContext.empty
        chrome.frontmostApp = "com.google.Chrome"; chrome.frontmostAppName = "Google Chrome"
        #expect(QueryRouter.browserControlRow(for: "go back", context: chrome)?.title == "Going back")
        #expect(router.instantResults(for: "go back", context: chrome).first?.id.hasPrefix("browser:") == true)
        var mail = QueryContext.empty
        mail.frontmostApp = "com.apple.mail"
        #expect(QueryRouter.browserControlRow(for: "go back", context: mail) == nil)
        #expect(QueryRouter.browserControlRow(for: "go back to canvas", context: chrome) == nil)
    }

    // MARK: App names

    @Test func possessivesAndPronounsInAppQueries() {
        #expect(AppIndex.normalize("open my calendar") == "calendar")
        #expect(AppIndex.normalize("open the calculator") == "calculator")
        #expect(AppIndex.normalize("open up slack") == "slack")
        #expect(AppIndex.normalize("open it") == "")
        #expect(AppIndex.normalize("it") == "it")            // typed alone it is still the start of iTerm
        #expect(router.appIndex.search("open my calculator", limit: 1).first?.entry.name == "Calculator")
    }

    // MARK: Navi's own commands

    @Test func pauseScreenMemoryIsACommand() {
        #expect(SystemCommands.matches("pause screen memory for an hour").first?.action == .pauseMemory(minutes: 60))
        #expect(SystemCommands.matches("pause recall for 30 minutes").first?.action == .pauseMemory(minutes: 30))
        #expect(SystemCommands.matches("stop screen recording for 2 hours").first?.action == .pauseMemory(minutes: 120))
        #expect(SystemCommands.matches("pause memory until tomorrow").first?.action == .pauseMemory(minutes: nil))
        #expect(SystemCommands.matches("pause screen memory").first?.action == .pauseMemory(minutes: 60))
        #expect(SystemCommands.matches("resume screen memory").first?.action == .resumeMemory)
        #expect(!SystemCommands.matches("stop recording").contains { $0.action == .pauseMemory(minutes: 60) })
    }

    // MARK: Recall answers

    @Test func clockTimeNarrowsTheRecallWindow() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_793_500_000)          // 2026-11-01 ~02:27 UTC
        let today = cal.startOfDay(for: now)
        let (w, terms) = Recall.parseTimeWindow("what was I doing at 3pm yesterday", now: now, calendar: cal)
        let center = today.addingTimeInterval(-86_400 + 15 * 3600)
        #expect(w == DateInterval(start: center.addingTimeInterval(-2700), end: center.addingTimeInterval(2700)))
        #expect(terms == "what was i doing")
        // No day named and 3 PM has not come yet today: yesterday's.
        let (w2, _) = Recall.parseTimeWindow("what was I doing around 3:30 pm", now: now, calendar: cal)
        #expect(w2?.start == center.addingTimeInterval(30 * 60 - 2700))
    }

    @Test func thisMorningBeforeDawnMeansSinceMidnight() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_793_500_000)          // ~02:27, before 5 AM
        let (w, terms) = Recall.parseTimeWindow("what did I work on this morning", now: now, calendar: cal)
        #expect(w == DateInterval(start: cal.startOfDay(for: now), end: now))
        #expect(terms == "what did i work on")
    }

    @Test func emptyRecallSaysMemoryHasNothingNotNoAccess() {
        var ctx = QueryContext.empty
        ctx.memorySearched = true
        let p = AnswerService.systemPrompt(query: "what was I doing at 3pm yesterday", context: ctx, memory: [])
        #expect(p.contains("found no matching moments"))
        #expect(p.contains("Never tell the user you cannot open apps"))
        #expect(!AnswerService.systemPrompt(query: "explain dns", context: .empty, memory: []).contains("found no matching moments"))
    }
}
