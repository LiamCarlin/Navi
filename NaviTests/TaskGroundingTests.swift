import Foundation
import Testing
@testable import Navi

/// `TaskGrounding`: what "the last assignment I did", "the doc I was working on" or
/// "that video from yesterday" mean, read from what the user really had open.
@Suite struct TaskGroundingTests {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    /// Thursday 2026-10-01, 4:00 PM in Boston.
    static let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 16))!

    static func session(_ bundle: String, _ app: String, url: String? = nil, title: String, hoursAgo: Double, minutes: Double = 1,
                        _ entities: [(String, String)] = []) -> SessionRecord {
        let end = now.addingTimeInterval(-hoursAgo * 3600)
        return SessionRecord(start: end.addingTimeInterval(-minutes * 60), end: end, bundleID: bundle, appName: app, url: url,
                             title: title, summary: "private summary text", topics: [],
                             entities: entities.map { EntityRef(name: $0.0, type: $0.1) })
    }

    static let chrome = ("com.google.Chrome", "Google Chrome")

    /// A day like the one that asked for this: a long morning on one assignment, a glance at
    /// another course's list, the lab report doc, an Onshape model, a chat, an assistant, a search.
    static let sessions: [SessionRecord] = {
        var s: [SessionRecord] = []
        for i in 0..<6 {
            s.append(session(chrome.0, chrome.1, url: "https://canvas.olin.edu/courses/1079/assignments/20385?module_item_id=9",
                             title: "Work on MTH3199 Assignment 02 Strandbeest", hoursAgo: 6 + Double(i) * 0.2, minutes: 9,
                             [("Assignment 02", "project")]))
        }
        s.append(session(chrome.0, chrome.1, url: "https://docs.google.com/document/d/LAB/edit", title: "Edit MTH3199 Assignment 2 Lab Report",
                         hoursAgo: 5.7, minutes: 4))
        s.append(session(chrome.0, chrome.1, url: "https://canvas.olin.edu/courses/1083/assignments", title: "Review AHSE2199 assignment list",
                         hoursAgo: 2.2, minutes: 1))
        s.append(session(chrome.0, chrome.1, url: "https://cad.onshape.com/documents/32e/w/d02/e/ecd", title: "Model the Yarn Bowl surface in Onshape",
                         hoursAgo: 1, minutes: 20, [("Assignment 02", "project")]))
        s.append(session("com.apple.MobileSMS", "Messages", title: "Chat with Bella Chen about the assignment", hoursAgo: 0.5))
        s.append(session("com.anthropic.claudefordesktop", "Claude", title: "Asked Claude about the assignment", hoursAgo: 0.4, minutes: 10))
        s.append(session(chrome.0, chrome.1, url: "https://www.google.com/search?q=assignment+help", title: "Searched assignment help", hoursAgo: 0.3))
        s.append(session(chrome.0, chrome.1, url: "https://github.com/me/MTH3199-Assignment-2/settings/access", title: "Assignment repo access settings",
                         hoursAgo: 0.2))
        s.append(session(chrome.0, chrome.1, url: "https://www.youtube.com/watch?v=gWotBPtsulo&t=40", title: "Watched How Shein Built a Fast-Fashion Empire",
                         hoursAgo: 24, minutes: 3))
        s.append(session(chrome.0, chrome.1, url: "https://docs.google.com/spreadsheets/d/MECH/edit", title: "Reviewed MECHDES Schedule F26",
                         hoursAgo: 5.9, minutes: 2))
        return s
    }()

    static let titles = [
        "https://canvas.olin.edu/courses/1079/assignments/20385": "Assignment 02 - Part of group Claude - Google Chrome - Liam",
        "https://docs.google.com/document/d/LAB/edit": "MTH3199 Mech E Math: Assignment 2 Lab Report - Google Docs - High memory usage - 958 MB - Google Chrome - Liam",
    ]

    static func candidates(_ task: String) -> [TaskGrounding.Candidate] {
        TaskGrounding.candidates(task: task, scope: TaskGrounding.scope(of: task, now: now, calendar: calendar), sessions: sessions,
                                 pageTitles: titles, things: [], now: now)
    }

    // MARK: Reading the task

    @Test func scopeReadsTimeAndPointingBack() {
        func scope(_ t: String) -> TaskGrounding.Scope { TaskGrounding.scope(of: t, now: Self.now, calendar: Self.calendar) }
        #expect(scope("open the last assignment I did").recent)
        #expect(scope("pull up the doc I was working on").recent)
        #expect(scope("continue where I left off").recent)
        #expect(scope("open that linkedin profile").recent)
        #expect(!scope("open chrome").recent)
        #expect(!scope("text mikey saying I did the homework").recent)               // dictated, not a reference
        let y = scope("open the video from yesterday")
        #expect(y.recent && y.interval?.start == Self.calendar.date(byAdding: .day, value: -1, to: Self.calendar.startOfDay(for: Self.now)))
        #expect(scope("open the spreadsheet from this morning").interval?.start == Self.calendar.startOfDay(for: Self.now))
        // "on monday" is the most recent Monday before today (Thursday → three days back).
        #expect(scope("the doc I made on monday").interval?.start == Self.calendar.date(byAdding: .day, value: -3, to: Self.calendar.startOfDay(for: Self.now)))
    }

    @Test func wordsSayWhatNotWhenOrWho() {
        let w = TaskGrounding.words(of: "open the last assignment I did")
        #expect(w.specific.isEmpty && w.generic == ["assignment"])
        let m = TaskGrounding.words(of: "open my mth3199 assignment 02 on onshape")
        #expect(m.specific.isSuperset(of: ["mth3199", "2", "onshape"]))
        #expect(TaskGrounding.words(of: "send dhvan the hci notes", exclude: ["dhvan"]).specific == ["hci"])
        #expect(TaskGrounding.norm("canvas") == "canvas")
        #expect(TaskGrounding.norm("assignments") == "assignment")
        #expect(TaskGrounding.norm("docs") == "document")
        #expect(TaskGrounding.norm("02") == "2")
        #expect(TaskGrounding.norm("0002") == "0002")
        #expect(TaskGrounding.withoutDictation("text mom saying I'm on my way") == "text mom")
    }

    @Test func onlyTasksThatPointAtSomethingAreGrounded() {
        func should(_ t: String, named: Bool = false) -> Bool {
            TaskGrounding.shouldGround(task: t, scope: TaskGrounding.scope(of: t, now: Self.now, calendar: Self.calendar),
                                       words: TaskGrounding.words(of: t), named: named)
        }
        #expect(!should("open chrome"))
        #expect(!should("click submit"))
        #expect(!should("search for cats on youtube"))
        #expect(should("open my lab report"))
        #expect(should("continue where I left off"))
        #expect(should("reply to the email from gabi"))
        #expect(should("open the yarn bowl", named: true))
    }

    @Test func peopleAreRecipientsOnlyWhenTheTaskReachesThem() {
        #expect(TaskGrounding.recipientWords(task: "send dhvan the hci notes", people: ["dhvan"]) == ["dhvan"])
        #expect(TaskGrounding.recipientWords(task: "open the doc dhvan shared", people: ["dhvan"]).isEmpty)
        #expect(TaskGrounding.recipientWords(task: "reply to the email from gabi", people: ["gabi"]).isEmpty)
        #expect(TaskGrounding.recipientWords(task: "text mom hi", people: []).contains("mom"))
    }

    @Test func reopeningOwnWorkIsATask() {
        #expect(TaskGrounding.reopensOwnWork("open the last assignment I did", now: Self.now))
        #expect(TaskGrounding.reopensOwnWork("can you pull up my lab report", now: Self.now))
        #expect(TaskGrounding.reopensOwnWork("go back to the onshape model I was on", now: Self.now))
        #expect(!TaskGrounding.reopensOwnWork("open chrome", now: Self.now))
        #expect(!TaskGrounding.reopensOwnWork("play it again", now: Self.now))                 // nothing named to reopen
        #expect(TaskGrounding.reopensOwnWork("continue where I left off", now: Self.now))
        // ⌘Space keeps "open my notes" for the Notes app: only explicit references there.
        #expect(!TaskGrounding.reopensOwnWork("open my notes", now: Self.now, possessive: false))
        #expect(TaskGrounding.reopensOwnWork("open the notes from yesterday", now: Self.now, possessive: false))
        #expect(!TaskGrounding.reopensOwnWork("what is the capital of peru", now: Self.now))
    }

    // MARK: Candidates

    @Test func pagesAreNamedByTheirOwnTitles() {
        #expect(TaskGrounding.cleanTitle("Assignment 02 - Part of group Claude - Google Chrome - Liam") == "Assignment 02")
        #expect(TaskGrounding.cleanTitle("(398) How Shein Built - YouTube - Audio playing - High memory usage - 958 MB - Google Chrome - Liam") == "How Shein Built")
        #expect(TaskGrounding.pageKey("https://www.youtube.com/watch?v=gWotBPtsulo&t=40#x") == "https://www.youtube.com/watch?v=gWotBPtsulo")
        #expect(TaskGrounding.pageKey("https://canvas.olin.edu/courses/1079/assignments/20385?module_item_id=9") == "https://canvas.olin.edu/courses/1079/assignments/20385")
    }

    @Test func lastAssignmentCandidatesAreRealWorkNewestFirst() throws {
        let cs = Self.candidates("open the last assignment I did")
        let names = cs.map(\.name)
        #expect(names.contains("Assignment 02"))
        #expect(names.contains("MTH3199 Mech E Math: Assignment 2 Lab Report"))
        // Never an assistant chat, a search page, a settings page or a conversation.
        #expect(!cs.contains { $0.place == "Claude" || ($0.url ?? "").contains("google.com/search") || ($0.url ?? "").contains("/settings") })
        #expect(!cs.contains { $0.bundleID == "com.apple.MobileSMS" })
        #expect(cs.map(\.id) == (1...cs.count).map { "c\($0)" })
        // Newest first; the long morning on Assignment 02 carries its time.
        #expect(cs.first?.url == "https://canvas.olin.edu/courses/1083/assignments")
        let a2 = try #require(cs.first { $0.name == "Assignment 02" })
        #expect(a2.sessions == 6 && a2.seconds == 6 * 9 * 60)
        #expect(a2.url == "https://canvas.olin.edu/courses/1079/assignments/20385")
    }

    @Test func kindsFindThingsTheTaskNeverNames() {
        let doc = Self.candidates("pull up the doc I was working on")
        #expect(doc.contains { $0.url == "https://docs.google.com/document/d/LAB/edit" })
        let sheet = Self.candidates("open the spreadsheet from this morning")
        #expect(sheet.first?.url == "https://docs.google.com/spreadsheets/d/MECH/edit")
        let video = Self.candidates("open the video I was watching yesterday")
        #expect(video.first?.url == "https://www.youtube.com/watch?v=gWotBPtsulo")
        let model = Self.candidates("go back to the onshape model I was on")
        #expect(model.first?.place == "cad.onshape.com")
    }

    @Test func whereILeftOffIsWorkNotAChat() {
        let cs = Self.candidates("continue where I left off")
        #expect(!cs.isEmpty)
        #expect(!cs.contains { $0.bundleID == "com.apple.MobileSMS" || $0.place == "Claude" })
    }

    // MARK: Jev

    @Test func jevChoosesFromAStructuredList() throws {
        let cs = Self.candidates("open the last assignment I did")
        let (state, questions) = TaskGrounding.request(task: "open the last assignment I did", candidates: cs,
                                                       screen: FrontmostProbe.Info(bundleID: "com.apple.finder", appName: "Finder"), now: Self.now)
        let list = try #require(state["candidates"] as? [[String: Any]])
        #expect(list.count == cs.count)
        #expect(list.first?["last_open"] as? String != nil && list.first?["what_the_user_did"] != nil)
        #expect((state["on_screen_now"] as? [String: Any])?["app"] as? String == "Finder")
        guard case .choice(_, let criteria)? = questions["refers_to"] else { Issue.record("refers_to is a choice"); return }
        #expect(Set(criteria.keys) == Set(cs.map(\.id) + ["none"]))
        let json = String(decoding: try JSONSerialization.data(withJSONObject: state), as: UTF8.self)
        #expect(!json.contains("private summary"))                                          // titles only, never summaries or OCR
    }

    @Test func jevsPickIsTakenOnlyWhenSure() {
        let cs = Self.candidates("open the last assignment I did")
        let a2 = cs.first { $0.name == "Assignment 02" }!
        let sure = JevClient.Answer.choice(choice: a2.id, probabilities: [a2.id: 0.8, "c1": 0.15, "none": 0.05], confidence: 0.8)
        #expect(TaskGrounding.pick(sure, among: cs)?.0.name == "Assignment 02")
        #expect(TaskGrounding.pick(.choice(choice: "none", probabilities: ["none": 0.9], confidence: 0.9), among: cs) == nil)
        #expect(TaskGrounding.pick(.choice(choice: "c1", probabilities: ["c1": 0.3, "c2": 0.29], confidence: 0.3), among: cs) == nil)
        // Without Jev: the newest when the task points back in time.
        #expect(TaskGrounding.localPick(cs, scope: .init(interval: nil, recent: true)) == cs.first)
    }

    @Test func theGroundedThingReadsAsUserContext() {
        let c = Self.candidates("open the last assignment I did").first { $0.name == "Assignment 02" }!
        let d = TaskGrounding.context(.init(task: "t", thing: c, confidence: 0.8, source: "jev", alternatives: []), now: Self.now)
        #expect(d["name"] as? String == "Assignment 02")
        #expect(d["url"] as? String == "https://canvas.olin.edu/courses/1079/assignments/20385")
        #expect(d["the_task_refers_to_this"] as? String == "80% sure")
        #expect(d["id"] == nil)
    }

    @Test func spokenReopenIsATaskNotAnAppOrAnAnswer() {
        func verdict(_ kind: String) -> VoiceDecider.Verdict {
            var v = VoiceDecider.Verdict()
            v.boundary = .init(choice: "complete", probabilities: ["complete": 0.9], confidence: 0.9)
            v.kind = .init(choice: kind, probabilities: [kind: 0.9], confidence: 0.9)
            v.control = .init(choice: "none", probabilities: ["none": 0.9], confidence: 0.9)
            return v
        }
        let head = "open the last assignment I did"
        let n = head.split(separator: " ").count
        let input = VoiceDecider.Input(clause: .init(head: head, following: "", connector: ".", start: 0, end: n, resume: n),
                                       silenceMs: 800, context: VoiceDecider.Context())
        for kind in ["open_app", "answer", "browse_or_search"] {
            guard case .task(let goal, let surface, _, _, _) = VoiceDecider.command(verdict(kind), input: input) else {
                Issue.record("\(kind): reopening past work should run as a task"); continue
            }
            #expect(goal == head && surface == .unsure)
        }
    }

    @Test func sendingAThingIsNotGoingToIt() {
        #expect(TaskGrounding.isCommunication("send dhvan the hci notes"))
        #expect(TaskGrounding.isCommunication("email gabi the lab report"))
        #expect(!TaskGrounding.isCommunication("open the lab report"))
    }
}
