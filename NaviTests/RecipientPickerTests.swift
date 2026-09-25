import Testing
import Foundation
import CoreGraphics
@testable import Navi

/// Recipient fields: which fields count, and which suggestion gets picked.
/// Labels are the real AXDescriptions Messages exposed for "Mikey" on 2026-09-25.
struct RecipientPickerTests {

    static func field(_ label: String, role: String = "AXTextField") -> AXElement {
        AXElement(id: "e1", role: role, label: label, frame: CGRect(x: 600, y: 208, width: 699, height: 45))
    }

    static func s(_ label: String, y: CGFloat = 260, selected: Bool = false, role: String = "AXButton") -> RecipientPicker.Suggestion {
        RecipientPicker.Suggestion(role: role, label: label, frame: CGRect(x: 627, y: y, width: 238, height: 40), isSelected: selected)
    }

    /// The Messages "Results" list after typing "Mikey".
    static let messagesMikey: [RecipientPicker.Suggestion] = [
        s("Mikey Ku, \u{200E}+1 (774) 578-8428, Text Message", y: 260, selected: true),
        s("Mikey, Bhar, Zach, Kilan, Dhvan, Heesung, Shanna, Jackson, +14257800416, Pranav", y: 300),
        s("Mikey, Dhvan & David, Mikey, Dhvan & David, iMessage", y: 340),
        s("Beer Mile, Mikey, Dhvan, Heesung, Shanna, Jackson, Pranav, Kilan & David, iMessage", y: 380),
        s("Mikey Pallazola, \u{200E}(508) 740-3562, mobile, iMessage", y: 420),
        s("Aiden Louie, \u{200E}(647) 825-0686, iMessage", y: 460),
    ]

    // MARK: Fields

    @Test func recipientFieldsAreRecognised() {
        for label in ["To:", "To", "Cc:", "Bcc", "To Recipients", "Add recipients", "Add guests", "Invitees", "Enter a name or email"] {
            #expect(RecipientPicker.isRecipientField(Self.field(label)), "\(label)")
        }
    }

    @Test func otherFieldsAreNot() {
        for label in ["Search", "Subject", "Message", "iMessage", "Today", "Tomorrow", "Top"] {
            #expect(!RecipientPicker.isRecipientField(Self.field(label)), "\(label)")
        }
        #expect(!RecipientPicker.isRecipientField(Self.field("To:", role: "AXButton")))
        #expect(!RecipientPicker.isRecipientField(Self.field("To:", role: "AXSecureTextField")))
    }

    @Test func addresses() {
        #expect(RecipientPicker.looksLikeAddress("mikey.ku@olin.edu"))
        #expect(RecipientPicker.looksLikeAddress("+1 (774) 578-8428"))
        #expect(RecipientPicker.looksLikeAddress("7745788428"))
        #expect(!RecipientPicker.looksLikeAddress("Mikey"))
        #expect(!RecipientPicker.looksLikeAddress("mikey ku"))
    }

    // MARK: People vs groups

    @Test func personEntriesCarryTheirHandleRightAfterTheName() {
        #expect(RecipientPicker.hasHandle("Mikey Ku, \u{200E}+1 (774) 578-8428, Text Message"))
        #expect(RecipientPicker.hasHandle("Michael Ku Jr, mkujr@olin.edu"))
        // A group that happens to list an unsaved member's number is still a group.
        #expect(!RecipientPicker.hasHandle("Mikey, Bhar, Zach, Kilan, Dhvan, Heesung, Shanna, Jackson, +14257800416, Pranav"))
        #expect(RecipientPicker.isGroup("Mikey, Bhar, Zach, Kilan, Dhvan, Heesung, Shanna, Jackson, +14257800416, Pranav"))
        #expect(RecipientPicker.isGroup("Mikey, Dhvan & David, Mikey, Dhvan & David, iMessage"))
        #expect(!RecipientPicker.isGroup("Mikey Pallazola, \u{200E}(508) 740-3562, mobile, iMessage"))
    }

    // MARK: Picking

    @Test func picksThePersonNotAGroupThatStartsWithTheName() {
        let pick = RecipientPicker.best(typed: "Mikey", among: Self.messagesMikey)
        #expect(pick.map { RecipientPicker.name(of: $0.label) } == "Mikey Ku")
    }

    @Test func aFullNamePicksThatPersonEvenWhenNotHighlighted() {
        var list = Self.messagesMikey
        list[0].isSelected = false
        list[4].isSelected = true
        #expect(RecipientPicker.best(typed: "mikey ku", among: list).map { RecipientPicker.name(of: $0.label) } == "Mikey Ku")
        #expect(RecipientPicker.best(typed: "Mikey Pallazola", among: list).map { RecipientPicker.name(of: $0.label) } == "Mikey Pallazola")
    }

    @Test func thePrefixTheAppHighlightsIsNotAlwaysTheOneTyped() {
        // For "Mik" Messages highlights Mike Grandinetti; typing "Mikey" means Mikey.
        let list = [
            Self.s("Mike Grandinetti, \u{200E}+1 (508) 878-4715, iMessage", y: 260, selected: true),
            Self.s("Mikey Ku, \u{200E}+1 (774) 578-8428, Text Message", y: 300),
        ]
        #expect(RecipientPicker.best(typed: "Mikey", among: list).map { RecipientPicker.name(of: $0.label) } == "Mikey Ku")
    }

