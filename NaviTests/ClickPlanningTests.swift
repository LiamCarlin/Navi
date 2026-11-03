import CoreGraphics
import Foundation
import Testing
@testable import Navi

/// "Find my availability on Outlook, then text Dhvan Shah" (2026-11-02): Dhvan's contact was
/// picked, then the Messages step typed "Dhvan Shah" into To: a second time and ended "no contact".
/// Messages' bubbles were offered as fields, its message box was never reached by the walk, the
/// recipient chip read as "￼", and the whole task's Outlook "New mail" path rode into the step.
/// Each fix is pure and pinned here, with the learning that keeps a run's lesson for the next one.
struct ClickPlanningTests {
    static let messages = "com.apple.MobileSMS"

    static func el(_ id: String, _ role: String, _ label: String, _ frame: CGRect, value: String? = nil,
                   placeholder: String = "", focused: Bool = false) -> AXElement {
        AXElement(id: id, role: role, label: label, value: value, frame: frame, isFocused: focused, placeholder: placeholder)
    }

    /// The Messages window right after the contact was picked, as the live probe read it.
    static var afterPick: AXSnapshot {
        AXSnapshot(elements: [
            el("e1", "AXTextField", "To:", CGRect(x: 378, y: 119, width: 1076, height: 45), value: "\u{FFFC}", focused: true),
            el("e2", "AXPopUpButton", "Dhvan Shah, +1 555 0100", CGRect(x: 396, y: 131, width: 120, height: 20)),
            el("e3", "AXTextField", "Search", CGRect(x: 47, y: 164, width: 300, height: 36), value: "", placeholder: "Search"),
            el("e4", "AXTextField", "Message", CGRect(x: 415, y: 777, width: 973, height: 31), value: "", placeholder: "iMessage"),
        ], pid: 1, bundleID: messages, appName: "Messages", windowFrame: CGRect(x: 29, y: 112, width: 1446, height: 708))
    }

    // MARK: Perception

