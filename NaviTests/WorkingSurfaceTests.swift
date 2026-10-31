import Foundation
import Testing
@testable import Navi

// The places and phrases are the ones from the logged failures of 2026-10-29/30
// (~/Library/Logs/Navi/agent-runs.log): a DoorDash order followed by "open my cart",
// "I meant in DoorDash where we just were", "Wait, close this tab"; "order me a burger"
// run on the Canvas tab; fragments like "to my cart" and "a burger" run as tasks.

private let doordashURL = "https://www.doordash.com/store/7th-street-burger-south-boston-41195704/99111953/?cursor=abc&pickup=false"

private func doordash(minutesAgo: Double = 1, now: Date = Date()) -> WorkingSurface {
    WorkingSurface(kind: .browserTab, task: "order me a burger", outcome: .completed, summary: "Ready for you to place the order",
                   bundleID: "com.google.Chrome", appName: "Google Chrome", url: doordashURL,
                   title: "Order 7th Street Burger - South Boston, MA Menu Delivery - DoorDash", viaRunner: true,
                   at: now.addingTimeInterval(-minutesAgo * 60))
}

private func amazonCart(now: Date = Date()) -> WorkingSurface {
    WorkingSurface(kind: .browserTab, task: "open my cart to see where I'm gonna pay", outcome: .completed, summary: "click Go to Cart",
                   bundleID: "com.google.Chrome", appName: "Google Chrome", url: "https://www.amazon.com/cart?ref_=ox", title: "Amazon.com Shopping Cart",
                   viaRunner: true, at: now)
}

private func notesApp(now: Date = Date()) -> WorkingSurface {
    WorkingSurface(kind: .app, task: "open notes", outcome: .completed, bundleID: "com.apple.Notes", appName: "Notes", at: now)
}

private func chromeFront(_ url: String, title: String = "") -> FrontmostProbe.Info {
    FrontmostProbe.Info(bundleID: "com.google.Chrome", appName: "Google Chrome", windowTitle: title, url: url)
}

@Suite struct WorkingSurfaceStoreTests {
    @Test func aRunsLastNotedPlaceBecomesARecentPlaceWhenItEnds() {
        let store = WorkingSurface.Store()
        let started = Date().addingTimeInterval(-5)
        WorkingSurface.noteBrowserPage(task: "order me a burger", url: "https://www.google.com/search?q=burger", title: nil, store: store)
        WorkingSurface.noteBrowserPage(task: "order me a burger", url: doordashURL, title: "Order 7th Street Burger", store: store)
        #expect(store.recent().isEmpty)        // still running: nothing to continue in yet
        WorkingSurface.observe(.completed(summary: "Ready for you to place the order"), task: "order me a burger", startedAt: started, store: store)
        let r = store.recent()
        #expect(r.count == 1)
        #expect(r.first?.site == "doordash.com")
        #expect(r.first?.outcome == .completed)
        #expect(r.first?.summary == "Ready for you to place the order")
        #expect(store.isRecentPage("http://doordash.com/store/7th-street-burger-south-boston-41195704/99111953/?cursor=abc&pickup=false#top"))
        #expect(!store.isRecentPage("https://www.amazon.com/cart"))
    }

    @Test func runsThatNotedNothingLeaveNothingAndStatusEventsAreIgnored() {
        let store = WorkingSurface.Store()
        WorkingSurface.observe(.status("Connecting to Chrome…"), task: "x", startedAt: .distantPast, store: store)
        WorkingSurface.observe(.failed("nope"), task: "x", startedAt: .distantPast, store: store)
        #expect(store.recent().isEmpty)
        // A note from before this run started is another run's.
        WorkingSurface.noteApp(task: "old", bundleID: "com.apple.Notes", appName: "Notes", store: store)
        WorkingSurface.observe(.completed(summary: ""), task: "new", startedAt: Date().addingTimeInterval(60), store: store)
        #expect(store.recent().isEmpty)
    }

