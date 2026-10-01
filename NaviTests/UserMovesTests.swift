import AppKit
import Foundation
import Testing
@testable import Navi

/// Operational screen memory: the user's own clicks and shortcuts (`ActionJournal`) and the
/// procedures the digester distils from them → `UserMoves` → Jev's state every step.
@Suite struct UserMovesTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let outlook = "com.microsoft.Outlook"
    static let canvas = "https://canvas.olin.edu/courses/123/assignments"

    static func act(_ kind: ActionRecord.Kind, _ label: String, role: String = "button", bundle: String = outlook, app: String = "Microsoft Outlook",
                    url: String? = nil, shortcut: String? = nil, path: String? = nil, at seconds: Double) -> ActionRecord {
        ActionRecord(timestamp: now.addingTimeInterval(seconds), bundleID: bundle, appName: app, windowTitle: "Inbox", url: url,
                     kind: kind, role: role, label: label, shortcut: shortcut, path: path)
    }

    /// Three mornings of email the way this user does it: open a message, Reply with the
    /// toolbar button, send with ⌘↩; File › New Email from the menu (it has ⌘N); and a
    /// Canvas course page in Chrome.
    static let actions: [ActionRecord] = {
        var a: [ActionRecord] = []
        for day in 0..<3 {
            let t = Double(day) * 86_400
            a.append(act(.click, "Mikey Ku, are we still on for 5?", role: "row", at: t))
            a.append(act(.click, "Reply", at: t + 10))
            a.append(act(.key, "Send", shortcut: "cmd+return", path: "Message", at: t + 40))
            a.append(act(.menu, "New Email", role: "menu item", shortcut: "cmd+n", path: "File", at: t + 600))
            a.append(act(.click, "Assignments", role: "link", bundle: "com.google.Chrome", app: "Google Chrome", url: canvas, at: t + 900))
        }
        return a
    }()

    static let procedures: [ProcedureRecord] = [
        ProcedureRecord(sessionID: 1, start: now, end: now.addingTimeInterval(120), bundleID: outlook, appName: "Microsoft Outlook",
                        site: nil, goal: "reply to Mikey's email about the meeting",
                        steps: ["Outlook: click the message row", "click 'Reply'", "cmd+return"],
                        habits: ["Replies from the reading pane and sends with cmd+return"]),
        ProcedureRecord(sessionID: 2, start: now.addingTimeInterval(-86_400), end: now, bundleID: "com.google.Chrome", appName: "Google Chrome",
                        site: "canvas.olin.edu", goal: "submit assignment 2 on canvas",
                        steps: ["canvas.olin.edu: Courses › MTH3199 › Assignments", "click 'Submit Assignment'"],
                        habits: ["Opens assignments from the course's Assignments tab"]),
    ]

    static let profile = UserMoves.build(actions: actions, procedures: procedures)

    // MARK: ActionJournal helpers

    @Test func shortcutsAreRecordedTypingIsNot() throws {
        #expect(ActionJournal.combo(keyCode: 15, flags: [.command]) == "cmd+r")
        #expect(ActionJournal.combo(keyCode: 17, flags: [.command, .shift]) == "cmd+shift+t")
        #expect(ActionJournal.combo(keyCode: 48, flags: [.control]) == "ctrl+tab")
        #expect(ActionJournal.combo(keyCode: 36, flags: [.command]) == "cmd+return")
        #expect(ActionJournal.combo(keyCode: 15, flags: []) == nil)                 // typing "r"
        #expect(ActionJournal.combo(keyCode: 15, flags: [.shift]) == nil)           // typing "R"
        #expect(ActionJournal.combo(keyCode: 15, flags: [.option]) == nil)          // typing "®"
        // Every recorded combo replays through the agent's own key parser.
        let k = try KeyCombo.parse(try #require(ActionJournal.combo(keyCode: 17, flags: [.command, .shift])))
        #expect(k.keyCode == 17 && k.flags.contains(.maskCommand) && k.flags.contains(.maskShift))
    }

    @Test func menuItemShortcuts() {
        #expect(ActionJournal.menuCombo(char: "N", modifiers: 0, virtualKey: nil) == "cmd+n")
        #expect(ActionJournal.menuCombo(char: "N", modifiers: 1, virtualKey: nil) == "cmd+shift+n")
        #expect(ActionJournal.menuCombo(char: "F", modifiers: 2, virtualKey: nil) == "cmd+option+f")
        #expect(ActionJournal.menuCombo(char: "?", modifiers: 0, virtualKey: nil) == "cmd+shift+slash")
        #expect(ActionJournal.menuCombo(char: nil, modifiers: 0, virtualKey: 36) == "cmd+return")
        #expect(ActionJournal.menuCombo(char: nil, modifiers: 0, virtualKey: nil) == nil)
        #expect(ActionJournal.menuCombo(char: "N", modifiers: 8, virtualKey: nil) == nil)        // no modifier at all
        #expect(ActionJournal.menuCombo(char: "N", modifiers: 12, virtualKey: nil) == "ctrl+n")   // ⌃ without ⌘
    }

    @Test func labelsAreOneCleanLine() {
        #expect(ActionJournal.clean("  New\n   Email ", policy: .strict) == "New")
        #expect(ActionJournal.clean("Reply   all", policy: .strict) == "Reply all")
        #expect(ActionJournal.clean("   ", policy: .strict) == nil)
        #expect(ActionJournal.clean(String(repeating: "a", count: 200), policy: .strict)?.count == ActionJournal.maxLabel)
        let ssn = ActionJournal.clean("SSN 123-45-6789", policy: .strict) ?? ""
        #expect(!ssn.contains("123-45-6789"))
    }

    @Test func actionLinesFoldRepeatsAndNamePlaces() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let a = [Self.act(.click, "Reply", at: 0), Self.act(.click, "Reply", at: 1),
                 Self.act(.key, "Send", shortcut: "cmd+return", path: "Message", at: 30),
                 Self.act(.click, "Assignments", role: "link", bundle: "com.google.Chrome", app: "Chrome", url: Self.canvas, at: 60)]
        let lines = ActionJournal.lines(a, calendar: cal)
        #expect(lines.count == 3)
        #expect(lines[0].hasSuffix("Microsoft Outlook · click button ‘Reply’ ×2"))
        #expect(lines[1].hasSuffix(" press cmd+return → ‘Send’ in Message menu"))
        #expect(!lines[1].contains("Outlook"))                                        // same place: not repeated
        #expect(lines[2].contains("canvas.olin.edu · click link ‘Assignments’"))
        #expect(ActionJournal.describe(Self.act(.menu, "New Email", shortcut: "cmd+n", path: "File", at: 0)) == "menu File › New Email (cmd+n)")
    }

    // MARK: Store

    @Test func storeKeepsActionsAndProceduresLongerThanFrames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("navi-moves-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MemoryStore(directory: dir)
        let real = Date()
        let old = ActionRecord(timestamp: real.addingTimeInterval(-30 * 86_400), bundleID: "a", appName: "A", kind: .click, role: "button", label: "Old")
        let ancient = ActionRecord(timestamp: real.addingTimeInterval(-200 * 86_400), bundleID: "a", appName: "A", kind: .key, shortcut: "cmd+k")
        let fresh = ActionRecord(timestamp: real, bundleID: "a", appName: "A", windowTitle: "W", url: "https://x.test/", kind: .menu,
                                 role: "menu item", label: "New", shortcut: "cmd+n", path: "File")
        try store.insertActions([old, ancient, fresh])
        #expect(try store.actionCount() == 3)
        let back = try store.actions(in: DateInterval(start: real.addingTimeInterval(-10), end: real.addingTimeInterval(10)))
        #expect(back.count == 1 && back[0].kind == .menu && back[0].shortcut == "cmd+n" && back[0].path == "File" && back[0].url == "https://x.test/")

        var p = Self.procedures[0]; p.start = real; p.end = real
        try store.insertProcedure(p)
        try store.insertProcedure(ProcedureRecord(sessionID: 9, start: real.addingTimeInterval(-400 * 86_400), end: real.addingTimeInterval(-400 * 86_400),
                                                  bundleID: "a", appName: "A", goal: "too old", steps: [], habits: []))
        // Frames go after 14 days; a 30-day-old click stays (90), a 200-day-old one goes; procedures last a year.
        try store.pruneOlderThan(days: 14, now: real)
        #expect(try store.actionCount() == 2)
        let procs = try store.procedures(since: .distantPast)
        #expect(procs.count == 1 && procs[0].goal == p.goal && procs[0].steps == p.steps && procs[0].habits == p.habits)
    }

    // MARK: Digest

    @Test func digestParsesTheOperationalHalf() throws {
        let d = try Digester.parse("""
        {"title": "Replied to Mikey", "summary": "Replied.", "goal": "reply to Mikey's email",
         "steps": ["Outlook: click 'Reply'", "cmd+return"], "habits": ["Sends with cmd+return"], "topics": [], "entities": []}
        """)
        #expect(d.goal == "reply to Mikey's email")
        #expect(d.steps == ["Outlook: click 'Reply'", "cmd+return"])
        #expect(d.habits == ["Sends with cmd+return"])
        let browsing = try Digester.parse(#"{"title": "Read news", "summary": "Read.", "goal": null, "steps": ["scrolled"], "habits": []}"#)
        #expect(browsing.goal == nil && browsing.steps.isEmpty)                          // no task: no procedure
        let legacy = try Digester.parse(#"{"title": "T", "summary": "S"}"#)
        #expect(legacy.goal == nil && legacy.steps.isEmpty && legacy.habits.isEmpty)
    }

    @Test func promptCarriesWhatTheUserDid() {
        let f = [FrameRecord(timestamp: Self.now, bundleID: Self.outlook, appName: "Microsoft Outlook", windowTitle: "Inbox",
                             ocrText: "Mikey Ku — are we still on for 5?", importance: 2)]
        let (text, _) = Digester.buildPrompt(for: f, actions: Array(Self.actions.prefix(3)))
        #expect(text.contains("[ACTIONS]\n"))
        #expect(text.contains("click button ‘Reply’"))
        #expect(text.contains("press cmd+return → ‘Send’"))
        #expect(Digester.buildPrompt(for: f).text.contains("[ACTIONS] none recorded"))
        #expect(Digester.basePrompt.contains("\"goal\"") && Digester.basePrompt.contains("\"steps\"") && Digester.basePrompt.contains("\"habits\""))
    }

    @Test func aSessionWithAGoalBecomesAProcedure() {
        let s = SessionRecord(id: 7, start: Self.now, end: Self.now, bundleID: "com.google.Chrome", appName: "Google Chrome",
                              url: Self.canvas, title: "T", summary: "S", topics: [], entities: [])
        var d = DigestResult.empty
        #expect(Digester.procedure(for: s, digest: d) == nil)
        d.goal = "submit assignment 2"; d.steps = ["a", "b"]; d.habits = ["h"]
        let p = Digester.procedure(for: s, digest: d)
        #expect(p?.sessionID == 7 && p?.site == "canvas.olin.edu" && p?.steps == ["a", "b"] && p?.habits == ["h"])
        // Without a model the recorded actions are the steps; no goal, so no procedure.
        let local = Digester.localDigest([FrameRecord(timestamp: Self.now, bundleID: Self.outlook, appName: "Outlook", ocrText: "x", importance: 2)],
                                         actions: Array(Self.actions.prefix(2)))
        #expect(local.steps == ["click row ‘Mikey Ku, are we still on for 5?’", "click button ‘Reply’"] && local.goal == nil)
    }

    @Test func scrubCoversStepsAndGoal() {
        var d = DigestResult.empty
        d.title = "T"; d.summary = "S"
        d.goal = "update SSN 123-45-6789 on the form"
        d.steps = ["type 123-45-6789 into SSN"]
        let (clean, removed) = PersonalData.scrub(d, policy: .strict)
        #expect(removed >= 2)
        #expect(!(clean.goal ?? "").contains("123-45-6789") && !clean.steps[0].contains("123-45-6789"))
    }

    // MARK: UserMoves

    @Test func profileCountsClicksShortcutsAndWhatComesNext() throws {
        let place = try #require(Self.profile.places[Self.outlook])
        #expect(place.controls["reply"]?.count == 3)
        #expect(place.shortcuts["cmd+return"]?.count == 3 && place.shortcuts["cmd+return"]?.title == "Send")
        #expect(place.controls["new email"]?.kind == .menu && place.controls["new email"]?.shortcut == "cmd+n")
        #expect(place.next[UserMoves.norm("Mikey Ku, are we still on for 5?")]?["reply"] == 3)
        // Pages are their own place: Canvas, not "Chrome".
        #expect(Self.profile.places["canvas.olin.edu"]?.controls["assignments"]?.count == 3)
        #expect(Self.profile.places["com.google.Chrome"] == nil)
    }

    @Test func labelsMatchAcrossBadgesAndPreviews() {
        #expect(UserMoves.norm("Drafts (3)") == "drafts")
        #expect(UserMoves.norm("Assignment 2") == "assignment 2")                       // a number that names something stays
        #expect(UserMoves.norm("New Email…") == "new email")
        #expect(UserMoves.sameControl("mikey ku", "mikey ku, see you at 5"))
        #expect(!UserMoves.sameControl("reply", "reply all"))
        #expect(!UserMoves.sameControl("assignment 2", "assignment 23"))
        // A row is its name: the same conversation with a newer preview still matches; a button does not.
        let row = UserMoves.Control(label: "Mikey Ku, are we still on?", role: "row", kind: .click, count: 3, lastSeen: Self.now)
        #expect(UserMoves.matches(row, "mikey ku, new preview"))
        #expect(!UserMoves.matches(row, "mikey kuhn, hi"))
        var button = row; button.role = "button"
        #expect(!UserMoves.matches(button, "mikey ku, new preview"))
    }

    @Test func hintsMarkWhatThisUserClicksHere() {
        let items: [(index: Int, text: String)] = [(1, "Reply"), (2, "Reply All"), (3, "Forward"), (4, "Mikey Ku, new preview text"), (5, "Delete")]
        let base: [(String, String)] = [("cmd+n", "New: note, message"), ("cmd+f", "Find")]
        let h = UserMoves.hints(profile: Self.profile, goal: "reply to mikey about the meeting", bundleID: Self.outlook, url: nil,
                                items: items, lastClicked: "Mikey Ku, new preview text", shortcuts: base)
        #expect(h.clicks[1] == 3 && h.clicks[4] == 3)                                 // Reply, and the row despite a new preview
        #expect(h.clicks[2] == nil && h.clicks[3] == nil && h.clicks[5] == nil)
        #expect(h.next == [1])                                                        // after opening the message: Reply
        // ⌘N already offered gets "this user chooses it"; ⌘↩ (pressed, named Send) is added.
        #expect(h.shortcuts.first { $0.0 == "cmd+n" }?.1.contains("this user chooses ‘New Email’ from the File menu, 3×") == true)
        #expect(h.shortcuts.contains { $0.0 == "cmd+return" && $0.1.hasPrefix("Send — this user presses it here, 3×") })
        let state = h.state ?? [:]
        #expect((state["did_before"] as? [String])?.first?.hasPrefix("reply to Mikey's email about the meeting (Microsoft Outlook) → ") == true)
        #expect((state["habits"] as? [String])?.contains("Replies from the reading pane and sends with cmd+return") == true)
        #expect((state["often_clicks_here"] as? [String]) == ["‘New Email’ (menu item, 3×)", "‘Reply’ (button, 3×)"])  // rows stay out
        #expect(state["here"] as? String == "Microsoft Outlook")
    }

    @Test func noMemoryNoHints() {
        let h = UserMoves.hints(profile: .empty, goal: "reply", bundleID: Self.outlook, url: nil, items: [(1, "Reply")], lastClicked: nil,
                                shortcuts: [("cmd+n", "New")])
        #expect(h.isEmpty && h.shortcuts.count == 1 && h.state == nil)
        // An unrelated goal in an app with history still gets the app's habits and clicks, but no procedure.
        let other = UserMoves.hints(profile: Self.profile, goal: "play some music", bundleID: Self.outlook, url: nil, items: [], lastClicked: nil, shortcuts: [])
        #expect(other.state?["did_before"] == nil && other.state?["often_clicks_here"] != nil)
    }

    @Test func proceduresMatchByGoalPreferringThePlace() {
        let any = UserMoves.matching(goal: "submit assignment 3 on canvas", place: nil, in: Self.profile.procedures, limit: 3)
        #expect(any.first?.goal == "submit assignment 2 on canvas")
        #expect(UserMoves.matching(goal: "open spotify", place: nil, in: Self.profile.procedures, limit: 3).isEmpty)
    }

    @Test func jevSeesTheMarksAndTheWay() throws {
        var input = TypesafeCUTests.input()
        let signIn = try #require(input.screen.items.first { $0.text == "Sign in" }).index
        #expect(CUDecide.state(input)["how_this_user_works"] == nil)
        input.userMoves = UserMoves.Hints(clicks: [signIn: 5], next: [signIn], shortcuts: [],
                                          state: ["note": UserMoves.note, "did_before": ["buy a ticket → click 'Sign in'"]])
        let state = CUDecide.state(input)
        let item = (state["screen_items_in_reading_order"] as? [[String: Any]])?.first { $0["i"] as? Int == signIn }
        #expect(item?["user_clicks"] as? Int == 5 && item?["user_next"] as? Bool == true)
        #expect((state["how_this_user_works"] as? [String: Any])?["did_before"] as? [String] == ["buy a ticket → click 'Sign in'"])
        let crit = CUDecide.itemCriteria(input)["\(signIn)"] ?? ""
        #expect(crit.contains("this user clicks this here (5×)") && crit.contains("what this user usually clicks next"))
        guard case .choice(let instructions, _)? = CUDecide.request(input).questions["kind"] else { Issue.record("no kind question"); return }
        #expect(instructions.contains("follow their way"))
    }

    @Test func vaultNoteShowsRoutinesAndFasterWays() {
        let md = UserMoves.markdown(Self.profile)
        #expect(md.contains("## Your routines"))
        #expect(md.contains("**reply to Mikey's email about the meeting** (Microsoft Outlook): Outlook: click the message row → click 'Reply' → cmd+return"))
        #expect(md.contains("## How you do things"))
        #expect(md.contains("## Faster ways"))
        #expect(md.contains("you chose **File › New Email** from the menu 3× — **⌘N** does it in one keystroke."))
        let tips = UserMoves.tips(Self.profile)
        #expect(tips.count == 1 && tips[0].shortcut == "cmd+n" && tips[0].presses == 0)
    }
}

@Suite struct ActionCleanupTests {
    @Test func blockedDetailsLeaveClicksAndRoutinesToo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("navi-moves-clean-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MemoryStore(directory: dir)
        try store.insertActions([
            ActionRecord(timestamp: Date(), bundleID: "a", appName: "A", windowTitle: "Card 4111 1111 1111 1111", kind: .click, role: "button", label: "Pay"),
            ActionRecord(timestamp: Date(), bundleID: "a", appName: "A", kind: .click, role: "button", label: "Reply"),
        ])
        try store.insertProcedure(ProcedureRecord(sessionID: 1, start: Date(), end: Date(), bundleID: "a", appName: "A",
                                                  goal: "update SSN 123-45-6789", steps: ["type it"], habits: []))
        let cleanup = PersonalDataCleanup(store: store, vaultRoot: dir, policy: .strict)
        let plan = try cleanup.plan()
        #expect(plan.actionRows == 2)
        let report = try cleanup.apply(plan)
        #expect(report.actionRowsRedacted == 2)
        let all = try store.actions(in: DateInterval(start: .distantPast, end: .distantFuture))
        #expect(!all.contains { ($0.windowTitle ?? "").contains("4111") } && all.contains { $0.label == "Reply" })
        #expect(try store.procedures(since: .distantPast).first?.goal.contains("123-45-6789") == false)
        #expect(try cleanup.plan().actionRows == 0)
    }
}

@Suite struct ActionPrivacyTests {
    @Test func deleteEverythingAndDeleteBeforeTakeClicksAndRoutines() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("navi-moves-erase-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MemoryStore(directory: dir)
        let now = Date()
        func seed() throws {
            try store.insertActions([ActionRecord(timestamp: now.addingTimeInterval(-3600), bundleID: "a", appName: "A", kind: .click, role: "button", label: "Reply")])
            try store.insertProcedure(ProcedureRecord(sessionID: 1, start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-3600),
                                                      bundleID: "a", appName: "A", goal: "reply", steps: ["x"], habits: []))
        }
        try seed()
        try store.prune(before: now)                       // "delete history before now": nothing learned survives
        #expect(try store.actionCount() == 0 && (try store.procedures(since: .distantPast)).isEmpty)
        try seed()
        try store.deleteAll()
        #expect(try store.actionCount() == 0 && (try store.procedures(since: .distantPast)).isEmpty)
    }
}

