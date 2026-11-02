import Testing
import Foundation
import CoreGraphics
@testable import Navi

/// A message for one person never lands in a group conversation. Labels are the real ones from
/// the four "text jonathan" runs of 2026-11-02 (runs/20261102T1042…–1044…).
struct MessageAudienceTests {

    // MARK: The task

    @Test func oneNamedPersonIsOnePerson() {
        for t in ["send a text to jonathan saying hi", "send a text to jonathan saying to explode",
                  "send a message to only jonathan saying explode", "send a message to jonathan saying hi",
                  "text mom I'm on my way", "email the registrar about my transfer credit",
                  "reply to the email from gabi", "message jonathan on whatsapp: running late",
                  "send jonathan a text saying hi", "dm mikey ku that the meeting moved"] {
            #expect(MessageAudience.isOnePerson(t), "\(t)")
        }
    }

    @Test func severalPeopleOrAGroupIsNot() {
        for t in ["text jonathan and kieran saying hi", "message jonathan, kieran saying the room changed",
                  "text the group chat that I'm late", "message everyone on the team", "text the gc saying hi",
                  "send a message to jonathan & kieran", "email both of them the slides"] {
            #expect(!MessageAudience.isOnePerson(t), "\(t)")
        }
    }

    @Test func tasksThatSendNothingAreNotMessages() {
        #expect(!MessageAudience.isOnePerson("open youtube"))
        #expect(!MessageAudience.isOnePerson("order me a burger"))
        #expect(MessageAudience.addressee(of: "open the hci notes") == nil)
    }

    // MARK: Conversations

    @Test func memberListsAreGroups() {
        for l in ["Jonathan & +1, You loved “Dude I’m like 1k wpm typeracer and codi",
                  "Jonathan & +1",
                  "Jack,  Dhvan,  Lena,  Premkumar,  Reja & Jonathan, Unread, son , 10:04 AM",
                  "\u{200E}New Message to Jonathan, Kieran & [redacted]",
                  "Jonathan, Kieran & [redacted]",
                  "Jonathan, Kieran & +1 (925) 548-3198",
                  "Jonathan, Kieran & +1 (9…",
                  "Mikey, Dhvan & David, Mikey, Dhvan & David, iMessage"] {
            #expect(MessageAudience.isGroupConversation(l), "\(l)")
        }
    }

    @Test func peopleAndNamedGroupsAreNot() {
        for l in ["Lena Conde Araujo, Unread, wait what is tonight, 9:25 AM", "Jonathan Sun",
                  "Mikey Ku, \u{200E}+1 (774) 578-8428, Text Message", "THE GANG, Unread, Pinned",
                  "Bella, Pinned", "\u{200E}New Message", "Messages", "Banana Peels🏀, Unread, Wb tmrw night ?, 10:17 AM",
                  "Zach Wolter, Hey their car was at the babson gate & now they’re pulling away, Yesterday",
                  "Gabi Smith, Re: lab report & data, 9:02 AM"] {
            #expect(!MessageAudience.isGroupConversation(l), "\(l)")
        }
    }

    @Test func pillsCountRecipients() {
        #expect(MessageAudience.pillCount("\u{FFFC}\u{FFFC}\u{FFFC}") == 3)
        #expect(MessageAudience.pillCount("") == 0)
        #expect(MessageAudience.pillCount(nil) == 0)
    }

    @Test func factOnlyForOnePerson() {
        #expect(MessageAudience.fact(task: "text jonathan saying hi", person: "Jonathan Sun")?["person"] as? String == "Jonathan Sun")
        #expect(MessageAudience.fact(task: "text jonathan and kieran saying hi", person: nil) == nil)
    }

    // MARK: The recipient picker (Messages' To: suggestions for "Jonathan")

    static func s(_ label: String, y: CGFloat, selected: Bool = false) -> RecipientPicker.Suggestion {
        RecipientPicker.Suggestion(role: "AXButton", label: label, frame: CGRect(x: 627, y: y, width: 238, height: 40), isSelected: selected)
    }