    @Test func oneEntryPerPlaceNewestFirstAndOldPlacesExpire() {
        let store = WorkingSurface.Store()
        let now = Date()
        store.record(doordash(minutesAgo: 30, now: now))
        #expect(store.recent(now: now).isEmpty)          // older than maxAge
        store.record(doordash(minutesAgo: 2, now: now))
        store.record(amazonCart(now: now))
        var again = doordash(minutesAgo: 0, now: now)
        again.task = "now add fries"
        store.record(again)
        let r = store.recent(now: now)
        #expect(r.map(\.site) == ["doordash.com", "amazon.com"])
        #expect(r.first?.task == "now add fries")
        store.record(notesApp(now: now))
        store.forget(bundleID: "com.apple.Notes")
        #expect(store.recent(now: now).count == 2)
    }

    @Test func aNativelyDrivenBrowserIsATabAndAnAppIsAnApp() {
        let store = WorkingSurface.Store()
        let t0 = Date().addingTimeInterval(-1)
        WorkingSurface.noteApp(task: "click the first video", bundleID: "com.apple.Safari", appName: "Safari", url: "https://www.youtube.com/results?search_query=cats", store: store)
        store.finish(task: "click the first video", startedAt: t0, outcome: .completed, summary: nil)
        WorkingSurface.noteApp(task: "make the title hello", bundleID: "com.apple.Notes", appName: "Notes", title: "hello", store: store)
        store.finish(task: "make the title hello", startedAt: t0, outcome: .completed, summary: nil)
        let r = store.recent()
        #expect(r.map(\.kind) == [.app, .browserTab])
        #expect(r.last?.site == "youtube.com")
    }

    @Test func samePageIgnoresSchemeWwwFragmentAndTrailingSlash() {
        #expect(WorkingSurface.samePage("https://www.amazon.com/cart/", "http://amazon.com/cart#x"))
        #expect(!WorkingSurface.samePage("https://amazon.com/cart", "https://amazon.com/cart?x=1"))
        #expect(!WorkingSurface.samePage("", ""))
    }
}

@Suite struct WorkingSurfaceQuestionTests {
    @Test func offersTheScreenInFrontEachRecentPlaceAndANewPlace() throws {
        let now = Date()
        let front = chromeFront("https://www.amazon.com/cart?ref_=ox", title: "Amazon.com Shopping Cart")
        // Amazon cart (just now, and in front) + DoorDash (1 min ago, a background tab).
        let w = try #require(WorkingSurface.question(recent: [amazonCart(now: now), doordash(now: now)], front: front, now: now))
        guard case .choice(_, let criteria) = w.question else { Issue.record("not a choice"); return }
        #expect(Set(criteria.keys) == ["here", "last_1", "new_place"])
        #expect(w.places["last_1"]?.site == "doordash.com")
        // The place in front is offered once, as "here", and says the last task worked there.
        #expect(criteria["here"]?.contains("open my cart to see where I'm gonna pay") == true)
        #expect(criteria["last_1"]?.contains("doordash.com/store/7th-street-burger") == true)
        #expect(w.state.map { $0["id"] as? String } == ["here", "last_1"])
        #expect(JSONSerialization.isValidJSONObject(w.state))
    }

    @Test func nothingToChooseBetweenAsksNothing() {
        #expect(WorkingSurface.question(recent: [], front: nil) == nil)
        #expect(WorkingSurface.question(recent: [], front: chromeFront("https://canvas.olin.edu/courses/1079")) != nil)   // here vs new_place
    }

    @Test func jevsPickIsActedOnOnlyWhenSure() {
        let places = ["last_1": doordash()]
        #expect(WorkingSurface.choice(answer: "last_1", confidence: 0.86, places: places) == .last(places["last_1"]!))
        #expect(WorkingSurface.choice(answer: "here", confidence: 0.9, places: places) == .here)
        #expect(WorkingSurface.choice(answer: "new_place", confidence: 1, places: places) == .newPlace)
        #expect(WorkingSurface.choice(answer: "last_1", confidence: 0.4, places: places) == nil)
        #expect(WorkingSurface.choice(answer: "last_7", confidence: 0.9, places: places) == nil)
    }

