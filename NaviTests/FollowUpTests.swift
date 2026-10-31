import Testing
import Foundation
@testable import Navi

/// "Order me a burger" … "can you do it through Uber eats": a follow-up that only names a place is the
/// instruction before, moved there — and a multi-site playbook starts on the site the task names
/// (2026-10-31: the run opened DoorDash, then Googled "do it through ubereats"). Pure logic.
struct FollowUpTests {

    // MARK: Follow-up → the instruction before, elsewhere

    @Test func aPlaceOnlyFollowUpMovesTheInstructionBefore() {
        let burger = "Order me a burger"
        #expect(VoiceDecider.followUpGoal("do it through ubereats", previous: burger) == "Order me a burger through ubereats")
        #expect(VoiceDecider.followUpGoal("Do it through Uber eats.", previous: burger) == "Order me a burger through uber eats")
        #expect(VoiceDecider.followUpGoal("actually use doordash instead", previous: burger) == "Order me a burger on doordash")
        #expect(VoiceDecider.followUpGoal("no, on uber eats", previous: burger) == "Order me a burger on uber eats")
        #expect(VoiceDecider.followUpGoal("try that on the doordash app", previous: burger) == "Order me a burger on doordash")
        #expect(VoiceDecider.followUpGoal("search it on youtube", previous: "search for lofi beats") == "search for lofi beats on youtube")
    }

