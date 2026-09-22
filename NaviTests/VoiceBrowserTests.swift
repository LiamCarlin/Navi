import Testing
import Foundation
import CoreGraphics
@testable import Navi

/// Voice → browser: local browser-level commands, goal normalisation, page
/// actions staying on the current tab, the no-model text guess, and the
/// runner-vs-native browser rule. Pure logic; no network, no Accessibility.
struct VoiceBrowserTests {

    // MARK: Browser controls

    @Test func browserControlsMatchSpokenPhrases() {
        #expect(BrowserControls.match("close the tab")?.key == "cmd+w")
        #expect(BrowserControls.match("Can you close this tab please")?.key == "cmd+w")
        #expect(BrowserControls.match("close tab")?.isDestructive == true)
        #expect(BrowserControls.match("go back")?.key == "cmd+[")
        #expect(BrowserControls.match("okay go back a page")?.key == "cmd+[")
        #expect(BrowserControls.match("reload the page")?.key == "cmd+r")
        #expect(BrowserControls.match("refresh")?.key == "cmd+r")
        #expect(BrowserControls.match("next tab")?.key == "ctrl+tab")
        #expect(BrowserControls.match("switch to the previous tab")?.key == "ctrl+shift+tab")
        #expect(BrowserControls.match("open a new tab")?.key == "cmd+t")
        #expect(BrowserControls.match("scroll down")?.scroll == 10)
        #expect(BrowserControls.match("scroll down a bit")?.scroll == 10)
        #expect(BrowserControls.match("scroll up a lot")?.scroll == -30)
        #expect(BrowserControls.match("scroll to the top")?.key == "cmd+up")
        #expect(BrowserControls.match("zoom in")?.key == "cmd+=")
        #expect(BrowserControls.match("reopen the last closed tab")?.key == "cmd+shift+t")
    }

