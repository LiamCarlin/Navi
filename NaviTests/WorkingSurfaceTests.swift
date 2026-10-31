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
        guard case .commit(.task(let goal, let surface, let tab, _, .here?)) = d else { Issue.record("got \(d)"); return }
        #expect(surface == .browser && tab)
        // In front *and* where the last task worked: that task's place is continued (no screen-memory detour).
        let p = VoiceCommandExecutor.placement(goal: goal, surface: surface, useCurrentTab: tab, place: .here, frontmostBundle: "com.google.Chrome",
                                               compound: false, lastWorkedHere: true, hereSurface: doordash(), namesPage: { _ in false })
        #expect(p.continueOn?.site == "doordash.com")
        let plain = VoiceCommandExecutor.placement(goal: goal, surface: surface, useCurrentTab: tab, place: .here, frontmostBundle: "com.google.Chrome",
                                                   compound: false, lastWorkedHere: false, namesPage: { _ in false })
        #expect(plain.continueOn == nil && plain.useCurrentTab)
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
        ("a burger", 0.05), ("updated it", 0.08), ("open up when you do tab", 0.15),
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
        for head in ["with Google", "into the doc", "to order"] {
            let d = VoiceDecider.decide(verdict(whole: nil), input: input(head, silence: 2500))
            #expect(!isRun(d), Comment(rawValue: "\(head) → \(d)"))
        }
        // …but a verb makes it an instruction for Jev to judge.
        #expect(VoiceDecider.incompleteReason("to order a burger go to doordash", v: verdict(whole: nil)) == nil)
    }

    @Test func aTailJoinsTheInstructionStillWaitingInTheQueue() {
        var inp = input("to my cart", silence: 500)
        inp.context.amendable = .task(goal: "add a big mac", surface: .browser, useCurrentTab: false, isRisky: false, place: nil)
        #expect(VoiceDecider.decide(verdict(whole: 0.06), input: inp)
                == .amend(.task(goal: "add a big mac to my cart", surface: .browser, useCurrentTab: false, isRisky: false, place: nil)))
        // An app launch takes no tail: "to my cart" is then a destination of its own ("go to my cart").
        inp.context.amendable = .openApp(AppEntry(name: "Notes", path: "/System/Applications/Notes.app", bundleID: "com.apple.Notes"), text: "open notes")
        inp.silenceMs = 2500
        guard case .commit(.task(let goal, _, _, _, _)) = VoiceDecider.decide(verdict(whole: 0.06), input: inp) else { Issue.record("expected a task"); return }
        #expect(goal == "go to my cart")
        // A real fragment with nothing to join is given up on.
        var frag = input("a burger", silence: 2500)
        frag.context.amendable = inp.context.amendable
        if case .giveUp = VoiceDecider.decide(verdict(whole: 0.05), input: frag) {} else { Issue.record("expected give up") }
    }

    @Test func aDestinationWhoseGoWasSwallowedIsRecovered() {
        // Benchmark school-04: "go to my most recent Canvas assignment" heard without its "go".
        #expect(VoiceDecider.recoveringDroppedGo("to my most recent cannabis assignment") == "go to my most recent cannabis assignment")
        #expect(VoiceDecider.recoveringDroppedGo("to my cart") == "go to my cart")
        #expect(VoiceDecider.recoveringDroppedGo("to order a burger") == nil)
        #expect(VoiceDecider.recoveringDroppedGo("with Google") == nil)
        let d = VoiceDecider.decide(verdict(whole: 0.06), input: input("to my most recent cannabis assignment", silence: 2500))
        guard case .commit(.task(let goal, _, _, _, _)) = d else { Issue.record("got \(d)"); return }
        #expect(goal == "go to my most recent cannabis assignment")
    }

    @Test func aFragmentWithWordsAfterItJoinsThem() {
        let d = VoiceDecider.decide(verdict(whole: 0.06), input: input("a burger", following: "and fries", connector: "and", silence: 200))
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

    @Test func theInstructionsVerbIsNeverRenamed() {
        // Bench school-06: "continue where I left off" became "content where I left off".
        let t = terms + [VoiceVocabulary.Term("Content", kind: "apps and sites")]
        #expect(VoiceVocabulary.soundAlikes(in: "continue where I left off", terms: t).isEmpty)
        #expect(VoiceVocabulary.soundAlikes(in: "please continue the content", terms: t).isEmpty)
    }

    @Test func aDroppedGoDestinationIsActedOnAfterAPauseEvenIfJevWaits() {
        // Bench school-04: boundary "continues" 62–68 %, whole 0.03 → given up after 6 s.
        var v = VoiceDecider.Verdict()
        v.boundary = .init(choice: "continues", probabilities: ["complete": 0.25, "continues": 0.68, "not_a_command": 0.07], confidence: 0.68)
        v.kind = .init(choice: "do_in_app", probabilities: ["do_in_app": 0.9], confidence: 0.9)
        v.whole = 0.03
        let inp = VoiceDecider.Input(clause: .init(head: "to my most recent cannabis assignment", following: "", connector: "", start: 0, end: 3, resume: 3),
                                     silenceMs: VoiceDecider.longPauseMs, context: VoiceDecider.Context())
        guard case .commit(.task(let goal, _, _, _, _)) = VoiceDecider.decide(v, input: inp) else { Issue.record("not acted on"); return }
        #expect(goal.hasPrefix("go to my most recent"))
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
            Issue.record("I meant in DoorDash → \(d1) \(String(describing: v1.workWhere)) boundary=\(String(describing: v1.boundary)) kind=\(v1.kind?.choice ?? "?")")
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
        for head in ["a burger", "updated it", "open up when you do tab"] {
            let (d, v) = try await ask(head, front: canvas, recent: [], recentDone: ["“Open up my class canvas” → completed"])
            #expect(!isRun(d), Comment(rawValue: "\(head) → \(d) whole=\(v.whole ?? -1)"))
        }
    }

    @Test(.needsNetwork) func benchmarkBaselinePhrases() async throws {
        let amazon = chromeFront("https://www.amazon.com/cart?ref_=ox", title: "Amazon.com Shopping Cart")
        // No recent place: still never an app named after the sentence.
        let (d1, _) = try await ask("I meant in DoorDash where we just were", front: amazon, recent: [],
                                    recentDone: ["“open my cart to see where I'm gonna pay” → completed: click Go to Cart"])
        if case .commit(.task) = d1 {} else { Issue.record("I meant in DoorDash → \(d1)") }
        let (d2, _) = try await ask("Wait close this tab", front: amazon, recent: [amazonCart()])
        if case .commit(.browser(let b, _)) = d2 { #expect(b.key == "cmd+w") } else { Issue.record("Wait close this tab → \(d2)") }
        let (d3, v3) = try await ask("continue where I left off", front: FrontmostProbe.Info(bundleID: "com.apple.finder", appName: "Finder"), recent: [])
        if case .commit(.task) = d3 {} else { Issue.record("continue where I left off → \(d3) kind=\(v3.kind?.choice ?? "?")") }
    }

    @Test(.needsNetwork) func theNextPartOfAQueuedInstructionWorksWhereItDoes() async throws {
        let jev = JevClient()
        try #require(jev.isConfigured)
        var ctx = VoiceDecider.Context()
        ctx.frontmostApp = "Slack"; ctx.frontmostBundle = "com.tinyspeck.slackmacgap"
        ctx.busyWith = "Go to canvas"
        ctx.previousInstruction = "go to canvas"
        ctx.recentDone = []
        let inp = VoiceDecider.Input(clause: .init(head: "open my assignments", following: "", connector: "", start: 0, end: 3, resume: 3), silenceMs: 2500, context: ctx)
        let r = try await jev.ask(state: JevClient.JSONValue(any: VoiceDecider.stateJSON(inp)), questions: VoiceDecider.questions(inp), cacheable: false)
        let v = VoiceDecider.verdict(from: r)
        #expect(v.workWhere?.choice == "previous", Comment(rawValue: String(describing: v.workWhere)))
    }

    @Test(.needsNetwork) func aMisheardCanvasIsPutRight() async throws {
        let terms = [VoiceVocabulary.Term("Canvas", kind: "apps and sites"), VoiceVocabulary.Term("Onshape", kind: "apps and sites"),
                     VoiceVocabulary.Term("Notion", kind: "apps and sites")]
        let (d, v) = try await ask("go to my most recent cannabis assignment", front: chromeFront("https://www.google.com/"), recent: [], terms: terms)
        guard case .commit(.task(let goal, _, _, _, _)) = d else { Issue.record("→ \(d)"); return }
        #expect(goal.contains("Canvas"), Comment(rawValue: "\(goal) misheard=\(v.misheard)"))
    }
}

// MARK: - ⌘Space: the planner continues where the last task worked

@Suite(.serialized) struct PlannerWorkingSurfaceTests {
    @Test func plannerStateCarriesTheExactPageToContinueOn() {
        let state = TaskPlanner.stateJSON(task: "now add fries", frontmost: FrontmostProbe.Info(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack"),
                                          recentWork: [doordash(), notesApp()])
        let recent = state["recent_work"] as? [[String: Any]]
        #expect(recent?.first?["url"] as? String == doordashURL)
        #expect(recent?.last?["app"] as? String == "Notes")
        #expect(TaskPlanner.stateJSON(task: "x", frontmost: FrontmostProbe.Info())["recent_work"] == nil)
        #expect(JSONSerialization.isValidJSONObject(state))
    }

    /// Haiku, live: "open my cart" after a DoorDash order plans the DoorDash tab, not a search or Amazon.
    @Test(.needsNetwork) func openMyCartAfterTheOrderPlansThatTab() async throws {
        let claude = ClaudeClient()
        try #require(claude.isConfigured, "set ANTHROPIC_API_KEY")
        WorkingSurface.Store.shared.reset()
        WorkingSurface.Store.shared.record(doordash())
        defer { WorkingSurface.Store.shared.reset() }
        let slack = FrontmostProbe.Info(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", windowTitle: "general")
        for task in ["open my cart to see where I'm gonna pay", "now add a large fries"] {
            let (plan, _, raw) = try await TaskPlanner.planRaw(task: task, frontmost: slack, claude: claude)
            let step = try #require(plan?.steps.first, Comment(rawValue: raw))
            #expect(step.surface == .browser, Comment(rawValue: raw))
            #expect(TaskPlanner.startURL(for: step, frontmost: slack).contains("doordash.com"), Comment(rawValue: raw))
        }
        // Something else entirely does not go to DoorDash.
        let (other, _, raw) = try await TaskPlanner.planRaw(task: "text mom I'm running late", frontmost: slack, claude: claude)
        #expect(other?.steps.first?.surface == .app, Comment(rawValue: raw))
    }
}

// MARK: - Decision-layer baseline failures (benchmark, 2026-10-30)

@Suite struct VoiceBaselineFailureTests {
    private func clause(_ head: String) -> UtteranceSegmenter.Clause {
        UtteranceSegmenter.Clause(head: head, following: "", connector: "", start: 0, end: 3, resume: 3)
    }

    private func verdict(kind: String, control: String = "none", work: (String, Double)? = nil, whole: Double? = 0.9,
                         boundary: [String: Double] = ["complete": 0.9, "continues": 0.05, "not_a_command": 0.05]) -> VoiceDecider.Verdict {
        var v = VoiceDecider.Verdict()
        let best = boundary.max { $0.value < $1.value }!
        v.boundary = .init(choice: best.key, probabilities: boundary, confidence: best.value)
        v.kind = .init(choice: kind, probabilities: [kind: 0.9], confidence: 0.9)
        v.control = .init(choice: control, probabilities: [control: 0.9], confidence: 0.9)
        v.surface = .init(choice: "unsure", probabilities: ["unsure": 0.6], confidence: 0.6)
        if let (w, p) = work { v.workWhere = .init(choice: w, probabilities: [w: p], confidence: p) }
        v.whole = whole
        return v
    }

    private func input(_ head: String, silence: Int = 2500, front: FrontmostProbe.Info? = nil, recent: [WorkingSurface] = [],
                       previous: String? = nil) -> VoiceDecider.Input {
        var ctx = VoiceDecider.Context()
        ctx.frontmostApp = front?.appName
        ctx.frontmostBundle = front?.bundleID
        ctx.browserURL = front?.url
        ctx.recentWork = recent
        ctx.previousInstruction = previous
        return VoiceDecider.Input(clause: clause(head), silenceMs: silence, context: ctx)
    }

    @Test func iMeantInDoorDashIsNeverAnAppNamedAfterTheSentence() {
        // No recent place recorded (the benchmark's memory copy): still the DoorDash site, not open_app "i meant doordash where we were".
        let d = VoiceDecider.decide(verdict(kind: "open_app"), input: input("I meant in DoorDash where we just were"))
        guard case .commit(.task(_, let surface, _, _, _)) = d else { Issue.record("got \(d)"); return }
        #expect(surface == .browser)
        // A plain "open X" still guesses the app name.
        guard case .commit(.openAppNamed) = VoiceDecider.decide(verdict(kind: "open_app"), input: input("open figma")) else { Issue.record("open figma"); return }
    }

    @Test func waitCloseThisTabIsOneKeyPressEvenWithoutTheComma() {
        let amazon = chromeFront("https://www.amazon.com/cart")
        for head in ["Wait close this tab", "Wait, close this tab"] {
            // Even when Jev points the work at an earlier task's tab: the browser in front is what "this tab" is.
            let d = VoiceDecider.decide(verdict(kind: "do_in_app", work: ("last_1", 0.7)), input: input(head, front: amazon, recent: [doordash()]))
            guard case .commit(.browser(let b, _)) = d else { Issue.record("\(head) → \(d)"); continue }
            #expect(b.key == "cmd+w")
        }
    }

    @Test func continueWhereILeftOffIsATaskNotResume() {
        let d = VoiceDecider.decide(verdict(kind: "control_navi", control: "resume"), input: input("continue where I left off"))
        guard case .commit(.task) = d else { Issue.record("got \(d)"); return }
    }

    @Test func anAndInsideDictatedTextDoesNotSplitIt() {
        var s = UtteranceSegmenter()
        s.update(finalized: "text mom that I'm running late and I'll call her tonight")
        #expect(s.pending()?.head == "text mom that I'm running late and I'll call her tonight")
        s = UtteranceSegmenter()
        s.update(finalized: "send Bella a message saying the meeting moved and the slides are in the drive")
        #expect(s.pending()?.hasBoundary == false)
        // A new instruction after the text still splits (Jev confirms it).
        s = UtteranceSegmenter()
        s.update(finalized: "text mom I'm late and open spotify")
        #expect(s.pending()?.head == "text mom I'm late")
        // "and then" always ends the head.
        s = UtteranceSegmenter()
        s.update(finalized: "text mom I'm late and then call dad")
        #expect(s.pending()?.head == "text mom I'm late")
    }

    @Test func theSecondHalfOfASplitSentenceContinuesWhereTheFirstHalfWorks() {
        let canvasFront = FrontmostProbe.Info(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack")
        let inp = input("open my assignments", front: canvasFront, previous: "go to canvas")
        #expect(VoiceDecider.questions(inp)["work_where"] != nil)
        let d = VoiceDecider.decide(verdict(kind: "browse_or_search", work: ("previous", 0.8)), input: inp)
        guard case .commit(.task(let goal, let surface, let tab, _, .previous?)) = d else { Issue.record("got \(d)"); return }
        let canvas = WorkingSurface(kind: .browserTab, task: "go to canvas", outcome: .completed, bundleID: "com.google.Chrome",
                                    appName: "Google Chrome", url: "https://canvas.olin.edu/", at: Date())
        let p = VoiceCommandExecutor.placement(goal: goal, surface: surface, useCurrentTab: tab, place: .previous, frontmostBundle: nil,
                                               compound: false, lastWorkedHere: false, previousSurface: canvas, namesPage: { _ in false })
        #expect(p.continueOn?.site == "canvas.olin.edu")
        // Not a Google search of "open my assignments".
        #expect(p.surface == .browser)
    }

    @Test func aWholeInstructionIsActedOnAfterALongPauseNotGivenUp() {
        let v = verdict(kind: "do_in_app", whole: 0.9, boundary: ["complete": 0.1, "continues": 0.85, "not_a_command": 0.05])
        for silence in [VoiceDecider.longPauseMs, VoiceDecider.giveUpMs + 500] {
            let d = VoiceDecider.decide(v, input: input("submit my lab report for physics on canvas", silence: silence))
            guard case .commit(.task) = d else { Issue.record("@\(silence) → \(d)"); continue }
        }
        // Not whole: still given up.
        let frag = verdict(kind: "do_in_app", whole: 0.1, boundary: ["complete": 0.05, "continues": 0.9, "not_a_command": 0.05])
        if case .giveUp = VoiceDecider.decide(frag, input: input("for the physics", silence: VoiceDecider.giveUpMs + 500)) {} else { Issue.record("fragment not given up") }
    }

    @Test func aWebAppNamedIsNotTheBrowserAndAnOwnDocumentIsNotAnApp() {
        let chrome = VoiceAppMatcher.Candidate(id: "a1", entry: AppEntry(name: "Google Chrome", path: "/Applications/Google Chrome.app", bundleID: "com.google.Chrome"),
                                               score: 0.8, phrase: "google")
        var inp = input("Open up a Google Doc")
        inp.context.appCandidates = [chrome]
        var v = verdict(kind: "open_app")
        v.appTarget = .init(choice: "a1", probabilities: ["a1": 0.8], confidence: 0.8)
        switch VoiceDecider.decide(v, input: inp) {
        case .commit(.openApp): Issue.record("opened Chrome for a Google Doc")
        case .commit(.openURL(let u, _)): #expect(u.host?.contains("docs.google.com") == true)
        case .commit(.task(_, let s, _, _, _)): #expect(s == .browser)
        case let d: Issue.record("got \(d)")
        }
        // "open chrome" still opens Chrome.
        var plain = input("open chrome")
        plain.context.appCandidates = [VoiceAppMatcher.Candidate(id: "a1", entry: chrome.entry, score: 1, phrase: "chrome")]
        guard case .commit(.openApp) = VoiceDecider.decide(v, input: plain) else { Issue.record("open chrome"); return }

        let notes = VoiceAppMatcher.Candidate(id: "a1", entry: AppEntry(name: "Notes", path: "/System/Applications/Notes.app", bundleID: "com.apple.Notes"),
                                              score: 1, phrase: "notes")
        var hci = input("open the hci notes")
        hci.context.appCandidates = [notes]
        hci.context.namesOwnDocument = true
        guard case .commit(.task(_, .browser, _, _, _)) = VoiceDecider.decide(v, input: hci) else { Issue.record("hci notes → Notes app"); return }
        var justNotes = input("open the notes app")
        justNotes.context.appCandidates = [notes]
        justNotes.context.namesOwnDocument = true
        guard case .commit(.openApp) = VoiceDecider.decide(v, input: justNotes) else { Issue.record("open the notes app"); return }
    }

    @Test func continuingInABrowserAppIsItsTabInFront() {
        let chromeApp = WorkingSurface(kind: .app, task: "open chrome", outcome: .completed, bundleID: "com.google.Chrome", appName: "Google Chrome", at: Date())
        let p = VoiceCommandExecutor.placement(goal: "write some random phrase into it", surface: .unsure, useCurrentTab: false, place: .previous,
                                               frontmostBundle: "com.google.Chrome", compound: false, lastWorkedHere: false,
                                               previousSurface: chromeApp, namesPage: { _ in false })
        #expect(p.surface == .browser && p.useCurrentTab && p.continueOn == nil)
    }

    @Test func anErrandAtABusinessStartsFromThatBusinessesOwnSite() {
        #expect(TaskPlanner.errandQuery(for: "order me a random thing from kfc under 10 bucks") == "kfc order online")
        #expect(TaskPlanner.errandQuery(for: "get me a large pepperoni pizza from Domino's") == "domino's order online")
        #expect(TaskPlanner.errandQuery(for: "book a table at Tatte for 7pm") == "tatte reservations")
        #expect(TaskPlanner.errandQuery(for: "order me a burger") == nil)
        #expect(TaskPlanner.errandQuery(for: "search for kfc history") == nil)
        #expect(TaskPlanner.errandQuery(for: "order it from home") == nil)
        let url = TaskSurface.startURL(task: "order me a random thing from kfc under 10 bucks", frontmost: FrontmostProbe.Info()) ?? ""
        #expect(url.lowercased().contains("kfc"))
        #expect(!url.contains("random"))
    }

    @Test func anErrandStartsOnTheBusinessesOwnSiteFromHistoryElseTheTopResult() {
        let task = "get me a large pepperoni pizza from dominos"
        // The user's own browsing knows the site.
        #expect(TaskPlanner.errandStartURL(for: task, sites: ["canvas.olin.edu", "dominos.com"]) == "https://dominos.com")
        #expect(TaskPlanner.errandStartURL(for: "book a table at tatte for 7", sites: ["tattebakery.com"]) == "https://tattebakery.com")
        #expect(!TaskPlanner.siteCarries("kfcfans.org", name: "kfcx"))
        // Otherwise the search engine's first-result redirect (no consent page).
        let lucky = TaskPlanner.errandStartURL(for: "order me a random thing from kfc under 10 bucks", sites: []) ?? ""
        #expect(lucky.hasPrefix("https://duckduckgo.com/?q=") && lucky.contains("ducky") && lucky.contains("kfc"))
        #expect(TaskPlanner.errandStartURL(for: "order me a burger", sites: ["dominos.com"]) == nil)
        // The redirect page's target, as DuckDuckGo served it on 2026-10-31.
        let page = "<meta http-equiv='refresh' content='0; url=/l/?uddg=https%3A%2F%2Fwww.kfc.com%2F&rut=eff74f'>"
        #expect(TaskPlanner.landing(inRedirectPage: page) == "https://www.kfc.com/")
        #expect(TaskPlanner.landing(inRedirectPage: "<html>no redirect</html>") == nil)
    }

    @Test(.needsNetwork) func theTopResultRedirectLandsOnTheBusinessesSite() async throws {
        for (task, host) in [("order me a random thing from kfc under 10 bucks", "kfc.com"), ("get me a large pepperoni pizza from dominos", "dominos.com")] {
            let q = try #require(TaskPlanner.errandQuery(for: task))
            let landing = await TaskPlanner.luckyLanding(TaskPlanner.luckyURL(q))
            #expect(landing?.contains(host) == true, Comment(rawValue: "\(task) → \(landing ?? "nil")"))
        }
    }
}

// MARK: - Dictated messages are sent, never dropped or answered (bench msg-02 / msg-06)

@Suite struct VoiceDictatedMessageTests {
    private func input(_ head: String, people: Set<String> = []) -> VoiceDecider.Input {
        var ctx = VoiceDecider.Context()
        ctx.knownPeople = people
        return VoiceDecider.Input(clause: .init(head: head, following: "", connector: "", start: 0, end: 3, resume: 3), silenceMs: 2500, context: ctx)
    }

    private func verdict(_ b: String, _ p: Double, kind: String, whole: Double = 0.5) -> VoiceDecider.Verdict {
        var v = VoiceDecider.Verdict()
        var probs = ["complete": (1 - p) / 2, "continues": (1 - p) / 2, "not_a_command": (1 - p) / 2]
        probs[b] = p
        v.boundary = .init(choice: b, probabilities: probs, confidence: p)
        v.kind = .init(choice: kind, probabilities: [kind: 0.8], confidence: 0.8)
        v.control = .init(choice: "none", probabilities: ["none": 0.9], confidence: 0.9)
        v.surface = .init(choice: "native_app", probabilities: ["native_app": 0.6], confidence: 0.6)
        v.whole = whole
        return v
    }

    @Test func recognisesMessagesToSomeone() {
        #expect(VoiceDecider.isDictatedMessage("text mom I'm at the store and I'll be home soon", people: []))
        #expect(VoiceDecider.isDictatedMessage("text joão are we still on for tonight", people: ["joão"]))
        #expect(VoiceDecider.isDictatedMessage("text João are we still on for tonight", people: []))
        #expect(VoiceDecider.isDictatedMessage("text joão are we still on for tonight", people: []))   // not known, not capitalised
        #expect(VoiceDecider.isDictatedMessage("um can you text dhvan uh that I'll be there in ten", people: ["dhvan"]))
        #expect(VoiceDecider.isDictatedMessage("Send a message to the whole team about lunch", people: []))
        #expect(VoiceDecider.isDictatedMessage("send Bella a text saying I'm late", people: []))
        #expect(VoiceDecider.isDictatedMessage("reply to the email from gabi saying sounds good", people: []))
        for h in ["tell me a joke", "what's the weather tomorrow", "text size bigger", "message", "email", "search for cats"] {
            #expect(!VoiceDecider.isDictatedMessage(h, people: ["dhvan"]), Comment(rawValue: h))
        }
    }

    @Test func aMessageJevCallsChatterIsStillSent() {
        // Bench msg-02: "not an instruction (65%)".
        let d = VoiceDecider.decide(verdict("not_a_command", 0.65, kind: "do_in_app"), input: input("text mom I'm at the store and I'll be home soon"))
        guard case .commit(.task) = d else { Issue.record("got \(d)"); return }
    }

    @Test func aMessageWhoseTextIsAQuestionIsSentNotAnswered() {
        // Bench msg-06: classified as an answer.
        let d = VoiceDecider.decide(verdict("complete", 0.8, kind: "answer"), input: input("text joão are we still on for tonight", people: ["joão"]))
        guard case .commit(.task(let goal, _, _, _, _)) = d else { Issue.record("got \(d)"); return }
        #expect(goal == "text joão are we still on for tonight")
        // A real question is still answered.
        guard case .commit(.answer) = VoiceDecider.decide(verdict("complete", 0.8, kind: "answer"), input: input("are we still on for tonight")) else {
            Issue.record("question not answered"); return
        }
    }
}
