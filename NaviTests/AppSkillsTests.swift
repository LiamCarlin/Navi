import Testing
import Foundation
import CoreGraphics
@testable import Navi

/// App playbooks, the experience store and the driver changes that carry them:
/// what Jev is told about the app it is driving. No network, no live AX.
struct AppSkillsTests {

    // MARK: Library integrity

    @Test func everySkillIsWellFormed() throws {
        var seenBundles = Set<String>(), seenHosts = Set<String>(), seenNames = Set<String>()
        for s in AppSkills.all {
            #expect(!s.name.isEmpty)
            #expect(seenNames.insert(s.name).inserted, "duplicate skill name \(s.name)")
            #expect(!s.bundleIDs.isEmpty || !s.hosts.isEmpty, "\(s.name) has neither bundle ids nor hosts")
            #expect(!s.howItWorks.isEmpty, "\(s.name) has no how_it_works")
            for b in s.bundleIDs { #expect(seenBundles.insert(b).inserted, "bundle \(b) listed twice") }
            for h in s.hosts { #expect(seenHosts.insert(h).inserted, "host \(h) listed twice") }
            for (combo, meaning) in s.shortcuts {
                #expect(!meaning.isEmpty)
                #expect(throws: Never.self, "\(s.name): shortcut \(combo) must parse") { try KeyCombo.parse(combo) }
            }
            for r in s.recipes {
                #expect(!r.goal.isEmpty && !r.steps.isEmpty, "\(s.name): recipe \(r.goal) is empty")
                #expect(!r.keywords.isEmpty, "\(s.name): recipe \(r.goal) has no keywords")
                #expect(r.keywords.allSatisfy { $0 == $0.lowercased() }, "\(s.name): keywords must be lower-case")
            }
            for (_, url) in s.deepLinks { #expect(url.hasPrefix("https://"), "\(s.name): deep link \(url)") }
            for t in s.triggers + s.weakTriggers + s.aliases { #expect(t == t.lowercased() && !t.isEmpty, "\(s.name): '\(t)' must be lower-case") }
            for h in s.hosts { #expect(!h.hasPrefix("http") && !h.hasSuffix("/") && h.contains("."), "\(s.name): host entry '\(h)'") }
            if let search = s.deepLinks["search"] { #expect(search.hasSuffix("=") || search.hasSuffix("/"), "\(s.name): search link must end in = or /") }
        }
        #expect(AppSkills.native.count >= 60 && AppSkills.web.count >= 50, "library shrank: \(AppSkills.native.count) native, \(AppSkills.web.count) web")
        // The apps the failed runs were in are all covered.
        for b in ["com.apple.Notes", "com.apple.MobileSMS", "com.apple.calculator", "com.apple.iCal", "com.microsoft.Outlook", "com.apple.finder"] {
            #expect(AppSkills.skill(bundleID: b) != nil, "no skill for \(b)")
        }
        for u in ["https://drive.google.com/drive/shared-with-me", "https://docs.google.com/document/d/1/edit", "https://mail.google.com/mail/u/0/#inbox"] {
            #expect(AppSkills.skill(url: u) != nil, "no web skill for \(u)")
        }
    }

    @Test func lookupByBundleNameAndURL() {
        #expect(AppSkills.skill(bundleID: "com.apple.Notes")?.name == "Notes")
        #expect(AppSkills.skill(bundleID: "com.example.unknown") == nil)
        #expect(AppSkills.skill(bundleID: nil) == nil)
        #expect(AppSkills.skill(appName: "messages")?.name == "Messages")
        #expect(AppSkills.skill(appName: "Calculator.app")?.name == "Calculator")
        // Longest host suffix wins; subdomains match; unknown hosts don't.
        #expect(AppSkills.skill(url: "https://docs.google.com/document/create")?.name == "Google Docs")
        #expect(AppSkills.skill(url: "https://www.google.com/search?q=x")?.name == "Google Search")
        #expect(AppSkills.skill(url: "https://outlook.office.com/calendar/")?.name == "Outlook Web")
        #expect(AppSkills.skill(url: "https://example.com/") == nil)
        #expect(AppSkills.skill(url: "not a url") == nil)
        // A web app open in a browser beats the browser's own skill; a native app keeps its skill.
        #expect(AppSkills.skill(bundleID: "com.google.Chrome", url: "https://drive.google.com/drive/my-drive")?.name == "Google Drive")
        #expect(AppSkills.skill(bundleID: "com.google.Chrome", url: "https://example.com/")?.name == "Google Chrome")
        #expect(AppSkills.skill(bundleID: "com.apple.Notes", url: "https://drive.google.com/")?.name == "Notes")
    }

    // MARK: Which app a task means (voice: nothing named)

    static let installed: Set<String> = ["com.apple.MobileSMS", "com.apple.mail", "com.apple.Notes", "com.apple.reminders", "com.apple.iCal", "com.apple.Music",
                                         "com.spotify.client", "com.apple.finder", "com.apple.calculator", "com.apple.clock", "com.apple.Maps", "us.zoom.xos",
                                         "com.tinyspeck.slackmacgap", "com.microsoft.Outlook", "com.apple.FaceTime", "com.apple.systempreferences", "com.google.Chrome",
                                         "com.apple.PhotoBooth", "com.apple.Photos", "com.apple.weather", "com.apple.Dictionary"]
    static func infer(_ task: String, front: String? = "com.google.Chrome", running: Set<String> = []) -> String? {
        AppSkills.inferApp(for: task, frontmostBundleID: front, isInstalled: { installed.contains($0) }, isRunning: { running.contains($0) })?.skill.name
    }

    @Test func spokenTasksImplyTheRightApp() {
        #expect(Self.infer("text mom I'm running late") == "Messages")
        #expect(Self.infer("tell Sam I'll be there at 6") == "Messages")
        #expect(Self.infer("email Sarah the report") == "Mail")
        #expect(Self.infer("email Sarah the report", running: ["com.microsoft.Outlook"]) == "Outlook")       // the running client wins a tie
        #expect(Self.infer("schedule a dentist appointment", running: ["com.microsoft.Outlook"]) == "Outlook")
        #expect(Self.infer("remind me to call the dentist at 3") == "Reminders")
        #expect(Self.infer("add milk to my grocery list") == "Reminders")
        #expect(Self.infer("jot down that the meeting moved to Friday") == "Notes")
        #expect(Self.infer("schedule a dentist appointment for Tuesday at 10") == "Calendar")
        #expect(Self.infer("join my meeting") == "zoom.us")
        #expect(Self.infer("play some jazz") == "Music")                                                      // a tie goes to Apple's app…
        #expect(Self.infer("play some jazz", running: ["com.spotify.client"]) == "Spotify")                   // …unless the alternative is running
        #expect(Self.infer("put on my liked songs", running: ["com.spotify.client"]) == "Spotify")
        #expect(Self.infer("play the video") == nil)                                                          // Chrome in front claims "play"
        #expect(Self.infer("play the video", front: "com.apple.Notes") == "Google Chrome")                    // a video is a browser thing
        #expect(Self.infer("set a timer for 10 minutes") == "Clock")
        #expect(Self.infer("how long to drive to Northeastern") == "Maps")
        #expect(Self.infer("what's 12 times 34") == "Calculator")
        #expect(Self.infer("open my downloads folder") == "Finder")
        #expect(Self.infer("turn on dark mode") == "System Settings")
        #expect(Self.infer("call mom") == "FaceTime")
        #expect(Self.infer("rename the file and call it Report") == "Finder")                                // "call it" is a rename, not a call
        #expect(Self.infer("take a picture of me") == "Photo Booth")
        #expect(Self.infer("find photos from last summer") == "Photos")
        #expect(Self.infer("define ubiquitous") == "Dictionary")
        #expect(Self.infer("in slack tell John the build is green") == "Slack")                             // named app wins over "tell"
        #expect(Self.infer("zoom in on the map", front: "com.apple.Maps") == nil)                           // "zoom" needs an opener to name the app
        #expect(Self.infer("click the button") == nil)
        #expect(Self.infer("make it bigger") == nil)
        #expect(Self.infer("text mom I'm late", front: "com.apple.MobileSMS") == "Messages")               // caller drops it when already in front
    }

    @Test func mentionsNeedAnOpenerForCommonWords() {
        #expect(AppSkills.mentioned(in: "open notes")?.name == "Notes")
        #expect(AppSkills.mentioned(in: "in the notes app write hello")?.name == "Notes")
        #expect(AppSkills.mentioned(in: "note that the meeting moved") == nil)
        #expect(AppSkills.mentioned(in: "play some music") == nil)
        #expect(AppSkills.mentioned(in: "switch to music")?.name == "Music")
        #expect(AppSkills.mentioned(in: "send it on slack")?.name == "Slack")
        #expect(AppSkills.mentioned(in: "look it up on youtube")?.name == "YouTube")
        #expect(AppSkills.mentioned(in: "go to google docs")?.name == "Google Docs")                  // longest alias beats "google"
        #expect(AppSkills.mentioned(in: "google the weather")?.name == "Google Search")
        #expect(AppSkills.mentioned(in: "use vscode")?.name == "Visual Studio Code")
        #expect(AppSkills.mentioned(in: "In Messages: reply ok")?.name == "Messages")
    }

    @Test func deepLinksCarryTheSpokenQuery() {
        #expect(AppSkills.startURL(for: "play lofi beats on youtube") == "https://www.youtube.com/results?search_query=lofi%20beats")
        #expect(AppSkills.startURL(for: "search amazon for a usb-c cable") == "https://www.amazon.com/s?k=usb-c%20cable")
        #expect(AppSkills.startURL(for: "open gmail") == "https://mail.google.com/mail/u/0/#inbox")
        #expect(AppSkills.startURL(for: "go to google drive shared with me") == "https://drive.google.com/drive/shared-with-me")
        #expect(AppSkills.startURL(for: "google the weather in boston") == "https://www.google.com/search?q=weather%20in%20boston")
        #expect(AppSkills.startURL(for: "look up apollo 11 on wikipedia") == "https://en.wikipedia.org/w/index.php?search=apollo%2011")
        #expect(AppSkills.startURL(for: "pull up netflix") == "https://www.netflix.com/browse")
        #expect(AppSkills.startURL(for: "text mom I'm late") == nil)                                   // no web app named
        #expect(AppSkills.startURL(for: "open notes") == nil)                                          // native app named
        // Planned browser steps and the planner-less path both use it.
        #expect(TaskSurface.startURL(task: "watch the new trailer on youtube", frontmost: FrontmostProbe.Info(bundleID: nil, appName: nil)) == "https://www.youtube.com/results?search_query=new%20trailer")
        var step = TaskPlanner.Step(surface: .browser, goal: "on youtube play lofi beats")
        #expect(TaskPlanner.startURL(for: step, frontmost: FrontmostProbe.Info(bundleID: nil, appName: nil)) == "https://www.youtube.com/results?search_query=lofi%20beats")
        step.url = "https://example.com/"
        #expect(TaskPlanner.startURL(for: step, frontmost: FrontmostProbe.Info(bundleID: nil, appName: nil)) == "https://example.com/")   // an explicit URL still wins
    }

    @Test func hostEntriesMayCarryPaths() {
        #expect(AppSkills.skill(url: "https://docs.google.com/spreadsheets/d/1/edit")?.name == "Google Sheets")
        #expect(AppSkills.skill(url: "https://docs.google.com/presentation/d/1/edit")?.name == "Google Slides")
        #expect(AppSkills.skill(url: "https://docs.google.com/document/d/1/edit")?.name == "Google Docs")
        #expect(AppSkills.skill(url: "https://docs.google.com/forms/d/e/1/viewform")?.name == "Google Forms")
        #expect(AppSkills.skill(url: "https://www.google.com/maps/dir/a/b")?.name == "Google Maps")
        #expect(AppSkills.skill(url: "https://www.google.com/travel/flights?hl=en")?.name == "Google Flights")
        #expect(AppSkills.skill(url: "https://www.google.com/search?q=x")?.name == "Google Search")
        #expect(AppSkills.skill(url: "https://canvas.northeastern.instructure.com/courses/1")?.name == "Canvas")
        #expect(AppSkills.skill(url: "https://www.target.com/s?searchTerm=lamp")?.name == "Shopping sites")
        #expect(AppSkills.hostEntry("google.com/maps", matchesHost: "www.google.com", path: "/maps/place/x"))
        #expect(!AppSkills.hostEntry("google.com/maps", matchesHost: "www.google.com", path: "/search"))
        #expect(AppSkills.hostEntry("google.com", matchesHost: "www.google.com", path: "/anything"))
    }

    // MARK: Playbook selection

    @Test func playbookKeepsOnlyMatchingRecipes() throws {
        let notes = try #require(AppSkills.skill(bundleID: "com.apple.Notes"))
        let book = AppSkills.playbook(for: notes, goal: "make hello the title of the note")
        #expect(book["app"] as? String == "Notes")
        let recipes = try #require(book["recipes"] as? [[String: Any]])
        #expect(recipes.count <= AppSkills.maxRecipes)
        #expect(recipes.first?["goal"] as? String == "title a note / write something in a note")   // most keyword hits first
        #expect(book["done_when"] != nil && book["avoid"] != nil && book["shortcuts"] != nil)
        // No recipe matches → no recipes key, the rest stays.
        let none = AppSkills.playbook(for: notes, goal: "zzz qqq")
        #expect(none["recipes"] == nil && none["how_it_works"] != nil)
        // Multi-word keywords match as phrases.
        let messages = try #require(AppSkills.skill(bundleID: "com.apple.MobileSMS"))
        let read = AppSkills.recipes(for: messages, goal: "what did Mikey say in his last message")
        #expect(read.contains { $0.goal.hasPrefix("open a conversation") })
        // JSON-serialisable (it goes straight into the Jev state).
        #expect(JSONSerialization.isValidJSONObject(book))
    }

    @Test func calculatorRecipeMatchesArithmetic() throws {
        let calc = try #require(AppSkills.skill(bundleID: "com.apple.calculator"))
        #expect(!AppSkills.recipes(for: calc, goal: "compute 12 times 34").isEmpty)
        #expect(!AppSkills.recipes(for: calc, goal: "what's 7 plus 9").isEmpty)
    }

    // MARK: KEY head

    @Test func keyCombosMergeAppShortcuts() throws {
        let outlook = try #require(AppSkills.skill(bundleID: "com.microsoft.Outlook"))
        let combos = AppSkills.keyCombos(for: outlook)
        let names = combos.map(\.0)
        // Generic combos stay, app-specific ones are appended once, generic ones are re-described.
        #expect(names.first == "Return")
        #expect(names.contains("cmd+2"))
        #expect(Set(names).count == names.count)
        #expect(combos.first { $0.0 == "cmd+n" }?.1.contains("Outlook") == true)
        #expect(combos.first { $0.0 == "Escape" }?.1 == JevDriver.keyCombos.first { $0.0 == "Escape" }?.1)
        #expect(AppSkills.keyCombos(for: nil).map(\.0) == JevDriver.keyCombos.map(\.0))
    }

    @Test func driverOffersAppShortcutsAndCarriesPlaybook() throws {
        let outlook = try #require(AppSkills.skill(bundleID: "com.microsoft.Outlook"))
        var input = JevDriverTests.input()
        input.playbook = AppSkills.playbook(for: outlook, goal: "create a calendar event")
        input.experience = ["create an event → Press ⌘2 · Press ⌘N · Type ‘…’ into ‘Subject’ · Press Return"]
        input.keyCombos = AppSkills.keyCombos(for: outlook)
        input.actionsTaken = 2
        let req = JevDriver.request(for: input)
        #expect(req.heads["key_target"]?.contains("cmd+2") == true)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(JevDriver.formatState(input).utf8)) as? [String: Any])
        #expect((json["playbook"] as? [String: Any])?["app"] as? String == "Outlook")
        #expect((json["experience"] as? [String])?.count == 1)
        #expect((json["progress"] as? [String: Any])?["actions_taken"] as? Int == 2)
        #expect((json["progress"] as? [String: Any])?["note"] == nil)
        input.doneRejected = true
        let again = try #require(try JSONSerialization.jsonObject(with: Data(JevDriver.formatState(input).utf8)) as? [String: Any])
        #expect((again["progress"] as? [String: Any])?["note"] != nil)
        // The coach can name an app-specific combo.
        #expect(JevDriver.coachAction(operation: "KEY", target: "cmd+2", request: req) == .key("cmd+2"))
        #expect(JevDriver.coachAction(operation: "KEY", target: "not a key", request: req) == nil)
    }

    // MARK: Premature DONE

    @Test func prematureDoneIsReaskedOnce() {
        let input = JevDriverTests.input()
        let req = JevDriver.request(for: input)
        let done = JevDriverTests.verdict(op: "DONE", confidence: 0.9, request: req)
        // Effect goal, nothing done yet, not certain → look again.
        #expect(JevDriver.decide(done, request: req, threshold: 0.5, effectGoal: true, actionsTaken: 0) == .prematureDone(reason: "Jev chose DONE (90%) before any action"))
        // Already rejected once → final. Something was done → final. Lookup → final. Very sure → final.
        #expect(JevDriver.decide(done, request: req, threshold: 0.5, effectGoal: true, actionsTaken: 0, doneRejected: true) == .finish(reason: "Jev chose DONE (90%)"))
        #expect(JevDriver.decide(done, request: req, threshold: 0.5, effectGoal: true, actionsTaken: 1) == .finish(reason: "Jev chose DONE (90%)"))
        #expect(JevDriver.decide(done, request: req, threshold: 0.5, effectGoal: false, actionsTaken: 0) == .finish(reason: "Jev chose DONE (90%)"))
        let sure = JevDriverTests.verdict(op: "DONE", confidence: 0.99, request: req)
        #expect(JevDriver.decide(sure, request: req, threshold: 0.5, effectGoal: true, actionsTaken: 0) == .finish(reason: "Jev chose DONE (99%)"))
        // task_complete noul follows the same rule.
        let complete = JevDriverTests.verdict(op: "CLICK", request: req, target: ("click_target", "2"), taskComplete: 0.9)
        #expect(JevDriver.decide(complete, request: req, threshold: 0.5, effectGoal: true, actionsTaken: 0) == .prematureDone(reason: "Jev sees the goal satisfied (90%) before any action"))
        #expect(JevDriver.decide(complete, request: req, threshold: 0.5, effectGoal: true, actionsTaken: 3) == .finish(reason: "Jev sees the goal satisfied (90%)"))
        // Default arguments keep the old behaviour.
        #expect(JevDriver.decide(done, request: req, threshold: 0.5) == .finish(reason: "Jev chose DONE (90%)"))
    }

    // MARK: Experience store

    @Test func experienceRecordsRecallsAndDedupes() {
        let store = AgentExperience(fileURL: nil)
        #expect(store.recall(bundleID: "com.apple.Notes", goal: "create a note").isEmpty)
        store.record(bundleID: "com.apple.Notes", appName: "Notes", goal: "create a new note", actions: ["Press ⌘N"], at: Date(timeIntervalSince1970: 1))
        store.record(bundleID: "com.apple.Notes", appName: "Notes", goal: "title the note hello", actions: ["Type ‘…’ into the text area", "Press Return"], at: Date(timeIntervalSince1970: 2))
        store.record(bundleID: "com.apple.MobileSMS", appName: "Messages", goal: "send a note to Sam", actions: ["Press ⌘N"], at: Date(timeIntervalSince1970: 3))
        let hits = store.recall(bundleID: "com.apple.Notes", goal: "please create a note for me")
        #expect(hits == ["create a new note → Press ⌘N"])                        // other app never leaks in
        #expect(store.recall(bundleID: "com.apple.Notes", goal: "delete everything").isEmpty)
        // Same app + same goal words replaces the old entry.
        store.record(bundleID: "com.apple.Notes", appName: "Notes", goal: "Create a new note!", actions: ["Press ⌘N", "Wait"], at: Date(timeIntervalSince1970: 4))
        #expect(store.count == 3)
        #expect(store.recall(bundleID: "com.apple.Notes", goal: "create a note") == ["Create a new note! → Press ⌘N · Wait"])
        // Empty inputs are ignored.
        store.record(bundleID: nil, appName: nil, goal: "x", actions: ["a"])
        store.record(bundleID: "b", appName: nil, goal: "  ", actions: ["a"])
        store.record(bundleID: "b", appName: nil, goal: "x", actions: [])
        #expect(store.count == 3)
        #expect(store.recall(bundleID: nil, goal: "create").isEmpty)
    }

    @Test func experiencePersistsToDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("navi-exp-\(UUID().uuidString)/agent-experience.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let a = AgentExperience(fileURL: url)
        a.record(bundleID: "com.apple.iCal", appName: "Calendar", goal: "schedule dinner wednesday", actions: ["Press ⌘N", "Type ‘…’ into ‘Title’"])
        let b = AgentExperience(fileURL: url)
        #expect(b.count == 1)
        #expect(b.recall(bundleID: "com.apple.iCal", goal: "schedule lunch wednesday").first?.hasPrefix("schedule dinner wednesday →") == true)
    }

    @Test func experienceCapsSize() {
        let store = AgentExperience(fileURL: nil)
        for i in 0..<(AgentExperience.maxEntries + 20) {
            store.record(bundleID: "b", appName: nil, goal: "goal number \(i) unique\(i)", actions: (0..<30).map { "step \($0)" })
        }
        #expect(store.count == AgentExperience.maxEntries)
        let line = store.recall(bundleID: "b", goal: "goal number 5 unique5").first ?? ""
        #expect(line.components(separatedBy: " · ").count == AgentExperience.maxActionsPerEntry)
    }

    // MARK: Inferred labels

    @Test func unlabelledElementsAreNamedByTheirText() {
        let cell = AXElement(id: "e1", role: "AXCell", label: "", frame: CGRect(x: 0, y: 100, width: 300, height: 60))
        let texts: [(String, CGRect)] = [
            ("9:12 PM", CGRect(x: 240, y: 104, width: 50, height: 14)),
            ("Mikey Ku", CGRect(x: 10, y: 104, width: 100, height: 14)),
            ("Istg if I have to do mech e math again", CGRect(x: 10, y: 130, width: 260, height: 14)),
            ("Elsewhere", CGRect(x: 10, y: 400, width: 100, height: 14)),
            ("Huge", CGRect(x: 0, y: 0, width: 1000, height: 1000)),            // larger than the cell: not its text
        ]
        #expect(AXSnapshot.inferredLabel(for: cell, texts: texts, identifier: "", roleDescription: "cell") == "Mikey Ku · 9:12 PM")
        // Identifier when there is no text; role description last; nothing for useless ones.
        let button = AXElement(id: "e2", role: "AXButton", label: "", frame: CGRect(x: 0, y: 0, width: 30, height: 30))
        #expect(AXSnapshot.inferredLabel(for: button, texts: [], identifier: "newNoteButton", roleDescription: "button") == "new note button")
        #expect(AXSnapshot.inferredLabel(for: button, texts: [], identifier: "compose_message", roleDescription: "button") == "compose message")
        #expect(AXSnapshot.inferredLabel(for: button, texts: [], identifier: "_NS:123", roleDescription: "toolbar button") == "toolbar button")
        #expect(AXSnapshot.inferredLabel(for: button, texts: [], identifier: "", roleDescription: "button") == "")
    }

    // MARK: App name matching

    @Test func dictatedAppNamesResolve() {
        let apps = ["Calculator", "Calendar", "Safari", "Google Chrome", "Messages", "Notes", "System Settings", "Music"]
        #expect(AgentCustomTools.bestAppMatch(names: apps, wanted: "Calculator") == 0)
        #expect(AgentCustomTools.bestAppMatch(names: apps, wanted: "calculatorcul app") == 0)    // dictation tail
        #expect(AgentCustomTools.bestAppMatch(names: apps, wanted: "the calculator") == 0)
        #expect(AgentCustomTools.bestAppMatch(names: apps, wanted: "safar") == 2)
        #expect(AgentCustomTools.bestAppMatch(names: apps, wanted: "chrome") == 3)
        #expect(AgentCustomTools.bestAppMatch(names: apps, wanted: "Mesages") == 4)             // one typo
        #expect(AgentCustomTools.bestAppMatch(names: apps, wanted: "settings") == 6)
        #expect(AgentCustomTools.bestAppMatch(names: apps, wanted: "Xcode") == nil)
        #expect(AgentCustomTools.bestAppMatch(names: apps, wanted: "a") == nil)
        #expect(AgentCustomTools.editDistance("kitten", "sitting") == 3)
    }

    // MARK: Tab policy

    @Test func browserTabPolicy() {
        #expect(UltrafastBridge.tabPolicy(task: "make a new google doc", background: false, revealWhenDone: true) == "keep")
        #expect(UltrafastBridge.tabPolicy(task: "make a new google doc", background: true, revealWhenDone: true) == "reveal")
        #expect(UltrafastBridge.tabPolicy(task: "make a new google doc", background: true, revealWhenDone: false) == "keep")
        #expect(UltrafastBridge.tabPolicy(task: "find the score of the patriots game", background: true, revealWhenDone: true) == "close")
        #expect(UltrafastBridge.tabPolicy(task: "find the score of the patriots game", background: false, revealWhenDone: true) == "keep")
    }

    // MARK: Planner / helper plumbing

    @Test func plannerReferenceAndWebJSON() throws {
        let ref = AppSkills.plannerReference()
        #expect((ref["known_apps"] as? [String])?.contains("Messages") == true)
        #expect((ref["deep_links"] as? [String: String])?["Google Drive: shared with me"] == "https://drive.google.com/drive/shared-with-me")
        let state = TaskPlanner.stateJSON(task: "x", frontmost: FrontmostProbe.Info(bundleID: nil, appName: nil))
        #expect(state["reference"] != nil)
        let web = try #require(try JSONSerialization.jsonObject(with: Data(AppSkills.webPlaybooksJSON().utf8)) as? [[String: Any]])
        #expect(web.allSatisfy { !($0["hosts"] as? [String] ?? []).isEmpty })
        #expect(web.contains { $0["app"] as? String == "Google Drive" })
        let field = AXElement(id: "e1", role: "AXTextArea", label: "", frame: .zero)
        let ctx = FieldText.context(goal: "g", field: field, pageTitle: nil, pageText: "", recentActions: [], hints: ["first line is the title"])
        #expect(ctx["field_hints"] as? [String] == ["first line is the title"])
        #expect(FieldText.context(goal: "g", field: field, pageTitle: nil, pageText: "", recentActions: [])["field_hints"] == nil)
    }
}
