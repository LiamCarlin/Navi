import Foundation

/// The background knowledge Jev does not have: how each app is laid out, what
/// its shortcuts do *there*, the recipe for the goals people ask for, what
/// "done" looks like, and the wrong moves it keeps making.
///
/// Jev decides from structured state only (TypeSafe: "do not rely on knowledge
/// stored in model weights when current information can come from your own
/// knowledge base" — and "the model cannot choose an omitted value"). Without
/// this it treats every app like a web form: it clicked seven times to make a
/// Notes note that ⌘N creates, chose DONE in Calculator without pressing a key,
/// and messaged the open conversation instead of the person asked for.
///
/// A skill rides along in three places:
///   - `state.playbook` of every Jev request (`JevDriver.stateJSON`), trimmed to
///     the recipes that match the goal so the state stays small;
///   - the KEY head: the skill's shortcuts are *offered* (an app-specific combo
///     such as Outlook's ⌘2 can't be chosen unless it is a candidate) and the
///     generic combos get their meaning in this app;
///   - Claude's prompts (planner deep links, coach, text helper field hints).
///
/// Web apps carry `hosts` and are also handed to the browser runner
/// (`webPlaybooksJSON`), which injects the matching one per page.
struct AppSkill: Sendable, Equatable {
    var name: String
    var bundleIDs: [String]
    /// Web apps: host names this skill applies to (suffix match: "docs.google.com").
    var hosts: [String] = []
    /// Where things are and how the UI behaves — 3–6 short facts.
    var howItWorks: [String]
    /// Key combo (in `KeyCombo.parse` spelling) → what it does in this app.
    var shortcuts: [String: String] = [:]
    var recipes: [Recipe] = []
    /// Visible evidence that the usual goals are complete.
    var doneWhen: [String] = []
    /// Wrong moves seen in real runs.
    var avoid: [String] = []
    /// Hints for the text helper (what a field's value should look like here).
    var fieldHints: [String] = []
    /// Web apps: a page the planner can open directly instead of navigating there.
    var deepLinks: [String: String] = [:]

    struct Recipe: Sendable, Equatable {
        var goal: String
        /// Lower-case words; a recipe is offered when the goal contains any of them.
        var keywords: [String]
        /// Ordered steps in Jev's operation vocabulary (KEY, CLICK, TYPE_TEXT, SELECT, …).
        var steps: [String]
    }
}

enum AppSkills {
    // MARK: Lookup

