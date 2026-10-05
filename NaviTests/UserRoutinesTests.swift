import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Navi

/// Routines: the user's own clicks (`ActionJournal`) + the digester's procedures →
/// `RoutineMiner` → `routines` table → `UserRoutines` matches a task → `UserRoute` follows it.
@Suite struct UserRoutinesTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let slack = "com.tinyspeck.slackmacgap"
    static let chrome = "com.google.Chrome"

    static func act(_ kind: ActionRecord.Kind, _ label: String, role: String = "button", bundle: String = slack, app: String = "Slack",
                    url: String? = nil, shortcut: String? = nil, path: String? = nil, at seconds: Double, id: Int64 = 0) -> ActionRecord {
        ActionRecord(id: id, timestamp: now.addingTimeInterval(seconds), bundleID: bundle, appName: app, windowTitle: "W", url: url,
                     kind: kind, role: role, label: label, shortcut: shortcut, path: path)
    }

    /// Messaging Haakon on Slack the way this user does: Dock → the DM → the composer → ⌘↩,
    /// with the noise of a real session around it.
    static let haakon: [ActionRecord] = [
        act(.click, "Clock", role: "control", bundle: "com.apple.notificationcenterui", app: "Notification Center", at: 0),
        act(.click, "Slack", role: "dock item", bundle: "com.apple.dock", app: "Dock", at: 2),
        act(.click, "Haakon Olsen", role: "control", path: "Direct Messages", at: 5),
        act(.click, "Message to Haakon Olsen", role: "field", path: "composer", at: 7),
        act(.type, "Message to Haakon Olsen", role: "field", path: "composer", at: 8),
        act(.key, "", shortcut: "cmd+backspace", at: 12),
        act(.key, "", shortcut: "cmd+return", at: 20),
    ]

    static let canvas = "https://canvas.olin.edu/courses/1083/assignments"
    /// Opening an assignment in Canvas: the course card, the Assignments tab, the assignment.
    static func canvasRun(course: String, assignment: String, at t: Double) -> [ActionRecord] {
        [act(.key, "New Tab", bundle: chrome, app: "Google Chrome", url: "https://news.test/", shortcut: "cmd+t", at: t),
         act(.click, course, role: "link", bundle: chrome, app: "Google Chrome", url: "https://canvas.olin.edu/", at: t + 3),
         act(.click, "Assignments", role: "link", bundle: chrome, app: "Google Chrome", url: "https://canvas.olin.edu/courses/1083",
             path: "Courses Navigation Menu", at: t + 6),
         act(.click, assignment, role: "link", bundle: chrome, app: "Google Chrome", url: canvas, at: t + 9)]
    }

    // MARK: Miner: actions → steps

    @Test func stepsDropNoiseAndFoldTheFieldIntoTyping() {
        let steps = RoutineMiner.steps(from: Self.haakon, goal: "send a message to Haakon Olsen on Slack")
        #expect(steps.map(\.kind) == [.open, .click, .type, .submit])
        #expect(steps[0].label == "Slack")                                         // the Dock click opens the app
        #expect(steps[1].label == "Haakon Olsen" && steps[1].slot == "haakon olsen") // the person is the slot
        #expect(steps[2].slot == "haakon olsen" && steps[2].fixedLabel == "message to")
        #expect(steps[3].shortcut == "cmd+return")                                 // ⌘↩ after typing sends
        #expect(steps.allSatisfy { $0.shortcut != "cmd+backspace" })               // text edits are not steps
        #expect(steps[2].human == "type in ‘Message to …’")
    }

    @Test func slotsAreNamesNotKindsOfThings() {
        #expect(RoutineMiner.slotWords("add Mateo Otero-Diaz as a collaborator") == ["mateo", "otero", "diaz"])
        #expect(RoutineMiner.slotWords("open Assignment 03 for MTH3199") == ["03", "mth3199"])   // "Assignment" is a kind
        #expect(RoutineMiner.slotWords("submit the midterm survey").isEmpty)
        #expect(RoutineMiner.slotWords("Send an email").isEmpty)                                // a capital first word is not a name
        let s = RoutineMiner.steps(from: [Self.act(.click, "Complete this survey", role: "link", at: 0), Self.act(.click, "Next", at: 2)],
                                   goal: "complete the midterm survey")
        #expect(s.allSatisfy { $0.slot == nil })
    }

    @Test func aClickUndoneByBackIsNotAStep() {
        let a = [Self.act(.click, "Wrong page", role: "link", bundle: Self.chrome, url: Self.canvas, at: 0),
                 Self.act(.key, "", bundle: Self.chrome, url: Self.canvas, shortcut: "cmd+left", at: 2),
                 Self.act(.click, "Modules", role: "link", bundle: Self.chrome, url: Self.canvas, at: 4),
                 Self.act(.click, "Back", role: "button", bundle: Self.chrome, url: Self.canvas, at: 6),
                 Self.act(.click, "Assignments", role: "link", bundle: Self.chrome, url: Self.canvas, at: 8),
                 Self.act(.click, "Assignments", role: "link", bundle: Self.chrome, url: Self.canvas, at: 9)]
        #expect(RoutineMiner.steps(from: a, goal: "x").map(\.label) == ["Assignments"])
    }

    @Test func returnSendsOnlyAfterTyping() {
        let a = [Self.act(.key, "", shortcut: "return", at: 0),
                 Self.act(.type, "Search", role: "field", at: 2),
                 Self.act(.key, "", shortcut: "return", at: 3)]
        let s = RoutineMiner.steps(from: a, goal: "x")
        #expect(s.map(\.kind) == [.type, .submit] && s[1].shortcut == "return")
    }

    @Test func aLongGapEndsTheRoutine() {
        let a = [Self.act(.click, "Assignments", role: "link", at: 0), Self.act(.click, "Modules", role: "link", at: 10),
                 Self.act(.click, "Grades", role: "link", at: 10 + RoutineMiner.maxGap + 1)]
        #expect(RoutineMiner.steps(from: a, goal: "x").map(\.label) == ["Assignments", "Modules"])
    }

    @Test func leadingClicksElsewhereAreTrimmedAndTheStartIsTheFirstStepsPage() {
        let a = [Self.act(.click, "Submit", role: "button", bundle: Self.chrome, url: "https://docs.google.com/forms/d/abc/viewform", at: 0)]
            + Self.canvasRun(course: "Mechanical Design ENGR3330", assignment: "Phase 1 Strategy Review", at: 10)
        let (steps, start) = RoutineMiner.build(from: a, goal: "View the Phase 1 Strategy Review assignment for Mechanical Design ENGR3330",
                                                place: "canvas.olin.edu")
        #expect(steps.map(\.label) == ["Mechanical Design ENGR3330", "Assignments", "Phase 1 Strategy Review"])
        #expect(start == "https://canvas.olin.edu/")                               // not the stale tab ⌘T was pressed on
        #expect(steps[0].slot != nil && steps[1].slot == nil && steps[2].slot != nil)
        #expect(steps[1].page == "canvas.olin.edu/courses/#")
    }

    @Test func pagePatternsFoldIds() {
        #expect(RoutineMiner.pagePattern("https://canvas.olin.edu/courses/1083/assignments/20412") == "canvas.olin.edu/courses/#/assignments/#")
        // A long name is an id too: every repository's access settings are one page.
        #expect(RoutineMiner.pagePattern("https://www.github.com/LiamCarlin/MTH3199-Assignment-2/settings/access") == "github.com/liamcarlin/#/settings/access")
        #expect(RoutineMiner.pagePattern("https://docs.google.com/document/d/1AbCdEfGhIjKlMnOpQrStUvWxYz/edit") == "docs.google.com/document/d/#/edit")
        #expect(RoutineMiner.pagePattern("https://canvas.olin.edu/") == "canvas.olin.edu/")
        #expect(RoutineMiner.pagePattern("not a url") == nil)
    }

    // MARK: Miner: prose steps → actions

    @Test func writtenStepsAlignToTheActionsTheyQuote() {
        let window = [Self.act(.click, "General", role: "control", at: 0)] + Self.haakon
        let aligned = RoutineMiner.align(steps: ["Dock: click 'Slack'", "Slack: click control 'Haakon Olsen' in Direct Messages",
                                                 "Slack: press cmd+return to send"], actions: window)
        #expect(aligned.map(\.label) == ["Slack", "Haakon Olsen", ""])
        #expect(aligned.last?.shortcut == "cmd+return")
        #expect(RoutineMiner.align(steps: ["click 'Nothing like this'"], actions: window).isEmpty)
    }

    // MARK: Miner: procedures → routines

    static func procedure(_ goal: String, at t: Double, ids: [Int64] = [], site: String? = nil, bundle: String = slack) -> ProcedureRecord {
        ProcedureRecord(sessionID: 1, start: now.addingTimeInterval(t), end: now.addingTimeInterval(t + 60), bundleID: bundle, appName: "App",
                        site: site, goal: goal, steps: [], habits: [], actionIDs: ids)
    }

    @Test func theSameWayForAnotherPersonIsOneRoutineDoneTwice() {
        let pia = Self.haakon.map { a -> ActionRecord in
            var a = a
            a.label = a.label.replacingOccurrences(of: "Haakon Olsen", with: "Pia Swarup")
            a.timestamp = a.timestamp.addingTimeInterval(86_400)
            return a
        }
        let p1 = Self.procedure("send a message to Haakon Olsen on Slack", at: 0)
        let p2 = Self.procedure("text Pia Swarup on Slack", at: 86_400)
        let routines = RoutineMiner.mine([p1, p2]) { $0.goal.contains("Haakon") ? Self.haakon : pia }
        #expect(routines.count == 1)
        let r = routines[0]
        #expect(r.count == 2 && r.goals == ["text Pia Swarup on Slack", "send a message to Haakon Olsen on Slack"])   // newest first
        #expect(r.template == "text … on Slack" && r.bundleID == Self.slack)
        #expect(r.slotWords == ["pia", "swarup"])
    }

    @Test func navigationTheUserTakesForManyTasksIsCounted() {
        let a = Self.canvasRun(course: "Mechanical Design ENGR3330", assignment: "Phase 1 Strategy Review", at: 0)
        let b = Self.canvasRun(course: "Applied Mathematics MTH3180", assignment: "Assignment 03", at: 1000)
        let routines = RoutineMiner.mine([Self.procedure("View the Phase 1 Strategy Review for Mechanical Design ENGR3330", at: 0, site: "canvas.olin.edu", bundle: Self.chrome),
                                          Self.procedure("review homework", at: 1000, site: "canvas.olin.edu", bundle: Self.chrome)]) {
            $0.goal.hasPrefix("View") ? a : b
        }
        #expect(routines.count == 2)
        let tabs = routines.flatMap(\.steps).filter { $0.label == "Assignments" }
        #expect(tabs.count == 2 && tabs.allSatisfy { $0.seen == 2 })               // the tab: in both
        #expect(routines.flatMap(\.steps).first { $0.label == "Assignment 03" }?.seen == 1)
    }

    @Test func oneClickIsNotARoutine() {
        #expect(RoutineMiner.routine(goal: "x", at: (Self.now, Self.now), bundleID: "a", appName: "A", site: nil,
                                     actions: [Self.act(.click, "OK", at: 0)]) == nil)
        #expect(RoutineMiner.routine(goal: "x", at: (Self.now, Self.now), bundleID: "a", appName: "A", site: nil,
                                     actions: [Self.act(.type, "Search", role: "field", at: 0)]) != nil)   // typing somewhere is a way
    }

    // MARK: Store

    @Test func routinesAreStoredWithHowTheAgentFared() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("navi-routines-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MemoryStore(directory: dir)
        try store.insertActions(Self.haakon)
        let ids = try store.actions(in: DateInterval(start: .distantPast, end: .distantFuture)).map(\.id)
        #expect(try store.actions(ids: [ids[2], ids[1], 99_999]).map(\.label) == ["Haakon Olsen", "Slack"])   // in the order asked

        try store.insertProcedure(Self.procedure("send a message to Haakon Olsen on Slack", at: 0, ids: [ids[2], ids[4]]))
        #expect(try store.procedures(since: .distantPast).first?.actionIDs == [ids[2], ids[4]])

        let routine = try #require(RoutineMiner.mine(try store.procedures(since: .distantPast)) { _ in Self.haakon }.first)
        try store.saveRoutines([routine])
        try store.noteRoutineOutcome(key: routine.key, worked: true)
        try store.noteRoutineOutcome(key: routine.key, worked: false)
        try store.saveRoutines([routine])                                          // mined again: the record stays
        let back = try #require(try store.routines().first)
        #expect(back.key == routine.key && back.steps == routine.steps && back.template == routine.template)
        #expect(back.worked == 1 && back.failed == 1 && !back.isDiscredited)
        try store.noteRoutineOutcome(key: routine.key, worked: false)
        #expect(try store.routines().first?.isDiscredited == true)

        try store.deleteAll()
        #expect(try store.routines().isEmpty)
    }

    @Test func oldDatabasesGainActionIDs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("navi-routines-old-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("memory.sqlite").path
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sh.arguments = [path, """
        CREATE TABLE procedures(id INTEGER PRIMARY KEY, session_id INTEGER NOT NULL DEFAULT 0, start_ts REAL NOT NULL, end_ts REAL NOT NULL,
          bundle_id TEXT NOT NULL DEFAULT '', app_name TEXT NOT NULL DEFAULT '', site TEXT, goal TEXT NOT NULL,
          steps TEXT NOT NULL DEFAULT '[]', habits TEXT NOT NULL DEFAULT '[]');
        INSERT INTO procedures(start_ts, end_ts, goal) VALUES (1, 2, 'old goal');
        """]
        try sh.run(); sh.waitUntilExit()
        let store = try MemoryStore(directory: dir)
        let p = try #require(try store.procedures(since: .distantPast).first)
        #expect(p.goal == "old goal" && p.actionIDs.isEmpty)
    }

    // MARK: Digester: the lines that did it

    @Test func theDigestNamesTheActionsThatDidIt() throws {
        var a = Self.haakon
        for i in a.indices { a[i].id = Int64(100 + i) }
        a.insert(a[2], at: 3)                                                        // a repeated click folds into one line
        let numbered = ActionJournal.numbered(a)
        #expect(numbered.lines.first?.hasPrefix("#1 ") == true)
        #expect(numbered.ids[2] == [102, 102])
        let d = try Digester.parse("""
        {"title": "T", "summary": "S", "goal": "message Haakon", "steps": ["x"], "habits": [], "did_it": [2, "#3", 3, 99, 0]}
        """)
        #expect(d.didIt == [2, 3, 99])
        let s = SessionRecord(id: 1, start: Self.now, end: Self.now, bundleID: Self.slack, appName: "Slack", title: "T", summary: "S", topics: [], entities: [])
        #expect(Digester.procedure(for: s, digest: d, actions: a)?.actionIDs == [101, 102])   // out-of-range lines dropped
        #expect(Digester.basePrompt.contains("\"did_it\""))
        let prompt = Digester.buildPrompt(for: [FrameRecord(timestamp: Self.now, bundleID: Self.slack, appName: "Slack", ocrText: "hi", importance: 2)], actions: a).text
        #expect(prompt.contains("#2 ") && prompt.contains("type in ‘Message to Haakon Olsen’"))
    }

    // MARK: Journal: typing is a place, never text

    @Test func typingAndSendingKeys() {
        #expect(ActionJournal.isTypingKey(keyCode: 0, flags: []))                  // "a"
        #expect(ActionJournal.isTypingKey(keyCode: 0, flags: [.shift]))
        #expect(ActionJournal.isTypingKey(keyCode: 49, flags: []))                 // space
        #expect(!ActionJournal.isTypingKey(keyCode: 0, flags: [.command]))         // a shortcut
        #expect(!ActionJournal.isTypingKey(keyCode: 123, flags: [.function]))      // ←
        #expect(!ActionJournal.isTypingKey(keyCode: 36, flags: []))                // Return is not typing
        #expect(ActionJournal.isSubmitKey(keyCode: 36, flags: []))
        #expect(!ActionJournal.isSubmitKey(keyCode: 36, flags: [.shift]))          // a new line
        #expect(!ActionJournal.isSubmitKey(keyCode: 0, flags: []))
        #expect(ActionJournal.describe(Self.act(.type, "Search", role: "field", at: 0)) == "type in ‘Search’")
    }

    // MARK: Matching a task

    static var routines: [Routine] {
        let pia = Self.haakon.map { a -> ActionRecord in
            var a = a; a.label = a.label.replacingOccurrences(of: "Haakon Olsen", with: "Pia Swarup"); return a
        }
        var slack = RoutineMiner.mine([procedure("send a message to Haakon Olsen on Slack", at: 0), procedure("text Pia Swarup on Slack", at: 100)]) {
            $0.goal.contains("Haakon") ? Self.haakon : pia
        }
        let canvas = RoutineMiner.mine([procedure("View the Phase 1 Strategy Review assignment for Mechanical Design ENGR3330", at: 200,
                                                  site: "canvas.olin.edu", bundle: chrome)]) { _ in
            canvasRun(course: "Mechanical Design ENGR3330 Fall 2026", assignment: "Phase 1 Strategy Review", at: 200)
        }
        slack += canvas
        return slack
    }

    @Test func aTaskFindsTheRoutineItIsAnotherInstanceOf() throws {
        let cs = UserRoutines.candidates(task: "message mikey on slack", routines: Self.routines, places: [Self.slack])
        let top = try #require(cs.first)
        #expect(top.routine.bundleID == Self.slack && top.fills == ["mikey"])
        let hw = try #require(UserRoutines.candidates(task: "open the phase 2 review assignment for mechanical design", routines: Self.routines).first)
        #expect(hw.routine.site == "canvas.olin.edu" && Set(hw.fills) == ["phase", "2", "mechanical", "design"])
        // Sharing only an app's name is no match.
        #expect(UserRoutines.candidates(task: "open slack", routines: Self.routines).isEmpty)
        #expect(UserRoutines.candidates(task: "what's the weather", routines: Self.routines).isEmpty)
        // Dictated text is the message, not a name to look for.
        #expect(UserRoutines.candidates(task: "message mikey on slack saying the review is done", routines: Self.routines).first?.fills == ["mikey"])
    }

    @Test func jevPicksAndWithoutJevOnlyAClearRepeat() throws {
        let cs = UserRoutines.candidates(task: "message mikey on slack", routines: Self.routines)
        let (state, questions) = UserRoutines.request(task: "message mikey on slack", candidates: cs)
        #expect((state["routines"] as? [[String: Any]])?.count == cs.count)
        guard case .choice(_, let criteria)? = questions["same_task"] else { Issue.record("no same_task question"); return }
        #expect(criteria["none"] != nil && criteria["r1"]?.contains("Slack") == true)
        let yes = JevClient.Answer.choice(choice: "r1", probabilities: ["r1": 0.8, "none": 0.2], confidence: 0.8)
        #expect(UserRoutines.pick(yes, among: cs)?.1 == 0.8)
        #expect(UserRoutines.pick(JevClient.Answer.choice(choice: "r1", probabilities: ["r1": 0.4], confidence: 0.4), among: cs) == nil)
        #expect(UserRoutines.pick(JevClient.Answer.choice(choice: "none", probabilities: ["none": 0.9], confidence: 0.9), among: cs) == nil)
        #expect(UserRoutines.localPick(cs)?.routine.count == 2)                    // done twice, covers the task
        let once = UserRoutines.candidates(task: "open the phase 2 review assignment for mechanical design", routines: Self.routines)
        #expect(UserRoutines.localPick(once) == nil)                                // done once: Jev must say so
    }

    // MARK: Following a route on the screen

    static func el(_ id: String, _ role: String, _ label: String, y: CGFloat, path: String = "", subrole: String? = nil) -> AXElement {
        AXElement(id: id, role: role, subrole: subrole, label: label, frame: CGRect(x: 20, y: y, width: 200, height: 20), path: path,
                  actions: ["AXPress"], pid: 42)
    }

    static func slackScreen(open chat: String? = nil) -> CUScreen {
        var els = [el("e1", "AXButton", "Haakon Olsen", y: 100, path: "Direct Messages"),
                   el("e2", "AXButton", "Pia Swarup", y: 130, path: "Direct Messages"),
                   el("e3", "AXButton", "Mikey Ku", y: 160, path: "Direct Messages"),
                   el("e4", "AXButton", "Delete message", y: 300)]
        if let chat { els.append(el("e5", "AXTextArea", "Message to \(chat)", y: 500, path: "composer")) }
        let snap = AXSnapshot(elements: els, windowTitle: "Slack", url: nil, focused: nil, visibleText: "", capturedAt: now,
                              pid: 42, bundleID: slack, appName: "Slack", windowFrame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        return CUPerception.perceive(snap, ocr: nil, goal: "message pia on slack")
    }

    static var slackRoute: UserRoute {
        let r = routines.first { $0.bundleID == slack }!
        return UserRoute(routine: r, fills: ["pia"], confidence: 0.8)
    }

    @Test func theSlotIsFilledWithTheTasksPerson() throws {
        var route = Self.slackRoute
        let screen = Self.slackScreen()
        // Already in Slack: "open Slack" is behind us; the DM row for Pia is the next step.
        let next = route.direct(on: screen, task: "message pia on slack")
        let (i, a) = try #require(next)
        #expect(route.steps[i].kind == .click && a == .click(elementID: "e2"))
        #expect(route.done == [0])
        // Not followable: typing and sending are Jev's (and the writer's, and the gate's).
        route.complete(through: i)
        let chat = Self.slackScreen(open: "Pia Swarup")
        #expect(route.direct(on: chat, task: "message pia on slack") == nil)
        let field = try #require(route.nextOnScreen(chat))
        #expect(route.steps[field.index].kind == .type && field.action == .typeText(elementID: "e5"))
        let marked = route.marks(on: chat)
        #expect(marked.count == 1 && chat.elementForItem[marked.first!] == "e5")
        // Jev typed there: the route moves on to sending, which it offers as this user's key.
        route.observe(.typeText(elementID: "e5"), on: chat)
        #expect(route.pending.map { route.steps[$0].kind } == [.submit])
        let keys = route.shortcuts([("cmd+n", "New message")])
        #expect(keys.contains { $0.0 == "cmd+return" && $0.1.contains("how this user sends") })
        let state = route.state(on: chat)
        #expect((state["steps"] as? [String])?.first?.hasPrefix("✓ ") == true && state["they_send_with"] as? String == "cmd+return")
    }

    @Test func aMissingOrAmbiguousControlIsJevs() {
        var nobody = UserRoute(routine: Self.slackRoute.routine, fills: ["zed"], confidence: 0.8)
        #expect(nobody.direct(on: Self.slackScreen(), task: "message zed on slack") == nil)
        // Words that fit two people equally well: ambiguous, so nothing is pressed.
        var two = UserRoute(routine: Self.slackRoute.routine, fills: ["olsen", "swarup"], confidence: 0.8)
        #expect(two.direct(on: Self.slackScreen(), task: "message olsen and swarup") == nil)
    }

    @Test func whatCodeMayPressWithoutJev() {
        func step(_ kind: RoutineStep.Kind, _ label: String, shortcut: String? = nil, slot: String? = nil, seen: Int? = nil) -> RoutineStep {
            var s = RoutineStep(kind: kind, app: "Chrome", bundleID: Self.chrome, site: "canvas.olin.edu", role: "link", label: label, shortcut: shortcut, slot: slot)
            s.seen = seen
            return s
        }
        let steps = [step(.click, "Assignments", seen: 3),                    // 0 navigation the user takes for many tasks
                     step(.click, "Applied Mathematics MTH3180 Fall 2026", seen: 3), // 1 a long, numbered item
                     step(.click, "Delete", seen: 5),                          // 2 reads irreversible
                     step(.click, "Haakon Olsen", slot: "haakon olsen"),        // 3 a slot the task fills
                     step(.type, "Search"),                                    // 4 typing
                     step(.submit, "", shortcut: "cmd+return"),                // 5 sending
                     step(.key, "New Message", shortcut: "cmd+n"),             // 6 a harmless shortcut
                     step(.click, "Modules", seen: 1),                         // 7 seen once, task does not name it
                     step(.click, "Modules", seen: 1)]                         // 8 (same, for the named case)
        let r = Routine(key: "k", goals: ["g"], template: "g", bundleID: Self.chrome, appName: "Chrome", steps: steps, count: 1, first: Self.now, last: Self.now)
        let route = UserRoute(routine: r, fills: [], confidence: 0.8)
        let task = "open my homework"
        #expect(route.mayFollow(0, task: task))
        #expect(!route.mayFollow(1, task: task))
        #expect(!route.mayFollow(2, task: task))
        #expect(route.mayFollow(3, task: task))
        #expect(!route.mayFollow(4, task: task) && !route.mayFollow(5, task: task))
        #expect(route.mayFollow(6, task: task))
        #expect(!route.mayFollow(7, task: task))
        #expect(route.mayFollow(8, task: "open modules"))                          // the task names it
    }

    @Test func theRunnerGetsOnlyWebSteps() throws {
        #expect(Self.slackRoute.runnerJSON() == nil)
        let web = try #require(Self.routines.first { $0.site == "canvas.olin.edu" })
        let json = try #require(UserRoute(routine: web, fills: ["mechanical", "design"], confidence: 0.7).runnerJSON())
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let steps = try #require(obj["steps"] as? [[String: Any]])
        #expect(steps.count == 3 && steps[1]["label"] as? String == "Assignments" && steps[0]["slot"] != nil)
        #expect(obj["fills"] as? [String] == ["mechanical", "design"])
    }

    // MARK: Page-aware marks

    @Test func marksComeFromThisPageWhenTheUserUsesIt() {
        var a: [ActionRecord] = []
        for i in 0..<6 {
            a.append(Self.act(.click, "Modules", role: "link", bundle: Self.chrome, url: "https://canvas.olin.edu/courses/\(1000 + i)", at: Double(i * 10)))
        }
        for i in 0..<4 {
            a.append(Self.act(.click, "Inbox", role: "link", bundle: Self.chrome, url: "https://canvas.olin.edu/", at: Double(100 + i * 10)))
        }
        let p = UserMoves.build(actions: a, procedures: [])
        #expect(p.pages["canvas.olin.edu/courses/#"]?.controls["modules"]?.count == 6)
        let items: [(index: Int, text: String)] = [(0, "Modules"), (1, "Inbox")]
        let onCourse = UserMoves.hints(profile: p, goal: "x", bundleID: Self.chrome, url: "https://canvas.olin.edu/courses/77", items: items,
                                       lastClicked: nil, shortcuts: [])
        #expect(onCourse.clicks.keys.sorted() == [0])                              // on a course page: what they click there
        let home = UserMoves.hints(profile: p, goal: "x", bundleID: Self.chrome, url: "https://canvas.olin.edu/", items: items,
                                   lastClicked: nil, shortcuts: [])
        #expect(Set(home.clicks.keys) == [0, 1])                                   // too few on this page: the site's
    }
}