    @Test func continuingATabPrefersTheSameSiteInFrontElseTheRunsOwnPage() {
        let d = doordash()
        let moved = "https://www.doordash.com/cart"
        #expect(WorkingSurface.start(for: d, front: chromeFront(moved)) == .page(url: moved, attach: true))
        #expect(WorkingSurface.start(for: d, front: chromeFront("https://www.amazon.com/cart")) == .page(url: doordashURL, attach: true))
        #expect(WorkingSurface.start(for: notesApp(), front: chromeFront("https://x.com")) == .app(bundleID: "com.apple.Notes", name: "Notes"))
    }
}

// MARK: - Voice: where a spoken task works

@Suite struct VoiceWorkingSurfaceTests {
    private func clause(_ head: String, following: String = "", connector: String = "") -> UtteranceSegmenter.Clause {
        UtteranceSegmenter.Clause(head: head, following: following, connector: connector, start: 0, end: 3, resume: connector.isEmpty ? 3 : 4)
    }

    private func verdict(kind: String = "do_in_app", surface: String = "browser", work: (String, Double)? = nil, whole: Double? = 0.95,
                         complete: Double = 0.9) -> VoiceDecider.Verdict {
        var v = VoiceDecider.Verdict()
        v.boundary = .init(choice: "complete", probabilities: ["complete": complete, "continues": (1 - complete) / 2, "not_a_command": (1 - complete) / 2], confidence: complete)
        v.kind = .init(choice: kind, probabilities: [kind: 0.9], confidence: 0.9)
        v.control = .init(choice: "none", probabilities: ["none": 0.9], confidence: 0.9)
        v.surface = .init(choice: surface, probabilities: [surface: 0.8], confidence: 0.8)
        if let (w, p) = work { v.workWhere = .init(choice: w, probabilities: [w: p], confidence: p) }
        v.whole = whole
        return v
    }

    private func input(_ head: String, following: String = "", connector: String = "", silence: Int = 2000,
                       front: FrontmostProbe.Info?, recent: [WorkingSurface]) -> VoiceDecider.Input {
        var ctx = VoiceDecider.Context()
        ctx.frontmostApp = front?.appName
        ctx.frontmostBundle = front?.bundleID
        ctx.windowTitle = front?.windowTitle
        ctx.browserURL = front?.url
        ctx.recentWork = recent
        return VoiceDecider.Input(clause: clause(head, following: following, connector: connector), silenceMs: silence, context: ctx)
    }

    @Test func iMeantInDoorDashContinuesOnTheDoorDashTabNotAnAppNamedThat() {
        let now = Date()
        let inp = input("I meant in DoorDash where we just were", front: chromeFront("https://www.amazon.com/cart?ref_=ox"),
                        recent: [amazonCart(now: now), doordash(now: now)])
        // Jev (live 2026-10-30): last_2 at 0.99 in the voice state, which offers the Amazon tab as "here".
        let d = VoiceDecider.decide(verdict(kind: "open_app", surface: "unsure", work: ("last_1", 0.99), whole: 0.32), input: inp)
        guard case .commit(.task(let goal, let surface, let tab, _, let place)) = d else { Issue.record("got \(d)"); return }
        #expect(goal == "I meant in DoorDash where we just were")
        #expect(surface == .browser)
        #expect(!tab)
        guard case .last(let s)? = place else { Issue.record("place \(String(describing: place))"); return }
        #expect(s.site == "doordash.com")
        let p = VoiceCommandExecutor.placement(goal: goal, surface: surface, useCurrentTab: tab, place: place, frontmostBundle: "com.google.Chrome",
                                               compound: false, lastWorkedHere: true, namesPage: { _ in false })
        #expect(p.continueOn?.site == "doordash.com")
        #expect(p.surface == .browser && !p.useCurrentTab)
    }

