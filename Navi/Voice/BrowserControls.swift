import AppKit
import Foundation

/// Browser-level instructions that no page can carry out — "close the tab",
/// "go back", "reload", "next tab", "scroll down", "zoom in" — recognised
/// locally and done with one key press or wheel event in the browser. They
/// used to reach the page driver, which (correctly) found no element for them,
/// answered BLOCKED and paid for a Claude diagnosis to say so.
///
/// Every browser understands these shortcuts (Safari, Chrome, Arc, Firefox,
/// Edge, Brave, Orion…). Pure matching, unit-tested; the executor presses.
enum BrowserControls {
    struct Command: Equatable, Sendable {
        /// Shown in the island: "Closing the tab".
        var title: String
        /// `KeyCombo.parse` spelling; nil for wheel scrolling.
        var key: String?
        /// Wheel lines (negative = up) when `key` is nil.
        var scroll: Int = 0
        /// Closing a tab / window loses the page; the gate asks like it does for the agent.
        var isDestructive = false
    }

    /// (phrases, command). Longer phrases first within a group so "close all
    /// tabs" never matches "close tab"… it doesn't match at all (too much to lose).
    static let table: [(phrases: [String], command: Command)] = [
        (["close this tab", "close the tab", "close that tab", "close current tab", "close the current tab", "close tab", "close this page", "close the page"],
         Command(title: "Closing the tab", key: "cmd+w", isDestructive: true)),
        (["reopen the last closed tab", "reopen the closed tab", "reopen last tab", "reopen the last tab", "reopen that tab", "bring back the tab", "undo close tab"],
         Command(title: "Reopening the last closed tab", key: "cmd+shift+t")),
        (["open a new tab", "open new tab", "new tab", "make a new tab", "start a new tab", "another tab"],
         Command(title: "Opening a new tab", key: "cmd+t")),
        (["go back a page", "go back one page", "go back to the previous page", "back to the previous page", "previous page", "go back", "navigate back", "back up a page"],
         Command(title: "Going back", key: "cmd+[")),
        (["go forward a page", "go forward", "navigate forward", "forward a page", "next page"],
         Command(title: "Going forward", key: "cmd+]")),
        (["reload the page", "reload this page", "refresh the page", "refresh this page", "reload the tab", "refresh the tab", "reload", "refresh", "refresh it", "reload it"],
         Command(title: "Reloading", key: "cmd+r")),
        (["go to the next tab", "switch to the next tab", "next tab", "the next tab", "tab to the right"],
         Command(title: "Next tab", key: "ctrl+tab")),
        (["go to the previous tab", "switch to the previous tab", "previous tab", "the previous tab", "last tab", "tab to the left", "go to the last tab"],
         Command(title: "Previous tab", key: "ctrl+shift+tab")),
        (["scroll to the top", "scroll to top", "scroll all the way up", "go to the top of the page", "go to the top", "back to the top", "top of the page"],
         Command(title: "Scrolling to the top", key: "cmd+up")),
        (["scroll to the bottom", "scroll to bottom", "scroll all the way down", "go to the bottom of the page", "go to the bottom", "bottom of the page"],
         Command(title: "Scrolling to the bottom", key: "cmd+down")),
        (["scroll down a lot", "scroll way down", "scroll down a page", "page down"],
         Command(title: "Scrolling down", key: nil, scroll: 30)),
        (["scroll up a lot", "scroll way up", "scroll up a page", "page up"],
         Command(title: "Scrolling up", key: nil, scroll: -30)),
        (["scroll down a bit", "scroll down a little", "scroll down some", "scroll down more", "scroll down", "scroll further", "keep scrolling", "scroll more", "scroll a bit"],
         Command(title: "Scrolling down", key: nil, scroll: 10)),
        (["scroll up a bit", "scroll up a little", "scroll up some", "scroll up more", "scroll up", "scroll back up"],
         Command(title: "Scrolling up", key: nil, scroll: -10)),
        (["zoom in on the page", "zoom in", "make it bigger", "make the text bigger", "bigger text"],
         Command(title: "Zooming in", key: "cmd+=")),
        (["zoom out on the page", "zoom out", "make it smaller", "make the text smaller", "smaller text"],
         Command(title: "Zooming out", key: "cmd+-")),
        (["reset the zoom", "reset zoom", "normal zoom", "actual size"],
         Command(title: "Resetting zoom", key: "cmd+0")),
        (["go to the address bar", "focus the address bar", "click the address bar", "select the address bar", "address bar", "click on the url bar", "focus the url bar"],
         Command(title: "Focusing the address bar", key: "cmd+l")),
        (["bookmark this page", "bookmark the page", "bookmark this", "add a bookmark", "save this page as a bookmark"],
         Command(title: "Bookmarking the page", key: "cmd+d")),
        (["find on the page", "find on page", "find in page", "search the page", "search on this page", "search this page"],
         Command(title: "Find on page", key: "cmd+f")),
    ]

    /// Words that may surround the phrase without changing it.
    static let padding: Set<String> = ["please", "can", "could", "would", "you", "navi", "just", "now", "for", "me", "okay", "ok",
                                       "and", "then", "also", "quickly", "real", "quick", "in", "the", "browser", "chrome", "safari",
                                       "arc", "firefox", "this", "window", "here", "again", "one", "more", "time"]

    /// The browser command `text` asks for, if it is one and nothing more.
    /// "can you close this tab please" → close tab; "close the tab and open
    /// gmail" → nil (two instructions: the segmenter splits those first).
    static func match(_ text: String) -> Command? {
        let cleaned = " " + text.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9' ]"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ") + " "
        guard cleaned.count > 2, cleaned.split(separator: " ").count <= 10 else { return nil }
        for entry in table {
            for p in entry.phrases where cleaned.contains(" \(p) ") {
                // Everything besides the phrase must be padding.
                let rest = cleaned.replacingOccurrences(of: " \(p) ", with: " ")
                    .split(separator: " ").map(String.init)
                if rest.allSatisfy({ padding.contains($0) }) { return entry.command }
            }
        }
        return nil
    }

    /// Bundle ids of running browsers, frontmost first.
    @MainActor
    static func runningBrowsers() -> [NSRunningApplication] {
        let all = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier.map(AXSnapshotter.isBrowser) ?? false }
        let front = NSWorkspace.shared.frontmostApplication
        return all.sorted { a, b in a == front && b != front }
    }

    /// Carries out `command` in the browser in front (or the most recently
    /// used one, brought forward first). Returns what was done, or nil when
    /// no browser is running.
    @MainActor
    static func perform(_ command: Command, input: InputController) async -> String? {
        guard let browser = runningBrowsers().first else { return nil }
        if NSWorkspace.shared.frontmostApplication != browser {
            browser.activate()
            try? await Task.sleep(for: .milliseconds(250))
        }
        if let k = command.key, let combo = try? KeyCombo.parse(k) {
            await input.press(combo)
        } else if command.scroll != 0 {
            // Over the middle of the browser window, so the page (not a sidebar) scrolls.
            let pid = browser.processIdentifier
            let point: CGPoint? = await AXQueue.run {
                guard let win = AgentTarget.axWindow(pid: pid), let f = AXSnapshotter.frame(of: win) else { return nil }
                return CGPoint(x: f.midX, y: f.midY)
            }
            await input.scroll(command.scroll > 0 ? .down : .up, amount: abs(command.scroll), at: point)
        }
        return command.title
    }
}
