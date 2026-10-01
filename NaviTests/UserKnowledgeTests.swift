import Foundation
import Testing
@testable import Navi

/// `UserKnowledge`: digested sessions → the user's people, projects and
/// documents, where each lives → the planner, Jev's state and start URLs.
@Suite struct UserKnowledgeTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let doc = "https://docs.google.com/document/d/1AfP/edit?tab=t.0"

    static func session(_ bundle: String, _ app: String, url: String? = nil, daysAgo: Double = 0, minute: Double = 0,
                        _ entities: [(String, String)]) -> SessionRecord {
        let start = now.addingTimeInterval(-daysAgo * 86_400 + minute * 60)
        return SessionRecord(start: start, end: start.addingTimeInterval(60), bundleID: bundle, appName: app, url: url,
                             title: "", summary: "private summary text", topics: [],
                             entities: entities.map { EntityRef(name: $0.0, type: $0.1) })
    }

    /// A week that looks like the one that motivated this: Bella texted in Messages,
    /// Dhvan in WhatsApp, a shared HCI doc, an assignment that starts on Canvas and
    /// goes on in MATLAB, and the user's own name on every screen.
    static let sessions: [SessionRecord] = {
        var s: [SessionRecord] = []
        for d in 0..<4 {
            let day = Double(d)
            s.append(session("com.apple.MobileSMS", "Messages", daysAgo: day, [("Bella Chen", "person"), ("Liam Carlin", "person")]))
            s.append(session("com.apple.MobileSMS", "Messages", daysAgo: day, minute: 5, [("Bella", "person")]))
            s.append(session("net.whatsapp.WhatsApp", "\u{200E}WhatsApp", daysAgo: day, minute: 10, [("Dhvan Shah", "person")]))
            s.append(session("com.google.Chrome", "Google Chrome", url: doc, daysAgo: day, minute: 20,
                             [("HCI Team Notes", "file"), ("Dhvan Shah", "person"), ("Suraj Sajjala", "person")]))
            s.append(session("com.google.Chrome", "Google Chrome", url: "https://canvas.olin.edu/courses/1079/assignments/20385?module_item_id=9",
                             daysAgo: day, minute: 30, [("MTH3199-Assignment-2", "project")]))
            s.append(session("com.mathworks.matlab", "MATLAB", daysAgo: day, minute: 40, [("MTH3199-Assignment-2", "project")]))
            s.append(session("com.anthropic.claudefordesktop", "Claude", daysAgo: day, minute: 50, [("MTH3199-Assignment-2", "project")]))
        }
        s.append(session("com.google.Chrome", "Google Chrome", url: "https://github.com/me/MTH3199-Assignment-2/settings/access",
                         daysAgo: 1, minute: 45, [("MTH3199-Assignment-2", "project")]))
        s.append(session("com.google.Chrome", "Google Chrome", url: "https://docs.google.com/document/d/LS/edit",
                         [("Executive Summary: Lead Screw", "file")]))
        s.append(session("com.google.Chrome", "Google Chrome", url: "https://docs.google.com/document/d/LS/edit", daysAgo: 1,
                         [("Lead Screw Executive Summary", "file")]))
        s.append(session("com.apple.MobileSMS", "Messages", [("someone@example.com", "person"), ("/Applications/Navi.app", "file")]))
        s.append(session("com.apple.MobileSMS", "Messages", daysAgo: 1, [("someone@example.com", "person"), ("/Applications/Navi.app", "file")]))
        s.append(session("com.apple.MobileSMS", "Messages", [("Once Only", "person")]))
        s.append(session("net.whatsapp.WhatsApp", "WhatsApp", minute: 60, [("Dhvan Shah", "person")]))
        return s
    }()

    static let things = UserKnowledge.build(sessions: sessions, selfNames: ["Liam Carlin"])

    static func thing(_ name: String) -> UserKnowledge.Thing? { things.first { $0.name == name } }

    // MARK: Building

    @Test func keepsPeopleProjectsAndDocumentsNotTheUserOrJunk() {
        let names = Set(Self.things.map(\.name))
        #expect(names.contains("Bella Chen"))
        #expect(names.contains("HCI Team Notes"))
        #expect(names.contains("MTH3199-Assignment-2"))
        #expect(!names.contains("Liam Carlin"))                 // the user themself
        #expect(!names.contains("Bella"))                       // folded into Bella Chen
        #expect(!names.contains("Once Only"))                   // one session is not knowledge
        #expect(!names.contains { $0.contains("@") || $0.hasPrefix("/") })
        #expect(Self.thing("HCI Team Notes")?.type == "document")
    }

    @Test func firstNameFoldsIntoTheOnlyFullName() throws {
        let bella = try #require(Self.thing("Bella Chen"))
        #expect(bella.sessions == 8)
        #expect(bella.places.map(\.key) == ["com.apple.MobileSMS"])
    }

    @Test func wordOrderIsNotIdentity() {
        let docs = Self.things.filter { $0.tokens.contains("screw") }
        #expect(docs.count == 1)
        #expect(docs.first?.sessions == 2)
    }

    @Test func placesAreWhereThingsLiveNotAssistantsOrSetupPages() throws {
        let hw = try #require(Self.thing("MTH3199-Assignment-2"))
        #expect(!hw.places.contains { $0.app == "Claude" })                                    // assistant chats never count
        #expect(hw.places.first { $0.key == "canvas.olin.edu" }?.url == "https://canvas.olin.edu/courses/1079/assignments/20385")
        #expect(!hw.places.contains { $0.key == "github.com" })                                // once, on a settings page: noise
        #expect(hw.workflow == ["canvas.olin.edu", "MATLAB"])                                  // Canvas first, then MATLAB
    }

    @Test func peopleAndDocumentsSeenTogetherAreRelated() throws {
        #expect(Self.thing("HCI Team Notes")?.related.sorted() == ["Dhvan Shah", "Suraj Sajjala"])
        #expect(try #require(Self.thing("Dhvan Shah")).related == ["HCI Team Notes"])
        #expect(Self.thing("Bella Chen")?.related.isEmpty == true)
    }

    @Test func workflowOrdersPlacesByWhenTheyComeUpInADay() {
        let places = ["a", "b", "c"].map { UserKnowledge.Place(key: $0, app: $0.uppercased(), isWeb: false, url: nil, sessions: 3) }
        let order = UserKnowledge.workflow(dayOrder: ["d1": ["c", "a", "b"], "d2": ["c", "b", "a"], "d3": ["a", "c", "b"]], places: places)
        #expect(order == ["C", "A", "B"])
        #expect(UserKnowledge.workflow(dayOrder: ["d1": ["a"]], places: Array(places.prefix(1))).isEmpty)
    }

    @Test func splitsJoinedCodes() {
        #expect(UserKnowledge.parts("mth3199") == ["mth", "3199"])
        #expect(UserKnowledge.parts("hci") == ["hci"])
    }

    // MARK: Matching

    @Test func firstNamesFindPeople() {
        #expect(UserKnowledge.matches(task: "text bella I'm running late", in: Self.things).map(\.thing.name) == ["Bella Chen"])
        #expect(UserKnowledge.matches(task: "tell dhvan the wireframes are done", in: Self.things).first?.thing.name == "Dhvan Shah")
    }

    @Test func spokenCodesFindTheExactProject() {
        let m = UserKnowledge.matches(task: "go to mth 3199 assignment 2", in: Self.things)
        #expect(m.map(\.thing.name) == ["MTH3199-Assignment-2"])
        #expect(m.first?.coverage == 1)
    }

    @Test func genericWordsAloneMatchNothing() {
        #expect(UserKnowledge.matches(task: "open my notes", in: Self.things).isEmpty)
        #expect(UserKnowledge.matches(task: "open the team doc", in: Self.things).isEmpty)
        #expect(UserKnowledge.matches(task: "open the hci notes", in: Self.things).map(\.thing.name) == ["HCI Team Notes"])
    }

    // MARK: Output

    @Test func documentsOpenAtTheirOwnPage() {
        let open = "open the hci notes"
        #expect(UserKnowledge.startURL(task: open, matches: UserKnowledge.matches(task: open, in: Self.things))
                == "https://docs.google.com/document/d/1AfP/edit")
        let hw = "mth3199 assignment 2 on canvas"
        #expect(UserKnowledge.startURL(task: hw, matches: UserKnowledge.matches(task: hw, in: Self.things))
                == "https://canvas.olin.edu/courses/1079/assignments/20385")
        // Making something new, or texting about it, does not start at the old document.
        for t in ["make a new doc for the hci notes", "text dhvan the hci notes are ready"] {
            #expect(UserKnowledge.startURL(task: t, matches: UserKnowledge.matches(task: t, in: Self.things)) == nil)
        }
    }

    @Test func peopleAreTextedWhereTheUserTalksToThem() {
        let t = "text dhvan I'm on my way"
        #expect(UserKnowledge.channelApp(task: t, matches: UserKnowledge.matches(task: t, in: Self.things)) == "net.whatsapp.WhatsApp")
        let b = "message bella"
        #expect(UserKnowledge.channelApp(task: b, matches: UserKnowledge.matches(task: b, in: Self.things)) == "com.apple.MobileSMS")
        // No email app in what memory saw of Dhvan: the default mail app decides.
        let e = "email dhvan the notes"
        #expect(UserKnowledge.channelApp(task: e, matches: UserKnowledge.matches(task: e, in: Self.things)) == nil)
    }

    @Test func describeCarriesNamesPlacesAndPagesNeverSummaries() throws {
        let d = UserKnowledge.describe(try #require(Self.thing("HCI Team Notes")), now: Self.now)
        #expect(d["url"] as? String == "https://docs.google.com/document/d/1AfP/edit")
        #expect(d["people_involved"] as? [String] != nil)
        let p = UserKnowledge.describe(try #require(Self.thing("Dhvan Shah")), now: Self.now)
        #expect(p["talks_with_them_in"] as? [String] == ["WhatsApp (5)", "docs.google.com/document (4)"])
        #expect(p["reach_them_by"] as? [String: String] == ["texting": "WhatsApp"])
        #expect(p["url"] == nil)                                                           // a person has no page to open
        let json = String(decoding: try JSONSerialization.data(withJSONObject: [d, p]), as: UTF8.self)
        #expect(!json.contains("private summary"))
    }

    @Test func jevStateCarriesUserContext() {
        var input = TypesafeCUTests.input()
        #expect(CUDecide.state(input)["user_context"] == nil)
        input.userContext = [["name": "Bella Chen", "type": "person"]]
        let ctx = CUDecide.state(input)["user_context"] as? [String: Any]
        #expect((ctx?["things"] as? [[String: Any]])?.first?["name"] as? String == "Bella Chen")
    }

    @Test func vaultNoteListsWhatNaviKnows() {
        let md = UserKnowledge.markdown(Self.things, now: Self.now)
        #expect(md.contains("# How you work"))
        #expect(md.contains("## People"))
        #expect(md.contains("[[Dhvan Shah]] — texting in WhatsApp"))
        #expect(md.contains("usually canvas.olin.edu → MATLAB"))
        // Dhvan worked in the HCI doc, but that page is the doc's, not his.
        let dhvan = md.split(separator: "\n").first { $0.hasPrefix("- [[Dhvan Shah]]") }
        #expect(dhvan?.contains("[open]") == false)
        #expect(md.contains("[[HCI Team Notes]]") && md.contains("[open](https://docs.google.com/document/d/1AfP/edit)"))
        #expect(!md.contains("private summary"))
    }
}
