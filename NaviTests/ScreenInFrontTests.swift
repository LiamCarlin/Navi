import CoreGraphics
import Foundation
import Testing
@testable import Navi

// The tasks, tabs and plans are the ones of the overnight bench of 2026-11-01
// (build/taskbench/overnight-20261101): typed over a page with ⌘Space (navi://run), every run
// started somewhere else — the last run's tab, a habit, a Google search for the sentence.

private let servo = "https://www.amazon.com/dp/B0H9XPQNNS"
private let doordashStore = "https://www.doordash.com/store/7th-street-burger-needham-2468/"
private let rickAstley = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
private let canvasCourse = "https://canvas.olin.edu/courses/1079/modules"

private func chrome(_ url: String, _ title: String = "") -> FrontmostProbe.Info {
    FrontmostProbe.Info(bundleID: "com.google.Chrome", appName: "Google Chrome", windowTitle: title, url: url)
}
private let preview = FrontmostProbe.Info(bundleID: "com.apple.Preview", appName: "Preview", windowTitle: "MTH3180_PSet4.pdf")

private func browserStep(_ goal: String, url: String? = nil, query: String? = nil, needsResult: Bool = false) -> TaskPlanner.Step {
    TaskPlanner.Step(surface: .browser, goal: goal, url: url, query: query, needsResult: needsResult)
}

struct ScreenInFrontTests {
    // MARK: Words that point at the screen

    @Test func deixisPointsAtTheScreen() {
        for t in ["add 2 of these to my cart", "pause the video", "skip the ad", "reload this page",
                  "copy the due dates from this course's assignments page into a note",
                  "calculate the average of the scores on page 2 and put the answer at the bottom of a new textedit doc",
                  "bookmark this page", "summarize this", "what does it say here", "like this video"] {
            #expect(ScreenInFront.pointsAtScreen(t), Comment(rawValue: t))
        }
        for t in ["what's on my calendar this week", "remind me this friday", "order me a burger", "open my amazon cart",
                  "what's the weather this weekend", "find a video about rice", "open the website for kfc",
                  "where is the nearest cafe", "text mom i'm late"] {
            #expect(!ScreenInFront.pointsAtScreen(t), Comment(rawValue: t))
        }
    }

    @Test func pageActionsAreStrict() {
        #expect(ScreenInFront.isPageAction("pause the video"))
        #expect(ScreenInFront.isPageAction("skip the ad"))
        #expect(ScreenInFront.isPageAction("please click add to cart"))
        #expect(ScreenInFront.isPageAction("reload this page"))
        #expect(!ScreenInFront.isPageAction("check the weather"))
        #expect(!ScreenInFront.isPageAction("play lofi beats"))
        #expect(!ScreenInFront.isPageAction("scroll down and search for cats"))
    }

    @Test func pagesOfTheSiteInFront() {
        for t in ["open my cart", "to my cart", "add fries too", "go to checkout", "add another one", "show me my orders"] {
            #expect(ScreenInFront.continuesOnPage(t), Comment(rawValue: t))
        }
        for t in ["order me a burger", "find me cheap servos", "open my email"] {
            #expect(!ScreenInFront.continuesOnPage(t), Comment(rawValue: t))
        }
    }

    @Test func anotherPlaceNamedOverridesTheTab() {
        #expect(ScreenInFront.namesOtherWebPlace("open my amazon cart", frontURL: doordashStore))
        #expect(!ScreenInFront.namesOtherWebPlace("open my amazon cart", frontURL: servo))
        #expect(ScreenInFront.namesOtherWebPlace("order a large pepperoni from domino's", frontURL: doordashStore))
        #expect(ScreenInFront.namesOtherWebPlace("open youtube.com", frontURL: doordashStore))
        #expect(!ScreenInFront.namesOtherWebPlace("pause this youtube video", frontURL: rickAstley))
        // The user's own Canvas host is Canvas; a native app it names ("…into a note") is not another web place.
        #expect(!ScreenInFront.namesOtherWebPlace("open the assignments on canvas", frontURL: canvasCourse))
        #expect(!ScreenInFront.namesOtherWebPlace("copy this page into notes", frontURL: canvasCourse))
    }

    @Test func benchTasksBelongToTheTabInFront() {
        #expect(ScreenInFront.anchorsToTab("add 2 of these to my cart", url: servo))           // errand-005
        #expect(ScreenInFront.anchorsToTab("open my cart", url: doordashStore))                 // errand-002
        #expect(ScreenInFront.anchorsToTab("to my cart", url: doordashStore))                   // edge-004
        #expect(ScreenInFront.anchorsToTab("add fries too", url: doordashStore))                // errand-007
        #expect(ScreenInFront.anchorsToTab("pause the video", url: rickAstley))                 // web-004
        #expect(ScreenInFront.anchorsToTab("skip the ad", url: rickAstley))                     // web-005
        #expect(ScreenInFront.anchorsToTab("copy the due dates from this course's assignments page into a note", url: canvasCourse)) // multi-002
        // Unrelated tasks, another place, or a cart where there is none stay the planner's.
        #expect(!ScreenInFront.anchorsToTab("what's the weather in boston", url: rickAstley))
        #expect(!ScreenInFront.anchorsToTab("order me a burger", url: canvasCourse))
        #expect(!ScreenInFront.anchorsToTab("open my amazon cart", url: doordashStore))
        #expect(!ScreenInFront.anchorsToTab("open my cart", url: "https://www.google.com/"))
        #expect(ScreenInFront.anchorsToTab("summarize this page", url: "https://www.google.com/search?q=x"))
    }