    static func skill(bundleID: String?) -> AppSkill? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return all.first { $0.bundleIDs.contains(bundleID) }
    }

    static func skill(appName: String?) -> AppSkill? {
        guard let appName else { return nil }
        let wanted = appName.lowercased().replacingOccurrences(of: ".app", with: "").trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return nil }
        return all.first { $0.name.lowercased() == wanted }
    }

    /// The web skill for a URL: longest matching host suffix wins
    /// ("docs.google.com" over "google.com").
    static func skill(url: String?) -> AppSkill? {
        guard let url, let host = URL(string: url)?.host?.lowercased() else { return nil }
        var best: (AppSkill, Int)?
        for s in all {
            for h in s.hosts where host == h || host.hasSuffix("." + h) {
                if best == nil || h.count > best!.1 { best = (s, h.count) }
            }
        }
        return best?.0
    }

    /// The skill for what's on screen: a web app open in a browser beats the
    /// browser's own skill; otherwise the app's.
    static func skill(bundleID: String?, url: String?) -> AppSkill? {
        if let b = bundleID, AXSnapshotter.isBrowser(b), let web = skill(url: url) { return web }
        return skill(bundleID: bundleID)
    }

    // MARK: Playbook (state section)

    static let maxRecipes = 3

    /// Recipes whose keywords appear in the goal, best match first.
    static func recipes(for skill: AppSkill, goal: String) -> [AppSkill.Recipe] {
        let words = Set(goal.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let lower = goal.lowercased()
        let scored: [(recipe: AppSkill.Recipe, hits: Int, index: Int)] = skill.recipes.enumerated().compactMap { i, r in
            let hits = r.keywords.filter { k in k.contains(" ") ? lower.contains(k) : words.contains(k) }.count
            return hits > 0 ? (r, hits, i) : nil
        }
        // Most hits first; the library's own order breaks ties (deterministic state → cache hits).
        return scored.sorted { $0.hits != $1.hits ? $0.hits > $1.hits : $0.index < $1.index }.prefix(maxRecipes).map(\.recipe)
    }

    /// The compact JSON object Jev gets as `state.playbook`.
    static func playbook(for skill: AppSkill, goal: String) -> [String: Any] {
        var p: [String: Any] = ["app": skill.name, "how_it_works": skill.howItWorks]
        if !skill.shortcuts.isEmpty { p["shortcuts"] = skill.shortcuts }
        let matched = recipes(for: skill, goal: goal)
        if !matched.isEmpty { p["recipes"] = matched.map { ["goal": $0.goal, "steps": $0.steps] } }
        if !skill.doneWhen.isEmpty { p["done_when"] = skill.doneWhen }
        if !skill.avoid.isEmpty { p["avoid"] = skill.avoid }
        return p
    }

    /// KEY candidates for this app: the generic combos, re-described where the
    /// skill gives them an app-specific meaning, plus the skill's own combos.
    static func keyCombos(for skill: AppSkill?, base: [(String, String)] = JevDriver.keyCombos) -> [(String, String)] {
        guard let skill else { return base }
        var out: [(String, String)] = base.map { k, d in (k, skill.shortcuts[k].map { "\($0) (\(skill.name))" } ?? d) }
        let known = Set(base.map { $0.0.lowercased() })
        for (k, d) in skill.shortcuts.sorted(by: { $0.key < $1.key }) where !known.contains(k.lowercased()) {
            out.append((k, "\(d) (\(skill.name))"))
        }
        return out
    }

    // MARK: For Claude

    /// Deep links and app names for the planner: a step that starts on the
    /// right page needs no navigation at all.
    static func plannerReference() -> [String: Any] {
        var links: [String: String] = [:]
        for s in all { for (k, v) in s.deepLinks { links["\(s.name): \(k)"] = v } }
        let apps = all.filter { !$0.bundleIDs.isEmpty }.map(\.name).sorted()
        return ["known_apps": apps, "deep_links": links]
    }

    /// Every web skill as JSON for the browser runner (`NAVI_PLAYBOOKS_JSON`).
    static func webPlaybooksJSON() -> String {
        let web: [[String: Any]] = all.filter { !$0.hosts.isEmpty }.map { s in
            var d: [String: Any] = ["app": s.name, "hosts": s.hosts, "how_it_works": s.howItWorks,
                                    "recipes": s.recipes.map { ["goal": $0.goal, "keywords": $0.keywords, "steps": $0.steps] }]
            if !s.doneWhen.isEmpty { d["done_when"] = s.doneWhen }
            if !s.avoid.isEmpty { d["avoid"] = s.avoid }
            if !s.fieldHints.isEmpty { d["field_hints"] = s.fieldHints }
            return d
        }
        let data = (try? JSONSerialization.data(withJSONObject: web, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - The library

    static let all: [AppSkill] = native + web

    // Shared wording, so Jev sees the same phrasing across apps.
    private static let sendMessageDone = "the message appears as the newest bubble at the bottom of the conversation and the message field is empty again"

    static let native: [AppSkill] = [
        AppSkill(
            name: "Notes", bundleIDs: ["com.apple.Notes"],
            howItWorks: [
                "Three columns: folders on the left, the note list in the middle, the open note's text on the right (role AXTextArea).",
                "A note has no separate title field: its FIRST LINE is the title. Type the title into the note body, then press Return and continue with the body.",
                "A brand-new note is empty and its text area already has keyboard focus.",
                "Search field at the top of the note list filters notes by content.",
            ],
            shortcuts: ["cmd+n": "New note (empty note, cursor in the body)", "cmd+f": "Search notes",
                        "cmd+shift+n": "New folder", "cmd+return": "Finish editing / end the note",
                        "cmd+shift+t": "Make the current line a Title", "cmd+shift+b": "Make the current line Body text",
                        "cmd+shift+l": "Checklist", "cmd+shift+u": "Make the current line a Heading"],
            recipes: [
                .init(goal: "create a new note", keywords: ["new note", "create", "start", "new", "blank"],
                      steps: ["KEY cmd+n", "DONE when an empty note with a focused text area is open"]),
                .init(goal: "title a note / write something in a note", keywords: ["title", "name", "write", "type", "call", "put"],
                      steps: ["If no empty note is open: KEY cmd+n", "TYPE_TEXT the title into the note's text area (AXTextArea) — the first line becomes the title",
                              "KEY Return", "TYPE_TEXT the rest of the content if the goal gives any"]),
                .init(goal: "find a note", keywords: ["find", "open", "search", "look"],
                      steps: ["TYPE_TEXT the words into the Search field", "CLICK the matching note in the note list"]),
            ],
            doneWhen: ["the note list shows a note whose first line is the requested title",
                       "the requested text is visible in the note body"],
            avoid: ["Do not type the title into the Search field or into a note-list cell.",
                    "Do not click the note body repeatedly: after one click (or ⌘N) it is already focused — type.",
                    "Do not choose DONE before the requested text is visible in the note."],
            fieldHints: ["The note body's first line is the title; for 'title it X' the value is X."]
        ),
        AppSkill(
            name: "Messages", bundleIDs: ["com.apple.MobileSMS", "com.apple.iChat"],
            howItWorks: [
                "Left sidebar lists conversations (each cell: contact name + last message + time). The right pane shows the open conversation with the message field ('iMessage' / 'Text Message') at the bottom.",
                "Messaging someone who is NOT the open conversation needs a new message: ⌘N opens a blank conversation with the 'To:' field focused.",
                "Typing a name in 'To:' shows contact suggestions; Return accepts the top suggestion (a blue pill appears). Then the message field gets the text.",
                "Return in the message field SENDS the message (irreversible).",
                "Search at the top of the sidebar filters conversations and messages; it does not start a conversation.",
            ],
            shortcuts: ["cmd+n": "New message (blank conversation, To: field focused)", "cmd+f": "Search conversations",
                        "return": "In the message field: SEND. In the To: field: accept the highlighted contact"],
            recipes: [
                .init(goal: "send a message / text to a person", keywords: ["send", "text", "message", "imessage", "tell", "let", "reply", "say"],
                      steps: ["If the open conversation is not with that person: KEY cmd+n",
                              "TYPE_TEXT the person's name into the 'To:' field", "KEY Return to accept the contact suggestion",
                              "TYPE_TEXT the message into the message field at the bottom ('iMessage' or 'Text Message')",
                              "KEY Return to send", "DONE when the sent bubble is visible"]),
                .init(goal: "reply in the open conversation", keywords: ["reply", "respond", "answer"],
                      steps: ["TYPE_TEXT the reply into the message field at the bottom", "KEY Return"]),
                .init(goal: "open a conversation / read messages", keywords: ["open", "read", "show", "check", "what did", "last message"],
                      steps: ["CLICK the conversation cell with that person's name in the sidebar", "DONE when the conversation is showing"]),
            ],
            doneWhen: [sendMessageDone],
            avoid: ["Do not click an existing conversation to message a DIFFERENT person — use ⌘N.",
                    "Do not type the recipient's name into the Search field.",
                    "Do not press Return in the message field until the text is complete (Return sends).",
                    "'No Results' after typing a name in To: means the contact is unknown — type their phone number or email instead, never guess."],
            fieldHints: ["The To: field takes only the contact's name (or number/email), nothing else.",
                         "The message field takes the message text exactly as the goal states it, without a greeting the goal did not ask for."]
        ),
        AppSkill(
            name: "Mail", bundleIDs: ["com.apple.mail"],
            howItWorks: [
                "Mailboxes on the left, message list in the middle, the selected message on the right.",
                "⌘N opens a new message window with 'To:', 'Cc:', 'Subject:' fields and the body; the To: field is focused first.",
                "In To:, typing a name shows suggestions; Return (or a comma) accepts the top one.",
                "⌘⇧D sends the message that is open (irreversible). The Send button is the paper-plane toolbar button.",
                "⌘R replies to the selected message; ⌘⇧F forwards it.",
            ],
            shortcuts: ["cmd+n": "New email (To: focused)", "cmd+shift+d": "Send the open email", "cmd+r": "Reply to the selected email",
                        "cmd+shift+r": "Reply all", "cmd+shift+f": "Forward", "cmd+option+f": "Search mailbox", "cmd+delete": "Delete selected email",
                        "cmd+shift+n": "Get new mail"],
            recipes: [
                .init(goal: "send an email", keywords: ["send", "email", "mail", "write", "compose"],
                      steps: ["KEY cmd+n", "TYPE_TEXT the recipient into 'To:'", "KEY Tab", "KEY Tab (past Cc)", "TYPE_TEXT the subject into 'Subject:'",
                              "CLICK the body (the large text area) and TYPE_TEXT the body", "KEY cmd+shift+d to send", "DONE when the compose window is gone"]),
                .init(goal: "reply to an email", keywords: ["reply", "respond", "answer"],
                      steps: ["CLICK the message in the list if not selected", "KEY cmd+r", "TYPE_TEXT the reply into the body", "KEY cmd+shift+d"]),
                .init(goal: "find / open an email", keywords: ["find", "open", "search", "look", "from", "latest", "newest"],
                      steps: ["KEY cmd+option+f", "TYPE_TEXT the search words", "KEY Return", "CLICK the matching message in the list"]),
            ],
            doneWhen: ["after sending: the compose window has closed", "after opening: the message body is showing on the right"],
            avoid: ["Do not type the recipient into the mailbox search field.", "Do not press Send before To, Subject and body are filled."],
            fieldHints: ["Subject is one short line; the body is the full message."]
        ),
        AppSkill(
            name: "Calendar", bundleIDs: ["com.apple.iCal"],
            howItWorks: [
                "Toolbar: Day/Week/Month/Year view buttons, ◀ Today ▶ arrows, a '+' button that creates an event, and a search field.",
                "⌘N creates a new event on the selected day with its title field focused; Return saves it. Double-clicking a time slot in Day/Week view also creates an event there.",
                "The event inspector (popover) has: title, location, 'all-day' checkbox, starts/ends date & time fields, repeat, alert, notes.",
                "Date/time fields are editable text: click the hour, type the number, Tab to minutes, Tab to AM/PM. ⌘T jumps to today.",
                "Search (⌘F / top-right field) finds events by title.",
            ],
            shortcuts: ["cmd+n": "New event on the selected day (title focused)", "cmd+t": "Go to today", "cmd+1": "Day view", "cmd+2": "Week view",
                        "cmd+3": "Month view", "cmd+4": "Year view", "cmd+f": "Search events", "cmd+right": "Next day/week/month", "cmd+left": "Previous day/week/month",
                        "cmd+shift+t": "Go to a specific date"],
            recipes: [
                .init(goal: "create an event / meeting / appointment", keywords: ["create", "add", "schedule", "event", "meeting", "appointment", "book", "put", "set up"],
                      steps: ["KEY cmd+n (or CLICK the '+' toolbar button)", "TYPE_TEXT the event title into the focused title field",
                              "Set the date and time fields in the inspector (click the field, type the value)", "KEY Return to save", "DONE when the event shows on the calendar grid"]),
                .init(goal: "check what's on / find an event", keywords: ["what", "when", "check", "find", "show", "next", "today", "tomorrow"],
                      steps: ["KEY cmd+t for today, or CLICK ◀/▶ to reach the day", "DONE when that day's events are visible"]),
            ],
            doneWhen: ["the new event is drawn on the calendar grid with the requested title"],
            avoid: ["Do not click 'next day' repeatedly to find a date — use ⌘⇧T (go to date) or the Month view.",
                    "Do not create a second event when one with the title already exists on that day.",
                    "Set the time in the inspector fields, not by clicking around the grid."],
            fieldHints: ["Event title is a short phrase (e.g. 'Dinner with Sam'), never a sentence about the task."]
        ),
        AppSkill(
            name: "Reminders", bundleIDs: ["com.apple.reminders"],
            howItWorks: [
                "Lists on the left (Today, Scheduled, All, Flagged, then custom lists); the selected list's reminders on the right.",
                "⌘N adds a reminder to the selected list with its title focused; Return saves it. ⌘⇧N makes a new list.",
                "Each reminder row has a circle checkbox (click = complete), the title, and an 'i' info button for date, time, notes, flag.",
            ],
            shortcuts: ["cmd+n": "New reminder in the selected list (title focused)", "cmd+shift+n": "New list", "cmd+shift+i": "Show reminder info (date, time, notes)",
                        "cmd+shift+f": "Flag the reminder", "cmd+e": "Indent (make sub-reminder)"],
            recipes: [
                .init(goal: "add a reminder", keywords: ["remind", "reminder", "add", "create", "todo", "to do", "task"],
                      steps: ["CLICK the list if a specific one is named", "KEY cmd+n", "TYPE_TEXT the reminder title", "KEY Return",
                              "DONE when the reminder row appears in the list"]),
                .init(goal: "complete a reminder", keywords: ["complete", "done", "check off", "finish", "mark"],
                      steps: ["CLICK the circle checkbox at the left of that reminder's row"]),
            ],
            doneWhen: ["the reminder row with the requested title is listed"],
            avoid: ["Do not type the reminder into the search field."]
        ),
        AppSkill(
            name: "Finder", bundleIDs: ["com.apple.finder"],
            howItWorks: [
                "Sidebar (Favorites: AirDrop, Recents, Applications, Desktop, Documents, Downloads; iCloud; Locations) on the left; the folder contents on the right.",
                "⌘⇧G opens 'Go to Folder' with a path field; ⌘N opens a new Finder window; ⌘⇧N makes a new folder named 'untitled folder' with its name selected — type the name and press Return.",
                "Return on a selected item RENAMES it; ⌘O or ⌘↓ opens it. Space shows a Quick Look preview.",
                "The search field (⌘F / top right) searches the Mac; results appear in the same window.",
                "Files are moved by ⌘C then ⌘⌥V (move), copied with ⌘C/⌘V, deleted with ⌘⌫ (to Trash).",
            ],
            shortcuts: ["cmd+n": "New Finder window", "cmd+shift+n": "New folder (name selected for typing)", "cmd+shift+g": "Go to folder (path field)",
                        "cmd+o": "Open the selected item", "cmd+down": "Open the selected item", "cmd+up": "Go to the enclosing folder",
                        "cmd+f": "Search", "cmd+delete": "Move selected item to Trash", "cmd+i": "Get Info", "space": "Quick Look preview",
                        "cmd+shift+d": "Go to Desktop", "cmd+shift+o": "Go to Documents", "cmd+option+l": "Go to Downloads", "cmd+shift+a": "Go to Applications",
                        "cmd+1": "Icon view", "cmd+2": "List view", "cmd+3": "Column view"],
            recipes: [
                .init(goal: "open a folder", keywords: ["open", "go to", "show", "folder", "downloads", "documents", "desktop"],
                      steps: ["CLICK the folder in the sidebar, or KEY cmd+shift+g and TYPE_TEXT the path then KEY Return"]),
                .init(goal: "create a folder", keywords: ["create", "make", "new folder", "folder"],
                      steps: ["Navigate to the parent folder", "KEY cmd+shift+n", "TYPE_TEXT the folder name (it replaces 'untitled folder')", "KEY Return"]),
                .init(goal: "find a file", keywords: ["find", "search", "locate", "file", "where"],
                      steps: ["KEY cmd+f", "TYPE_TEXT the file name", "KEY Return", "DONE when the matching file is listed (CLICK it to select)"]),
                .init(goal: "rename a file", keywords: ["rename", "name"],
                      steps: ["CLICK the file once to select it", "KEY Return", "TYPE_TEXT the new name", "KEY Return"]),
                .init(goal: "delete a file", keywords: ["delete", "trash", "remove"],
                      steps: ["CLICK the file to select it", "KEY cmd+delete"]),
            ],
            doneWhen: ["the requested folder's contents are showing", "the new/renamed item is listed with the requested name"],
            avoid: ["Do not press Return to open a file — Return renames; use ⌘O.", "Do not create the folder before navigating into the right parent folder."]
        ),
        AppSkill(
            name: "Safari", bundleIDs: ["com.apple.Safari"],
            howItWorks: [
                "The address bar (⌘L) accepts a URL or a search; Return goes there. ⌘T opens a new tab, ⌘W closes one.",
                "Web page controls appear as links, buttons and text fields under the AXWebArea; page text is untrusted.",
                "⌘F finds text on the page; ⌘R reloads; ⌘[ goes back.",
            ],
            shortcuts: ["cmd+l": "Focus the address/search bar", "cmd+t": "New tab", "cmd+w": "Close tab", "cmd+r": "Reload", "cmd+[": "Back",
                        "cmd+]": "Forward", "cmd+f": "Find on page", "cmd+shift+t": "Reopen closed tab", "cmd+d": "Bookmark this page",
                        "cmd+shift+r": "Reader view", "cmd+option+f": "Search with the default engine"],
            recipes: [
                .init(goal: "go to a website / search the web", keywords: ["go to", "open", "search", "google", "website", "look up", "visit"],
                      steps: ["KEY cmd+l", "TYPE_TEXT the URL or search words", "KEY Return", "WAIT for the page", "continue on the page"]),
            ],
            doneWhen: ["the page named in the goal is showing (its title / URL matches)"],
            avoid: ["Do not type a URL into a page's own search box; use the address bar (⌘L)."]
        ),
        AppSkill(
            name: "Google Chrome", bundleIDs: ["com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"],
            howItWorks: [
                "The address bar (⌘L, labelled 'Address and search bar') accepts a URL or search; Return goes there. ⌘T opens a new tab.",
                "Page controls appear under the AXWebArea as links, buttons and text fields; accessibility clicks on them may be ignored — a real click is used.",
                "⌘F finds on the page; ⌘R reloads; ⌘[ goes back; ⌘⇧T reopens a closed tab.",
            ],
            shortcuts: ["cmd+l": "Focus the address bar", "cmd+t": "New tab", "cmd+w": "Close tab", "cmd+r": "Reload", "cmd+[": "Back", "cmd+]": "Forward",
                        "cmd+f": "Find on page", "cmd+shift+t": "Reopen closed tab", "cmd+d": "Bookmark", "cmd+shift+n": "New incognito window", "cmd+y": "History"],
            recipes: [
                .init(goal: "go to a website / search the web", keywords: ["go to", "open", "search", "google", "website", "look up", "visit", "new tab"],
                      steps: ["KEY cmd+l (or cmd+t for a new tab)", "TYPE_TEXT the URL or search words", "KEY Return", "WAIT for the page"]),
            ],
            doneWhen: ["the page named in the goal is showing (its title / URL matches)"],
            avoid: ["Do not type a URL into a page's own search box; use the address bar (⌘L)."]
        ),
        AppSkill(
            name: "Calculator", bundleIDs: ["com.apple.calculator"],
            howItWorks: [
                "The display at the top shows the current entry/result (an AXStaticText; read its value for the answer).",
                "Digits and operators are buttons: 0–9, '.', '+', '−' (subtract), '×' (multiply), '÷' (divide), '=' (equals), 'AC'/'C' (clear), '%', '±'.",
                "The keyboard works too: type digits, * for multiply, / for divide, - and +, then Return for equals. ⌘C copies the result.",
                "Nothing is computed until '=' (or Return) is pressed; a fresh Calculator showing 0 has computed nothing.",
            ],
            shortcuts: ["return": "Equals (=) — compute the result", "escape": "Clear (AC)", "cmd+c": "Copy the displayed result", "cmd+1": "Basic mode", "cmd+2": "Scientific mode"],
            recipes: [
                .init(goal: "compute an arithmetic expression", keywords: ["compute", "calculate", "times", "plus", "minus", "divided", "multiply", "add", "subtract", "what is", "what's", "x", "*", "+", "/", "percent", "square", "root", "sum"],
                      steps: ["KEY escape to clear if the display is not 0", "CLICK the digit buttons of the first number in order (e.g. '1' then '2')",
                              "CLICK the operator button ('×', '+', '−', '÷')", "CLICK the digits of the second number", "CLICK '=' (or KEY return)",
                              "DONE only when the display shows the result (not the last operand)"]),
            ],
            doneWhen: ["the display shows the computed result, e.g. 408 for 12 × 34"],
            avoid: ["Never choose DONE while the display still shows 0 or an operand — the answer must be visible.",
                    "Do not click '=' before both numbers and the operator are entered."]
        ),
        AppSkill(
            name: "TextEdit", bundleIDs: ["com.apple.TextEdit"],
            howItWorks: [
                "⌘N opens a new untitled document whose text area is focused; type directly. ⌘S saves (a sheet asks for the name and location the first time).",
                "The document body is one AXTextArea; there is no separate title — the title comes from the file name at save time.",
            ],
            shortcuts: ["cmd+n": "New document (text area focused)", "cmd+s": "Save (name sheet on first save)", "cmd+o": "Open a file", "cmd+shift+t": "Toggle rich/plain text", "cmd+a": "Select all"],
            recipes: [
                .init(goal: "write text in a document", keywords: ["write", "type", "create", "new", "document", "note", "text"],
                      steps: ["KEY cmd+n if no document is open", "TYPE_TEXT the content into the text area", "DONE when the text is visible"]),
                .init(goal: "save a document", keywords: ["save"],
                      steps: ["KEY cmd+s", "TYPE_TEXT the file name into 'Save As:'", "KEY Return"]),
            ],
            doneWhen: ["the requested text is visible in the document"],
            avoid: ["Do not click the text area repeatedly; it is focused after ⌘N."]
        ),
        AppSkill(
            name: "Music", bundleIDs: ["com.apple.Music"],
            howItWorks: [
                "Sidebar: Home, New, Radio, Search; then Library (Recently Added, Artists, Albums, Songs, Playlists). The player controls and the 'Now Playing' title are at the top.",
                "The Search field (⌘F) searches your library and Apple Music; results list songs/albums with a play button (▶) on hover — Return on a selected song plays it.",
                "Space toggles play/pause; ⌘→ skips to the next track.",
            ],
            shortcuts: ["space": "Play / pause", "cmd+f": "Search", "cmd+right": "Next track", "cmd+left": "Previous track", "cmd+up": "Volume up", "cmd+down": "Volume down",
                        "cmd+l": "Show the current song", "cmd+n": "New playlist"],
            recipes: [
                .init(goal: "play a song / artist / album / playlist", keywords: ["play", "listen", "put on", "song", "music", "album", "artist", "playlist"],
                      steps: ["KEY cmd+f", "TYPE_TEXT the song/artist name into the search field", "KEY Return", "CLICK the matching result's play button or the result then KEY Return",
                              "DONE when the Now Playing area shows that title"]),
                .init(goal: "pause / resume / skip", keywords: ["pause", "stop", "resume", "skip", "next", "previous"],
                      steps: ["KEY space (pause/resume) or KEY cmd+right (next)"]),
            ],
            doneWhen: ["the Now Playing title at the top is the requested song/artist and the pause button is showing"],
            avoid: ["Do not choose DONE when only search results are showing — the song must be playing."]
        ),
        AppSkill(
            name: "Spotify", bundleIDs: ["com.spotify.client"],
            howItWorks: [
                "Electron app: the search field is at the top ('What do you want to play?'); results show Top result, Songs, Artists, Albums with a green play button.",
                "The player bar at the bottom shows the current track and play/pause; Space toggles playback.",
            ],
            shortcuts: ["cmd+l": "Focus the search field", "space": "Play / pause", "cmd+right": "Next track", "cmd+left": "Previous track", "cmd+shift+left": "Back", "cmd+up": "Volume up"],
            recipes: [
                .init(goal: "play something", keywords: ["play", "listen", "put on", "song", "music", "album", "artist", "playlist"],
                      steps: ["KEY cmd+l", "TYPE_TEXT the name", "KEY Return", "CLICK the green play button of the top result", "DONE when the player bar shows it"]),
            ],
            doneWhen: ["the bottom player bar shows the requested title and a pause button"],
            avoid: ["Do not choose DONE with only results on screen."]
        ),
        AppSkill(
            name: "Maps", bundleIDs: ["com.apple.Maps"],
            howItWorks: [
                "The search field is in the sidebar ('Search Maps'); results list places. Selecting a place shows its card with a 'Directions' button.",
                "Directions view: 'From' (defaults to 'My Location') and 'To' fields, transport mode buttons (Drive, Walk, Transit, Cycle), and a 'Go' button per route; the travel time is written on each route card.",
                "A 'Leave at' / 'Arrive by' control under the fields sets the departure time.",
            ],
            shortcuts: ["cmd+f": "Focus the search field", "cmd+r": "Directions", "cmd+l": "Current location", "cmd+plus": "Zoom in", "cmd+minus": "Zoom out"],
            recipes: [
                .init(goal: "get directions / travel time", keywords: ["directions", "drive", "how long", "route", "get to", "travel", "distance", "from", "to"],
                      steps: ["KEY cmd+r (Directions)", "TYPE_TEXT the destination into 'To'", "KEY Return", "TYPE_TEXT the origin into 'From' if the goal names one",
                              "CLICK the transport mode if requested", "DONE when route cards with times are showing"]),
                .init(goal: "find a place", keywords: ["find", "search", "where", "near", "nearest", "show"],
                      steps: ["KEY cmd+f", "TYPE_TEXT the place", "KEY Return", "DONE when results/the place card show"]),
            ],
            doneWhen: ["the route cards show the travel time", "the place card is open"],
            avoid: ["Do not type the destination into 'From'."]
        ),
        AppSkill(
            name: "Contacts", bundleIDs: ["com.apple.AddressBook"],
            howItWorks: ["Search field at the top-left filters the list; selecting a contact shows the card with phone/email. ⌘N creates a new contact with First name focused."],
            shortcuts: ["cmd+n": "New contact", "cmd+f": "Search contacts", "cmd+l": "Edit the card"],
            recipes: [
                .init(goal: "find someone's number / email", keywords: ["find", "number", "phone", "email", "contact", "look up"],
                      steps: ["KEY cmd+f", "TYPE_TEXT the name", "CLICK the matching contact", "DONE when the card is showing"]),
                .init(goal: "add a contact", keywords: ["add", "create", "new contact", "save"],
                      steps: ["KEY cmd+n", "TYPE_TEXT the first name", "KEY Tab", "TYPE_TEXT the last name", "fill the phone/email fields", "CLICK Done"]),
            ],
            doneWhen: ["the contact card with the requested name is showing"]
        ),
        AppSkill(
            name: "Photos", bundleIDs: ["com.apple.Photos"],
            howItWorks: ["Sidebar: Library, Memories, Favorites, Albums…; the search field (⌘F) finds photos by people, places, dates and content. Double-click (or Return) opens a photo; ⌘I shows info."],
            shortcuts: ["cmd+f": "Search photos", "cmd+i": "Info", "cmd+n": "New album", "return": "Open the selected photo", "escape": "Back to the grid"],
            recipes: [
                .init(goal: "find photos of something", keywords: ["find", "show", "photos", "pictures", "search", "look"],
                      steps: ["KEY cmd+f", "TYPE_TEXT what to find", "KEY Return", "DONE when matching photos are showing"]),
            ],
            doneWhen: ["the grid shows the matching photos"]
        ),
        AppSkill(
            name: "Preview", bundleIDs: ["com.apple.Preview"],
            howItWorks: ["Shows PDFs and images. ⌘F searches the document; the sidebar (⌘⌥1) shows thumbnails; ⌘S saves, ⌘⇧S exports."],
            shortcuts: ["cmd+f": "Find in document", "cmd+o": "Open a file", "cmd+s": "Save", "cmd+shift+s": "Export", "cmd+option+1": "Toggle thumbnails sidebar"],
            doneWhen: ["the requested page/text is showing"]
        ),
        AppSkill(
            name: "System Settings", bundleIDs: ["com.apple.systempreferences"],
            howItWorks: [
                "Sidebar lists panes (Wi-Fi, Bluetooth, Network, Notifications, Sound, Focus, Screen Time, General, Appearance, Accessibility, Control Center, Siri, Privacy & Security, Desktop & Dock, Displays, Wallpaper, Screen Saver, Battery, Lock Screen, Touch ID, Users & Groups, Internet Accounts, Keyboard, Trackpad, Mouse, Printers).",
                "The search field at the top of the sidebar jumps to a setting by name.",
                "Toggles are switches (AXCheckBox/AXSwitch): do not click one that is already in the requested state.",
            ],
            shortcuts: ["cmd+f": "Search settings"],
            recipes: [
                .init(goal: "change a setting", keywords: ["turn", "enable", "disable", "set", "change", "switch", "on", "off", "wifi", "bluetooth", "dark", "volume", "wallpaper"],
                      steps: ["CLICK the pane in the sidebar (or KEY cmd+f and TYPE_TEXT the setting name, then CLICK the result)",
                              "CLICK the switch/control for the setting", "DONE when the control shows the requested state"]),
            ],
            doneWhen: ["the switch/control shows the requested state"],
            avoid: ["Do not toggle a switch that already shows the requested state."]
        ),
        AppSkill(
            name: "Terminal", bundleIDs: ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty"],
            howItWorks: ["A shell prompt in a text area: type the command and press Return to run it; output appears below. ⌘T opens a new tab, ⌘N a new window, ⌘K clears."],
            shortcuts: ["return": "Run the typed command", "cmd+t": "New tab", "cmd+n": "New window", "cmd+k": "Clear", "ctrl+c": "Interrupt the running command"],
            recipes: [
                .init(goal: "run a command", keywords: ["run", "execute", "command", "type", "ls", "cd", "git", "brew", "npm"],
                      steps: ["TYPE_TEXT the command into the terminal text area", "KEY Return", "DONE when the output is visible"]),
            ],
            doneWhen: ["the command's output (or a new prompt) is visible below the command"],
            avoid: ["Do not press Return twice."]
        ),
        AppSkill(
            name: "Outlook", bundleIDs: ["com.microsoft.Outlook"],
            howItWorks: [
                "One window with module switcher buttons at the bottom-left / sidebar: Mail, Calendar, People, Tasks. ⌘1 Mail, ⌘2 Calendar, ⌘3 People, ⌘4 Tasks.",
                "Mail: folders on the left, message list, reading pane. ⌘N = new email (To: focused); ⌘Return sends.",
                "Calendar: ⌘N = new event with Subject focused; the event window has Start/End date and time fields and 'Save & Close'. Day/Work Week/Week/Month buttons switch views.",
                "In the Calendar module 'next day' arrows move the view; they never create events.",
            ],
            shortcuts: ["cmd+1": "Switch to Mail", "cmd+2": "Switch to Calendar", "cmd+3": "Switch to People (contacts)", "cmd+4": "Switch to Tasks",
                        "cmd+n": "New item in the current module (email / event / contact)", "cmd+return": "Send the open email", "cmd+r": "Reply", "cmd+shift+r": "Reply all",
                        "cmd+j": "Forward", "cmd+option+f": "Search", "cmd+t": "Go to today (Calendar)"],
            recipes: [
                .init(goal: "create a calendar event", keywords: ["calendar", "event", "meeting", "schedule", "appointment", "invite"],
                      steps: ["KEY cmd+2 to switch to Calendar (if the window is in Mail)", "KEY cmd+n", "TYPE_TEXT the subject into the focused Subject field",
                              "Set the Start date/time fields (CLICK the field, TYPE_TEXT the value)", "CLICK 'Save & Close'", "DONE when the event shows on the calendar"]),
                .init(goal: "send an email", keywords: ["send", "email", "mail", "write"],
                      steps: ["KEY cmd+1 to switch to Mail", "KEY cmd+n", "TYPE_TEXT the recipient into To", "KEY Tab", "TYPE_TEXT the subject", "CLICK the body and TYPE_TEXT it", "KEY cmd+return to send"]),
            ],
            doneWhen: ["the new event appears on the calendar grid", "the sent email is no longer open"],
            avoid: ["Do not stay BLOCKED in the Mail module when the goal is a calendar task — press ⌘2.",
                    "Do not click 'next day' repeatedly; set the date in the event's Start field."]
        ),
        AppSkill(
            name: "Slack", bundleIDs: ["com.tinyspeck.slackmacgap"],
            howItWorks: [
                "Electron app. Sidebar lists channels (#name) and direct messages; the message composer is at the bottom of the open channel/DM.",
                "⌘K opens the quick switcher: type a channel or person name, Return opens it. Return in the composer sends; Shift+Return adds a line.",
            ],
            shortcuts: ["cmd+k": "Quick switcher: jump to a channel or person", "cmd+n": "New message (choose recipient)", "cmd+f": "Search", "return": "Send the composed message",
                        "shift+return": "New line in the composer", "cmd+shift+a": "All unreads", "cmd+[": "Back"],
            recipes: [
                .init(goal: "message a person or channel", keywords: ["send", "message", "dm", "tell", "post", "slack", "channel", "reply"],
                      steps: ["KEY cmd+k", "TYPE_TEXT the person or channel name", "KEY Return", "TYPE_TEXT the message into the composer at the bottom", "KEY Return to send",
                              "DONE when the message shows in the conversation"]),
            ],
            doneWhen: [sendMessageDone],
            avoid: ["Do not send to the channel that happens to be open unless it is the one asked for — use ⌘K first."]
        ),
        AppSkill(
            name: "Discord", bundleIDs: ["com.hnc.Discord"],
            howItWorks: ["Electron app. Servers on the far left, channels/DMs next, the chat with its composer at the bottom. ⌘K opens the quick switcher (type a channel or friend, Return). Return sends."],
            shortcuts: ["cmd+k": "Quick switcher", "return": "Send the message", "shift+return": "New line", "cmd+f": "Search"],
            recipes: [
                .init(goal: "message someone / a channel", keywords: ["send", "message", "dm", "tell", "post", "channel"],
                      steps: ["KEY cmd+k", "TYPE_TEXT the name", "KEY Return", "TYPE_TEXT the message into the composer", "KEY Return"]),
            ],
            doneWhen: [sendMessageDone]
        ),
        AppSkill(
            name: "zoom.us", bundleIDs: ["us.zoom.xos"],
            howItWorks: ["Home tab: New Meeting, Join, Schedule buttons. Join asks for a meeting ID; Schedule opens a form with Topic, date, time. In a meeting: Mute (⌘⇧A), Video (⌘⇧V), Leave."],
            shortcuts: ["cmd+shift+a": "Mute / unmute", "cmd+shift+v": "Start / stop video", "cmd+j": "Join a meeting", "cmd+ctrl+v": "Start a meeting", "cmd+w": "Leave / end meeting"],
            recipes: [
                .init(goal: "join a meeting", keywords: ["join", "meeting", "call"],
                      steps: ["CLICK 'Join'", "TYPE_TEXT the meeting ID", "CLICK 'Join'"]),
                .init(goal: "start a meeting", keywords: ["start", "new meeting", "host"], steps: ["CLICK 'New Meeting'"]),
            ]
        ),
        AppSkill(
            name: "FaceTime", bundleIDs: ["com.apple.FaceTime"],
            howItWorks: ["'New FaceTime' button opens a sheet with a 'To:' field; type a name, Return picks the contact, then the green FaceTime (or Audio) button starts the call."],
            shortcuts: ["cmd+n": "New FaceTime (To: field)"],
            recipes: [
                .init(goal: "call someone", keywords: ["call", "facetime", "ring", "video"],
                      steps: ["KEY cmd+n", "TYPE_TEXT the person's name into To:", "KEY Return", "CLICK the 'FaceTime' (video) or 'Audio' button"]),
            ],
            doneWhen: ["the call window shows 'Connecting…' or the other person"]
        ),
        AppSkill(
            name: "Freeform", bundleIDs: ["com.apple.freeform"],
            howItWorks: ["A canvas app: boards in the sidebar, an infinite canvas with a toolbar (sticky note, shapes, text, media). Most of the canvas is not in the accessibility tree — prefer NEED_VISION for drawing."],
            shortcuts: ["cmd+n": "New board", "cmd+t": "Text box", "cmd+shift+n": "Sticky note"],
            avoid: ["Do not choose BLOCKED for canvas work; choose NEED_VISION."]
        ),
        AppSkill(
            name: "Pages", bundleIDs: ["com.apple.iWork.Pages"],
            howItWorks: ["⌘N opens the template chooser: CLICK 'Blank' then 'Create' to get an empty document whose body is focused. The body is an AXTextArea; ⌘S saves with a name sheet."],
            shortcuts: ["cmd+n": "New document (template chooser)", "cmd+s": "Save", "cmd+shift+e": "Export", "cmd+a": "Select all"],
            recipes: [
                .init(goal: "write a document", keywords: ["write", "create", "document", "type", "letter", "essay"],
                      steps: ["KEY cmd+n", "CLICK 'Blank'", "CLICK 'Create'", "TYPE_TEXT the content into the body", "DONE when the text is visible"]),
            ],
            doneWhen: ["the requested text is visible in the document body"]
        ),
        AppSkill(
            name: "Numbers", bundleIDs: ["com.apple.iWork.Numbers"],
            howItWorks: ["⌘N opens the template chooser: CLICK 'Blank' then 'Create'. Cells are AXCell elements (labelled by their A1-style address); CLICK a cell then TYPE_TEXT and KEY Return to enter a value."],
            shortcuts: ["cmd+n": "New spreadsheet", "cmd+s": "Save", "return": "Confirm the cell and move down", "tab": "Confirm the cell and move right"],
            recipes: [
                .init(goal: "enter values in a spreadsheet", keywords: ["enter", "put", "spreadsheet", "cell", "table", "column", "row", "sum"],
                      steps: ["KEY cmd+n and CLICK 'Blank' → 'Create' if no sheet is open", "CLICK the cell", "TYPE_TEXT the value", "KEY Return", "repeat for the next cell"]),
            ]
        ),
        AppSkill(
            name: "Keynote", bundleIDs: ["com.apple.iWork.Keynote"],
            howItWorks: ["⌘N opens the theme chooser (CLICK a theme, then 'Create'). Slides are listed on the left; the title and body are text boxes on the slide (double-click to edit). ⌘⇧N adds a slide."],
            shortcuts: ["cmd+n": "New presentation", "cmd+shift+n": "New slide", "cmd+option+p": "Play the slideshow", "escape": "Stop the slideshow"]
        ),
        AppSkill(
            name: "Microsoft Word", bundleIDs: ["com.microsoft.Word"],
            howItWorks: ["⌘N opens a new blank document (or the template gallery: CLICK 'Blank Document' then 'Create'). The page body is the text area; ⌘S saves."],
            shortcuts: ["cmd+n": "New document", "cmd+s": "Save", "cmd+a": "Select all", "cmd+b": "Bold"],
            recipes: [.init(goal: "write a document", keywords: ["write", "create", "document", "type"], steps: ["KEY cmd+n", "TYPE_TEXT the content into the page", "DONE when visible"])]
        ),
        AppSkill(
            name: "Microsoft Excel", bundleIDs: ["com.microsoft.Excel"],
            howItWorks: ["Cells are addressed A1-style; CLICK a cell, TYPE_TEXT, KEY Return. The formula bar shows the active cell's content."],
            shortcuts: ["cmd+n": "New workbook", "cmd+s": "Save", "return": "Confirm cell, move down", "tab": "Confirm cell, move right"]
        ),
        AppSkill(
            name: "Xcode", bundleIDs: ["com.apple.dt.Xcode"],
            howItWorks: ["Navigator on the left (⌘1 files), editor in the middle, inspectors on the right. ⌘⇧O opens a file by name; ⌘R runs; ⌘B builds; ⌘U tests."],
            shortcuts: ["cmd+shift+o": "Open quickly (type a file/symbol name, Return)", "cmd+r": "Run", "cmd+b": "Build", "cmd+u": "Test", "cmd+1": "Project navigator", "cmd+shift+y": "Toggle the console"],
            recipes: [
                .init(goal: "open a file", keywords: ["open", "file", "go to", "find"], steps: ["KEY cmd+shift+o", "TYPE_TEXT the file name", "KEY Return"]),
                .init(goal: "run / build / test", keywords: ["run", "build", "test", "launch"], steps: ["KEY cmd+r (run), cmd+b (build) or cmd+u (test)", "DONE when the activity bar reports the result"]),
            ]
        ),
        AppSkill(
            name: "Visual Studio Code", bundleIDs: ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.vscodium"],
            howItWorks: ["Electron editor. ⌘P opens a file by name; ⌘⇧P runs a command by name; ⌘` toggles the terminal; ⌘S saves; ⌘⇧F searches the project. The editor body is a text area."],
            shortcuts: ["cmd+p": "Open a file by name", "cmd+shift+p": "Command palette (run a command by name)", "cmd+`": "Toggle terminal", "cmd+s": "Save", "cmd+shift+f": "Search in files", "cmd+b": "Toggle the sidebar"],
            recipes: [
                .init(goal: "open a file", keywords: ["open", "file", "go to"], steps: ["KEY cmd+p", "TYPE_TEXT the file name", "KEY Return"]),
                .init(goal: "run a command / setting", keywords: ["run", "command", "toggle", "format", "setting"], steps: ["KEY cmd+shift+p", "TYPE_TEXT the command name", "KEY Return"]),
            ]
        ),
        AppSkill(
            name: "Notion", bundleIDs: ["notion.id"],
            howItWorks: ["Electron app. Sidebar lists pages; ⌘N makes a new page with its title focused (type the title, Return moves to the body). ⌘P searches pages. Blocks are contenteditable text; '/' opens the block menu."],
            shortcuts: ["cmd+n": "New page (title focused)", "cmd+p": "Search / jump to a page", "cmd+shift+n": "New window", "cmd+[": "Back"],
            recipes: [
                .init(goal: "create a page", keywords: ["create", "new page", "page", "note", "write"], steps: ["KEY cmd+n", "TYPE_TEXT the title", "KEY Return", "TYPE_TEXT the body"]),
                .init(goal: "open a page", keywords: ["open", "find", "go to"], steps: ["KEY cmd+p", "TYPE_TEXT the page name", "KEY Return"]),
            ]
        ),
        AppSkill(
            name: "Weather", bundleIDs: ["com.apple.weather"],
            howItWorks: ["Sidebar lists saved locations with a search field at the top; the main pane shows the forecast for the selected one. Type a city in the search field and click the result to see it."],
            shortcuts: ["cmd+f": "Search for a location"],
            recipes: [.init(goal: "weather for a place", keywords: ["weather", "forecast", "temperature", "rain"], steps: ["KEY cmd+f", "TYPE_TEXT the city", "CLICK the matching result", "DONE when the forecast for that city is showing"])],
            doneWhen: ["the forecast for the requested city is showing"]
        ),
        AppSkill(
            name: "Clock", bundleIDs: ["com.apple.clock"],
            howItWorks: ["Tabs: World Clock, Alarm, Stopwatch, Timer. Timer has hour/minute/second fields and a Start button; Alarm has a '+' button and time fields."],
            recipes: [
                .init(goal: "set a timer", keywords: ["timer", "minutes", "countdown"], steps: ["CLICK 'Timer'", "CLICK the minutes field and TYPE_TEXT the value", "CLICK 'Start'"]),
                .init(goal: "set an alarm", keywords: ["alarm", "wake"], steps: ["CLICK 'Alarm'", "CLICK '+'", "set the time fields", "CLICK 'Save'"]),
            ]
        ),
        AppSkill(
            name: "Stickies", bundleIDs: ["com.apple.Stickies"],
            howItWorks: ["Each note is its own small window (AXTextArea). ⌘N makes a new note that is focused; type directly."],
            shortcuts: ["cmd+n": "New sticky note (focused)"],
            recipes: [.init(goal: "write a sticky note", keywords: ["sticky", "note", "write", "remind"], steps: ["KEY cmd+n", "TYPE_TEXT the text"])]
        ),
    ]

    static let web: [AppSkill] = [
        AppSkill(
            name: "Google Docs", bundleIDs: [], hosts: ["docs.google.com"],
            howItWorks: [
                "A document's title is the small text field at the top-left (labelled 'Rename' / 'Untitled document'). The page body is the textbox labelled 'Document body — the page itself…': TYPE_TEXT into it appends the text at the end of the document.",
                "Documents save automatically ('Saved to Drive' near the title); there is no Save button.",
                "Sheets: cells are addressed A1-style; type into the selected cell and press Enter. Slides: click a text placeholder to type.",
            ],
            recipes: [
                .init(goal: "create a doc and write in it", keywords: ["create", "new", "doc", "document", "write", "type", "note", "sheet", "slides"],
                      steps: ["Open https://docs.google.com/document/create (or spreadsheets/create, presentation/create)",
                              "To title it: TYPE_TEXT the title into the 'Rename' title field (once)",
                              "To write the body: TYPE_TEXT the content into 'Document body — the page itself…' (not the title)", "DONE when the text is visible in the page"]),
            ],
            doneWhen: ["the requested text is visible in the document body (or the requested title in the title field)"],
            avoid: ["Do not type body text into the 'Rename' title field, and never type into it more than once.",
                    "Do not look for a Save button — Docs saves itself."],
            fieldHints: ["The 'Rename' / title field takes a short document title only, never the body text."],
            deepLinks: ["new document": "https://docs.google.com/document/create", "new spreadsheet": "https://docs.google.com/spreadsheets/create",
                        "new presentation": "https://docs.google.com/presentation/create", "documents home": "https://docs.google.com/document/"]
        ),
        AppSkill(
            name: "Google Drive", bundleIDs: [], hosts: ["drive.google.com"],
            howItWorks: [
                "Left sidebar: '+ New' button (menu: New folder, File upload, Google Docs, Sheets, Slides, Forms), then Home, My Drive, Computers, Shared with me, Recent, Starred, Spam, Trash, Storage.",
                "'Search in Drive' at the top: type words and press Enter; filter chips (Type, People, Modified) narrow results. The People filter opens a list of people to pick from.",
                "Files are items labelled 'name type' (grid view) or rows 'name · owner/sharer · date' (List view — CLICK the 'List' radio to see who shared each file): CLICK an item selects it; its 'Open (double-click): …' action OPENS the file.",
                "While typing in the search box, matching files appear as options 'Open document \"<name> <date> <sharer>\"': CLICK the suggestion naming the wanted file/person to open it directly — when one is listed, do not click 'Search Google Drive' first.",
            ],
            recipes: [
                .init(goal: "find a file shared by someone", keywords: ["shared", "find", "file", "report", "document", "from", "by", "open"],
                      steps: ["Open https://drive.google.com/drive/shared-with-me", "TYPE_TEXT the person's name into 'Search in Drive'",
                              "CLICK the 'Open document \"…\"' suggestion whose text names that person and the wanted file — it opens the file",
                              "If no suggestion fits: CLICK 'Search Google Drive' once, then CLICK 'Open (double-click): <the file>' among the results",
                              "DONE when the file is open (or its item is selected, if only finding was asked)"]),
                .init(goal: "create a new doc/folder from Drive", keywords: ["create", "new", "make", "doc", "folder", "sheet"],
                      steps: ["CLICK '+ New'", "CLICK 'Google Docs' (or 'New folder' / 'Google Sheets')", "DONE when the new item opens"]),
            ],
            doneWhen: ["the file with the requested name/sharer is open or highlighted in the list"],
            avoid: ["Do not click 'Shared with me' / 'Items shared with me' again once that page is showing — read the rows instead.",
                    "Do not click 'Search Google Drive' more than once for the same query, and never leave a results page by clicking a sidebar link.",
                    "Do not re-open the People filter repeatedly; pick a person once, then read the results.",
                    "Do not navigate to made-up URLs; use the deep links."],
            deepLinks: ["my drive": "https://drive.google.com/drive/my-drive", "shared with me": "https://drive.google.com/drive/shared-with-me",
                        "recent": "https://drive.google.com/drive/recent", "starred": "https://drive.google.com/drive/starred", "trash": "https://drive.google.com/drive/trash",
                        "search": "https://drive.google.com/drive/search?q="]
        ),
        AppSkill(
            name: "Gmail", bundleIDs: [], hosts: ["mail.google.com"],
            howItWorks: [
                "'Compose' button at the top-left opens a compose card with To, Subject and body; 'Send' is at its bottom-left. Ctrl/⌘+Enter also sends.",
                "The search bar ('Search mail') at the top: type and press Enter; results replace the inbox list. Click a row to open the message.",
                "Reply/Forward buttons are at the bottom of an open message.",
            ],
            recipes: [
                .init(goal: "send an email", keywords: ["send", "email", "mail", "write", "compose"],
                      steps: ["CLICK 'Compose' (or open https://mail.google.com/mail/?view=cm&fs=1)", "TYPE_TEXT the recipient into 'To'", "TYPE_TEXT the subject into 'Subject'",
                              "TYPE_TEXT the body into 'Message Body'", "CLICK 'Send'", "DONE when the compose card is gone / 'Message sent' shows"]),
                .init(goal: "find / open an email", keywords: ["find", "open", "search", "look", "from", "latest", "newest", "unread"],
                      steps: ["TYPE_TEXT the words into 'Search mail'", "press Enter", "CLICK the matching row", "DONE when the message body is showing"]),
            ],
            doneWhen: ["'Message sent' appears / the compose card closed", "the requested message is open"],
            avoid: ["Do not click Send before To, Subject and body are filled."],
            deepLinks: ["compose": "https://mail.google.com/mail/?view=cm&fs=1", "inbox": "https://mail.google.com/mail/u/0/#inbox", "search": "https://mail.google.com/mail/u/0/#search/"]
        ),
        AppSkill(
            name: "Google Calendar", bundleIDs: [], hosts: ["calendar.google.com"],
            howItWorks: [
                "'+ Create' button at the top-left → 'Event' opens the quick card (title, date, time, 'Save'); 'More options' opens the full form.",
                "Day/Week/Month view switcher at the top-right; 'Today' and ◀ ▶ arrows move the view. Clicking an empty slot also opens the quick card.",
            ],
            recipes: [
                .init(goal: "create an event", keywords: ["create", "add", "schedule", "event", "meeting", "appointment", "book"],
                      steps: ["Open https://calendar.google.com/calendar/r/eventedit (full form) or CLICK '+ Create' → 'Event'", "TYPE_TEXT the title into 'Add title'",
                              "Set the date and time fields", "CLICK 'Save'", "DONE when the event shows on the grid"]),
            ],
            doneWhen: ["the event with the requested title is drawn on the calendar grid"],
            avoid: ["Do not click ▶ repeatedly to reach a date; set the date in the event form."],
            deepLinks: ["new event": "https://calendar.google.com/calendar/r/eventedit", "week view": "https://calendar.google.com/calendar/r/week", "day view": "https://calendar.google.com/calendar/r/day"]
        ),
        AppSkill(
            name: "Outlook Web", bundleIDs: [], hosts: ["outlook.live.com", "outlook.office.com", "outlook.office365.com"],
            howItWorks: [
                "Left rail icons switch modules: Mail, Calendar, People, To Do. The Calendar module is at /calendar/ — a mail page cannot create events.",
                "Mail: 'New mail' button opens a compose pane (To, Add a subject, body) with 'Send' at the top. Calendar: 'New event' button opens a form (Add a title, date, start/end time, 'Save').",
            ],
            recipes: [
                .init(goal: "create a calendar event", keywords: ["calendar", "event", "meeting", "schedule", "appointment"],
                      steps: ["Open https://outlook.office.com/calendar/ (or CLICK the Calendar icon in the left rail)", "CLICK 'New event'", "TYPE_TEXT the title",
                              "set the date and time fields", "CLICK 'Save'", "DONE when the event shows on the calendar"]),
                .init(goal: "send an email", keywords: ["send", "email", "mail", "write"],
                      steps: ["CLICK 'New mail'", "TYPE_TEXT the recipient into 'To'", "TYPE_TEXT the subject into 'Add a subject'", "TYPE_TEXT the body", "CLICK 'Send'"]),
            ],
            doneWhen: ["the event is drawn on the calendar grid", "the compose pane closed after Send"],
            avoid: ["Do not stay on the Mail module for a calendar goal — go to /calendar/."],
            deepLinks: ["calendar": "https://outlook.office.com/calendar/", "new event": "https://outlook.office.com/calendar/deeplink/compose",
                        "compose mail": "https://outlook.office.com/mail/deeplink/compose", "mail": "https://outlook.office.com/mail/"]
        ),
        AppSkill(
            name: "Google Search", bundleIDs: [], hosts: ["google.com", "www.google.com"],
            howItWorks: [
                "Results are links: the title line opens the page; the site name line above it is part of the same link. Answer boxes / knowledge panels show facts (scores, weather, times) directly on the results page.",
                "Tabs under the search box (All, Images, Videos, News, Maps, Shopping) switch result types.",
            ],
            recipes: [
                .init(goal: "look something up", keywords: ["find", "what", "who", "when", "score", "weather", "how", "search", "look up"],
                      steps: ["Read the answer box / top results", "DONE when the answer is visible on the results page; open a result only when the goal asks to open one"]),
            ],
            doneWhen: ["the requested fact is visible in an answer box or result snippet"],
            avoid: ["Do not click a result when the answer is already visible on the results page, unless the goal asks to open it."]
        ),
        AppSkill(
            name: "Google Maps", bundleIDs: [], hosts: ["google.com/maps", "maps.google.com"],
            howItWorks: [
                "Search box at the top-left; a place card opens with 'Directions'. Directions view has origin/destination fields, mode buttons (Drive, Transit, Walk, Cycle) and a 'Leave now ▾' menu with 'Depart at' / 'Arrive by' and time fields; routes list their travel time.",
            ],
            recipes: [
                .init(goal: "directions / travel time", keywords: ["directions", "drive", "how long", "route", "get to", "travel", "leave", "arrive"],
                      steps: ["TYPE_TEXT the destination into the search box and press Enter", "CLICK 'Directions'", "TYPE_TEXT the origin into 'Choose starting point'",
                              "For a departure time: CLICK 'Leave now', choose 'Depart at', set the time", "DONE when the routes with times are listed"]),
            ],
            doneWhen: ["route options with travel times are listed"],
            deepLinks: ["directions": "https://www.google.com/maps/dir/"]
        ),
        AppSkill(
            name: "YouTube", bundleIDs: [], hosts: ["youtube.com", "www.youtube.com"],
            howItWorks: ["Search box at the top; results are video links; clicking one opens the watch page where the video plays automatically (a large play/pause button sits on the player)."],
            recipes: [
                .init(goal: "play a video", keywords: ["play", "watch", "video", "youtube", "song", "music"],
                      steps: ["Open https://www.youtube.com/results?search_query=<words>", "CLICK the first matching video title", "DONE when the watch page is showing"]),
            ],
            doneWhen: ["the watch page with the requested video title is showing"],
            deepLinks: ["search": "https://www.youtube.com/results?search_query="]
        ),
        AppSkill(
            name: "Amazon", bundleIDs: [], hosts: ["amazon.com", "www.amazon.com"],
            howItWorks: ["Search bar at the top; result cards show the title, price and 'Add to Cart'. A product page has 'Add to Cart' and 'Buy Now' buttons on the right; the cart is the top-right icon."],
            recipes: [
                .init(goal: "find / price a product", keywords: ["find", "price", "how much", "buy", "search", "look", "product", "cheapest"],
                      steps: ["Open https://www.amazon.com/s?k=<words>", "Read the result cards", "CLICK the product to open it if details are needed", "DONE when the price is visible"]),
                .init(goal: "add to cart", keywords: ["add", "cart"], steps: ["Open the product page", "CLICK 'Add to Cart'", "DONE when 'Added to Cart' shows"]),
            ],
            avoid: ["Never click 'Buy Now' or 'Place your order' unless the goal explicitly asks to purchase."],
            deepLinks: ["search": "https://www.amazon.com/s?k=", "cart": "https://www.amazon.com/gp/cart/view.html"]
        ),
        AppSkill(
            name: "GitHub", bundleIDs: [], hosts: ["github.com"],
            howItWorks: ["Repository pages have tabs (Code, Issues, Pull requests, Actions). 'New issue' / 'New pull request' are green buttons; the search bar is at the top. The '/' key focuses search."],
            recipes: [
                .init(goal: "open a repo / issue / PR", keywords: ["open", "repo", "issue", "pull", "pr", "find", "check"],
                      steps: ["Open https://github.com/<owner>/<repo> (or /issues, /pulls)", "CLICK the matching item", "DONE when it is showing"]),
                .init(goal: "create an issue", keywords: ["create", "new issue", "file", "report"],
                      steps: ["Open https://github.com/<owner>/<repo>/issues/new", "TYPE_TEXT the title", "TYPE_TEXT the body", "CLICK 'Create'"]),
            ],
            deepLinks: ["home": "https://github.com", "notifications": "https://github.com/notifications", "pull requests": "https://github.com/pulls", "issues": "https://github.com/issues"]
        ),
        AppSkill(
            name: "Notion Web", bundleIDs: [], hosts: ["notion.so", "www.notion.so"],
            howItWorks: ["Sidebar lists pages; '+ New page' at the bottom of the sidebar (or the ⊕ next to a page) creates one with the title focused. Blocks are contenteditable text."],
            recipes: [
                .init(goal: "create a page", keywords: ["create", "new page", "page", "write", "note"],
                      steps: ["CLICK '+ New page'", "TYPE_TEXT the title into 'Untitled'", "press Enter", "TYPE_TEXT the body"]),
            ]
        ),
        AppSkill(
            name: "ChatGPT", bundleIDs: ["com.openai.chat"], hosts: ["chatgpt.com", "chat.openai.com"],
            howItWorks: ["A message composer ('Ask anything' / 'Message ChatGPT') at the bottom; Enter sends; the reply streams above. 'New chat' is at the top of the sidebar."],
            recipes: [
                .init(goal: "ask ChatGPT something", keywords: ["ask", "chatgpt", "prompt", "tell", "generate"],
                      steps: ["TYPE_TEXT the question into the composer", "press Enter", "WAIT for the reply", "DONE when the reply is visible"]),
            ],
            doneWhen: ["the assistant's reply to the question is visible"]
        ),
        AppSkill(
            name: "X / Twitter", bundleIDs: [], hosts: ["x.com", "twitter.com"],
            howItWorks: ["'Post' button (left rail) opens the composer ('What is happening?!'); the 'Post' button in the composer publishes (irreversible). Search is at the top-right ('Search')."],
            recipes: [
                .init(goal: "post a tweet", keywords: ["post", "tweet", "write", "publish"],
                      steps: ["CLICK 'Post' in the left rail", "TYPE_TEXT the text", "CLICK the composer's 'Post' button", "DONE when the post shows in the timeline"]),
                .init(goal: "search", keywords: ["search", "find", "look", "trending"], steps: ["TYPE_TEXT into 'Search'", "press Enter"]),
            ],
            avoid: ["Do not click the composer's Post button before the text is complete."]
        ),
        AppSkill(
            name: "Reddit", bundleIDs: [], hosts: ["reddit.com", "www.reddit.com"],
            howItWorks: ["Search bar at the top; subreddits are at r/<name>; posts are links whose title opens the thread with comments below."],
            recipes: [.init(goal: "find posts / a subreddit", keywords: ["find", "search", "subreddit", "post", "thread"], steps: ["Open https://www.reddit.com/r/<name> or TYPE_TEXT into search and press Enter", "CLICK the post title", "DONE when it is open"])],
            deepLinks: ["search": "https://www.reddit.com/search/?q="]
        ),
        AppSkill(
            name: "LinkedIn", bundleIDs: [], hosts: ["linkedin.com", "www.linkedin.com"],
            howItWorks: ["Search bar at the top-left; 'Start a post' opens the composer with a 'Post' button; Messaging is in the top bar (compose icon = new message: type a name, pick it, type, 'Send')."],
            recipes: [.init(goal: "message someone", keywords: ["message", "send", "dm", "connect"], steps: ["CLICK 'Messaging'", "CLICK the compose (new message) icon", "TYPE_TEXT the name and CLICK the match", "TYPE_TEXT the message", "CLICK 'Send'"])]
        ),
    ]
}