@Suite struct ProcedureBackfillTests {
    @Test func sessionsWithoutRoutinesNewestFirstBelowTheCursor() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("navi-backfill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MemoryStore(directory: dir)
        let t = Date()
        var ids: [Int64] = []
        for i in 0..<5 {
            ids.append(try store.insertSession(SessionRecord(start: t.addingTimeInterval(Double(i)), end: t.addingTimeInterval(Double(i)),
                                                             bundleID: "a", appName: "A", title: "s\(i)", summary: "", topics: [], entities: [])))
        }
        try store.insertProcedure(ProcedureRecord(sessionID: ids[3], start: t, end: t, bundleID: "a", appName: "A", goal: "g", steps: ["x"], habits: []))
        #expect(try store.maxSessionID() == ids[4])
        #expect(try store.sessionsWithoutProcedure(below: ids[4] + 1, limit: 3).map(\.id) == [ids[4], ids[2], ids[1]])
        #expect(try store.sessionsWithoutProcedure(below: ids[1], limit: 10).map(\.id) == [ids[0]])
    }

    @Test func oldNotesGainAHowSectionOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("navi-backfill-vault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sessions"), withIntermediateDirectories: true)
        let rel = "Sessions/old.md"
        try "---\ntype: session\ntitle: \"Old\"\n---\n\n# Old\n\nDid things.\n\n## Related\n- [[Daily/2026-09-20]]\n"
            .write(to: root.appendingPathComponent(rel), atomically: true, encoding: .utf8)
        var d = DigestResult.empty
        d.goal = "submit assignment 2"; d.steps = ["open Canvas", "click 'Submit'"]; d.habits = ["Uses the Assignments tab"]
        let vault = VaultWriter(root: root)
        try vault.appendHow(notePath: rel, digest: d)
        try vault.appendHow(notePath: rel, digest: d)                                    // a second pass changes nothing
        let text = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
        #expect(text.contains("goal: \"submit assignment 2\""))
        #expect(text.contains("## How\n**Goal:** submit assignment 2\n1. open Canvas\n2. click 'Submit'\n- *How you work:* Uses the Assignments tab"))
        #expect(text.components(separatedBy: "## How").count == 2)
        #expect(text.contains("Did things.") && text.contains("## Related"))
    }

    @Test func noModelNoBackfill() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("navi-backfill-local-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MemoryStore(directory: dir)
        let vault = VaultWriter(root: dir.appendingPathComponent("vault"))
        let digester = Digester(store: store, vault: vault, claude: ClaudeClient(), gemini: GeminiClient(), updateStatus: { _ in })
        let r = await ProcedureBackfill(store: store, digester: digester, vault: vault).run(provider: .local, policy: .strict)
        #expect(r == ProcedureBackfill.Report())
        #expect(UserDefaults.navi.object(forKey: ProcedureBackfill.doneKey) == nil)       // the local digest names no goal: try again with a model
    }
}