    // MARK: The plan

    @Test func oneStepPlanMovesOntoTheTabWithTheUsersWords() {
        // What Haiku planned from recent_work: the previous run's toilet-paper search.
        let planned = TaskPlanner.Plan(steps: [browserStep("Add 2 of the cheapest toilet paper items to your cart",
                                                           url: "https://www.amazon.com/s?k=toilet+paper&s=price-asc-rank")], source: "claude")
        let p = ScreenInFront.anchor(planned, task: "add 2 of these to my cart", frontmost: chrome(servo, "Amazon.com: MG996R Servo Motor 4-pack"))
        #expect(p.steps.count == 1)
        #expect(p.steps[0].useCurrentTab && p.steps[0].url == nil && p.steps[0].query == nil)
        #expect(p.steps[0].goal == "add 2 of these to my cart")
        #expect(p.source == "claude+front")
        #expect(TaskPlanner.startURL(for: p.steps[0], frontmost: chrome(servo)) == servo)
        // "to my cart" (the verb dropped) is "Go to my cart" on DoorDash, never Domino's.
        let pizza = TaskPlanner.Plan(steps: [browserStep("Add items to your cart", url: "https://www.dominos.com/menu")], source: "claude")
        let q = ScreenInFront.anchor(pizza, task: "to my cart", frontmost: chrome(doordashStore))
        #expect(q.steps[0].useCurrentTab && q.steps[0].goal == "Go to my cart")
    }

    @Test func multiStepPlanKeepsItsGoalsAndLaterSteps() {
        let planned = TaskPlanner.Plan(steps: [
            browserStep("Open the assignments page for this course and gather all the due dates", url: "https://canvas.olin.edu/courses/1064/assignments", needsResult: true),
            TaskPlanner.Step(surface: .app, app: "Notes", goal: "Create a new note with {{result}}"),
        ], source: "claude")
        let p = ScreenInFront.anchor(planned, task: "copy the due dates from this course's assignments page into a note", frontmost: chrome(canvasCourse))
        #expect(p.steps[0].useCurrentTab && p.steps[0].url == nil && p.steps[0].needsResult)
        #expect(p.steps[0].goal == planned.steps[0].goal)
        #expect(p.steps[1] == planned.steps[1])
    }

    @Test func aDocumentInFrontIsReadNotGoogled() {
        let planned = TaskPlanner.Plan(steps: [
            browserStep("Find the scores on page 2", query: "scores page 2", needsResult: true),
            TaskPlanner.Step(surface: .app, app: "TextEdit", goal: "Create a new document and put the average of {{result}} at the bottom"),
        ], source: "claude")
        let p = ScreenInFront.anchor(planned, task: "calculate the average of the scores on page 2 and put the answer at the bottom of a new textedit doc", frontmost: preview)
        #expect(p.steps[0].surface == .app && p.steps[0].app == "com.apple.Preview" && p.steps[0].needsResult)
        #expect(p.steps[0].goal == "Find the scores on page 2")
        #expect(p.steps[1] == planned.steps[1])
        // A site the planner chose on purpose stays.
        let named = TaskPlanner.Plan(steps: [browserStep("Look up this word", url: "https://www.merriam-webster.com")], source: "claude")
        #expect(ScreenInFront.anchor(named, task: "look up this word", frontmost: preview) == named)
    }

    @Test func unrelatedPlansAreUntouched() {
        let weather = TaskPlanner.Plan(steps: [browserStep("Find the weather in Boston", query: "weather in Boston")], source: "claude")
        #expect(ScreenInFront.anchor(weather, task: "what's the weather in boston", frontmost: chrome(rickAstley)) == weather)
        let amazon = TaskPlanner.Plan(steps: [browserStep("Open your Amazon cart", url: "https://www.amazon.com/gp/cart/view.html")], source: "claude")
        #expect(ScreenInFront.anchor(amazon, task: "open my amazon cart", frontmost: chrome(doordashStore)) == amazon)
        let text = TaskPlanner.Plan(steps: [TaskPlanner.Step(surface: .app, app: "Messages", goal: "Text mom I'm late")], source: "claude")
        #expect(ScreenInFront.anchor(text, task: "text mom i'm late", frontmost: chrome(rickAstley)) == text)
        // Nothing in front that Navi can name (the desktop with nothing probed): unchanged.
        #expect(ScreenInFront.anchor(weather, task: "pause this", frontmost: FrontmostProbe.Info()) == weather)
    }