    @Test func aCorrectionThatJevReadsAsStopIsStillTheInstruction() {
        let now = Date()
        let inp = input("I meant in DoorDash where we just were", front: chromeFront("https://www.amazon.com/cart?ref_=ox"),
                        recent: [amazonCart(now: now), doordash(now: now)])
        var v = verdict(kind: "control_navi", surface: "unsure", work: ("last_1", 1.0), whole: 0.32)
        v.control = .init(choice: "stop", probabilities: ["stop": 0.6], confidence: 0.6)
        guard case .commit(.task(_, _, _, _, .last?)) = VoiceDecider.decide(v, input: inp) else { Issue.record("not continued"); return }
        // A real "stop" / "never mind" stays a control.
        guard case .commit(.control(.stop, _)) = VoiceDecider.decide(v, input: input("never mind", front: nil, recent: [])) else { Issue.record("never mind"); return }
    }

    @Test func openMyCartRightAfterTheOrderIsThatOrdersCart() {
        let inp = input("open my cart to see where I'm gonna pay", front: chromeFront("https://www.google.com/"), recent: [doordash()])
        let d = VoiceDecider.decide(verdict(work: ("last_1", 0.86)), input: inp)
        guard case .commit(.task(_, _, _, _, .last(let s)?)) = d else { Issue.record("got \(d)"); return }
        #expect(s.task == "order me a burger")
    }

    @Test func anErrandOfItsOwnNeverRunsOnTheTabInFront() {
        let canvas = chromeFront("https://canvas.olin.edu/courses/1079", title: "Applied Mathematics for Engineers")
        let opened = WorkingSurface(kind: .browserTab, task: "Open up my class canvas", outcome: .completed, bundleID: "com.google.Chrome",
                                    appName: "Google Chrome", url: "https://canvas.olin.edu/courses/1079", at: Date())
        for head in ["order me a burger", "go to McDonald's and order a big mac"] {
            let d = VoiceDecider.decide(verdict(work: ("new_place", 0.99)), input: input(head, front: canvas, recent: [opened]))
            guard case .commit(.task(let goal, let surface, let tab, _, let place)) = d else { Issue.record("\(head): \(d)"); continue }
            #expect(place == .newPlace)
            #expect(!tab)
            let p = VoiceCommandExecutor.placement(goal: goal, surface: surface, useCurrentTab: true, place: place, frontmostBundle: "com.google.Chrome",
                                                   compound: false, lastWorkedHere: true, namesPage: { _ in false })
            #expect(!p.useCurrentTab, Comment(rawValue: head))
            #expect(p.continueOn == nil)
        }
        // Without Jev's answer, the local rules no longer put an errand on the Canvas tab just because
        // the last task was on the web — nor because it worked on that tab.
        let p = VoiceCommandExecutor.placement(goal: "order me a burger", surface: .browser, useCurrentTab: false, place: nil,
                                               frontmostBundle: "com.google.Chrome", compound: false, lastWorkedHere: true, namesPage: { _ in false })
        #expect(!p.useCurrentTab)
    }

    @Test func theScreenInFrontIsTheOpenTabOrTheAppInFront() {
        let d = VoiceDecider.decide(verdict(surface: "unsure", work: ("here", 0.9)),
                                    input: input("click on checkout", front: chromeFront(doordashURL), recent: [doordash()]))
        guard case .commit(.task(_, let surface, let tab, _, .here?)) = d else { Issue.record("got \(d)"); return }
        #expect(surface == .browser && tab)
        let notes = FrontmostProbe.Info(bundleID: "com.apple.Notes", appName: "Notes", windowTitle: "New Note")
        let n = VoiceDecider.decide(verdict(surface: "browser", work: ("here", 0.9)), input: input("make the title hello", front: notes, recent: [notesApp()]))
        guard case .commit(.task(_, let s2, let t2, _, _)) = n else { Issue.record("got \(n)"); return }
        #expect(s2 == .nativeApp && !t2)
    }