    @Test func browserControlsRefuseAnythingMore() {
        // Two instructions, an object, or a task the page must do: not a browser control.
        #expect(BrowserControls.match("close the tab and open gmail") == nil)
        #expect(BrowserControls.match("close all tabs") == nil)
        #expect(BrowserControls.match("go back to the dashboard") == nil)
        #expect(BrowserControls.match("scroll down to the comments") == nil)
        #expect(BrowserControls.match("open a new tab and search for cats") == nil)
        #expect(BrowserControls.match("click the back button") == nil)
        #expect(BrowserControls.match("refresh my memory about apollo 11") == nil)
        #expect(BrowserControls.match("") == nil)
        // Every key in the table parses.
        for entry in BrowserControls.table {
            if let k = entry.command.key { #expect((try? KeyCombo.parse(k)) != nil, "\(k)") }
            #expect(entry.command.key != nil || entry.command.scroll != 0)
        }
    }

    // MARK: Goal normalisation

    @Test func politenessAndLeftoverAddressAreStripped() {
        #expect(VoiceDecider.normalizedGoal("can you go to Google Drive") == "go to Google Drive")
        #expect(VoiceDecider.normalizedGoal("Navi, please open notes") == "open notes")
        #expect(VoiceDecider.normalizedGoal("hey navi could you please make the title hello") == "make the title hello")
        // What is left of "can you" once the recognizer revised "can" away (seen in real transcripts).
        #expect(VoiceDecider.normalizedGoal("you go to speech after Scott") == "go to speech after Scott")
        #expect(VoiceDecider.normalizedGoal("I want you to search for cats") == "search for cats")
        // Nothing left ⇒ unchanged (the fragment rule drops it).
        #expect(VoiceDecider.normalizedGoal("you") == "you")
        #expect(VoiceDecider.normalizedGoal("please") == "please")
        // Plain instructions untouched.
        #expect(VoiceDecider.normalizedGoal("open notes") == "open notes")
        #expect(VoiceDecider.normalizedGoal("YouTube lofi beats") == "YouTube lofi beats")
    }

    private func clause(_ head: String) -> UtteranceSegmenter.Clause {
        let n = head.split(separator: " ").count
        return .init(head: head, following: "", connector: ".", start: 0, end: n, resume: n)
    }

    private func verdict(kind: String, surface: String = "browser") -> VoiceDecider.Verdict {
        var v = VoiceDecider.Verdict()
        v.boundary = .init(choice: "complete", probabilities: ["complete": 0.9, "continues": 0.05, "not_a_command": 0.05], confidence: 0.9)
        v.kind = .init(choice: kind, probabilities: [kind: 0.9], confidence: 0.9)
        v.control = .init(choice: "none", probabilities: ["none": 0.9], confidence: 0.9)
        v.surface = .init(choice: surface, probabilities: [surface: 0.8], confidence: 0.8)
        return v
    }

    @Test func browserCommandsBypassTheAgent() {
        var ctx = VoiceDecider.Context()
        ctx.frontmostBundle = "com.google.Chrome"
        let input = { (h: String) in VoiceDecider.Input(clause: self.clause(h), silenceMs: 800, context: ctx) }
        guard case .browser(let b, _) = VoiceDecider.command(verdict(kind: "do_in_app"), input: input("Can you close the tab")) else {
            Issue.record("close the tab should be a browser command"); return
        }
        #expect(b.key == "cmd+w")
        guard case .browser(let s, _) = VoiceDecider.command(verdict(kind: "browse_or_search"), input: input("scroll down")) else {
            Issue.record("scroll down in a browser is a browser command"); return
        }
        #expect(s.scroll == 10)
        // Scrolling with Notes in front is Notes' business: the agent handles it.
        var notes = ctx; notes.frontmostBundle = "com.apple.Notes"
        let inNotes = VoiceDecider.Input(clause: clause("scroll down"), silenceMs: 800, context: notes)
        guard case .task = VoiceDecider.command(verdict(kind: "do_in_app", surface: "native_app"), input: inNotes) else {
            Issue.record("scroll down in Notes should be a task"); return
        }
        // Tab commands imply a browser wherever the user is.
        guard case .browser = VoiceDecider.command(verdict(kind: "do_in_app", surface: "native_app"),
                                                   input: VoiceDecider.Input(clause: clause("go back"), silenceMs: 800, context: notes)) else {
            Issue.record("go back is a browser command"); return
        }
        // A goal keeps its normalised form.
        guard case .task(let goal, _, _, _, _) = VoiceDecider.command(verdict(kind: "do_in_app"), input: input("can you click on speech after Scott")) else {
            Issue.record("expected a task"); return
        }
        #expect(goal == "click on speech after Scott")
    }

    @Test func webAppNamesOpenDirectly() {
        // A web app Navi has a playbook for but no native app: straight to its home page.
        #expect(VoiceDecider.knownSiteToOpen("go to Google Drive")?.host == "drive.google.com")
        #expect(VoiceDecider.knownSiteToOpen("can you open google drive")?.host == "drive.google.com")
        #expect(VoiceDecider.knownSiteToOpen("go to youtube")?.host == "www.youtube.com")
        // Something to do once there: not navigation-only.
        #expect(VoiceDecider.knownSiteToOpen("go to google drive and open the budget sheet") == nil)
        #expect(VoiceDecider.knownSiteToOpen("open notes") == nil)
    }

    // MARK: Current tab vs. web search

    @Test @MainActor func pageActionsStayOnTheCurrentTab() {
        for t in ["click in the write a message area", "inside of the executive summary, click the message box", "scroll down",
                  "select the second option", "type hello in the search box", "close the dialog", "click on speech after Scott",
                  "please click the blue button", "check the first box", "reply to the top comment"] {
            #expect(TaskSurface.isPageAction(t), Comment(rawValue: t))
        }
        for t in ["search for cats", "look up the weather in Boston", "go to youtube", "find me a flight to Denver", "open the amazon website",
                  "send an email to Bob", "what is the capital of France", "write a poem", "pull up google docs"] {
            #expect(!TaskSurface.isPageAction(t), Comment(rawValue: t))
        }
        var front = FrontmostProbe.Info()
        front.bundleID = "com.google.Chrome"
        front.url = "https://docs.google.com/document/d/abc/edit"
        // Jev's start_from said "web search" for a fragment, but the words act on the page: stay.
        #expect(TaskSurface.startURL(task: "click on speech after Scott", frontmost: front, start: .webSearch) == front.url)
        #expect(TaskSurface.startURL(task: "search for cats", frontmost: front, start: .webSearch)?.contains("google.com/search") == true)
        #expect(TaskSurface.startURL(task: "open youtube", frontmost: front, start: .webSearch)?.contains("youtube.com") == true)
        // The voice executor's local rule: a browser in front + a page action ⇒ current tab, whatever came before.
        #expect(VoiceCommandExecutor.continuesOnCurrentTab(goal: "click the write a message area", surface: .browser, frontmostApp: "com.apple.Safari",
                                                           continues: false, lastWasBrowser: false))
        #expect(!VoiceCommandExecutor.continuesOnCurrentTab(goal: "go to youtube", surface: .browser, frontmostApp: "com.apple.Safari",
                                                            continues: true, lastWasBrowser: true))
        #expect(!VoiceCommandExecutor.continuesOnCurrentTab(goal: "click the button", surface: .browser, frontmostApp: "com.apple.Notes",
                                                            continues: true, lastWasBrowser: true))
    }

    // MARK: Local text guess

    private func field(_ label: String, role: String = "AXTextField") -> AXElement {
        AXElement(id: "e1", role: role, label: label, value: "", frame: CGRect(x: 0, y: 0, width: 200, height: 20), actions: ["AXPress"])
    }

    @Test func localGuessTypesWhatTheGoalSpellsOut() {
        #expect(FieldText.localGuess(goal: "type good night in the message box", field: field("Message"), history: []) == "good night")
        #expect(FieldText.localGuess(goal: "tell her I'm running late", field: field("Message"), history: []) == "I'm running late")
        #expect(FieldText.localGuess(goal: "text mom see you at 5", field: field("iMessage"), history: []) == "see you at 5")
        #expect(FieldText.localGuess(goal: "put 'hello' in the title", field: field("Title"), history: []) == "hello")
        #expect(FieldText.localGuess(goal: "look up Matt Armstrong", field: field("Search in Drive", role: "AXSearchField"), history: []) == "Matt Armstrong")
        #expect(FieldText.localGuess(goal: "search for lo-fi beats", field: field("Search"), history: []) == "lo-fi beats")
        // Described, not spelled out: no guess (Haiku, then vision, may compose it).
        #expect(FieldText.localGuess(goal: "write a love message to my mom", field: field("Message"), history: []) == nil)
        #expect(FieldText.localGuess(goal: "click the message area", field: field("Message"), history: []) == nil)
        // Already typed once: not again.
        let typed = [JevDriver.HistoryEntry(action: "Type ‘good night’ into ‘Message’", kind: "type_text", text: "good night", pageChanged: true)]
        #expect(FieldText.localGuess(goal: "type good night in the message box", field: field("Message"), history: typed) == nil)
    }

    // MARK: Submits in the state

    @Test func stateMarksTheLastActionAndSubmits() throws {
        let hist = [JevDriver.HistoryEntry(action: "Type ‘hi’ into ‘Message’", kind: "type_text", text: "hi", pageChanged: true),
                    JevDriver.HistoryEntry(action: "Press ↩", kind: "key", text: nil, pageChanged: true)]
        var input = JevDriverTests.input(history: hist)
        input.actionsTaken = 2
        let json = try #require(try JSONSerialization.jsonObject(with: Data(JevDriver.formatState(input).utf8)) as? [String: Any])
        let progress = try #require(json["progress"] as? [String: Any])
        #expect(progress["last_action"] as? String == "Press ↩")
        #expect(progress["last_action_submitted"] as? Bool == true)
        #expect(JevDriver.isSubmit(.init(action: "Click ‘Send’", kind: "click", text: nil, pageChanged: true)))
        #expect(!JevDriver.isSubmit(.init(action: "Click ‘Home’", kind: "click", text: nil, pageChanged: true)))
        #expect(!JevDriver.isSubmit(.init(action: "Press ⌘N", kind: "key", text: nil, pageChanged: true)))
    }

    // MARK: Browser chrome in the AX table

    @Test func browserChromeIsTidied() {
        func el(_ role: String, _ label: String, web: Bool) -> AXElement {
            AXElement(id: "", role: role, label: label, frame: CGRect(x: 0, y: 0, width: 40, height: 20), actions: ["AXPress"], isWebContent: web)
        }
        let raw = [
            el("AXButton", "close button", web: false), el("AXButton", "this button also has an action to zoom the window", web: false),
            el("AXButton", "Close", web: false), el("AXPopUpButton", "ChatGPT\nHas access to this site", web: false),
            el("AXRadioButton", "Stories • Instagram - Memory usage - 473 MB", web: false),
            el("AXButton", "Back", web: false), el("AXTextField", "Address and search bar", web: false),
            el("AXButton", "Close", web: true), el("AXLink", "greglav Verified", web: true), el("AXButton", "Install Instagram", web: false),
        ]
        let tidy = AXSnapshot.tidyBrowserChrome(raw)
        let labels = tidy.map(\.label)
        #expect(labels == ["Stories • Instagram", "Back", "Address and search bar", "Close", "greglav Verified"])
        #expect(tidy[0].path == "Browser UI › Tabs")
        #expect(tidy[1].path == "Browser UI")
        #expect(tidy[3].path == "")            // the page's own Close button is untouched
    }

    // MARK: Runner vs native browser

    @Test func runnerIsOnlyForChromiumAndUnavailabilityIsRecognised() {
        #expect(!NativeBrowser.runnerUsable(for: "com.apple.Safari"))
        #expect(!NativeBrowser.runnerUsable(for: "org.mozilla.firefox"))
        #expect(NativeBrowser.isRunnerUnavailable("Browser runtime not installed. Navi → Settings → Agent → Install jev-ultrafast."))
        #expect(NativeBrowser.isRunnerUnavailable("Runner exited (1). browser_harness: could not connect to Chrome"))
        #expect(!NativeBrowser.isRunnerUnavailable("Blocked: Jev answered BLOCKED"))
        #expect(AXSnapshotter.isBrowser("org.mozilla.firefox"))
        #expect(AXSnapshotter.isBrowser("company.thebrowser.Browser"))
        #expect(AXSnapshotter.isBrowser("com.apple.Safari"))
        #expect(!AXSnapshotter.isBrowser("com.apple.Notes"))
    }
}
