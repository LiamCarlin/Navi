import Foundation
import Testing
@testable import Navi

/// `UserHabits`: screen memory → how this user does things → the planner.
@Suite struct UserHabitsTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func app(_ bundle: String, _ name: String, _ n: Int, daysAgo: Double = 0) -> MemoryStore.AppUsage {
        MemoryStore.AppUsage(bundleID: bundle, appName: name, screens: n, lastSeen: now.addingTimeInterval(-daysAgo * 86_400))
    }

    static func visits(_ url: String, _ n: Int, daysAgo: Double = 0) -> [MemoryStore.SiteVisit] {
        (0..<n).map { i in MemoryStore.SiteVisit(url: url, at: now.addingTimeInterval(-daysAgo * 86_400 - Double(i) * 60)) }
    }

    /// Roughly the profile that motivated this: Outlook app for mail (never Outlook
    /// on the web), a school Canvas on its own domain, Messages + WhatsApp for texts.
    static let profile = UserHabits.buildProfile(
        apps: [app("com.google.Chrome", "Google Chrome", 1536), app("com.microsoft.Outlook", "Microsoft Outlook", 159),
               app("com.apple.MobileSMS", "Messages", 152), app("net.whatsapp.WhatsApp", "\u{200E}WhatsApp", 55, daysAgo: 2),
               app("com.apple.WindowManager", "WindowManager", 40), app("com.apple.Notes", "Notes", 2)],
        visits: visits("https://canvas.olin.edu/courses/1083/assignments/18921?return_to=x", 176)
            + visits("https://babson.instructure.com/courses/7996554/groups", 59, daysAgo: 3)
            + visits("https://docs.google.com/presentation/d/abc/edit?slide=id.p", 40)
            + visits("https://docs.google.com/document/d/xyz/edit", 30, daysAgo: 1)
            + visits("https://mail.google.com/mail/u/0/#inbox", 7, daysAgo: 5)
            + visits("https://www.google.com/search?q=jev", 80)
            + visits("https://accounts.google.com/signin/v2", 20)
            + visits("https://cad.onshape.com/signin?email=me@example.com", 30)
            + visits("https://once.example.com/", 1))

    // MARK: Profile

    @Test func profileKeepsRealAppsAndSites() {
        let p = Self.profile
        #expect(p.apps.map(\.key) == ["com.google.Chrome", "com.microsoft.Outlook", "com.apple.MobileSMS", "net.whatsapp.WhatsApp"])
        #expect(p.apps[3].name == "WhatsApp")                               // the invisible LTR mark is gone
        // Search pages, sign-in pages and one-off visits say nothing about habits.
        #expect(p.sites.map(\.key) == ["canvas.olin.edu", "babson.instructure.com", "docs.google.com/presentation",
                                       "docs.google.com/document", "mail.google.com"])
        #expect(p.sites[0].screens == 176)
    }

    @Test func siteKeysAndCleanURLs() {
        #expect(UserHabits.siteKey(of: "https://www.youtube.com/watch?v=1") == "youtube.com")
        #expect(UserHabits.siteKey(of: "https://docs.google.com/spreadsheets/d/1/edit") == "docs.google.com/spreadsheets")
        #expect(UserHabits.siteKey(of: "https://www.google.com/maps/place/x") == "google.com/maps")
        #expect(UserHabits.siteKey(of: "chrome://inspect") == nil)
        #expect(UserHabits.cleanURL("https://canvas.olin.edu/courses/1/assignments/2?return_to=x#top") == "https://canvas.olin.edu/courses/1/assignments/2")
        #expect(UserHabits.cleanURL("https://www.youtube.com/watch?v=SNJ3&t=40&list=L") == "https://www.youtube.com/watch?v=SNJ3")
        #expect(UserHabits.cleanURL("https://cad.onshape.com/signin?page=1&email=me@example.com") == nil)
        #expect(UserHabits.cleanURL("https://login.microsoftonline.com/common/oauth2") == nil)
        #expect(UserHabits.cleanURL("file:///Users/me/a.pdf") == nil)
        #expect(!UserHabits.isAuthPage("https://github.com/LiamCarlin/Navi"))
    }

    // MARK: Which app for this kind of task

    @Test func personalHostsBelongToTheirWebApp() {
        #expect(UserHabits.skill(forSite: "canvas.olin.edu")?.name == "Canvas")          // by name, not by library host
        #expect(UserHabits.skill(forSite: "babson.instructure.com")?.name == "Canvas")
        #expect(UserHabits.skill(forSite: "docs.google.com/presentation")?.name == "Google Slides")
        #expect(UserHabits.skill(forSite: "olin.edu") == nil)
        let canvas = AppSkills.all.first { $0.name == "Canvas" }!
        let u = UserHabits.usage(of: canvas, in: Self.profile)
        #expect(u.screens == 235 && u.sites.map(\.key) == ["canvas.olin.edu", "babson.instructure.com"])
    }

    @Test func kindTableNamesOnlyRealSkills() {
        for k in UserHabits.kinds {
            for name in k.skills { #expect(AppSkills.all.contains { $0.name == name }, "\(k.kind): no skill named \(name)") }
        }
    }

    @Test func emailGoesWhereTheUserReadsMail() throws {
        let task = "go to my outlook and give me a summary of the emails that i got since yesterday @12"
        let s = try #require(UserHabits.plannerSection(task: task, profile: Self.profile, matches: [], now: Self.now))
        let kinds = try #require(s["apps_for_this_kind_of_task"] as? [[String: Any]])
        let email = try #require(kinds.first { $0["kind"] as? String == "email" })
        let options = try #require(email["options_most_used_first"] as? [[String: Any]])
        #expect(options.map { $0["app"] as? String } == ["Outlook", "Gmail", "Mail", "Outlook Web"])
        #expect(options[0]["type"] as? String == "mac app")
        #expect(options[0]["used"] as? String == "159 screens, last today")
        #expect(options[2]["used"] as? String == "never seen on this user's screen")
        #expect(options[1]["user_sites"] as? [String] == ["mail.google.com"])
        #expect((s["most_used_apps"] as? [String])?.first == "Google Chrome (1536)")
        #expect((s["most_used_sites"] as? [String])?.first == "canvas.olin.edu (176)")
        // Jev's surface question hears the same thing in one line.
        #expect(UserHabits.surfaceHint(task: task, profile: Self.profile)?.hasPrefix("Outlook: native mac app, 159 screens") == true)
        #expect(UserHabits.namedNativeApp(in: task, profile: Self.profile)?.name == "Outlook")
    }

    @Test func kindsWithoutAnySignalAreLeftOut() throws {
        // Nobody here uses a notes app: no "notes" entry rather than four "never"s.
        let s = try #require(UserHabits.plannerSection(task: "make a note about the meeting", profile: Self.profile, matches: [], now: Self.now))
        let kinds = (s["apps_for_this_kind_of_task"] as? [[String: Any]]) ?? []
        #expect(!kinds.contains { $0["kind"] as? String == "notes" })
        #expect(UserHabits.plannerSection(task: "x", profile: .init(), matches: [], now: Self.now) == nil)
    }

    @Test func namedAppMustBeOneTheUserUsesAndNotABrowser() {
        #expect(UserHabits.namedNativeApp(in: "open youtube in chrome", profile: Self.profile) == nil)   // browsers stay browser steps
        #expect(UserHabits.namedNativeApp(in: "write it in notes", profile: Self.profile) == nil)          // 2 screens is not a habit
        #expect(UserHabits.namedNativeApp(in: "search for cats", profile: Self.profile) == nil)
    }

    @Test func tiedAppInferenceFollowsUsage() {
        let installed: Set<String> = ["com.apple.mail", "com.microsoft.Outlook", "com.apple.MobileSMS"]
        func infer(_ task: String, usage: @escaping (AppSkill) -> Int) -> String? {
            AppSkills.inferApp(for: task, frontmostBundleID: "com.google.Chrome", isInstalled: { installed.contains($0) },
                               isRunning: { _ in false }, usage: usage)?.skill.name
        }
        #expect(infer("email Sarah the report") { _ in 0 } == "Mail")                          // no history: Apple's app, as before
        #expect(infer("email Sarah the report") { UserHabits.usage(of: $0, in: Self.profile).app?.screens ?? 0 } == "Outlook")
        // Usage only breaks ties: it never drags a text into Outlook.
        #expect(infer("text mom I'm late") { $0.name == "Outlook" ? 999 : 0 } == "Messages")
    }

    // MARK: Start URLs on the user's own host

    @Test func startURLsMoveToTheUsersHost() {
        let p = Self.profile
        #expect(UserHabits.personalize("https://canvas.instructure.com/calendar", profile: p) == "https://canvas.olin.edu/calendar")
        #expect(UserHabits.personalize("https://canvas.instructure.com/", profile: p) == "https://canvas.olin.edu/")
        // Already one of the user's hosts, or no history for that app: unchanged.
        #expect(UserHabits.personalize("https://babson.instructure.com/courses/1", profile: p) == "https://babson.instructure.com/courses/1")
        #expect(UserHabits.personalize("https://docs.google.com/document/create", profile: p) == "https://docs.google.com/document/create")
        #expect(UserHabits.personalize("https://outlook.office.com/mail/", profile: p) == "https://outlook.office.com/mail/")
        #expect(UserHabits.personalize("https://www.google.com/search?q=x", profile: p) == "https://www.google.com/search?q=x")
    }

    @Test func rivalSitesInOneSkillAreNeverSwapped() {
        let p = UserHabits.buildProfile(apps: [], visits: Self.visits("https://www.ebay.com/itm/1", 50))
        #expect(UserHabits.personalize("https://www.target.com/s?searchTerm=lamp", profile: p) == "https://www.target.com/s?searchTerm=lamp")
        // Subdomains of the same product do move.
        let q = UserHabits.buildProfile(apps: [], visits: Self.visits("https://babson.instructure.com/", 10))
        #expect(UserHabits.personalize("https://canvas.instructure.com/calendar", profile: q) == "https://babson.instructure.com/calendar")
    }

    // MARK: Seen for this task

    @Test func termsAreWhatTheTaskIsAbout() {
        #expect(UserHabits.terms(in: "open the Navi product launch roadmap") == ["navi", "product", "roadmap"])
        #expect(UserHabits.terms(in: "text Bella I'm running late") == ["bella", "running", "late"])
        #expect(UserHabits.terms(in: "go to my outlook and give me a summary of the emails that i got since yesterday @12").isEmpty)
        #expect(UserHabits.terms(in: "what's due on canvas for ORGB 3201") == ["orgb"])
    }

    @Test func matchesCollapseAndSkipAuthAndPreferActivities() {
        func hit(_ source: MemoryStore.Hit.Source, _ bundle: String, _ app: String, _ title: String?, _ url: String?, _ score: Double) -> MemoryStore.Hit {
            MemoryStore.Hit(source: source, id: 1, timestamp: Self.now, endTimestamp: nil, bundleID: bundle, appName: app, windowTitle: title,
                            url: url, snippet: "", thumbnailPath: nil, notePath: nil, score: score)
        }
        let hits = [
            hit(.frame, "com.google.Chrome", "Google Chrome", "Navi Product Launch Roadmap - Google Slides", "https://docs.google.com/presentation/d/1/edit?slide=a", 9),
            hit(.frame, "com.google.Chrome", "Google Chrome", "Navi Product Launch Roadmap - Google Slides", "https://docs.google.com/presentation/d/1/edit?slide=b", 8),
            hit(.frame, "com.google.Chrome", "Google Chrome", "Sign in", "https://accounts.google.com/signin", 20),
            hit(.frame, "com.apple.WindowManager", "WindowManager", "Roadmap", nil, 30),
            hit(.session, "com.google.Chrome", "Google Chrome", "Edited the launch roadmap slides", nil, 2),
            hit(.frame, "com.anthropic.claudefordesktop", "Claude", "Launch roadmap ideas", nil, 40),       // talked about, not done there
            hit(.frame, "com.apple.MobileSMS", "Messages", "Julian Shah", nil, 50),
        ]
        let m = UserHabits.matches(from: hits, terms: ["roadmap"])
        #expect(m.count == 3)
        // Title/URL relevance first, then activities before screens.
        #expect(m[0].isActivity && m[0].title == "Edited the launch roadmap slides" && m[0].relevance == 1)
        #expect(m[1].url == "https://docs.google.com/presentation/d/1/edit" && !m[1].isActivity)
        #expect(m[2].title == "Julian Shah" && m[2].relevance == 0)
        #expect(!m.contains { $0.app == "Claude" || $0.app == "WindowManager" })
    }

    @Test func storeFeedsTheProfileAndMatches() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("navi-habits-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MemoryStore(directory: dir)
        let now = Date()
        for i in 0..<5 {
            try store.insertFrame(FrameRecord(timestamp: now.addingTimeInterval(Double(-i * 60)), bundleID: "com.apple.MobileSMS", appName: "Messages",
                                              windowTitle: "Bella Rossi", url: nil, ocrText: "Bella Rossi: see you at practice"))
            try store.insertFrame(FrameRecord(timestamp: now.addingTimeInterval(Double(-i * 60 - 30)), bundleID: "com.google.Chrome", appName: "Google Chrome",
                                              windowTitle: "Assignments", url: "https://canvas.olin.edu/courses/1/assignments?x=1", ocrText: "ORGB 3201 case discussion due"))
        }
        // Older than the window: ignored.
        try store.insertFrame(FrameRecord(timestamp: now.addingTimeInterval(-40 * 86_400), bundleID: "com.apple.mail", appName: "Mail",
                                          windowTitle: "Inbox", url: nil, ocrText: "old"))
        let habits = UserHabits(store: store)
        let p = habits.profile(now: now)
        #expect(Set(p.apps.map(\.key)) == ["com.apple.MobileSMS", "com.google.Chrome"])
        #expect(p.sites.map(\.key) == ["canvas.olin.edu"])
        let m = habits.matches(for: "text bella that I'm on my way", now: now)
        #expect(m.map(\.title) == ["Bella Rossi"])
        let s = try #require(habits.plannerSection(task: "text bella that I'm on my way", now: now))
        let seen = try #require(s["seen_for_this_task"] as? [[String: Any]])
        #expect(seen.first?["app"] as? String == "Messages")
        #expect(UserHabits.personalize("https://canvas.instructure.com/calendar", profile: p) == "https://canvas.olin.edu/calendar")
    }

    @Test func plannerStateCarriesHabitsOnlyWhenGiven() {
        let front = FrontmostProbe.Info(bundleID: nil, appName: nil)
        #expect(TaskPlanner.stateJSON(task: "x", frontmost: front)["user_habits"] == nil)
        #expect(TaskPlanner.stateJSON(task: "x", frontmost: front, habits: ["source": "s"])["user_habits"] != nil)
        #expect(TaskPlanner.systemPrompt.contains("user_habits"))
    }
}