    @Test func aNamedGroupIsPickedWhenItIsWhatWasTyped() {
        let list = [
            Self.s("THE GANG, Bella, Juan, Papi, iMessage", y: 260),
            Self.s("Theo Gangi, \u{200E}+1 (617) 555-0101, iMessage", y: 300),
        ]
        #expect(RecipientPicker.best(typed: "the gang", among: list).map { RecipientPicker.name(of: $0.label) } == "THE GANG")
    }

    @Test func recentConversationBreaksATie() {
        let list = [
            Self.s("Mikey Pallazola, \u{200E}(508) 740-3562, mobile", y: 260),
            Self.s("Mikey Ku, \u{200E}+1 (774) 578-8428, Text Message", y: 300),
        ]
        let recent = RecipientPicker.fold("Pinned\nMikey Ku, Unread, This girl to the right")
        #expect(RecipientPicker.best(typed: "Mikey", among: list, recent: recent).map { RecipientPicker.name(of: $0.label) } == "Mikey Ku")
    }

    @Test func nonMatchingSuggestionsAreNotPicked() {
        #expect(RecipientPicker.best(typed: "Zara", among: Self.messagesMikey) == nil)
        #expect(RecipientPicker.score(typed: "mikey smith", label: "Mikey Ku, +1 (774) 578-8428", isSelected: true) == nil)
    }

    @Test func addressMatchesByDigits() {
        let list = [Self.s("Mikey Ku, \u{200E}+1 (774) 578-8428, Text Message")]
        #expect(RecipientPicker.best(typed: "774-578-8428", among: list) != nil)
    }

    // MARK: The app's own choice

    @Test func appChoiceTakesANicknameSpelling() {
        // Outlook offers "Michael Ku Jr" for "mikey ku".
        let list = [Self.s("Michael Ku Jr, mkujr@olin.edu", y: 250), Self.s("Search Directory", y: 290)]
        #expect(RecipientPicker.best(typed: "mikey ku", among: list) == nil)
        #expect(RecipientPicker.appChoice(typed: "mikey ku", among: list).map { RecipientPicker.name(of: $0.label) } == "Michael Ku Jr")
    }

    @Test func appChoiceNeverContradictsTheTypedName() {
        let list = [Self.s("Mikey Ku, +1 (774) 578-8428", y: 250, selected: true)]
        #expect(RecipientPicker.appChoice(typed: "mikey smith", among: list) == nil)
        // A highlighted group is not a nickname for a person.
        let groups = [Self.s("Mikey, Dhvan & David, iMessage", y: 250, selected: true)]
        #expect(RecipientPicker.appChoice(typed: "Mo", among: groups) == nil)
    }

    // MARK: Nicknames

    @Test func familyWordsTryWhatIsOnScreenFirst() {
        let alts = RecipientPicker.alternatives(for: "Mom", recent: "Bella\nMama, Pinned\nTHE GANG")
        #expect(alts.first == "Mama")
        #expect(alts.contains("Mum"))
        #expect(RecipientPicker.alternatives(for: "my dad", recent: "").contains("Papi"))
        #expect(RecipientPicker.alternatives(for: "Mikey", recent: "").isEmpty)
    }

    // MARK: Geometry & bookkeeping

    @Test func searchRegionIsUnderTheFieldNotTheSidebar() {
        let region = RecipientPicker.searchRegion(for: Self.field("To:").frame)
        #expect(region.intersects(CGRect(x: 627, y: 260, width: 238, height: 40)))      // Messages results
        #expect(!region.intersects(CGRect(x: 269, y: 529, width: 300, height: 80)))     // the conversation list
        #expect(!region.intersects(CGRect(x: 627, y: 1000, width: 238, height: 40)))    // far below
    }

    @Test func freshDropsWhatWasThereAndTheEcho() {
        let old = Self.s("Mikey Ku, Unread, This girl to the right", role: "AXStaticText")
        let echo = Self.s("Mikey", role: "AXStaticText")
        let new = Self.messagesMikey[0]
        let fresh = RecipientPicker.fresh([old, echo, new], baseline: [old.key], typed: "mikey")
        #expect(fresh.map(\.key) == [new.key])
    }

    @Test func outcomesTellJevAndStopOnlyWhenNobodyMatched() {
        #expect(RecipientPicker.Outcome.picked("Mikey Ku").note(typed: "Mikey").contains("recipient set"))
        #expect(RecipientPicker.Outcome.noSuggestions.note(typed: "Mikey").contains("NOT set"))
        #expect(RecipientPicker.Outcome.noSuggestions.stopsContactApp)
        #expect(RecipientPicker.Outcome.noMatch(["Mike Welch"]).stopsContactApp)
        #expect(!RecipientPicker.Outcome.picked("x").stopsContactApp)
        #expect(!RecipientPicker.Outcome.keptAddress.stopsContactApp)
        #expect(!RecipientPicker.Outcome.unconfirmed("x").stopsContactApp)
        let msg = RecipientPicker.Outcome.noMatch(["Mike Welch", "Mike Grandinetti"]).failure(typed: "Mikee", field: "‘To:’", app: "Messages")
        #expect(msg.contains("Mike Welch") && msg.contains("Messages"))
    }
}