    @Test func aLookupThatContinuesASiteSearchesThatSiteNotGoogle() {
        let yt = WorkingSurface(kind: .browserTab, task: "go to youtube", outcome: .completed, bundleID: "com.google.Chrome", appName: "Google Chrome",
                                url: "https://www.youtube.com/", at: Date())
        let slack = FrontmostProbe.Info(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", windowTitle: "general")
        let d = VoiceDecider.decide(verdict(kind: "browse_or_search", work: ("last_1", 0.6)), input: input("search for Matt Armstrong", front: slack, recent: [yt]))
        guard case .commit(.task(_, .browser, _, _, .last(let s)?)) = d else { Issue.record("got \(d)"); return }
        #expect(s.site == "youtube.com")
        // A fresh search stays a search.
        let fresh = VoiceDecider.decide(verdict(kind: "browse_or_search", work: ("new_place", 0.9)), input: input("search for Matt Armstrong", front: slack, recent: [yt]))
        #expect(fresh == .commit(.webSearch("Matt Armstrong", text: "search for Matt Armstrong")))
    }

    @Test func waitCloseThisTabClosesTheTab() {
        let amazon = chromeFront("https://www.amazon.com/cart")
        #expect(VoiceDecider.normalizedGoal("Wait, close this tab") == "close this tab")
        #expect(VoiceDecider.normalizedGoal("wait for the page to load") == "wait for the page to load")
        let d = VoiceDecider.decide(verdict(kind: "control_navi", work: ("here", 0.91)), input: input("Wait, close this tab", front: amazon, recent: [amazonCart()]))
        guard case .commit(.browser(let b, _)) = d else { Issue.record("got \(d)"); return }
        #expect(b.key == "cmd+w")
    }

    @Test func stateCarriesRecentWorkAndTheWorkWhereHead() {
        let inp = input("now add fries", front: FrontmostProbe.Info(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack"), recent: [doordash()])
        let state = VoiceDecider.stateJSON(inp)
        #expect((state["recent_work"] as? [[String: Any]])?.first?["task"] as? String == "order me a burger")
        #expect(JSONSerialization.isValidJSONObject(state))
        let q = VoiceDecider.questions(inp)
        #expect(q["work_where"] != nil)
        #expect(q["whole_instruction"] != nil)
        #expect(q["start_from"] == nil && q["continues_previous"] == nil)
    }
}

// MARK: - Voice: fragments never become runs

@Suite struct VoiceFragmentGuardTests {
    private func input(_ head: String, following: String = "", connector: String = "", silence: Int) -> VoiceDecider.Input {
        let c = UtteranceSegmenter.Clause(head: head, following: following, connector: connector, start: 0, end: 3, resume: connector.isEmpty ? 3 : 4)
        var ctx = VoiceDecider.Context()
        ctx.recentDone = ["“order me a burger” → completed: Ready for you to place the order"]
        return VoiceDecider.Input(clause: c, silenceMs: silence, context: ctx)
    }

    private func verdict(whole: Double?, kind: String = "do_in_app", complete: Double = 0.85) -> VoiceDecider.Verdict {
        var v = VoiceDecider.Verdict()
        v.boundary = .init(choice: "complete", probabilities: ["complete": complete, "continues": 1 - complete, "not_a_command": 0], confidence: complete)
        v.kind = .init(choice: kind, probabilities: [kind: 0.9], confidence: 0.9)
        v.surface = .init(choice: "browser", probabilities: ["browser": 0.8], confidence: 0.8)
        v.whole = whole
        return v
    }

    private func isRun(_ d: VoiceDecider.Decision) -> Bool {
        switch d {
        case .commit(let c), .replace(let c): return c.needsWholeInstruction
        default: return false
        }
    }

    // Jev's whole_instruction, measured live on 2026-10-30 for each logged phrase.
    static let logged: [(String, Double)] = [
        ("a burger", 0.05), ("to my cart", 0.06), ("updated it", 0.08), ("to my most recent cannabis assignment", 0.06),
        ("open up when you do tab", 0.15),
    ]

    @Test func loggedFragmentsAreNeverRun() {
        for (head, whole) in Self.logged {
            for silence in [300, 1000, 2500, 7000] {
                let d = VoiceDecider.decide(verdict(whole: whole), input: input(head, silence: silence))
                #expect(!isRun(d), Comment(rawValue: "\(head) @\(silence)ms → \(d)"))
            }
            // The user stopped: they hear that Navi didn't catch it.
            if case .giveUp = VoiceDecider.decide(verdict(whole: whole), input: input(head, silence: 2500)) {} else {
                Issue.record("\(head): no give-up after a pause")
            }
            // Still talking: wait for the rest of the sentence.
            if case .wait = VoiceDecider.decide(verdict(whole: whole), input: input(head, silence: 300)) {} else {
                Issue.record("\(head): did not wait while the user may still be talking")
            }
        }
    }

    @Test func aDanglingPrepositionIsCaughtEvenWithoutJev() {
        for head in ["to my cart", "to my most recent cannabis assignment", "with Google", "into the doc"] {
            let d = VoiceDecider.decide(verdict(whole: nil), input: input(head, silence: 2500))
            #expect(!isRun(d), Comment(rawValue: "\(head) → \(d)"))
        }
        // …but a verb makes it an instruction for Jev to judge.
        #expect(VoiceDecider.incompleteReason("to order a burger go to doordash", v: verdict(whole: nil)) == nil)
    }

    @Test func aFragmentWithWordsAfterItJoinsThem() {
        let d = VoiceDecider.decide(verdict(whole: 0.06), input: input("to my cart", following: "and check out", connector: "and", silence: 200))
        #expect(d == .merge)
    }

    @Test func wholeInstructionsAndCorrectionsStillRun() {
        for (head, whole) in [("open me a burger", 0.92), ("order me a burger", 0.98), ("the second one", 0.37),
                              ("I meant in DoorDash where we just were", 0.32), ("Sign into DoorDash with my Google account", 0.98),
                              ("close it", 0.79)] {
            let d = VoiceDecider.decide(verdict(whole: whole), input: input(head, silence: 2500))
            #expect(isRun(d) || { if case .commit(.window) = d { return true }; if case .commit(.browser) = d { return true }; return false }(),
                    Comment(rawValue: "\(head) → \(d)"))
        }
    }

    @Test func anAbandonedLeadIsDroppedFromTheGoal() {
        #expect(VoiceDecider.normalizedGoal("with... Click on sign in with DoorDash with Google") == "Click on sign in with DoorDash with Google")
        #expect(VoiceDecider.normalizedGoal("so, um, open notes") == "open notes")
        #expect(VoiceDecider.normalizedGoal("Boston, what's the weather") == "Boston, what's the weather")
        let d = VoiceDecider.decide(verdict(whole: 0.49), input: input("with... Click on sign in with DoorDash with Google", silence: 2500))
        guard case .commit(.task(let goal, _, _, _, _)) = d else { Issue.record("got \(d)"); return }
        #expect(goal == "Click on sign in with DoorDash with Google")
    }
}

// MARK: - Voice: the user's own words, misheard

@Suite struct VoiceVocabularyTests {
    let terms = [VoiceVocabulary.Term("Canvas", kind: "apps and sites"), VoiceVocabulary.Term("Onshape", kind: "apps and sites"),
                 VoiceVocabulary.Term("Dhvan", kind: "people"), VoiceVocabulary.Term("Notion", kind: "apps and sites"),
                 VoiceVocabulary.Term("DoorDash", kind: "apps and sites")]

    @Test func soundKeysFoldSpellingToSound() {
        #expect(VoiceVocabulary.phoneticKey("Canvas") == "knfs")
        #expect(VoiceVocabulary.phoneticKey("cannabis") == "knbs")
        #expect(VoiceVocabulary.similarity("knfs", "knbs") >= VoiceVocabulary.minSimilarity)
        #expect(VoiceVocabulary.similarity("knfs", "trtl") < 0.5)
    }

    @Test func cannabisIsProposedAsCanvasAndConfirmedByJev() throws {
        let head = "to my most recent cannabis assignment"
        let found = VoiceVocabulary.soundAlikes(in: head, terms: terms)
        let first = try #require(found.first)
        #expect(first.heard == "cannabis" && first.meant == "Canvas")
        #expect(VoiceVocabulary.apply([first], to: "go to my most recent cannabis assignment") == "go to my most recent Canvas assignment")
        // Only Jev's yes rewrites the goal.
        var ctx = VoiceDecider.Context()
        ctx.soundAlikes = found
        let inp = VoiceDecider.Input(clause: .init(head: "go to my most recent cannabis assignment", following: "", connector: "", start: 0, end: 3, resume: 3),
                                     silenceMs: 2000, context: ctx)
        var v = VoiceDecider.Verdict()
        v.misheard = [0.9]
        #expect(VoiceDecider.correctedGoal(inp.clause.head, v: v, input: inp) == "go to my most recent Canvas assignment")
        v.misheard = [0.2]
        #expect(VoiceDecider.correctedGoal(inp.clause.head, v: v, input: inp) == "go to my most recent cannabis assignment")
        #expect(VoiceDecider.questions(inp)["misheard_0"] != nil)
    }

    @Test func twoHeardWordsCanBeOneOfTheirs() {
        #expect(VoiceVocabulary.soundAlikes(in: "open my on shape model", terms: terms).first?.meant == "Onshape")
    }

    @Test func termsSaidOutrightOrCommonWordsAreLeftAlone() {
        #expect(VoiceVocabulary.soundAlikes(in: "open my canvas assignment", terms: terms).isEmpty)
        #expect(VoiceVocabulary.soundAlikes(in: "order me a burger", terms: terms).isEmpty)
        #expect(VoiceVocabulary.soundAlikes(in: "open notes and make the title hello", terms: terms).isEmpty)
    }
}

// MARK: - Live: the logged phrases through the real voice decision call

/// `NAVI_TEST_NETWORK=1 TYPESAFE_API_KEY=… scripts/test.sh`: every head of the voice decision
/// call (boundary, kind, surface, work_where, whole_instruction, misheard_i …) asked of Jev for the
/// phrases that failed on 2026-10-29/30, and the decision code run on the answers.
@Suite struct VoiceWorkingSurfaceLiveTests {
    private func ask(_ head: String, front: FrontmostProbe.Info?, recent: [WorkingSurface], recentDone: [String] = [],
                     terms: [VoiceVocabulary.Term] = []) async throws -> (VoiceDecider.Decision, VoiceDecider.Verdict) {
        let jev = JevClient()
        try #require(jev.isConfigured, "set TYPESAFE_API_KEY or AI_GATEWAY_API_KEY")
        var ctx = VoiceDecider.Context()
        ctx.frontmostApp = front?.appName
        ctx.frontmostBundle = front?.bundleID
        ctx.windowTitle = front?.windowTitle
        ctx.browserURL = front?.url
        ctx.recentWork = recent
        ctx.recentDone = recentDone
        ctx.soundAlikes = VoiceVocabulary.soundAlikes(in: head, terms: terms)
        let inp = VoiceDecider.Input(clause: .init(head: head, following: "", connector: "", start: 0, end: 3, resume: 3), silenceMs: 2500, context: ctx)
        let r = try await jev.ask(state: JevClient.JSONValue(any: VoiceDecider.stateJSON(inp)), questions: VoiceDecider.questions(inp), cacheable: false)
        let v = VoiceDecider.verdict(from: r)
        return (VoiceDecider.decide(v, input: inp), v)
    }

    private func isRun(_ d: VoiceDecider.Decision) -> Bool {
        if case .commit(let c) = d { return c.needsWholeInstruction }
        return false
    }

    @Test(.needsNetwork) func followUpsContinueWhereTheLastTaskWorked() async throws {
        let now = Date()
        let amazonFront = chromeFront("https://www.amazon.com/cart?ref_=ox", title: "Amazon.com Shopping Cart")
        let (d1, v1) = try await ask("I meant in DoorDash where we just were", front: amazonFront, recent: [amazonCart(now: now), doordash(now: now)],
                                     recentDone: ["“order me a burger” → completed", "“open my cart to see where I'm gonna pay” → completed: click Go to Cart"])
        if case .commit(.task(_, _, _, _, .last(let s)?)) = d1 { #expect(s.site == "doordash.com") } else {
            Issue.record("I meant in DoorDash → \(d1) \(String(describing: v1.workWhere))")
        }

        let slack = FrontmostProbe.Info(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", windowTitle: "general")
        let (d2, v2) = try await ask("open my cart to see where I'm gonna pay", front: slack, recent: [doordash(now: now)],
                                     recentDone: ["“order me a burger” → completed: Ready for you to place the order"])
        if case .commit(.task(_, _, _, _, .last(let s2)?)) = d2 { #expect(s2.site == "doordash.com") } else {
            Issue.record("open my cart → \(d2) \(String(describing: v2.workWhere))")
        }

        let (d3, _) = try await ask("Wait, close this tab", front: amazonFront, recent: [amazonCart(now: now), doordash(now: now)])
        if case .commit(.browser(let b, _)) = d3 { #expect(b.key == "cmd+w") } else { Issue.record("close this tab → \(d3)") }
    }

    @Test(.needsNetwork) func anErrandDoesNotRunOnTheCanvasTab() async throws {
        let canvas = chromeFront("https://canvas.olin.edu/courses/1079", title: "Applied Mathematics for Engineers")
        let opened = WorkingSurface(kind: .browserTab, task: "Open up my class canvas", outcome: .completed, summary: "click Applied Mathematics for Engineers",
                                    bundleID: "com.google.Chrome", appName: "Google Chrome", url: "https://canvas.olin.edu/courses/1079", at: Date())
        for head in ["order me a burger", "go to McDonald's"] {
            let (d, v) = try await ask(head, front: canvas, recent: [opened], recentDone: ["“Open up my class canvas” → completed"])
            switch d {
            case .commit(.task(_, _, let tab, _, let place)):
                #expect(!tab, Comment(rawValue: head))
                #expect(place == .newPlace, Comment(rawValue: "\(head): \(String(describing: v.workWhere))"))
            case .commit(.openURL), .commit(.webSearch): break
            default: Issue.record("\(head) → \(d)")
            }
        }
    }

    @Test(.needsNetwork) func loggedFragmentsDoNotRun() async throws {
        let canvas = chromeFront("https://canvas.olin.edu/courses/1079", title: "Applied Mathematics for Engineers")
        for head in ["a burger", "to my cart", "updated it", "open up when you do tab", "to my most recent cannabis assignment"] {
            let (d, v) = try await ask(head, front: canvas, recent: [], recentDone: ["“Open up my class canvas” → completed"])
            #expect(!isRun(d), Comment(rawValue: "\(head) → \(d) whole=\(v.whole ?? -1)"))
        }
    }

    @Test(.needsNetwork) func aMisheardCanvasIsPutRight() async throws {
        let terms = [VoiceVocabulary.Term("Canvas", kind: "apps and sites"), VoiceVocabulary.Term("Onshape", kind: "apps and sites"),
                     VoiceVocabulary.Term("Notion", kind: "apps and sites")]
        let (d, v) = try await ask("go to my most recent cannabis assignment", front: chromeFront("https://www.google.com/"), recent: [], terms: terms)
        guard case .commit(.task(let goal, _, _, _, _)) = d else { Issue.record("→ \(d)"); return }
        #expect(goal.contains("Canvas"), Comment(rawValue: "\(goal) misheard=\(v.misheard)"))
    }
}