    @Test func aBubbleTheCellAlreadyNamesIsText() {
        #expect(AXSnapshot.echoedByContainer("Here", context: "Messages\nYour iMessage, Here, 12:36 AM"))
        #expect(AXSnapshot.echoedByContainer("Nearly a 1 year anniversary ", context: "David Barsoum, Nearly a 1 year anniversary , 9:12 PM"))
        #expect(AXSnapshot.echoedByContainer("Founders’ Dinner with Christine Keung | J2 Ventures × Catalyst · Luma",
                                             context: "Your iMessage, Founders' Dinner with Christine Keung | J2 Ventures × Catalyst · Luma, luma.com, 1 image"))
        // A field's own contents are never its container's name.
        #expect(!AXSnapshot.echoedByContainer("Groceries: milk, eggs", context: "Notes\nNote body"))
        #expect(!AXSnapshot.echoedByContainer("", context: "Your iMessage, , 12:36 AM"))
        #expect(!AXSnapshot.echoedByContainer("Here", context: ""))
    }

    @Test func theContextKeepsTheTwoNearestContainers() {
        let c = AXSnapshot.nestedContext(AXSnapshot.nestedContext("Messages", "Transcript"), "Your iMessage, Here, 12:36 AM")
        #expect(c == "Transcript\nYour iMessage, Here, 12:36 AM")
    }

    @Test func aToFieldHoldingItsChipIsNoPlaceToWrite() {
        // To: with its recipient and the sidebar search: the walk must look further for the message box.
        let without = Self.afterPick.elements.filter { $0.id != "e4" }
        #expect(!AXSnapshot.hasWritableInput(without))
        #expect(AXSnapshot.hasWritableInput(Self.afterPick.elements))
    }

    @Test func aRecipientChipIsNamed() {
        let named = AXSnapshot.namingChips(Self.afterPick.elements)
        #expect(named.first { $0.id == "e1" }?.value == "‹Dhvan Shah›")
        // Two chips, the second without a pill under it.
        let two = AXSnapshot.namingChips([
            Self.el("t", "AXTextField", "To:", CGRect(x: 0, y: 0, width: 400, height: 40), value: "\u{FFFC}\u{FFFC}"),
            Self.el("p", "AXPopUpButton", "Mikey Ku, mikey@example.com", CGRect(x: 10, y: 10, width: 80, height: 20)),
        ])
        #expect(two.first?.value == "‹Mikey Ku›‹contact›")
        // A pop-up elsewhere in the window is not this field's chip.
        let away = AXSnapshot.namingChips([
            Self.el("t", "AXTextField", "To:", CGRect(x: 0, y: 0, width: 400, height: 40), value: "\u{FFFC}"),
            Self.el("p", "AXPopUpButton", "Font, Helvetica", CGRect(x: 10, y: 300, width: 80, height: 20)),
        ])
        #expect(away.first?.value == "‹contact›")
    }

    // MARK: Recipients

    @Test func aPickedRecipientIsNeverTypedAgain() {
        let picked = ["Dhvan Shah", "Dhvan Shah"]
        #expect(RecipientPicker.alreadyPicked("Dhvan Shah", picked: picked))
        #expect(RecipientPicker.alreadyPicked("dhvan", picked: picked))
        #expect(RecipientPicker.alreadyPicked("Mikey", picked: ["mikey", "Mikey Ku"]))
        // A second person is a second recipient, even with the same first letter.
        #expect(!RecipientPicker.alreadyPicked("Jill", picked: ["Jack", "Jack Smith"]))
        #expect(!RecipientPicker.alreadyPicked("Dhvan Shah", picked: []))
    }

    @Test func theMessageBoxIsTheComposer() {
        #expect(CUSend.composer(in: Self.afterPick)?.id == "e4")
        // No message box in sight: nothing to redirect to (the guard refuses instead).
        var none = Self.afterPick
        none.elements.removeAll { $0.id == "e4" }
        #expect(CUSend.composer(in: none) == nil)
    }

    // MARK: Plan noise

    @Test func aRoutineOnlyFitsWhereItHappens() {
        let outlook = RoutineStep(kind: .click, app: "Chrome", bundleID: "com.google.Chrome", site: "outlook.cloud.microsoft",
                                  role: "button", label: "New mail")
        let mail = Routine(key: "k", goals: ["new mail"], template: "new mail", bundleID: "com.google.Chrome", appName: "Chrome",
                           steps: [outlook], count: 1, first: Date(), last: Date())
        #expect(!UserRoute.fits(mail, bundleID: Self.messages, appName: "Messages", url: nil))
        #expect(UserRoute.fits(mail, bundleID: "com.google.Chrome", appName: "Google Chrome", url: "https://outlook.cloud.microsoft/mail/inbox"))

        let open = RoutineStep(kind: .open, app: "Messages", bundleID: Self.messages, label: "Messages")
        let text = RoutineStep(kind: .type, app: "Messages", bundleID: Self.messages, role: "field", label: "Message")
        let texting = Routine(key: "t", goals: ["text bella"], template: "text …", bundleID: Self.messages, appName: "Messages",
                              steps: [open, text], count: 3, first: Date(), last: Date())
        #expect(UserRoute.fits(texting, bundleID: Self.messages, appName: "Messages", url: nil))
        #expect(!UserRoute.fits(texting, bundleID: "com.microsoft.Outlook", appName: "Microsoft Outlook", url: nil))
    }

    @Test func aStepIsNotToldAboutAnotherAppsSession() {
        let context: [[String: Any]] = [
            ["name": "Search Outlook for registrar emails", "type": "app", "where": "Microsoft Outlook", "the_task_refers_to_this": "71% sure"],
            ["name": "Dhvan Shah", "type": "person", "reach_them_by": ["texting": "Messages"]],
        ]
        let step = UserKnowledge.forStep(context, appName: "Messages", isPlannerStep: true)
        #expect(step.map { $0["name"] as? String } == ["Dhvan Shah"])
        // In Outlook itself, or for the task as a whole, the pick stays.
        #expect(UserKnowledge.forStep(context, appName: "Microsoft Outlook", isPlannerStep: true).count == 2)
        #expect(UserKnowledge.forStep(context, appName: "Messages", isPlannerStep: false).count == 2)
    }

    // MARK: Learning

    @Test func aLongGoalRecallsTheShortOneItIsAnInstanceOf() {
        let store = AgentExperience(fileURL: nil)
        store.record(bundleID: Self.messages, appName: "Messages", goal: "Send a message to Jonathan saying hi",
                     actions: ["Type ‘…’ into ‘To:’", "Click ‘Message’", "Type ‘…’ into ‘Message’"])
        let step = "Send Dhvan Shah a text message with your availability for today and tomorrow: Your Outlook calendar is showing "
            + "today (Mon Nov 2) and tomorrow (Tue Nov 3) with busy blocks visible. Today you're booked 11am-3:05pm (MechDes/HCI)"
        let lines = store.recall(bundleID: Self.messages, goal: step)
        #expect(lines == ["Send a message to Jonathan saying hi → Type ‘…’ into ‘To:’ · Click ‘Message’ · Type ‘…’ into ‘Message’"])
        // Another app's runs never come back.
        #expect(store.recall(bundleID: "com.apple.Notes", goal: step).isEmpty)
    }

    @Test func theIntentStopsWhereTheMessageStarts() {
        #expect(AgentExperience.intent(of: "Send a message to Jonathan saying hi there") == "Send a message to Jonathan")
        #expect(AgentExperience.intent(of: "Send Dhvan a text: free after 5") == "Send Dhvan a text")
        #expect(AgentExperience.intent(of: "Text mom “on my way”") == "Text mom ")
        #expect(AgentExperience.intent(of: "Make a new note") == "Make a new note")
    }

    @Test func aFailureIsRecalledAsWhatWentWrong() {
        let store = AgentExperience(fileURL: nil)
        store.recordFailure(bundleID: Self.messages, appName: "Messages", goal: "Send Dhvan Shah a text with my availability",
                            actions: ["Press ⌘N", "Type ‘…’ into ‘To:’", "Type ‘…’ into ‘To:’"],
                            lesson: "no contact came up for the name typed into ‘To:’")
        store.record(bundleID: Self.messages, appName: "Messages", goal: "Send a text to Bella saying hi",
                     actions: ["Press ⌘N", "Type ‘…’ into ‘To:’", "Type ‘…’ into ‘Message’"])
        let lines = store.recall(bundleID: Self.messages, goal: "send a text to dhvan shah saying I'm free")
        #expect(lines.count == 2)
        #expect(lines.first?.hasPrefix("Send a text to Bella") == true)
        #expect(lines.last == "✗ Send Dhvan Shah a text with my availability → Press ⌘N · Type ‘…’ into ‘To:’ — went wrong: no contact came up for the name typed into ‘To:’")
        // A failure never replaces the success for the same goal, nor the other way round.
        store.record(bundleID: Self.messages, appName: "Messages", goal: "Send Dhvan Shah a text with my availability", actions: ["Press ⌘N"])
        #expect(store.count == 3)
    }

    @Test func detoursAreNotPartOfTheWay() {
        // The OBS run: every Add undone by Esc or Close.
        #expect(AgentExperience.condense(["Click ‘Add’", "Press Esc", "Click ‘Add’", "Click ‘Display Capture’", "Click ‘Close’", "Click ‘Add’"])
                == ["Click ‘Add’"])
        // Typing is never undone by a Cancel; the same click twice counts once.
        #expect(AgentExperience.condense(["Type ‘…’ into ‘Timer’", "Click ‘Cancel’", "Click ‘Start’", "Click ‘Start’"])
                == ["Type ‘…’ into ‘Timer’", "Click ‘Cancel’", "Click ‘Start’"])
        #expect(AgentExperience.condense(["Press ⌘N", "Type ‘…’ into ‘To:’"]) == ["Press ⌘N", "Type ‘…’ into ‘To:’"])
    }
}
