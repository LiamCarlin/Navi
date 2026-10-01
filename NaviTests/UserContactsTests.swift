import Foundation
import Testing
@testable import Navi

/// `UserContacts` + `UserKnowledge`: how the user reaches each person — the app they
/// open that person's conversation in, the address their mail shows for them.
@Suite struct UserContactsTests {
    static let now = UserKnowledgeTests.now

    // MARK: Email addresses from mail OCR

    @Test func readsNameAddressPairsThroughOCRJunk() {
        let text = """
        Results  O Nuray Molla <nmolla@tesla.com>  Yesterday
        PM, Yoi Tanaka <ytanaka@olin.edu>
        To: Liam Carlin <Icarlin@olin.edu>; Lena Conde Araujo <Icondearaujo@olin.edu>
        From: David Horne <DHorne@fenwick.com>
        Notifications <no-reply@example.com>
        """
        let pairs = UserContacts.pairs(in: text).map { "\($0.name)|\($0.address)" }
        #expect(pairs.contains("Nuray Molla|nmolla@tesla.com"))                 // column text and the avatar's initial dropped
        #expect(pairs.contains("Yoi Tanaka|ytanaka@olin.edu"))                   // a time's PM dropped
        #expect(pairs.contains("Lena Conde Araujo|lcondearaujo@olin.edu"))      // OCR's capital I read as l
        #expect(pairs.contains("David Horne|dhorne@fenwick.com"))               // addresses are lower-cased
        #expect(!pairs.contains { $0.contains("no-reply") })                     // nobody to write to
    }

    @Test func aNameWithItsAddressIsTypedAsTheAddress() {
        #expect(UserContacts.soleAddress(in: "Meera Baswan <mb128@wellesley.edu>") == "mb128@wellesley.edu")
        #expect(UserContacts.soleAddress(in: "mb128@wellesley.edu") == "mb128@wellesley.edu")
        #expect(UserContacts.soleAddress(in: "Meera Baswan") == nil)
        #expect(UserContacts.soleAddress(in: "a@x.com, b@y.com") == nil)                      // a list stays as typed
    }

    @Test func anAddressBelongsToANameItSpells() {
        #expect(UserContacts.belongs("cphillips@olin.edu", to: "Crawford Phillips"))
        #expect(UserContacts.belongs("mb128@wellesley.edu", to: "Meera Baswan"))          // initials
        #expect(UserContacts.belongs("carpediem@lists.olin.edu", to: "Carpe Diem"))
        #expect(UserContacts.belongs("gvandezande@olin.edu", to: "Zande"))
        #expect(!UserContacts.belongs("mkoh@olin.edu", to: "Jada Campbell"))               // the next column's address
    }

    // MARK: Open conversations