    @Test func thePlaceTheInstructionBeforeNamedGoesButItsBusinessStays() {
        #expect(VoiceDecider.followUpGoal("do it through ubereats", previous: "order me a burger on doordash") == "order me a burger through ubereats")
        #expect(VoiceDecider.followUpGoal("do it on uber eats", previous: "open doordash and order me a burger") == "order me a burger on uber eats")
        #expect(VoiceDecider.followUpGoal("do it through uber eats", previous: "order a big mac from mcdonalds")
                == "order a big mac from mcdonalds through uber eats")
    }

    @Test func otherInstructionsAreNoFollowUps() {
        let burger = "Order me a burger"
        #expect(VoiceDecider.followUpGoal("do it through ubereats", previous: nil) == nil)
        #expect(VoiceDecider.followUpGoal("ubereats", previous: burger) == nil)                 // "open ubereats" is its own
        #expect(VoiceDecider.followUpGoal("do it in the morning", previous: burger) == nil)     // no app or site
        #expect(VoiceDecider.followUpGoal("order a pizza on doordash", previous: burger) == nil)
        #expect(VoiceDecider.followUpGoal("open youtube", previous: burger) == nil)
        #expect(VoiceDecider.followUpGoal("do it", previous: burger) == nil)                    // a confirmation
    }

    private func input(_ head: String, _ ctx: VoiceDecider.Context) -> VoiceDecider.Input {
        let n = head.split(separator: " ").count
        return .init(clause: .init(head: head, following: "", connector: ".", start: 0, end: n, resume: n), silenceMs: 800, context: ctx)
    }

    private func verdict(kind: String) -> VoiceDecider.Verdict {
        var v = VoiceDecider.Verdict()
        v.boundary = .init(choice: "complete", probabilities: ["complete": 0.9], confidence: 0.9)
        v.kind = .init(choice: kind, probabilities: [kind: 0.9], confidence: 0.9)
        v.control = .init(choice: kind == "control_navi" ? "confirm" : "none", probabilities: [:], confidence: 0.9)
        v.surface = .init(choice: "browser", probabilities: ["browser": 0.8], confidence: 0.8)
        return v
    }

    @Test func theSpokenFollowUpRunsTheBurgerOrderOnUberEats() {
        var ctx = VoiceDecider.Context()
        ctx.frontmostBundle = "com.google.Chrome"
        ctx.lastInstruction = "Order me a burger"
        // Whatever Jev calls it — a search, a task, even "do it" as a confirmation.
        for kind in ["browse_or_search", "do_in_app", "control_navi"] {
            guard case .commit(.task(let goal, let surface, let tab, _, let place)) = VoiceDecider.act(verdict(kind: kind),
                                                                                                    input: input("can you do it through Uber eats", ctx)) else {
                Issue.record("\(kind): expected a task"); continue
            }
            #expect(goal == "Order me a burger through uber eats")
            #expect(surface == .browser && !tab && place == .newPlace)
        }
        // Offline: the same.
        guard case .task(let goal, _, _, _, _) = VoiceDecider.heuristicCommand(input("do it through ubereats", ctx)) else {
            Issue.record("offline: expected a task"); return
        }
        #expect(goal == "Order me a burger through ubereats")
    }

    @Test func aFollowUpOfTheRunningOrQueuedInstructionTakesItsPlace() {
        var ctx = VoiceDecider.Context()
        ctx.lastInstruction = "Order me a burger"
        ctx.previousInstruction = "Order me a burger"
        ctx.busyWith = "Order me a burger"
        guard case .replace = VoiceDecider.act(verdict(kind: "do_in_app"), input: input("do it through ubereats", ctx)) else {
            Issue.record("running: the follow-up replaces it"); return
        }
        ctx.amendable = .task(goal: "Order me a burger", surface: .browser, useCurrentTab: false, isRisky: false, place: nil)
        guard case .amend(.task(let goal, _, _, _, _)) = VoiceDecider.act(verdict(kind: "do_in_app"), input: input("do it through ubereats", ctx)) else {
            Issue.record("queued: the follow-up amends it"); return
        }
        #expect(goal == "Order me a burger through ubereats")
    }

    // MARK: Start pages

    @Test func aMultiSitePlaybookStartsOnTheSiteTheTaskNames() {
        #expect(AppSkills.startURL(for: "Order me a burger through uber eats", sites: []) == "https://www.ubereats.com/search?q=burger")
        #expect(AppSkills.startURL(for: "order me a burger through ubereats", sites: []) == "https://www.ubereats.com/search?q=burger")
        #expect(AppSkills.startURL(for: "order me a burger on door dash", sites: []) == "https://www.doordash.com/search/store/burger")
        #expect(AppSkills.startURL(for: "do it through ubereats", sites: []) == "https://www.ubereats.com")
        #expect(AppSkills.startURL(for: "open grubhub", sites: []) == "https://www.grubhub.com")
        // A skill with links of its own keeps them.
        #expect(AppSkills.startURL(for: "get me an uber", sites: []) == "https://m.uber.com/looking")
        #expect(UltrafastBridge.knownSiteURL(in: "do it through ubereats") == "https://www.ubereats.com")
    }

    @Test func foodFromNoNamedPlaceStartsOnTheUsersDeliverySite() {
        let sites = ["canvas.olin.edu", "ubereats.com", "doordash.com"]
        #expect(AppSkills.foodErrandStartURL(for: "Order me a burger", sites: sites) == "https://www.ubereats.com/search?q=burger")
        #expect(AppSkills.foodErrandStartURL(for: "Order me a burger", sites: []) == "https://www.doordash.com/search/store/burger")
        // Not food, a named place, or no errand: not this.
        #expect(AppSkills.foodErrandStartURL(for: "order me a phone charger", sites: sites) == nil)
        #expect(AppSkills.foodErrandStartURL(for: "order a burger on doordash", sites: sites) == nil)
        #expect(AppSkills.foodErrandStartURL(for: "how do you make a burger", sites: sites) == nil)
        // With Chrome in front and Jev saying "somewhere new", the errand still beats a search for the sentence.
        let front = FrontmostProbe.Info(bundleID: "com.google.Chrome", appName: "Google Chrome", windowTitle: "Canvas", url: "https://canvas.olin.edu/")
        let url = TaskSurface.startURL(task: "Order me a burger", frontmost: front, start: .webSearch) ?? ""
        #expect(url.hasSuffix("/burger") || url.hasSuffix("q=burger"), Comment(rawValue: url))
    }
}
