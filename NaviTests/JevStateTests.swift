import Testing
import Foundation
@testable import Navi

struct JevStateTests {
    @Test func stateSnapshot() {
        let router = RouterFakes.router()
        var ctx = QueryContext.empty
        ctx.frontmostApp = "com.apple.Safari"
        ctx.frontmostAppName = "Safari"
        ctx.frontmostWindowTitle = "Hacker News"
        ctx.recentQueries = ["12*34", "github.com"]
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 10, minute: 30))!
        let local = router.localSignals(for: "maps")
        let state = QueryRouter.jevState(query: "maps", context: ctx, local: local, now: now, timeZone: tz)
        let expected = """
        [QUERY]
        maps
        [CONTEXT]
        frontmost_app: Safari (com.apple.Safari)
        window_title: Hacker News
        time: 2026-09-19T10:30:00-07:00
        local_matches: app=Maps:1.00, calc=no, url=no, file=no
        recent_queries: 12*34 | github.com
        """
        #expect(state == expected)
    }

    @Test func stateWithNoContext() {
        let router = RouterFakes.router()
        let local = router.localSignals(for: "12*34")
        let state = QueryRouter.jevState(query: "12*34", context: .empty, local: local,
                                         now: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!)
        #expect(state.contains("frontmost_app: unknown"))
        #expect(state.contains("time: 1970-01-01T00:00:00Z"))
        #expect(state.contains("local_matches: app=none, calc=yes, url=no, file=no"))
        #expect(state.hasSuffix("recent_queries: (none)"))
    }

    @Test func questionsCoverEveryIntent() {
        let q = QueryRouter.jevQuestions
        guard case .choice(_, let criteria)? = q["intent"] else { Issue.record("intent must be a choice"); return }
        #expect(Set(criteria.keys) == Set(Intent.allCases.map(\.rawValue)))
        #expect(q["is_risky"] != nil && q["needs_clarification"] != nil && q["wants_memory"] != nil)
    }

    @Test func answerSystemPromptIncludesContextAndMemory() {
        var ctx = QueryContext.empty
        ctx.frontmostAppName = "Xcode"; ctx.frontmostWindowTitle = "Navi.xcodeproj"; ctx.clipboard = "secret paste"
        let hit = MemoryHit(id: 1, timestamp: Date(timeIntervalSince1970: 0), appName: "Safari", bundleID: "com.apple.Safari",
                            windowTitle: "Jev docs", url: nil, snippet: "Speculative fan-out\nsecond line", thumbnailPath: nil, score: 1)
        let p = AnswerService.systemPrompt(query: "what does fan-out mean", context: ctx, memory: [hit],
                                           now: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!)
        #expect(p.contains("Frontmost app: Xcode — window: “Navi.xcodeproj”"))
        #expect(p.contains("[Jan 1 12:00 AM · Safari · Jev docs] Speculative fan-out second line"))
        #expect(!p.contains("secret paste"))                        // clipboard not referenced by the query
        let p2 = AnswerService.systemPrompt(query: "summarize this", context: ctx, memory: [])
        #expect(p2.contains("secret paste"))
    }
}
