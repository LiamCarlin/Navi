import Foundation
import Testing
@testable import Navi

// Overnight bench 2026-11-01 (build/taskbench/overnight-20261101-hotkey): tasks typed over a page the
// user had open. Jev answered BLOCKED before acting, `NAVI_EARLY_BLOCK_EXIT` ended the run and
// `UltrafastBridge.freshStart` started over on a search for the sentence — somewhere else.

private let rickAstley = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
private let yarnBowl = "https://cad.onshape.com/documents/0b1c2d3e4f5a6b7c8d9e0f1a/w/1a2b3c4d5e6f7a8b9c0d1e2f/e/9f8e7d6c5b4a3f2e1d0c9b8a"
private let doordashStore = "https://www.doordash.com/store/cemitas-puebla-chicago-123456/"
private let canvasCourse = "https://canvas.olin.edu/courses/1079/modules"

struct PageActionStartTests {
    // MARK: An early BLOCKED on the user's own tab stays on that tab

    @Test func benchPageActionsStayOnTheirTab() {
        // web-027: the planner's goal and the user's words.
        #expect(UltrafastBridge.staysOnAttachedTab(task: "Turn on captions and set playback speed to 1.5x on the YouTube video currently playing",
                                                   attachURL: rickAstley))
        #expect(UltrafastBridge.staysOnAttachedTab(task: "turn on captions and make it 1.5x", attachURL: rickAstley))
        // native-020, schoolwork-022, errand-028.
        #expect(UltrafastBridge.staysOnAttachedTab(task: "make this full screen", attachURL: rickAstley))
        #expect(UltrafastBridge.staysOnAttachedTab(task: "export the bowl as an stl", attachURL: yarnBowl))
        #expect(UltrafastBridge.staysOnAttachedTab(task: "swap the cheeseburger for a veggie burger", attachURL: doordashStore))
        #expect(UltrafastBridge.staysOnAttachedTab(task: "swap the cheeseburger for a veggie burger in your cart", attachURL: doordashStore))
    }

    @Test func anotherNamedPlaceOrNoAttachedTabMayStartOver() {
        // The task names another site than the tab it was attached to: the old fresh start still applies.
        #expect(!UltrafastBridge.staysOnAttachedTab(task: "go to mcdonalds and order me a burger", attachURL: canvasCourse))
        #expect(!UltrafastBridge.staysOnAttachedTab(task: "search amazon for usb-c cables", attachURL: canvasCourse))
        #expect(!UltrafastBridge.staysOnAttachedTab(task: "open https://github.com/anthropics", attachURL: canvasCourse))
        #expect(!UltrafastBridge.staysOnAttachedTab(task: "open my amazon cart", attachURL: doordashStore))
        // Not attached (a page Navi opened itself), or no web page at all.
        #expect(!UltrafastBridge.staysOnAttachedTab(task: "turn on captions and make it 1.5x", attachURL: nil))
        #expect(!UltrafastBridge.staysOnAttachedTab(task: "turn on captions and make it 1.5x", attachURL: "about:blank"))
    }

    // MARK: Typed window instructions never become a run on the page

    @Test func typedWindowCommands() {
        let apps = ["Google Chrome", "Music", "Slack", "TextEdit"]
        #expect(AgentRun.typedWindowCommand("make this full screen", runningApps: apps) == WindowControls.Command(verb: .fullScreen, target: .front))
        #expect(AgentRun.typedWindowCommand("make it full screen", runningApps: apps)?.verb == .fullScreen)
        #expect(AgentRun.typedWindowCommand("minimize this", runningApps: apps)?.verb == .minimize)
        #expect(AgentRun.typedWindowCommand("hide music", runningApps: apps) == WindowControls.Command(verb: .hide, target: .app("Music")))
        // Quitting and closing lose something: those stay with the agent and its gate.
        #expect(AgentRun.typedWindowCommand("quit slack", runningApps: apps) == nil)
        #expect(AgentRun.typedWindowCommand("close this", runningApps: apps) == nil)
        // More than a window instruction.
        #expect(AgentRun.typedWindowCommand("make this full screen and turn on captions", runningApps: apps) == nil)
        #expect(AgentRun.typedWindowCommand("turn on captions and make it 1.5x", runningApps: apps) == nil)
    }
}
