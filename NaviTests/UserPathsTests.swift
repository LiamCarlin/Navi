import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Navi

/// The user's own paths (`UserPaths`): every recorded action → abstract steps and edges
/// (`PathGraph`) → a task's target → their most-used way there → a `UserRoute` the drivers follow.
@Suite struct UserPathsTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let chrome = "com.google.Chrome"
    static let messages = "com.apple.MobileSMS"
    static let notes = "com.apple.Notes"
    static let day: Double = 86_400

    static func act(_ kind: ActionRecord.Kind, _ label: String, role: String = "link", bundle: String = chrome, app: String = "Google Chrome",
                    url: String? = nil, title: String? = nil, shortcut: String? = nil, path: String? = nil, at seconds: Double) -> ActionRecord {
        ActionRecord(timestamp: now.addingTimeInterval(seconds), bundleID: bundle, appName: app, windowTitle: title, url: url,
                     kind: kind, role: role, label: label, shortcut: shortcut, path: path)
    }

    static let dash = "https://canvas.olin.edu/"
    static func course(_ id: Int) -> String { "https://canvas.olin.edu/courses/\(id)" }
    static func assignments(_ id: Int) -> String { "https://canvas.olin.edu/courses/\(id)/assignments" }

    /// Dashboard → course card → Assignments → the assignment, then something on its page (its title).
    static func canvasVisit(course c: String, id: Int, assignment: String, aid: Int, at t: Double) -> [ActionRecord] {
        [act(.click, c, url: dash, title: "Dashboard - Google Chrome - Liam", at: t),
         act(.click, "Assignments", url: course(id), title: "\(c) - Google Chrome - Liam", path: "Courses Navigation Menu", at: t + 4),
         act(.click, assignment, url: assignments(id), title: "Assignments - Google Chrome - Liam", at: t + 8),
         act(.click, "Download PDF", url: assignments(id) + "/\(aid)", title: "\(assignment) - Google Chrome - Liam", at: t + 12)]
    }

    static func messagesVisit(_ row: String, at t: Double) -> [ActionRecord] {
        [act(.click, row, role: "text", bundle: messages, app: "Messages", path: "Conversations", at: t),
         act(.type, "Message", role: "field", bundle: messages, app: "Messages", at: t + 2),
         act(.key, "", role: "", bundle: messages, app: "Messages", shortcut: "return", at: t + 6)]
    }

    static let history: [ActionRecord] = {
        var a: [ActionRecord] = []
        a += canvasVisit(course: "Applied Mathematics MTH3180 Fall 2026", id: 1079, assignment: "Assignment 02", aid: 20385, at: 0)
        a += canvasVisit(course: "Applied Mathematics MTH3180 Fall 2026", id: 1079, assignment: "Assignment 03", aid: 20491, at: day)
        a += canvasVisit(course: "Mechanical Design ENGR3330 Fall 2026", id: 1064, assignment: "Phase 1 Strategy Review", aid: 20458, at: 2 * day)
        // A one-off detour: the calendar once led to an assignment.
        a += [act(.click, "Calendar", url: dash, title: "Dashboard - Google Chrome - Liam", at: 3 * day),
              act(.click, "Assignment 02", url: "https://canvas.olin.edu/calendar", title: "Calendar - Google Chrome - Liam", at: 3 * day + 5)]
        a += messagesVisit("Mikey Ku, see you at 5, 2:41 PM", at: 4 * day)
        a += messagesVisit("Mikey Ku, ok, 9:12 AM", at: 5 * day)
        a += messagesVisit("Shanna, Mikey, David & Jil, lunch?, 1:00 PM", at: 5 * day + 900)
        a += messagesVisit("Bella, Pinned", at: 6 * day)
        a += messagesVisit("Bella, Pinned", at: 7 * day)
        for d in [8.0, 9.0, 10.0] {
            a.append(act(.key, "New Note", role: "", bundle: notes, app: "Notes", shortcut: "cmd+n", path: "File", at: d * day))
        }
        a += [act(.click, "Sign in with Google", role: "button", url: "https://www.atlassian.com/software/jira", title: "Jira - Google Chrome - Liam", at: 11 * day),
              act(.click, "Continue with Google", role: "button", url: "https://luma.com/signin", title: "Luma - Google Chrome - Liam", at: 12 * day)]
        // A tab switch: the window's title is another tab's (a doc), the URL YouTube's.
        a.append(act(.click, "Play", role: "button", url: "https://www.youtube.com/watch?v=x", title: "HCI Notes - Google Docs - Google Chrome - Liam", at: 13 * day))
        return a
    }()

    static let graph = PathGraph.build(actions: history)

    static func node(_ g: PathGraph, place: String, label: String? = nil, slot: Bool? = nil, page: String? = nil) -> PathNode? {
        g.nodes.values.first { n in
            n.place == place && (label.map { n.label == $0 } ?? true) && (slot.map { n.isSlot == $0 } ?? true) && (page.map { n.page == $0 } ?? true)
        }
    }

    // MARK: Building

    @Test func controlsAreFixedAndItemsAreSlots() throws {
        let g = Self.graph
        let tab = try #require(Self.node(g, place: "canvas.olin.edu", label: "Assignments", page: "canvas.olin.edu/courses/#"))
        #expect(!tab.isSlot && tab.count == 3 && tab.container == "courses navigation menu")   // the same tab, three days
        let courses = try #require(Self.node(g, place: "canvas.olin.edu", slot: true, page: "canvas.olin.edu/"))
        #expect(courses.items["applied mathematics mth3180 fall 2026"]?.count == 2 && courses.items["mechanical design engr3330 fall 2026"] != nil)
        let list = try #require(Self.node(g, place: "canvas.olin.edu", slot: true, page: "canvas.olin.edu/courses/#/assignments"))
        #expect(list.items["assignment 03"]?.ledTo == "https://canvas.olin.edu/courses/1079/assignments/20491")
        // Edges: card → Assignments → the assignment, each taken more than once.
        #expect(g.edges[courses.key]?[tab.key] == 3 && g.edges[tab.key]?[list.key] == 3)
        // A shortcut is a step; Return after typing is how they send.
        let newNote = try #require(Self.node(g, place: Self.notes))
        #expect(newNote.kind == .key && newNote.shortcut == "cmd+n" && newNote.intent == .newNote && newNote.entries == 3)
        #expect(g.nodes.values.contains { $0.place == Self.messages && $0.kind == .submit })
        // Pages keep their titles; a title naming another site's app is another tab's.
        #expect(g.pages["canvas.olin.edu/courses/#/assignments/#"]?["https://canvas.olin.edu/courses/1079/assignments/20491"]?.title == "Assignment 03")
        #expect(g.pages.values.flatMap(\.values).allSatisfy { !$0.title.contains("HCI") })
        #expect(g.sites.contains("canvas.olin.edu") && g.openedBy["https://canvas.olin.edu/courses/1079/assignments/20491"] != nil)
    }

    @Test func labelsAndWords() {
        #expect(PathGraph.stripState("New Mail, pressed") == "New Mail")
        #expect(PathWords.num("03") == "3" && PathWords.num("0") == "0" && PathWords.num("30") == "30")
        #expect(PathWords.taskWords("open assignment 03 on canvas") == ["assignment", "3", "canvas"])
        // "assignment 3" in a doc's title; a bare "3" names nothing.
        let words: Set<String> = ["assignment", "3", "applied", "math"]
        let names = PathWords.specific(words)
        #expect(PathGraph.covers(names, task: words, have: PathWords.tokens("Assignment 3: Numerical Integration Lab Report")).ok)
        #expect(!PathGraph.covers(["3"], task: ["assignment", "3"], have: PathWords.tokens("Week 3 - Social Scavenger Hunt")).ok)
        #expect(PathWords.wantsAnyOne("buy the cheapest pla filament on amazon") && PathWords.wantsAnyOne("order me a random chipotle bowl"))
        #expect(!PathWords.wantsAnyOne("add the polymaker filament to my cart"))
    }

    @Test func kindsOfControl() {
        #expect(PathIntent.of(label: "Continue with Google") == .signInWithGoogle)
        #expect(PathIntent.of(label: "Add to cart") == .addToCart && PathIntent.of(label: "4 items in cart") == .openCart)
        #expect(PathIntent.of(label: "New Note") == .newNote && PathIntent.of(label: "Blank document") == .newDocument)
        #expect(PathIntent.of(label: "New Mail") == .compose && PathIntent.of(label: "Assignments") == nil)
        #expect(PathIntent.of(label: "Add it to your Amazon cart and hit that checkout button before it sells out today") == nil)
        #expect(PathIntent.of(task: "sign into doordash with my google account").first == .signInWithGoogle)
        #expect(PathIntent.of(task: "order me a burger").starts(with: [.addToCart, .openCart]))
        #expect(PathIntent.of(task: "make a new note") == [.newNote])
        #expect(PathIntent.of(task: "reply to gabi").isEmpty)
    }

    // MARK: Paths

    @Test func theMostUsedWayWins() throws {
        let g = Self.graph
        let list = try #require(Self.node(g, place: "canvas.olin.edu", slot: true, page: "canvas.olin.edu/courses/#/assignments"))
        let path = try #require(g.path(from: .page(Self.chrome, "canvas.olin.edu/"), to: [list.key: 0]))
        // Card → Assignments → the item, not the calendar detour taken once.
        #expect(path.count == 3 && g.nodes[path[1]]?.label == "Assignments" && g.support(path) == 3)
    }

    @Test func aPageOfTheirsIsWhereTheRunStarts() throws {
        let p = try #require(UserPaths.plan(task: "open assignment 3 for applied math on canvas", graph: Self.graph, named: ["canvas.olin.edu"]))
        #expect(p.source == "page" && p.startURL == "https://canvas.olin.edu/courses/1079/assignments/20491" && p.site == "canvas.olin.edu")
        // Their usual way there, from the page they started on.
        #expect(p.theirPath.contains("‘Assignments’") && p.theirPath.last == "‘Assignment 03’")
        #expect(p.confidence >= 0.6)
    }

    @Test func anItemIsReachedTheirWay() throws {
        // No page title names it: the item they clicked, their next steps after it.
        let p = try #require(UserPaths.plan(task: "message mikey", graph: Self.graph, named: [Self.messages], people: ["Mikey Ku"]))
        #expect(p.source == "item" && p.bundleID == Self.messages && p.startURL == nil)
        #expect(p.steps.map(\.kind) == [.click, .type, .submit])
        let row = p.steps[0]
        // Their chat with Mikey (by its name), never the group that lists him.
        #expect(row.label == "Mikey Ku" && Set((row.slot ?? "").split(separator: " ").map(String.init)) == ["mikey", "ku"])
        #expect(p.theirPath.first == "click text ‘Mikey Ku’ in conversations")
        // A fixed conversation: its own label.
        let bella = try #require(UserPaths.plan(task: "text bella i'm on my way", graph: Self.graph, named: [Self.messages]))
        #expect(bella.steps.first?.label == "Bella, Pinned" && bella.support >= 2)
    }

    @Test func aKindOfControlTheyUseHere() throws {
        let p = try #require(UserPaths.plan(task: "make a new note", graph: Self.graph, places: [Self.notes]))
        #expect(p.source == "intent" && p.steps.count == 1 && p.steps[0].shortcut == "cmd+n" && p.support == 3)
        let route = UserRoute(routine: p.routine(task: "make a new note"), fills: [], confidence: p.confidence)
        #expect(route.mayFollow(0, task: "make a new note"))                      // a harmless shortcut: code presses it
    }

    @Test func elsewhereItIsOnlyAPattern() throws {
        // Never signed in on DoorDash: how they sign in with Google elsewhere, marked by what it does, never pressed.
        let p = try #require(UserPaths.plan(task: "sign into doordash with my google account", graph: Self.graph, named: ["doordash.com"]))
        #expect(p.pattern && p.source == "pattern" && p.startURL == nil && p.confidence < 0.6)
        #expect(Set(p.theirPath.map { $0.components(separatedBy: "’").first! }) == ["‘Sign in with Google", "‘Continue with Google"])
        var route = UserRoutines.Match(routine: p.routine(task: "x"), fills: [], confidence: p.confidence, source: "path", path: p).route
        #expect(route.pattern && route.labelMatches(route.steps[0], "Continue with Google") && !route.labelMatches(route.steps[0], "Continue with Apple"))
        #expect(!route.mayFollow(0, task: "x"))
        let screen = Self.screen(url: "https://www.doordash.com/", labels: ["Continue with Google", "Continue with Apple"])
        #expect(route.direct(on: screen, task: "x") == nil && route.marks(on: screen).count == 1)
    }

    @Test func errandsAndAnyOneAreNotLastTimesThing() {
        // "the cheapest" / "a random" one is not the product they looked at last time.
        let g = PathGraph.build(actions: [
            Self.act(.click, "Add to cart", role: "button", url: "https://www.amazon.com/Polymaker-PLA/dp/B09H2SL2PC", title: "Amazon.com: Polymaker PLA Filament", at: 0),
            Self.act(.click, "Add to cart", role: "button", url: "https://www.amazon.com/Polymaker-PLA/dp/B09H2SL2PC", title: "Amazon.com: Polymaker PLA Filament", at: Self.day)])
        let any = UserPaths.plan(task: "buy the cheapest pla filament on amazon", graph: g, named: ["amazon.com"])
        #expect(any?.source == "intent" && any?.startURL?.contains("Polymaker") != true)
        let that = UserPaths.plan(task: "add the polymaker pla filament to my amazon cart", graph: g, named: ["amazon.com"])
        #expect(that?.source == "page" && that?.startURL?.contains("Polymaker") == true)
        // A grounded thing never overrides an errand for any one ("random chipotle bowl" ≠ the "Yarn Bowl" doc).
        let bowl = UserPaths.plan(task: "order me a random chipotle bowl", graph: g,
                                  grounded: ("https://cad.onshape.com/documents/abc", nil, "Yarn Bowl"))
        #expect(bowl?.startURL?.contains("onshape") != true)
        #expect(TaskGrounding.isErrand("order me a random chipotle bowl") && TaskGrounding.isErrand("add it to my cart"))
        #expect(!TaskGrounding.shouldGround(task: "add it to my cart", scope: .init(interval: nil, recent: false),
                                             words: (["cart"], []), named: true))
    }

    @Test func aConversationWithSomeoneIsTheirChat() {
        #expect(TaskGrounding.isConversationWith("open my conversation with mikey") && TaskGrounding.isCommunication("open my conversation with mikey"))
        #expect(!TaskGrounding.isConversationWith("open the hci notes"))
    }

    // MARK: Place

    @Test func aRoutineNeverLeavesItsPlace() throws {
        let p = ProcedureRecord(sessionID: 1, start: Self.now, end: Self.now.addingTimeInterval(60), bundleID: Self.chrome, appName: "Google Chrome",
                                site: "atlassian.com", goal: "Sign in to Atlassian Jira using Google authentication", steps: [], habits: [])
        let acts = [Self.act(.click, "My account", role: "popup", url: "https://www.atlassian.com/agile", at: 1),
                    Self.act(.click, "sign up with Google", url: "https://www.atlassian.com/software/jira", at: 4),
                    Self.act(.click, "Skip", role: "button", url: "https://www.atlassian.com/ondemand/signup/confirmation", at: 9)]
        let r = try #require(RoutineMiner.mine([p]) { _ in acts }.first)
        let task = "sign into doordash with my google account"
        let named = UserRoutines.namedPlaces(for: task, sites: ["atlassian.com"])
        #expect(named.contains("doordash.com") && !UserRoutines.isInPlace(r, named: named))
        #expect(UserRoutines.candidates(task: task, routines: [r], named: named).isEmpty)
        #expect(UserRoutines.isInPlace(r, named: ["atlassian.com"]) && UserRoutines.isInPlace(r, named: []))
        // Slack on the web is not the Slack app they reach people in.
        var web = r; web.site = "app.slack.com"
        #expect(!UserRoutines.isInPlace(web, named: ["com.tinyspeck.slackmacgap"]))
    }

    @Test func sitesNamedByTheirOwnName() {
        let sites = ["canvas.olin.edu", "start.godaddy.com", "mcmaster.com", "docs.google.com/document"]
        #expect(UserRoutines.namedPlaces(for: "open my last canvas assignment", sites: sites).contains("canvas.olin.edu"))
        #expect(!UserRoutines.namedPlaces(for: "start working on my essay", sites: sites).contains("start.godaddy.com"))
        #expect(UserRoutines.namedPlaces(for: "find m3 screws on mcmaster", sites: sites).contains("mcmaster.com"))
        #expect(UserRoutines.brand(of: "start.godaddy.com") == "godaddy" && UserRoutines.brand(of: "app.slack.com") == "slack")
        #expect(PathGraph.Scope.samePlace("canvas.olin.edu", "olin.edu") && !PathGraph.Scope.samePlace("docs.google.com/document", "docs.google.com/forms"))
    }

    @Test func aRoutineOfTheirsForThisTaskBeatsThePathOnlyWhenRepeated() throws {
        let plan = try #require(UserPaths.plan(task: "message mikey", graph: Self.graph, named: [Self.messages], people: ["Mikey Ku"]))
        func routine(count: Int) -> UserRoutines.Match {
            let r = Routine(key: "r", goals: ["send a message to Mikey Ku"], template: "send a message to …", bundleID: Self.messages,
                            appName: "Messages", steps: plan.steps, count: count, first: Self.now, last: Self.now)
            return .init(routine: r, fills: ["mikey"], confidence: 0.6, source: "jev")
        }
        #expect(UserRoutines.choose(routine: routine(count: 2), path: plan, task: "message mikey")?.source == "jev")
        #expect(UserRoutines.choose(routine: routine(count: 1), path: plan, task: "message mikey")?.source == "path")
        #expect(UserRoutines.choose(routine: nil, path: plan, task: "message mikey")?.isPath == true)
    }

    // MARK: Following a path

    static func screen(url: String?, labels: [String], bundle: String = chrome) -> CUScreen {
        let els = labels.enumerated().map { i, l in
            AXElement(id: "e\(i)", role: "AXLink", subrole: nil, label: l, frame: CGRect(x: 20, y: 100 + CGFloat(i) * 30, width: 200, height: 20),
                      path: "", actions: ["AXPress"], pid: 42)
        }
        let snap = AXSnapshot(elements: els, windowTitle: "W", url: url, focused: nil, visibleText: "", capturedAt: now, pid: 42,
                              bundleID: bundle, appName: "Google Chrome", windowFrame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        return CUPerception.perceive(snap, ocr: nil, goal: "g")
    }

    @Test func aPathStepIsFoundOnlyOnItsPageWithAllItsWords() throws {
        let g = Self.graph
        let list = try #require(Self.node(g, place: "canvas.olin.edu", slot: true, page: "canvas.olin.edu/courses/#/assignments"))
        let it = try #require(list.items["assignment 03"])
        let fill = g.fill(it, hit: ["3"], in: list)
        #expect(fill == ["3", "assignment"])                                       // the number with its kind word
        var s = g.step(list, label: "Assignment 03", fill: fill)
        s.page = "canvas.olin.edu/courses/#/assignments"
        let r = Routine(key: "path:x", goals: ["g"], template: "t", bundleID: Self.chrome, appName: "Chrome", site: "canvas.olin.edu",
                        steps: [s], count: 3, first: Self.now, last: Self.now)
        var route = UserRoute(routine: r, fills: [], confidence: 0.9)
        route.fromPath = true
        #expect(route.labelMatches(s, "Assignment 03") && route.labelMatches(s, "Assignment 3"))
        #expect(!route.labelMatches(s, "Assignment 02") && !route.labelMatches(s, "Lab 3 Report"))
        let listing = Self.screen(url: Self.assignments(1079), labels: ["Assignment 02", "Assignment 03", "Lab 3 Report"])
        let direct = route.direct(on: listing, task: "open assignment 3")
        let next = try #require(direct)
        #expect(next.action == .click(elementID: "e1"))
        // The same link on another page is not their step.
        let dashboard = Self.screen(url: Self.dash, labels: ["Assignment 03"])
        #expect(route.direct(on: dashboard, task: "open assignment 3") == nil)
        // An item the path cannot name ("…") is shown, never matched or pressed.
        var unknown = s; unknown.slot = ""; unknown.label = "…"
        #expect(!route.labelMatches(unknown, "Assignment 03"))
        // State for Jev: the path's own words, the whole way.
        route.theirPath = ["Dashboard", "‘Assignments’", "‘Assignment 03’"]
        let state = route.state(on: listing)
        #expect(state["their_path"] as? String == "Dashboard → ‘Assignments’ → ‘Assignment 03’")
        #expect((state["steps"] as? [String])?.first == "→ click link ‘Assignment 03’")
    }

    @Test func signingInAddingAndCheckingOutAreNeverPressed() {
        for label in ["Sign in with Google", "Add to cart", "Checkout", "Log in"] {
            let s = RoutineStep(kind: .click, app: "Chrome", bundleID: Self.chrome, site: "x.com", role: "link", label: label, seen: 9)
            let route = UserRoute(routine: Routine(key: "k", goals: ["g"], template: "g", bundleID: Self.chrome, appName: "Chrome", steps: [s],
                                                   count: 5, first: Self.now, last: Self.now), fills: [], confidence: 0.9)
            #expect(!route.mayFollow(0, task: "x"), "\(label)")
        }
    }

    @Test func theRunnerGetsThePathAndPatterns() throws {
        let p = try #require(UserPaths.plan(task: "sign into doordash with google", graph: Self.graph, named: ["doordash.com"]))
        let m = UserRoutines.Match(routine: p.routine(task: "x"), fills: [], confidence: p.confidence, source: "path", path: p)
        let json = try #require(m.route.runnerJSON())
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(obj["source"] as? String == "pattern")
        #expect((obj["steps"] as? [[String: Any]])?.first?["intent"] as? String == "signInWithGoogle")
    }

    // MARK: Bench failures (2026-10-31), as rules

    /// "order me a randome chipotle bowl" opened his Onshape "Yarn Bowl"; "open the hci notes" opened Apple
    /// Notes although the HCI doc is known: what a task names must explain the thing it opens.
    @Test func aThingOpensOnlyWhenItExplainsTheTask() {
        func thing(_ name: String, _ type: String, _ place: UserKnowledge.Place) -> UserKnowledge.Thing {
            UserKnowledge.Thing(name: name, type: type, sessions: 6, days: 4, lastSeen: Self.now, places: [place], related: [], workflow: [],
                                tokens: UserKnowledge.tokens(name))
        }
        let things = [
            thing("Yarn Bowl", "document", .init(key: "cad.onshape.com", app: "Google Chrome", isWeb: true, url: "https://cad.onshape.com/documents/yarn/w/1", sessions: 6)),
            thing("HCI", "project", .init(key: Self.messages, app: "Messages", isWeb: false, url: nil, sessions: 6)),
            thing("HCI Concept Testing Engagements", "document",
                  .init(key: "docs.google.com/document", app: "Google Chrome", isWeb: true, url: "https://docs.google.com/document/d/HCI1/edit", sessions: 6)),
        ]
        func start(_ t: String) -> String? { UserKnowledge.startURL(task: t, matches: UserKnowledge.matches(task: t, in: things), things: things) }
        #expect(start("order me a randome chipotle bowl") == nil)              // an errand
        #expect(start("show me the chipotle bowl") == nil)                     // "chipotle" is not the Yarn Bowl's
        #expect(start("open the yarn bowl") == "https://cad.onshape.com/documents/yarn/w/1")
        #expect(start("open the hci notes") == "https://docs.google.com/document/d/HCI1/edit")   // the project's own doc
        #expect(PathWords.wantsAnyOne("order me a randome chipotle bowl"))
    }

    /// "open my canvas assignments for generative ai" grounded to a Babson course: when something carries
    /// every name the task says, what carries none of them is no contender.
    @Test func groundingKeepsWhatCarriesTheTasksNames() {
        let now = TaskGroundingTests.now
        func s(_ url: String, _ title: String, hoursAgo: Double) -> SessionRecord {
            TaskGroundingTests.session(Self.chrome, "Google Chrome", url: url, title: title, hoursAgo: hoursAgo, minutes: 20)
        }
        let sessions = [s("https://babson.instructure.com/courses/9/assignments", "Assignments: Enterprise 2.0", hoursAgo: 1),
                        s("https://babson.instructure.com/courses/9/assignments", "Assignments: Enterprise 2.0", hoursAgo: 2),
                        s("https://canvas.olin.edu/courses/1083/assignments", "Assignments: Generative AI", hoursAgo: 30)]
        let task = "open my canvas assignments for generative ai"
        let cs = TaskGrounding.candidates(task: task, scope: TaskGrounding.scope(of: task, now: now), sessions: sessions,
                                          pageTitles: [:], things: [], now: now)
        #expect(!cs.isEmpty && cs.allSatisfy { $0.url?.contains("olin") == true })
    }

    /// The start a routine or path gives a run, shared by the agent and the task bench.
    @Test func whereAMatchStartsARun() throws {
        let p = try #require(UserPaths.plan(task: "open assignment 3 for applied math on canvas", graph: Self.graph, named: ["canvas.olin.edu"]))
        var thing = p; thing.source = "thing"
        let m = UserRoutines.Match(routine: p.routine(task: "x"), fills: [], confidence: 0.8, source: "path", path: p)
        let t = UserRoutines.Match(routine: thing.routine(task: "x"), fills: [], confidence: 0.8, source: "path", path: thing)
        #expect(AgentRun.routineStartPlace(m, task: "open the hci notes", surface: .browser) == .page(p.startURL!))
        #expect(AgentRun.routineStartPlace(m, task: "open the hci notes", surface: .nativeApp) == nil)
        #expect(AgentRun.routineStartPlace(t, task: "open the hci notes", surface: .nativeApp) == .page(p.startURL!))   // the named thing wins
        var low = m; low.confidence = 0.5
        #expect(AgentRun.routineStartPlace(low, task: "x", surface: .browser) == nil)
    }

    /// Bench regressions: "email dhvan the hci notes" started on the doc, "email the registrar…" on a registrar
    /// page, "play my focus playlist" in System Settings' Focus.
    @Test func reachingSomeoneNeverStartsOnTheThingItSends() {
        let g = PathGraph.build(actions: Self.history + [
            Self.act(.click, "New Mail", role: "button", bundle: "com.microsoft.Outlook", app: "Microsoft Outlook", at: 20 * Self.day),
            Self.act(.click, "Read", role: "link", url: "https://docs.google.com/document/d/HCI1/edit", title: "HCI Notes - Google Docs", at: 21 * Self.day),
            Self.act(.click, "Focus", role: "row", bundle: "com.apple.systempreferences", app: "System Settings", path: "Sidebar", at: 22 * Self.day),
            Self.act(.click, "Focus", role: "row", bundle: "com.apple.systempreferences", app: "System Settings", path: "Sidebar", at: 23 * Self.day)])
        let mail = UserPaths.plan(task: "email dhvan the hci notes", graph: g, grounded: ("https://docs.google.com/document/d/HCI1/edit", nil, "HCI Notes"),
                                  named: ["com.microsoft.Outlook"])
        #expect(mail?.source == "intent" && mail?.bundleID == "com.microsoft.Outlook" && mail?.startURL == nil)
        #expect(UserPaths.plan(task: "play my focus playlist", graph: g, places: ["com.apple.Music", "com.spotify.client"]) == nil)
    }

    @Test func coverageCountsPlacesWithUsablePaths() {
        let c = UserPaths.coverage(Self.graph, minActions: 5)
        #expect(c.places >= 2 && c.withChains >= 2 && c.withChains <= c.withRepeats)
    }
}