    @Test func aGroupWhoseLastMemberIsANumberIsNoPerson() {
        let g = "Jonathan, Kieran & +1 (925) 548-3198, iMessage"
        #expect(!RecipientPicker.hasHandle(g))
        #expect(RecipientPicker.isGroup(g))
    }

    @Test func picksJonathanSunNotTheGroupStartingWithJonathan() {
        let list = [
            Self.s("Jonathan, Kieran & +1 (925) 548-3198, iMessage", y: 260, selected: true),
            Self.s("Jonathan Sun, \u{200E}+1 (510) 555-0134, iMessage", y: 300),
        ]
        #expect(RecipientPicker.best(typed: "Jonathan", among: list).map { RecipientPicker.name(of: $0.label) } == "Jonathan Sun")
    }

    @Test func aGroupIsNeverPickedForAName() {
        // Only the group came up: nothing is picked, the run stops before writing anything.
        let list = [Self.s("Jonathan, Kieran & +1 (925) 548-3198, iMessage", y: 260, selected: true)]
        #expect(RecipientPicker.best(typed: "Jonathan", among: list) == nil)
        #expect(RecipientPicker.appChoice(typed: "Jonathan", among: list) == nil)
    }

    @Test func severalPillsStopTheRun() {
        let o = RecipientPicker.Outcome.addedSeveral("Jonathan", 3)
        #expect(o.stopsContactApp)
        #expect(!o.isResolved)
    }

    // MARK: Sending

    static func screen(title: String, toValue: String = "") -> CUScreen {
        let to = AXElement(id: "to", role: "AXTextField", label: "To:", value: toValue, frame: CGRect(x: 380, y: 20, width: 1000, height: 30))
        let msg = AXElement(id: "msg", role: "AXTextArea", label: "Message", frame: CGRect(x: 420, y: 720, width: 1000, height: 30))
        let snap = AXSnapshot(elements: [to, msg], windowTitle: title, bundleID: "com.apple.MobileSMS", appName: "Messages")
        return CUScreen(snapshot: snap, items: [], elementForItem: [:], field: nil, usedOCR: false)
    }

    @Test func aOnePersonSendIntoAGroupIsRefused() {
        let send = AgentAction.typeText(elementID: "msg")
        let task = "send a message to jonathan saying hi"
        #expect(AgentRun.groupSend(send, submit: true, task: task, screen: Self.screen(title: "Jonathan, Kieran & +1 (925) 548-3198"),
                                        typedUnsent: nil, irreversible: 0.9) != nil)
        #expect(AgentRun.groupSend(send, submit: true, task: task, screen: Self.screen(title: "Messages", toValue: "\u{FFFC}\u{FFFC}\u{FFFC}"),
                                        typedUnsent: nil, irreversible: 0.9) != nil)
        // Jonathan's own chat, a group task, or typing without sending: fine.
        #expect(AgentRun.groupSend(send, submit: true, task: task, screen: Self.screen(title: "Jonathan Sun"),
                                        typedUnsent: nil, irreversible: 0.9) == nil)
        #expect(AgentRun.groupSend(send, submit: true, task: "text jonathan and kieran saying hi",
                                        screen: Self.screen(title: "Jonathan, Kieran & +1 (925) 548-3198"), typedUnsent: nil, irreversible: 0.9) == nil)
        #expect(AgentRun.groupSend(send, submit: false, task: task, screen: Self.screen(title: "Jonathan, Kieran & +1 (925) 548-3198"),
                                        typedUnsent: nil, irreversible: 0.9) == nil)
        #expect(AgentRun.groupSend(.key("return"), submit: false, task: task, screen: Self.screen(title: "Jonathan & +1"),
                                        typedUnsent: "hi", irreversible: 0.9) != nil)
    }
}