@Suite struct RunnerMarksTests {
    @Test func runnerGetsSitesNotApps() throws {
        let json = try #require(UserMoves.runnerJSON(UserMovesTests.profile))
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let sites = try #require(obj["sites"] as? [String: Any])
        #expect(Set(sites.keys) == ["canvas.olin.edu"])                               // Outlook is an app: the native driver's
        let canvas = try #require(sites["canvas.olin.edu"] as? [String: Any])
        let clicks = try #require(canvas["clicks"] as? [[String: Any]])
        #expect(clicks.first?["label"] as? String == "Assignments" && clicks.first?["count"] as? Int == 3)
        #expect(UserMoves.runnerJSON(.empty) == nil)
    }

    @Test func theStartPagesSiteComesFirst() throws {
        var acts: [ActionRecord] = []
        for i in 0..<30 { acts.append(UserMovesTests.act(.click, "Big", role: "link", bundle: "com.google.Chrome", app: "Chrome", url: "https://big.test/", at: Double(i))) }
        acts.append(UserMovesTests.act(.click, "Small", role: "link", bundle: "com.google.Chrome", app: "Chrome", url: "https://small.test/", at: 100))
        acts.append(UserMovesTests.act(.click, "Small", role: "link", bundle: "com.google.Chrome", app: "Chrome", url: "https://small.test/", at: 101))
        let profile = UserMoves.build(actions: acts, procedures: [])
        #expect(profile.places["small.test"]?.isWeb == true)
        let json = try #require(UserMoves.runnerJSON(profile, prefer: "https://small.test/page"))
        #expect(json.contains("small.test") && json.contains("big.test"))
    }
}