    @Test func fallbackStartURLUsesTheTab() {
        #expect(TaskSurface.startURL(task: "add 2 of these to my cart", frontmost: chrome(servo)) == servo)
        #expect(TaskSurface.startURL(task: "add fries too", frontmost: chrome(doordashStore)) == doordashStore)
    }

    // MARK: The planner sees the screen

    @Test func plannerStateCarriesTheScreenInFront() {
        let s = TaskPlanner.stateJSON(task: "calculate the average of the scores on page 2", frontmost: preview)
        let screen = s["screen_in_front"] as? [String: Any]
        #expect(screen?["app"] as? String == "Preview" && screen?["window_title"] as? String == "MTH3180_PSet4.pdf")
        #expect(s["open_browser_tab"] == nil)
        let older = WorkingSurface(kind: .browserTab, task: "find cheap toilet paper", outcome: .completed, summary: nil,
                                   bundleID: "com.google.Chrome", appName: "Google Chrome",
                                   url: "https://www.amazon.com/s?k=toilet+paper", title: "Amazon.com : toilet paper", viaRunner: true, at: Date())
        let here = WorkingSurface(kind: .browserTab, task: "find me cheap servos on amazon", outcome: .completed, summary: nil,
                                  bundleID: "com.google.Chrome", appName: "Google Chrome", url: "https://amazon.com/dp/B0H9XPQNNS/",
                                  title: "Servo", viaRunner: true, at: Date())
        let t = TaskPlanner.stateJSON(task: "add 2 of these to my cart", frontmost: chrome(servo, "Servo"), recentWork: [older, here])
        let recent = t["recent_work"] as? [[String: Any]]
        #expect(recent?[0]["is_the_screen_in_front"] as? Bool == false)
        #expect(recent?[1]["is_the_screen_in_front"] as? Bool == true)
        #expect((t["screen_in_front"] as? [String: Any])?["url"] as? String == servo)
        #expect(JSONSerialization.isValidJSONObject(t))
        #expect(TaskPlanner.systemPrompt.contains("screen_in_front"))
    }

    // MARK: The app the user is looking at

    @Test func topWindowOwnerSkipsNaviAndNonWindows() {
        let me: pid_t = 100
        func w(_ pid: pid_t, layer: Int = 0, alpha: Double = 1, w: CGFloat = 800, h: CGFloat = 600) -> [String: Any] {
            [kCGWindowOwnerPID as String: NSNumber(value: pid), kCGWindowLayer as String: NSNumber(value: layer),
             kCGWindowAlpha as String: NSNumber(value: alpha),
             kCGWindowBounds as String: CGRect(x: 0, y: 0, width: w, height: h).dictionaryRepresentation]
        }
        // Navi's panel on top, the menu bar (layer 25), a 1-pt helper, a transparent overlay, then Safari.
        let list = [w(me), w(7, layer: 25), w(8, w: 1, h: 1), w(9, alpha: 0), w(42), w(55)]
        #expect(UserFront.topWindowOwner(list, excluding: me) == 42)
        #expect(UserFront.topWindowOwner([w(me)], excluding: me) == nil)
    }

    // MARK: Zero-step "done"

    @Test func zeroStepDoneIsNeverACompletionUnlessJudged() {
        #expect(UltrafastBridge.isUnverifiedZeroStepDone(["status": "done", "judged": false, "summary": "Nothing to do."], acted: 0, openedIsDone: false))
        #expect(UltrafastBridge.isUnverifiedZeroStepDone(["status": "done", "summary": "Nothing to do."], acted: 0, openedIsDone: false))
        #expect(!UltrafastBridge.isUnverifiedZeroStepDone(["status": "done", "judged": true, "summary": "Your cart has 5 items ($328.67)."], acted: 0, openedIsDone: false))
        #expect(!UltrafastBridge.isUnverifiedZeroStepDone(["status": "done", "judged": false, "summary": "Done: click Add to cart."], acted: 1, openedIsDone: false))
        #expect(!UltrafastBridge.isUnverifiedZeroStepDone(["status": "done", "judged": false, "summary": "Nothing to do."], acted: 0, openedIsDone: true))
        #expect(!UltrafastBridge.isUnverifiedZeroStepDone(["status": "blocked", "summary": "Stopped"], acted: 0, openedIsDone: false))
    }

    @Test func browserControlsCoverTheTypedReload() {
        #expect(BrowserControls.match("reload this page")?.key == "cmd+r")
        #expect(BrowserControls.match("bookmark this page")?.key == "cmd+d")
        #expect(BrowserControls.match("reload the page and order a pizza") == nil)
    }
}