@Suite struct CompoundRoutineTests {
    @Test func twoInstructionsInTwoPlacesAreTwoRoutines() {
        #expect(RoutineMiner.goalParts("send a message to Jessica Sahagian on LinkedIn and review Assignment 03 in Canvas")
                == ["send a message to Jessica Sahagian on LinkedIn", "review Assignment 03 in Canvas"])
        #expect(RoutineMiner.goalParts("Access and review Assignment 03 on Canvas, then open the GitHub repository")
                == ["Access and review Assignment 03 on Canvas", "open the GitHub repository"])
        #expect(RoutineMiner.goalParts("find pants and shirts") == ["find pants and shirts"])   // "and" before a noun joins
        let chrome = UserRoutinesTests.chrome
        let a = [UserRoutinesTests.act(.type, "Write a message…", role: "field", bundle: chrome, app: "Chrome", url: "https://www.linkedin.com/in/jessica/", at: 0),
                 UserRoutinesTests.act(.key, "", bundle: chrome, app: "Chrome", url: "https://www.linkedin.com/in/jessica/", shortcut: "cmd+return", at: 5)]
            + UserRoutinesTests.canvasRun(course: "Applied Mathematics MTH3180", assignment: "Assignment 03", at: 30)
        let p = ProcedureRecord(sessionID: 1, start: UserRoutinesTests.now, end: UserRoutinesTests.now.addingTimeInterval(60), bundleID: chrome,
                                appName: "Chrome", site: "canvas.olin.edu",
                                goal: "send a message to Jessica Sahagian on LinkedIn and review Assignment 03 in Canvas", steps: [], habits: [])
        let rs = RoutineMiner.mine([p]) { _ in a }
        #expect(rs.count == 2)
        let canvas = rs.first { $0.site == "canvas.olin.edu" }
        #expect(canvas?.goals == ["review Assignment 03 in Canvas"] && canvas?.steps.count == 3)
        #expect(canvas?.steps.last?.slot == "03" && canvas?.steps.first?.slot == nil)
        // No control there shows her name: nothing to fill, the routine keeps its words.
        #expect(rs.first { $0.site == "linkedin.com" }?.template == "send a message to Jessica Sahagian on LinkedIn")
    }

    @Test func onlyNavigationIsPressedWithoutJev() {
        func route(_ role: String, _ label: String) -> UserRoute {
            let s = RoutineStep(kind: .click, app: "Chrome", bundleID: UserRoutinesTests.chrome, site: "github.com", role: role, label: label, seen: 3)
            return UserRoute(routine: Routine(key: "k", goals: ["g"], template: "g", bundleID: "b", appName: "A", steps: [s], count: 2,
                                              first: UserRoutinesTests.now, last: UserRoutinesTests.now), fills: [], confidence: 0.9)
        }
        #expect(route("button", "Show more").mayFollow(0, task: "x"))
        #expect(route("link", "Settings").mayFollow(0, task: "x"))
        #expect(!route("button", "Add people").mayFollow(0, task: "x"))         // opens an invite: Jev's, with its gate
        #expect(!route("button", "Continue").mayFollow(0, task: "x"))           // consent
        #expect(!route("button", "Export selected channels").mayFollow(0, task: "x"))
        #expect(!route("checkbox", "HTML").mayFollow(0, task: "x"))             // toggles change something
        #expect(!route("link", "Share").mayFollow(0, task: "x"))
    }
}
