import Testing
@testable import Navi

/// "text bella my schedule for the week" sent the same message seven times: the composer is empty
/// after each send and the screen changed, so only a remembered send can stop the next one.
struct CUSendTests {
    static let schedule = "Here's my schedule for the week: Applied Mathematics for Engineers, Mechanical Design, "
        + "Spec Topics in Arts/Hum/SocSci Gen AI, Human-Computer Interaction, MechDes Meeting, Baja Leads meeting, "
        + "1:1 Liam & Victoria, Catalyst Coffee Hour"

    @Test func aMessagesComposerSends() {
        // Jev's own nouls from the run: 0.65–0.87 irreversible.
        #expect(CUSend.isTypedSend(role: "AXTextField", label: "Message", placeholder: "iMessage", bundleID: "com.apple.MobileSMS", irreversible: 0.65))
        // Even when Jev is unsure it is irreversible, a chat app's message field sends on Return.
        #expect(CUSend.isTypedSend(role: "AXTextField", label: "Message", placeholder: "iMessage", bundleID: "com.apple.MobileSMS", irreversible: 0.2))
        #expect(CUSend.isTypedSend(role: "AXTextArea", label: "Message to Pia Swarup", placeholder: "", bundleID: "com.tinyspeck.slackmacgap", irreversible: 0.1))
    }

    @Test func searchesAndRecipientsAreNotSends() {
        #expect(!CUSend.isTypedSend(role: "AXSearchField", label: "Search", placeholder: "", bundleID: "com.apple.MobileSMS", irreversible: 0.9))
        #expect(!CUSend.isTypedSend(role: "AXTextField", label: "Search", placeholder: "Search", bundleID: "com.apple.MobileSMS", irreversible: 0.7))
        #expect(!CUSend.isTypedSend(role: "AXTextField", label: "To:", placeholder: "", bundleID: "com.apple.MobileSMS", irreversible: 0.7))
        // A form field outside a chat app that Jev does not call irreversible.
        #expect(!CUSend.isTypedSend(role: "AXTextField", label: "Name", placeholder: "", bundleID: "com.apple.Safari", irreversible: 0.1))
    }

    @Test func sendButtons() {
        #expect(CUSend.isSendControl(label: "Send", irreversible: 0.8))
        #expect(CUSend.isSendControl(label: "Post reply", irreversible: 0.6))
        #expect(!CUSend.isSendControl(label: "Send", irreversible: 0.2))
        #expect(!CUSend.isSendControl(label: "Reply", irreversible: 0.8))    // opens a composer
        #expect(!CUSend.isSendControl(label: "Sent Items", irreversible: 0.8))
    }

    @Test func theSameMessageIsNeverSentTwice() {
        let sent = [Self.schedule]
        #expect(CUSend.repeats(Self.schedule, sent: sent))
        #expect(CUSend.repeats(Self.schedule.uppercased() + "!", sent: sent))
        // Reworded by the writer on the next turn: still the same message.
        let reworded = Self.schedule.replacingOccurrences(of: "for the week", with: "this week")
        #expect(CUSend.repeats(reworded, sent: sent))
        // Another message is not a repeat.
        #expect(!CUSend.repeats("Running 10 min late, see you at Catalyst", sent: sent))
        #expect(!CUSend.repeats(Self.schedule, sent: []))
        #expect(CUSend.repeats("hi", sent: ["Hi!"]))
        #expect(!CUSend.repeats("hi there", sent: ["hi"]))
    }

    @Test func theWriterIsToldNotToSendAgain() {
        #expect(CURunState.Outcome.sent.told.contains("never sent again"))
        var run = CURunState()
        #expect(run.countStall(.sent) == .sent)
    }
}