    @Test func readsTheConversationAClickOpened() {
        #expect(UserContacts.conversation(clickedLabel: "r2 gang fall 26, \u{200E}2 unread messages", role: "button") == "r2 gang fall 26")
        #expect(UserContacts.conversation(clickedLabel: "\u{200E}\u{202A}Jillian & ~ Mateo\u{202C}", role: "button") == "Jillian & ~ Mateo")
        #expect(UserContacts.conversation(clickedLabel: "\u{200E}message, Yes, sure thing, 10:17 AM, \u{200E}Received from João Pedro Mendes",
                                          role: "text") == "João Pedro Mendes")
        #expect(UserContacts.conversation(clickedLabel: "Marie Kung, Unread, Hey are you around", role: "row") == "Marie Kung")
        #expect(UserContacts.conversation(clickedLabel: "Close", role: "button") == nil)
        #expect(UserContacts.conversation(clickedLabel: "Search", role: "field") == nil)
        #expect(UserContacts.conversation(clickedLabel: "+1 (617) 555-0100", role: "row") == nil)
        #expect(UserContacts.conversation(windowTitle: "Bella Chen") == "Bella Chen")
        #expect(UserContacts.conversation(windowTitle: "Messages") == nil)
    }

    // MARK: Folded into people

    static func opened(_ name: String, _ bundle: String, _ app: String, minutes: [Double]) -> [UserContacts.Opened] {
        minutes.map { .init(name: name, key: bundle, app: app, isWeb: false, at: now.addingTimeInterval(-$0 * 60)) }
    }

    static func address(_ name: String, _ addr: String, times: Int = 2) -> [UserContacts.Address] {
        (0..<times).map { i in .init(name: name, address: addr, key: "com.microsoft.Outlook", app: "Microsoft Outlook", isWeb: false,
                                     at: now.addingTimeInterval(Double(-i) * 3600)) }
    }

    static let signals: UserContacts.Signals = {
        var s = UserContacts.Signals()
        // Dhvan is in the WhatsApp chat list every day, but it is his Messages chat the user opens.
        s.opened += opened("Dhvan Shah", "com.apple.MobileSMS", "Messages", minutes: [10, 70, 130, 190])
        s.opened += opened("Bella, Dhvan & Suraj", "com.apple.MobileSMS", "Messages", minutes: [20, 300])
        s.addresses += address("Dhvan Shah", "dshah2@olin.edu", times: 3)
        s.addresses += address("Dhvan Shah", "mkoh@olin.edu", times: 1)            // OCR pairing with the next column
        s.addresses += address("Registrar's Office", "registrar@olin.edu")
        s.addresses += address("Liam Carlin", "lcarlin@olin.edu", times: 5)        // the user themself
        return s
    }()

    static let things = UserKnowledge.build(sessions: UserKnowledgeTests.sessions, selfNames: ["Liam Carlin"], signals: signals)

    @Test func openConversationsOutweighAChatList() throws {
        let dhvan = try #require(Self.things.first { $0.name == "Dhvan Shah" })
        #expect(dhvan.places.first?.key == "com.apple.MobileSMS")
        #expect(dhvan.places.first?.opened == 4)
        let t = "text dhvan I'm outside"
        #expect(UserKnowledge.channelApp(task: t, matches: UserKnowledge.matches(task: t, in: Self.things)) == "com.apple.MobileSMS")
    }

    @Test func emailsGoToTheAddressTheirMailShowed() throws {
        let dhvan = try #require(Self.things.first { $0.name == "Dhvan Shah" })
        #expect(dhvan.emails == ["dshah2@olin.edu"])
        #expect(UserKnowledge.emailAddress(named: "dhvan", in: Self.things) == "dshah2@olin.edu")
        #expect(UserKnowledge.emailAddress(named: "Dhvan Shah", in: Self.things) == "dshah2@olin.edu")
        #expect(UserKnowledge.emailAddress(named: "dhvan, bella", in: Self.things) == nil)       // a list stays as typed
        #expect(UserKnowledge.emailAddress(named: "someone@else.com", in: Self.things) == nil)
        let e = "email dhvan the notes"
        #expect(UserKnowledge.channelApp(task: e, matches: UserKnowledge.matches(task: e, in: Self.things)) == "com.microsoft.Outlook")
        let d = UserKnowledge.describe(dhvan, now: Self.now)
        #expect(d["email"] as? String == "dshah2@olin.edu")
        #expect((d["reach_them_by"] as? [String: String])?["email"] == "Microsoft Outlook")
        #expect((d["reach_them_by"] as? [String: String])?["texting"] == "Messages")
    }

    @Test func correspondentsKnownOnlyFromMailAreContacts() {
        #expect(UserKnowledge.emailAddress(named: "the registrar", in: Self.things) == "registrar@olin.edu")
        #expect(!Self.things.contains { $0.name == "Liam Carlin" })
    }

    @Test func groupChatsDoNotBlockFirstNames() {
        #expect(UserKnowledge.matches(task: "text bella hi", in: Self.things).first?.thing.name == "Bella Chen")
        #expect(!Self.things.contains { $0.name == "Bella" })
    }
}
