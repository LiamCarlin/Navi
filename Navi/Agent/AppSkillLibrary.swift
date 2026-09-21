import Foundation

/// The playbooks themselves — one per app (`native`, matched by bundle id) and per
/// web app (`web`, matched by host, optionally with a path prefix). The engine
/// that reads them is `AppSkills.swift`.
///
/// Writing a skill: `howItWorks` is 3–6 facts about where things are and how
/// the UI behaves; `shortcuts` only combos you are sure of, in `KeyCombo.parse`
/// spelling ("cmd+shift+n", "return"); `recipes` name the goals people ask for
/// with the words they *say* (voice: "text", "put on", "jot down", "shoot",
/// "let X know"), each step in Jev's operation vocabulary; `triggers` are the
/// nouns that imply this app when none is named ("song" → Music, "reminder" →
/// Reminders), `weakTriggers` the verbs that only count when the frontmost app
/// does not claim them ("play"); `aliases` are the spoken names. Order matters
/// for ties: Apple's default app comes before third-party alternatives, and a
/// third-party app that people install *instead* (Spotify) comes before the
/// Apple app it replaces — a running app wins either way.
extension AppSkills {
    static let all: [AppSkill] = native + web

    // Shared wording, so Jev sees the same phrasing across apps.
    static let sendMessageDone = "the message appears as the newest bubble at the bottom of the conversation and the message field is empty again"
    static let mediaWeak = ["play", "pause", "resume", "skip", "next", "previous", "shuffle", "repeat", "queue", "stop"]
    static let chatWeak = ["message", "reply", "dm", "send", "ping"]
    static let neverPurchase = "Never click 'Buy Now', 'Place order', 'Checkout', 'Book', 'Reserve', 'Pay' or any button that charges money unless the goal explicitly asks to buy/book — adding to a cart or basket is fine."

    // MARK: - Native apps

    static let native: [AppSkill] = [
        // ── Communication ─────────────────────────────────────────────────────
        AppSkill(
            name: "Messages", bundleIDs: ["com.apple.MobileSMS", "com.apple.iChat"],
            howItWorks: [
                "Left sidebar lists conversations (each cell: contact name + last message + time). The right pane shows the open conversation with the message field ('iMessage' / 'Text Message') at the bottom.",
                "Messaging someone who is NOT the open conversation needs a new message: ⌘N opens a blank conversation with the 'To:' field focused.",
                "Typing a name in 'To:' shows contact suggestions; Return accepts the top suggestion (a blue pill appears). Then the message field gets the text.",
                "Return in the message field SENDS the message (irreversible). Shift+Return adds a line without sending.",
                "Search at the top of the sidebar filters conversations and messages; it does not start a conversation.",
                "The 'i' / Details button at the top-right of a conversation has the audio and FaceTime call buttons for that person.",
            ],
            shortcuts: ["cmd+n": "New message (blank conversation, To: field focused)", "cmd+f": "Search conversations",
                        "return": "In the message field: SEND. In the To: field: accept the highlighted contact", "shift+return": "New line without sending"],
            recipes: [
                .init(goal: "send a message / text to a person", keywords: ["send", "text", "message", "imessage", "tell", "let", "reply", "say", "shoot", "ping", "know"],
                      steps: ["If the open conversation is not with that person: KEY cmd+n",
                              "TYPE_TEXT the person's name into the 'To:' field", "KEY Return to accept the contact suggestion",
                              "TYPE_TEXT the message into the message field at the bottom ('iMessage' or 'Text Message')",
                              "KEY Return to send", "DONE when the sent bubble is visible"]),
                .init(goal: "reply in the open conversation", keywords: ["reply", "respond", "answer", "write back", "say"],
                      steps: ["TYPE_TEXT the reply into the message field at the bottom", "KEY Return"]),
                .init(goal: "open a conversation / read messages", keywords: ["open", "read", "show", "check", "what did", "last message", "unread", "said"],
                      steps: ["CLICK the conversation cell with that person's name in the sidebar", "DONE when the conversation is showing"]),
                .init(goal: "call the person in the open conversation", keywords: ["call", "facetime", "ring"],
                      steps: ["CLICK the 'i' / Details button at the top-right", "CLICK 'Audio' or 'FaceTime'"]),
            ],
            doneWhen: [sendMessageDone],
            avoid: ["Do not click an existing conversation to message a DIFFERENT person — use ⌘N.",
                    "Do not type the recipient's name into the Search field.",
                    "Do not press Return in the message field until the text is complete (Return sends).",
                    "'No Results' after typing a name in To: means the contact is unknown — type their phone number or email instead, never guess."],
            fieldHints: ["The To: field takes only the contact's name (or number/email), nothing else.",
                         "The message field takes the message text exactly as the goal states it, in the first person as the user would say it, without a greeting the goal did not ask for."],
            aliases: ["texts", "imessage", "imessages", "text messages", "sms"],
            triggers: ["text", "texts", "imessage", "sms", "text message", "tell", "message", "texted"],
            weakTriggers: chatWeak
        ),
        AppSkill(
            name: "Mail", bundleIDs: ["com.apple.mail"],
            howItWorks: [
                "Mailboxes on the left, message list in the middle, the selected message on the right.",
                "⌘N opens a new message window with 'To:', 'Cc:', 'Subject:' fields and the body; the To: field is focused first.",
                "In To:, typing a name shows suggestions; Return (or a comma) accepts the top one.",
                "⌘⇧D sends the message that is open (irreversible). The Send button is the paper-plane toolbar button.",
                "⌘R replies to the selected message; ⌘⇧F forwards it; ⌃⌘A archives it; ⌘⌫ deletes it (to Trash, recoverable).",
            ],
            shortcuts: ["cmd+n": "New email (To: focused)", "cmd+shift+d": "Send the open email", "cmd+r": "Reply to the selected email",
                        "cmd+shift+r": "Reply all", "cmd+shift+f": "Forward", "cmd+option+f": "Search mailbox", "cmd+delete": "Delete selected email (to Trash)",
                        "cmd+shift+n": "Get new mail", "ctrl+cmd+a": "Archive the selected email", "cmd+shift+u": "Mark as unread / read",
                        "cmd+shift+l": "Flag / unflag", "cmd+shift+a": "Attach a file (file chooser)", "cmd+shift+j": "Move to Junk"],
            recipes: [
                .init(goal: "send an email", keywords: ["send", "email", "mail", "write", "compose", "shoot", "let", "know"],
                      steps: ["KEY cmd+n", "TYPE_TEXT the recipient into 'To:'", "KEY Tab", "KEY Tab (past Cc)", "TYPE_TEXT the subject into 'Subject:'",
                              "CLICK the body (the large text area) and TYPE_TEXT the body", "KEY cmd+shift+d to send", "DONE when the compose window is gone"]),
                .init(goal: "reply to an email", keywords: ["reply", "respond", "answer", "write back"],
                      steps: ["CLICK the message in the list if not selected", "KEY cmd+r", "TYPE_TEXT the reply into the body", "KEY cmd+shift+d"]),
                .init(goal: "forward an email", keywords: ["forward", "pass along", "send this to"],
                      steps: ["CLICK the message", "KEY cmd+shift+f", "TYPE_TEXT the recipient into 'To:'", "KEY cmd+shift+d"]),
                .init(goal: "find / open an email", keywords: ["find", "open", "search", "look", "from", "latest", "newest", "unread", "did", "get"],
                      steps: ["KEY cmd+option+f", "TYPE_TEXT the search words", "KEY Return", "CLICK the matching message in the list"]),
                .init(goal: "archive / delete / flag the selected email", keywords: ["archive", "delete", "trash", "flag", "unread", "junk", "spam"],
                      steps: ["CLICK the message in the list", "KEY ctrl+cmd+a (archive) / cmd+delete (trash) / cmd+shift+l (flag) / cmd+shift+u (unread)"]),
            ],
            doneWhen: ["after sending: the compose window has closed", "after opening: the message body is showing on the right"],
            avoid: ["Do not type the recipient into the mailbox search field.", "Do not press Send before To, Subject and body are filled.",
                    "Do not empty the Trash or permanently delete anything."],
            fieldHints: ["Subject is one short line; the body is the full message in the user's voice, with a greeting and sign-off only if the goal implies one."],
            aliases: ["apple mail", "email app", "mail app"],
            triggers: ["email", "emails", "e-mail", "mail", "inbox", "emailed"],
            weakTriggers: ["reply", "forward", "send", "archive"]
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
                .init(goal: "create a calendar event", keywords: ["calendar", "event", "meeting", "schedule", "appointment", "invite", "block"],
                      steps: ["KEY cmd+2 to switch to Calendar (if the window is in Mail)", "KEY cmd+n", "TYPE_TEXT the subject into the focused Subject field",
                              "Set the Start date/time fields (CLICK the field, TYPE_TEXT the value)", "CLICK 'Save & Close'", "DONE when the event shows on the calendar"]),
                .init(goal: "send an email", keywords: ["send", "email", "mail", "write", "compose"],
                      steps: ["KEY cmd+1 to switch to Mail", "KEY cmd+n", "TYPE_TEXT the recipient into To", "KEY Tab", "TYPE_TEXT the subject", "CLICK the body and TYPE_TEXT it", "KEY cmd+return to send"]),
                .init(goal: "check the calendar / what's on", keywords: ["what", "when", "check", "today", "tomorrow", "next", "free"],
                      steps: ["KEY cmd+2", "KEY cmd+t for today or CLICK the view buttons", "DONE when that day's events are visible"]),
            ],
            doneWhen: ["the new event appears on the calendar grid", "the sent email is no longer open"],
            avoid: ["Do not stay BLOCKED in the Mail module when the goal is a calendar task — press ⌘2.",
                    "Do not click 'next day' repeatedly; set the date in the event's Start field."],
            aliases: ["microsoft outlook"],
            triggers: ["outlook", "email", "emails", "inbox", "calendar", "event", "appointment", "schedule"],
            weakTriggers: ["reply", "forward", "send"]
        ),
        AppSkill(
            name: "FaceTime", bundleIDs: ["com.apple.FaceTime"],
            howItWorks: ["'New FaceTime' button opens a sheet with a 'To:' field; type a name, Return picks the contact, then the green 'FaceTime' (video) or 'Audio' button starts the call.",
                         "Recent calls are listed in the sidebar; clicking the camera/phone icon next to one calls back."],
            shortcuts: ["cmd+n": "New FaceTime (To: field)"],
            recipes: [
                .init(goal: "call someone", keywords: ["call", "facetime", "ring", "video", "phone"],
                      steps: ["KEY cmd+n", "TYPE_TEXT the person's name into To:", "KEY Return", "CLICK the 'FaceTime' (video) or 'Audio' button"]),
            ],
            doneWhen: ["the call window shows 'Connecting…' or the other person"],
            aliases: ["face time"],
            triggers: ["facetime", "video call", "audio call", "phone call"],
            weakTriggers: ["call", "ring"]
        ),
        AppSkill(
            name: "Slack", bundleIDs: ["com.tinyspeck.slackmacgap"],
            howItWorks: [
                "Electron app. Sidebar lists channels (#name) and direct messages; the message composer is at the bottom of the open channel/DM.",
                "⌘K opens the quick switcher: type a channel or person name, Return opens it. Return in the composer sends; Shift+Return adds a line.",
                "Threads open in a right pane with their own 'Reply…' composer. Reactions: hover a message → the emoji button.",
            ],
            shortcuts: ["cmd+k": "Quick switcher: jump to a channel or person", "cmd+n": "New message (choose recipient)", "cmd+f": "Search", "return": "Send the composed message",
                        "shift+return": "New line in the composer", "cmd+shift+a": "All unreads", "cmd+shift+k": "Direct messages", "cmd+[": "Back", "cmd+shift+m": "Activity / mentions"],
            recipes: [
                .init(goal: "message a person or channel", keywords: ["send", "message", "dm", "tell", "post", "slack", "channel", "reply", "ping", "let", "know"],
                      steps: ["KEY cmd+k", "TYPE_TEXT the person or channel name", "KEY Return", "TYPE_TEXT the message into the composer at the bottom", "KEY Return to send",
                              "DONE when the message shows in the conversation"]),
                .init(goal: "catch up / read a channel", keywords: ["read", "catch up", "unread", "what did", "check", "open"],
                      steps: ["KEY cmd+shift+a for all unreads, or KEY cmd+k and TYPE_TEXT the channel", "DONE when the messages are showing"]),
                .init(goal: "search Slack", keywords: ["search", "find", "look"], steps: ["KEY cmd+f", "TYPE_TEXT the words", "KEY Return"]),
            ],
            doneWhen: [sendMessageDone],
            avoid: ["Do not send to the channel that happens to be open unless it is the one asked for — use ⌘K first."],
            fieldHints: ["The composer takes the message text exactly as the goal states it."],
            triggers: ["slack", "channel", "workspace", "huddle"],
            weakTriggers: chatWeak
        ),
        AppSkill(
            name: "Discord", bundleIDs: ["com.hnc.Discord"],
            howItWorks: ["Electron app. Servers on the far left, channels/DMs next, the chat with its composer at the bottom. ⌘K opens the quick switcher (type a channel or friend, Return). Return sends.",
                         "In a voice channel: ⌘⇧M toggles mute, ⌘⇧D deafen; the 'Disconnect' (phone) button at the bottom-left leaves the voice channel."],
            shortcuts: ["cmd+k": "Quick switcher", "return": "Send the message", "shift+return": "New line", "cmd+f": "Search", "cmd+shift+m": "Mute / unmute microphone", "cmd+shift+d": "Deafen / undeafen"],
            recipes: [
                .init(goal: "message someone / a channel", keywords: ["send", "message", "dm", "tell", "post", "channel", "discord"],
                      steps: ["KEY cmd+k", "TYPE_TEXT the name", "KEY Return", "TYPE_TEXT the message into the composer", "KEY Return"]),
                .init(goal: "join a voice channel", keywords: ["join", "voice", "vc", "hop on"], steps: ["CLICK the server", "CLICK the voice channel name", "DONE when 'Voice Connected' shows"]),
            ],
            doneWhen: [sendMessageDone],
            triggers: ["discord", "voice channel"],
            weakTriggers: chatWeak
        ),
        AppSkill(
            name: "WhatsApp", bundleIDs: ["net.whatsapp.WhatsApp", "desktop.WhatsApp"],
            howItWorks: ["Chats listed on the left with a search field at the top; the open chat on the right with the message composer at the bottom. Return sends; Shift+Return adds a line.",
                         "A new chat: ⌘N (or the compose icon), type the contact's name, click it."],
            shortcuts: ["cmd+n": "New chat (search a contact)", "cmd+f": "Search chats", "return": "Send", "shift+return": "New line"],
            recipes: [
                .init(goal: "message someone on WhatsApp", keywords: ["send", "message", "text", "tell", "whatsapp", "let", "know"],
                      steps: ["KEY cmd+f and TYPE_TEXT the contact's name (or KEY cmd+n)", "CLICK the matching chat", "TYPE_TEXT the message into the composer", "KEY Return"]),
            ],
            doneWhen: [sendMessageDone],
            aliases: ["whats app"],
            triggers: ["whatsapp"],
            weakTriggers: chatWeak
        ),
        AppSkill(
            name: "Telegram", bundleIDs: ["ru.keepcoder.Telegram", "org.telegram.desktop"],
            howItWorks: ["Chats on the left with a search field at the top; the open chat on the right with the composer at the bottom. Return sends."],
            shortcuts: ["cmd+n": "New message", "cmd+f": "Search", "return": "Send"],
            recipes: [.init(goal: "message someone on Telegram", keywords: ["send", "message", "text", "tell", "telegram"],
                            steps: ["CLICK the search field and TYPE_TEXT the name", "CLICK the chat", "TYPE_TEXT the message", "KEY Return"])],
            doneWhen: [sendMessageDone],
            triggers: ["telegram"],
            weakTriggers: chatWeak
        ),
        AppSkill(
            name: "Signal", bundleIDs: ["org.whispersystems.signal-desktop"],
            howItWorks: ["Electron app. Conversations on the left with a search field; the open one on the right with the composer at the bottom. Return sends."],
            shortcuts: ["cmd+n": "New conversation", "cmd+f": "Search", "return": "Send"],
            recipes: [.init(goal: "message someone on Signal", keywords: ["send", "message", "text", "tell", "signal"],
                            steps: ["KEY cmd+f and TYPE_TEXT the name", "CLICK the conversation", "TYPE_TEXT the message", "KEY Return"])],
            doneWhen: [sendMessageDone],
            triggers: ["signal message", "on signal"],
            weakTriggers: chatWeak
        ),
        AppSkill(
            name: "Microsoft Teams", bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"],
            howItWorks: ["Left rail: Activity, Chat, Teams, Calendar, Calls. Chat: conversations listed, composer at the bottom (Return sends).",
                         "⌘E focuses search (people, chats, messages). Calendar shows meetings with a 'Join' button on each; in a meeting ⌘⇧M mutes, ⌘⇧O toggles camera, ⌘⇧H leaves."],
            shortcuts: ["cmd+e": "Search", "cmd+n": "New chat", "return": "Send", "cmd+shift+m": "Mute / unmute (in a meeting)", "cmd+shift+o": "Camera on / off",
                        "cmd+shift+h": "Leave the meeting", "cmd+shift+e": "Share screen"],
            recipes: [
                .init(goal: "message someone on Teams", keywords: ["send", "message", "chat", "tell", "teams"],
                      steps: ["KEY cmd+n", "TYPE_TEXT the person's name into To", "KEY Return", "TYPE_TEXT the message", "KEY Return"]),
                .init(goal: "join a meeting", keywords: ["join", "meeting", "call"], steps: ["CLICK 'Calendar' in the left rail", "CLICK 'Join' on the meeting", "CLICK 'Join now'"]),
            ],
            doneWhen: [sendMessageDone, "the meeting window is showing"],
            aliases: ["teams", "ms teams"],
            triggers: ["teams", "microsoft teams"],
            weakTriggers: chatWeak + ["join", "call"]
        ),
        AppSkill(
            name: "zoom.us", bundleIDs: ["us.zoom.xos"],
            howItWorks: ["Home tab: 'New Meeting', 'Join', 'Schedule', 'Share Screen' buttons. Join asks for a meeting ID (and passcode); Schedule opens a form with Topic, date, time.",
                         "In a meeting: Mute (⌘⇧A), Video (⌘⇧V), Share Screen (⌘⇧S), Chat (⌘⇧H), 'Leave' at the bottom-right."],
            shortcuts: ["cmd+shift+a": "Mute / unmute", "cmd+shift+v": "Start / stop video", "cmd+j": "Join a meeting", "cmd+ctrl+v": "Start a meeting",
                        "cmd+shift+s": "Share screen", "cmd+shift+h": "Show / hide chat", "cmd+w": "Leave / end meeting"],
            recipes: [
                .init(goal: "join a meeting", keywords: ["join", "meeting", "call", "zoom", "hop on"],
                      steps: ["CLICK 'Join' (or KEY cmd+j)", "TYPE_TEXT the meeting ID", "CLICK 'Join'", "DONE when the meeting window shows"]),
                .init(goal: "start a meeting", keywords: ["start", "new meeting", "host", "open a zoom"], steps: ["CLICK 'New Meeting'"]),
                .init(goal: "mute / unmute / camera / leave", keywords: ["mute", "unmute", "camera", "video", "leave", "end"], steps: ["KEY cmd+shift+a (mute) / cmd+shift+v (video) / cmd+w (leave)"]),
            ],
            aliases: ["zoom"],
            triggers: ["meeting id", "meeting link", "meeting code", "zoom meeting", "zoom call"],
            weakTriggers: ["join"]
        ),

        // ── Notes, tasks, writing ──────────────────────────────────────────────
        AppSkill(
            name: "Notes", bundleIDs: ["com.apple.Notes"],
            howItWorks: [
                "Three columns: folders on the left, the note list in the middle, the open note's text on the right (role AXTextArea).",
                "A note has no separate title field: its FIRST LINE is the title. Type the title into the note body, then press Return and continue with the body.",
                "A brand-new note is empty and its text area already has keyboard focus.",
                "Search field at the top of the note list filters notes by content.",
                "⌘⇧L turns the current line into a checklist item; ⌘⇧T makes it a Title, ⌘⇧B body text.",
            ],
            shortcuts: ["cmd+n": "New note (empty note, cursor in the body)", "cmd+f": "Search notes",
                        "cmd+shift+n": "New folder", "cmd+return": "Finish editing / end the note",
                        "cmd+shift+t": "Make the current line a Title", "cmd+shift+b": "Make the current line Body text",
                        "cmd+shift+l": "Checklist", "cmd+shift+u": "Make the current line a Heading"],
            recipes: [
                .init(goal: "create a new note", keywords: ["new note", "create", "start", "new", "blank"],
                      steps: ["KEY cmd+n", "DONE when an empty note with a focused text area is open"]),
                .init(goal: "title a note / write something in a note", keywords: ["title", "name", "write", "type", "call", "put", "jot", "add", "note", "down", "remember"],
                      steps: ["If no empty note is open: KEY cmd+n", "TYPE_TEXT the title into the note's text area (AXTextArea) — the first line becomes the title",
                              "KEY Return", "TYPE_TEXT the rest of the content if the goal gives any"]),
                .init(goal: "add to the open note", keywords: ["add", "append", "also", "another line", "put"],
                      steps: ["CLICK the end of the note text area once", "KEY Return", "TYPE_TEXT the new line"]),
                .init(goal: "find a note", keywords: ["find", "open", "search", "look", "where", "pull up"],
                      steps: ["TYPE_TEXT the words into the Search field", "CLICK the matching note in the note list"]),
                .init(goal: "make a checklist", keywords: ["checklist", "check list", "to-do", "list"],
                      steps: ["KEY cmd+n if no note is open", "TYPE_TEXT the title", "KEY Return", "KEY cmd+shift+l", "TYPE_TEXT the first item", "KEY Return and TYPE_TEXT each next item"]),
            ],
            doneWhen: ["the note list shows a note whose first line is the requested title",
                       "the requested text is visible in the note body"],
            avoid: ["Do not type the title into the Search field or into a note-list cell.",
                    "Do not click the note body repeatedly: after one click (or ⌘N) it is already focused — type.",
                    "Do not choose DONE before the requested text is visible in the note."],
            fieldHints: ["The note body's first line is the title; for 'title it X' the value is X.", "A dictated note is written as said, first person, without 'note that'."],
            aliases: ["apple notes", "notes app"],
            triggers: ["note", "notes", "jot", "jot down", "write down", "take a note", "make a note"]
        ),
        AppSkill(
            name: "Reminders", bundleIDs: ["com.apple.reminders"],
            howItWorks: [
                "Lists on the left (Today, Scheduled, All, Flagged, Completed, then custom lists such as Groceries); the selected list's reminders on the right.",
                "⌘N adds a reminder to WHICHEVER LIST IS SELECTED in the sidebar (its title focused; Return saves it) — so when the goal names a list (Groceries, Work…), CLICK that list first, then ⌘N. ⌘⇧N makes a new list.",
                "Each reminder row has a circle checkbox (click = complete), the title, and an 'i' info button that opens date, time, repeat, notes, flag.",
                "Typing a natural date in the title ('call mom tomorrow at 3pm') is parsed into a date suggestion the user can accept.",
            ],
            shortcuts: ["cmd+n": "New reminder in the CURRENTLY SELECTED list only — when the goal names a different list, CLICK that list first", "cmd+shift+n": "New list",
                        "cmd+shift+f": "Flag the reminder", "cmd+e": "Indent (make sub-reminder)", "cmd+1": "Show Today", "cmd+2": "Show Scheduled", "cmd+3": "Show All", "cmd+4": "Show Flagged"],
            recipes: [
                .init(goal: "add a reminder", keywords: ["remind", "reminder", "add", "create", "todo", "to do", "to-do", "task", "don't forget", "remember"],
                      steps: ["If the goal names a list and it is not the selected one: CLICK that list in the sidebar (the FIRST action)", "KEY cmd+n", "TYPE_TEXT the reminder title", "KEY Return",
                              "DONE when the reminder row appears in the list"]),
                .init(goal: "add an item to a list (groceries, shopping)", keywords: ["list", "groceries", "grocery", "shopping", "milk", "buy"],
                      steps: ["FIRST: CLICK the named list (e.g. 'Groceries') in the sidebar so it is selected — not ⌘N yet", "THEN: KEY cmd+n", "TYPE_TEXT the item", "KEY Return", "DONE when the item is listed under that list"]),
                .init(goal: "set a time/date on a reminder", keywords: ["at", "tomorrow", "tonight", "on", "time", "date", "due"],
                      steps: ["Include the time in the title ('… tomorrow at 3pm') and accept the date suggestion, or CLICK the 'i' button and set Date/Time"]),
                .init(goal: "complete a reminder", keywords: ["complete", "done", "check off", "finish", "mark", "did"],
                      steps: ["CLICK the circle checkbox at the left of that reminder's row"]),
                .init(goal: "what's due / show reminders", keywords: ["what", "show", "due", "today", "scheduled"],
                      steps: ["KEY cmd+1 (Today) or cmd+2 (Scheduled)", "DONE when the list is showing"]),
            ],
            doneWhen: ["the reminder row with the requested title is listed"],
            avoid: ["Do not type the reminder into the search field.",
                    "Do not press ⌘N while a list other than the named one is selected (the row marked selected) — the reminder would land in the wrong list; CLICK the named list first."],
            fieldHints: ["A reminder title is the thing to do ('Call the dentist'), not 'remind me to'."],
            aliases: ["apple reminders", "reminders app", "to-do list", "todo list"],
            triggers: ["remind", "reminder", "reminders", "to-do", "todo", "to do", "grocery list", "groceries", "shopping list", "task", "errand"]
        ),
        AppSkill(
            name: "Things", bundleIDs: ["com.culturedcode.ThingsMac"],
            howItWorks: ["Sidebar: Inbox, Today, Upcoming, Anytime, Someday, then Projects/Areas. ⌘N makes a new to-do in the current list with its title focused; Return saves. ⌘K completes the selected to-do.",
                         "Typing in the title 'tomorrow'/'friday' does not set a date — use the calendar (⌘S 'When')."],
            shortcuts: ["cmd+n": "New to-do (title focused)", "cmd+shift+n": "New project", "cmd+k": "Complete the selected to-do", "cmd+1": "Inbox", "cmd+2": "Today",
                        "cmd+3": "Upcoming", "cmd+4": "Anytime", "cmd+5": "Someday", "cmd+s": "Set When (date) for the selected to-do"],
            recipes: [.init(goal: "add a to-do", keywords: ["add", "todo", "to-do", "task", "remind", "create"],
                            steps: ["KEY cmd+2 for Today (or CLICK the project)", "KEY cmd+n", "TYPE_TEXT the title", "KEY Return"])],
            doneWhen: ["the to-do is listed"],
            aliases: ["things 3", "things three"],
            triggers: ["to-do", "todo", "task"]
        ),
        AppSkill(
            name: "Todoist", bundleIDs: ["com.todoist.mac.Todoist"],
            howItWorks: ["Electron app. Sidebar: Inbox, Today, Upcoming, Filters & Labels, projects. The 'q' key (or '+ Add task') opens quick add: type the task, natural dates like 'tomorrow 3pm' are parsed; Return saves."],
            shortcuts: ["q": "Quick add a task", "cmd+f": "Search", "return": "Save the task"],
            recipes: [.init(goal: "add a task", keywords: ["add", "task", "todo", "to-do", "remind", "create"],
                            steps: ["KEY q", "TYPE_TEXT the task (with its date words)", "KEY Return"])],
            doneWhen: ["the task is listed"],
            triggers: ["todoist", "task"]
        ),
        AppSkill(
            name: "Stickies", bundleIDs: ["com.apple.Stickies"],
            howItWorks: ["Each note is its own small window (AXTextArea). ⌘N makes a new note that is focused; type directly."],
            shortcuts: ["cmd+n": "New sticky note (focused)"],
            recipes: [.init(goal: "write a sticky note", keywords: ["sticky", "note", "write", "remind"], steps: ["KEY cmd+n", "TYPE_TEXT the text"])],
            triggers: ["sticky", "stickies", "sticky note"]
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
            avoid: ["Do not click the text area repeatedly; it is focused after ⌘N."],
            aliases: ["text edit"],
            triggers: ["textedit", "plain text", "txt"]
        ),
        AppSkill(
            name: "Obsidian", bundleIDs: ["md.obsidian"],
            howItWorks: [
                "Electron app over a folder of markdown notes (the vault). The editor is a text area; the file explorer and search are in the left sidebar.",
                "⌘O opens the quick switcher: type a note name, Return opens it (or creates it if none matches). ⌘N makes a new note with the title selected.",
                "⌘P opens the command palette: type a command such as 'Open today's daily note' and press Return. ⌘⇧F searches all notes.",
                "Links are written as [[Note name]]; ⌘E toggles editing/reading view.",
            ],
            shortcuts: ["cmd+o": "Quick switcher: open (or create) a note by name", "cmd+n": "New note", "cmd+p": "Command palette (run any command by name)",
                        "cmd+shift+f": "Search in all notes", "cmd+e": "Toggle edit / reading view", "cmd+,": "Settings"],
            recipes: [
                .init(goal: "open a note", keywords: ["open", "find", "go to", "pull up", "show"], steps: ["KEY cmd+o", "TYPE_TEXT the note name", "KEY Return"]),
                .init(goal: "create a note / write in the vault", keywords: ["create", "new note", "write", "jot", "add", "note"],
                      steps: ["KEY cmd+n", "TYPE_TEXT the title", "KEY Return", "TYPE_TEXT the body"]),
                .init(goal: "today's daily note", keywords: ["daily", "today", "journal"], steps: ["KEY cmd+p", "TYPE_TEXT Open today's daily note", "KEY Return", "TYPE_TEXT the entry"]),
                .init(goal: "search the vault", keywords: ["search", "look", "where", "which note"], steps: ["KEY cmd+shift+f", "TYPE_TEXT the words", "KEY Return", "CLICK the matching result"]),
            ],
            doneWhen: ["the note is open with the requested text"],
            triggers: ["obsidian", "vault", "daily note", "markdown note"]
        ),
        AppSkill(
            name: "Bear", bundleIDs: ["net.shinyfrog.bear"],
            howItWorks: ["Sidebar of tags, note list, editor. ⌘N makes a new note whose first line is the title; #tags in the text organise it. The search field sits above the note list."],
            shortcuts: ["cmd+n": "New note (first line = title)"],
            recipes: [.init(goal: "write a note", keywords: ["note", "write", "jot", "create", "new"], steps: ["KEY cmd+n", "TYPE_TEXT the title", "KEY Return", "TYPE_TEXT the body"])],
            triggers: ["bear note"]
        ),
        AppSkill(
            name: "Notion", bundleIDs: ["notion.id"],
            howItWorks: ["Electron app. Sidebar lists pages; ⌘N makes a new page with its title focused (type the title, Return moves to the body). ⌘P searches pages. Blocks are contenteditable text; '/' opens the block menu."],
            shortcuts: ["cmd+n": "New page (title focused)", "cmd+p": "Search / jump to a page", "cmd+shift+n": "New window", "cmd+[": "Back"],
            recipes: [
                .init(goal: "create a page", keywords: ["create", "new page", "page", "note", "write"], steps: ["KEY cmd+n", "TYPE_TEXT the title", "KEY Return", "TYPE_TEXT the body"]),
                .init(goal: "open a page", keywords: ["open", "find", "go to"], steps: ["KEY cmd+p", "TYPE_TEXT the page name", "KEY Return"]),
            ],
            triggers: ["notion"]
        ),
        AppSkill(
            name: "Freeform", bundleIDs: ["com.apple.freeform"],
            howItWorks: ["A canvas app: boards in the sidebar, an infinite canvas with a toolbar (sticky note, shapes, text, media). Most of the canvas is not in the accessibility tree — prefer NEED_VISION for drawing."],
            shortcuts: ["cmd+n": "New board", "cmd+t": "Text box", "cmd+shift+n": "Sticky note"],
            avoid: ["Do not choose BLOCKED for canvas work; choose NEED_VISION."],
            triggers: ["freeform", "whiteboard"]
        ),
        AppSkill(
            name: "Pages", bundleIDs: ["com.apple.iWork.Pages"],
            howItWorks: ["⌘N opens the template chooser: CLICK 'Blank' then 'Create' to get an empty document whose body is focused. The body is an AXTextArea; ⌘S saves with a name sheet."],
            shortcuts: ["cmd+n": "New document (template chooser)", "cmd+s": "Save", "cmd+shift+e": "Export", "cmd+a": "Select all"],
            recipes: [
                .init(goal: "write a document", keywords: ["write", "create", "document", "type", "letter", "essay", "draft"],
                      steps: ["KEY cmd+n", "CLICK 'Blank'", "CLICK 'Create'", "TYPE_TEXT the content into the body", "DONE when the text is visible"]),
            ],
            doneWhen: ["the requested text is visible in the document body"],
            aliases: ["apple pages"],
            triggers: ["pages document"]
        ),
        AppSkill(
            name: "Numbers", bundleIDs: ["com.apple.iWork.Numbers"],
            howItWorks: ["⌘N opens the template chooser: CLICK 'Blank' then 'Create'. Cells are AXCell elements (labelled by their A1-style address); CLICK a cell then TYPE_TEXT and KEY Return to enter a value. A formula starts with '='."],
            shortcuts: ["cmd+n": "New spreadsheet", "cmd+s": "Save", "return": "Confirm the cell and move down", "tab": "Confirm the cell and move right"],
            recipes: [
                .init(goal: "enter values in a spreadsheet", keywords: ["enter", "put", "spreadsheet", "cell", "table", "column", "row", "sum", "total"],
                      steps: ["KEY cmd+n and CLICK 'Blank' → 'Create' if no sheet is open", "CLICK the cell", "TYPE_TEXT the value", "KEY Return", "repeat for the next cell"]),
            ],
            aliases: ["apple numbers"],
            triggers: ["spreadsheet"]
        ),
        AppSkill(
            name: "Keynote", bundleIDs: ["com.apple.iWork.Keynote"],
            howItWorks: ["⌘N opens the theme chooser (CLICK a theme, then 'Create'). Slides are listed on the left; the title and body are text boxes on the slide (double-click to edit). ⌘⇧N adds a slide."],
            shortcuts: ["cmd+n": "New presentation", "cmd+shift+n": "New slide", "cmd+option+p": "Play the slideshow", "escape": "Stop the slideshow"],
            recipes: [.init(goal: "make slides", keywords: ["slide", "slides", "presentation", "deck"], steps: ["KEY cmd+n", "CLICK a theme", "CLICK 'Create'", "double-click the title box and TYPE_TEXT", "KEY cmd+shift+n for each new slide"])],
            aliases: ["apple keynote"],
            triggers: ["keynote", "presentation", "slides", "deck", "slideshow"]
        ),
        AppSkill(
            name: "Microsoft Word", bundleIDs: ["com.microsoft.Word"],
            howItWorks: ["⌘N opens a new blank document (or the template gallery: CLICK 'Blank Document' then 'Create'). The page body is the text area; ⌘S saves."],
            shortcuts: ["cmd+n": "New document", "cmd+s": "Save", "cmd+a": "Select all", "cmd+b": "Bold"],
            recipes: [.init(goal: "write a document", keywords: ["write", "create", "document", "type", "draft"], steps: ["KEY cmd+n", "TYPE_TEXT the content into the page", "DONE when visible"])],
            aliases: ["word", "ms word"],
            triggers: ["word document", "docx"]
        ),
        AppSkill(
            name: "Microsoft Excel", bundleIDs: ["com.microsoft.Excel"],
            howItWorks: ["Cells are addressed A1-style; CLICK a cell, TYPE_TEXT, KEY Return. The formula bar shows the active cell's content; formulas start with '='."],
            shortcuts: ["cmd+n": "New workbook", "cmd+s": "Save", "return": "Confirm cell, move down", "tab": "Confirm cell, move right"],
            recipes: [.init(goal: "enter values / formulas", keywords: ["enter", "cell", "spreadsheet", "sum", "formula", "column", "row"], steps: ["CLICK the cell", "TYPE_TEXT the value or =formula", "KEY Return"])],
            aliases: ["excel", "ms excel"],
            triggers: ["excel", "xlsx", "spreadsheet", "workbook"]
        ),
        AppSkill(
            name: "Microsoft PowerPoint", bundleIDs: ["com.microsoft.Powerpoint"],
            howItWorks: ["⌘N opens a new presentation (or the gallery: CLICK a theme then 'Create'). Slides on the left; title/body placeholders on the slide are clicked then typed into. ⌘⇧N adds a slide."],
            shortcuts: ["cmd+n": "New presentation", "cmd+shift+n": "New slide", "cmd+s": "Save"],
            recipes: [.init(goal: "make slides", keywords: ["slide", "slides", "presentation", "deck"], steps: ["KEY cmd+n", "CLICK the title placeholder and TYPE_TEXT", "KEY cmd+shift+n for each new slide"])],
            aliases: ["powerpoint", "power point"],
            triggers: ["powerpoint", "pptx", "presentation", "slides"]
        ),

        // ── Calendar, contacts, time ──────────────────────────────────────────
        AppSkill(
            name: "Calendar", bundleIDs: ["com.apple.iCal"],
            howItWorks: [
                "Toolbar: Day/Week/Month/Year view buttons, ◀ Today ▶ arrows, a '+' button that creates an event, and a search field.",
                "⌘N creates a new event on the selected day with its title field focused; Return saves it. Double-clicking a time slot in Day/Week view also creates an event there.",
                "The event inspector (popover) has: title, location, 'all-day' checkbox, starts/ends date & time fields, repeat, alert, invitees, notes.",
                "Date/time fields are editable text: click the hour, type the number, Tab to minutes, Tab to AM/PM. ⌘T jumps to today; ⌘⇧T goes to a typed date.",
                "Search (⌘F / top-right field) finds events by title. ⌘⌫ deletes the selected event.",
            ],
            shortcuts: ["cmd+n": "New event on the selected day (title focused)", "cmd+t": "Go to today", "cmd+1": "Day view", "cmd+2": "Week view",
                        "cmd+3": "Month view", "cmd+4": "Year view", "cmd+f": "Search events", "cmd+right": "Next day/week/month", "cmd+left": "Previous day/week/month",
                        "cmd+shift+t": "Go to a specific date", "cmd+delete": "Delete the selected event"],
            recipes: [
                .init(goal: "create an event / meeting / appointment", keywords: ["create", "add", "schedule", "event", "meeting", "appointment", "book", "put", "set up", "block", "calendar", "plan"],
                      steps: ["KEY cmd+n (or CLICK the '+' toolbar button)", "TYPE_TEXT the event title into the focused title field",
                              "Set the date and time fields in the inspector (click the field, type the value)", "KEY Return to save", "DONE when the event shows on the calendar grid"]),
                .init(goal: "check what's on / find an event", keywords: ["what", "when", "check", "find", "show", "next", "today", "tomorrow", "free", "busy", "week"],
                      steps: ["KEY cmd+t for today, or CLICK ◀/▶ to reach the day (KEY cmd+2 for the week)", "DONE when that day's events are visible"]),
                .init(goal: "move / reschedule / delete an event", keywords: ["move", "reschedule", "change", "delete", "cancel", "remove"],
                      steps: ["CLICK the event on the grid", "For a change: edit the date/time fields in the inspector", "For deletion: KEY cmd+delete"]),
                .init(goal: "invite someone to an event", keywords: ["invite", "add", "with"],
                      steps: ["CLICK the event", "CLICK 'Add Invitees…' in the inspector", "TYPE_TEXT the name", "KEY Return"]),
            ],
            doneWhen: ["the new event is drawn on the calendar grid with the requested title"],
            avoid: ["Do not click 'next day' repeatedly to find a date — use ⌘⇧T (go to date) or the Month view.",
                    "Do not create a second event when one with the title already exists on that day.",
                    "Set the time in the inspector fields, not by clicking around the grid."],
            fieldHints: ["Event title is a short phrase (e.g. 'Dinner with Sam'), never a sentence about the task."],
            aliases: ["apple calendar", "cal", "calendar app"],
            triggers: ["calendar", "event", "appointment", "schedule", "invite", "block off", "on my calendar"]
        ),
        AppSkill(
            name: "Contacts", bundleIDs: ["com.apple.AddressBook"],
            howItWorks: ["Search field at the top-left filters the list; selecting a contact shows the card with phone/email. ⌘N creates a new contact with First name focused."],
            shortcuts: ["cmd+n": "New contact", "cmd+f": "Search contacts", "cmd+l": "Edit the card"],
            recipes: [
                .init(goal: "find someone's number / email", keywords: ["find", "number", "phone", "email", "contact", "look up", "address"],
                      steps: ["KEY cmd+f", "TYPE_TEXT the name", "CLICK the matching contact", "DONE when the card is showing"]),
                .init(goal: "add a contact", keywords: ["add", "create", "new contact", "save"],
                      steps: ["KEY cmd+n", "TYPE_TEXT the first name", "KEY Tab", "TYPE_TEXT the last name", "fill the phone/email fields", "CLICK Done"]),
            ],
            doneWhen: ["the contact card with the requested name is showing"],
            aliases: ["address book"],
            triggers: ["contact", "contacts", "phone number", "address book", "number for"]
        ),
        AppSkill(
            name: "Clock", bundleIDs: ["com.apple.clock"],
            howItWorks: ["Tabs at the top: World Clock, Alarm, Stopwatch, Timer. Timer has hours/minutes/seconds fields (click a field, type), a label, and a Start button; Alarm has a '+' button opening time fields and a Save button; Stopwatch has Start/Lap."],
            recipes: [
                .init(goal: "set a timer", keywords: ["timer", "minutes", "countdown", "seconds", "hour"], steps: ["CLICK 'Timer'", "CLICK the minutes field and TYPE_TEXT the value (hours/seconds likewise)", "CLICK 'Start'", "DONE when the countdown is running"]),
                .init(goal: "set an alarm", keywords: ["alarm", "wake", "wake me"], steps: ["CLICK 'Alarm'", "CLICK '+'", "set the time fields (hour, minute, AM/PM)", "CLICK 'Save'"]),
                .init(goal: "stopwatch", keywords: ["stopwatch", "time this", "lap"], steps: ["CLICK 'Stopwatch'", "CLICK 'Start'"]),
                .init(goal: "time in a city", keywords: ["time in", "what time", "world clock", "time zone"], steps: ["CLICK 'World Clock'", "CLICK '+' and TYPE_TEXT the city if it is not listed", "DONE when the city's time is showing"]),
            ],
            doneWhen: ["the timer is counting down", "the alarm is listed and switched on"],
            triggers: ["timer", "alarm", "stopwatch", "countdown", "wake me", "world clock", "time in"]
        ),
        AppSkill(
            name: "Weather", bundleIDs: ["com.apple.weather"],
            howItWorks: ["Sidebar lists saved locations with a search field at the top; the main pane shows the hourly and 10-day forecast for the selected one. Type a city in the search field and click the result to see it."],
            shortcuts: ["cmd+f": "Search for a location"],
            recipes: [.init(goal: "weather for a place", keywords: ["weather", "forecast", "temperature", "rain", "snow", "hot", "cold", "umbrella"], steps: ["KEY cmd+f", "TYPE_TEXT the city", "CLICK the matching result", "DONE when the forecast for that city is showing"])],
            doneWhen: ["the forecast for the requested city is showing"],
            triggers: ["weather", "forecast", "temperature outside", "going to rain"]
        ),

        // ── Files and system ──────────────────────────────────────────────────
        AppSkill(
            name: "Finder", bundleIDs: ["com.apple.finder"],
            howItWorks: [
                "Sidebar (Favorites: AirDrop, Recents, Applications, Desktop, Documents, Downloads; iCloud; Locations) on the left; the folder contents on the right.",
                "⌘⇧G opens 'Go to Folder' with a path field; ⌘N opens a new Finder window; ⌘⇧N makes a new folder named 'untitled folder' with its name selected — type the name and press Return.",
                "Return on a selected item RENAMES it; ⌘O or ⌘↓ opens it. Space shows a Quick Look preview. ⌘D duplicates.",
                "The search field (⌘F / top right) searches the Mac; results appear in the same window.",
                "Files are moved by ⌘C then ⌘⌥V (move), copied with ⌘C/⌘V, deleted with ⌘⌫ (to Trash — recoverable). Right-click → Compress zips; Share → AirDrop sends.",
            ],
            shortcuts: ["cmd+n": "New Finder window", "cmd+shift+n": "New folder (name selected for typing)", "cmd+shift+g": "Go to folder (path field)",
                        "cmd+o": "Open the selected item", "cmd+down": "Open the selected item", "cmd+up": "Go to the enclosing folder",
                        "cmd+f": "Search", "cmd+delete": "Move selected item to Trash", "cmd+i": "Get Info", "space": "Quick Look preview",
                        "cmd+shift+d": "Go to Desktop", "cmd+shift+o": "Go to Documents", "cmd+option+l": "Go to Downloads", "cmd+shift+a": "Go to Applications",
                        "cmd+shift+r": "AirDrop", "cmd+1": "Icon view", "cmd+2": "List view", "cmd+3": "Column view", "cmd+d": "Duplicate", "cmd+t": "New tab",
                        "cmd+shift+.": "Show / hide hidden files", "cmd+e": "Eject the selected disk"],
            recipes: [
                .init(goal: "open a folder", keywords: ["open", "go to", "show", "folder", "downloads", "documents", "desktop", "applications"],
                      steps: ["CLICK the folder in the sidebar (or KEY cmd+option+l for Downloads, cmd+shift+o Documents, cmd+shift+d Desktop), or KEY cmd+shift+g and TYPE_TEXT the path then KEY Return"]),
                .init(goal: "create a folder", keywords: ["create", "make", "new folder", "folder"],
                      steps: ["Navigate to the parent folder", "KEY cmd+shift+n", "TYPE_TEXT the folder name (it replaces 'untitled folder')", "KEY Return"]),
                .init(goal: "find a file", keywords: ["find", "search", "locate", "file", "where", "pdf", "document", "recent"],
                      steps: ["KEY cmd+f", "TYPE_TEXT the file name or words", "KEY Return", "DONE when the matching file is listed (CLICK it to select; KEY cmd+o to open)"]),
                .init(goal: "open a file", keywords: ["open", "launch", "file"], steps: ["CLICK the file once to select it", "KEY cmd+o"]),
                .init(goal: "rename a file", keywords: ["rename", "name", "call"],
                      steps: ["CLICK the file once to select it", "KEY Return", "TYPE_TEXT the new name", "KEY Return"]),
                .init(goal: "delete a file", keywords: ["delete", "trash", "remove", "get rid"],
                      steps: ["CLICK the file to select it", "KEY cmd+delete"]),
                .init(goal: "move / copy a file", keywords: ["move", "copy", "put", "drag", "into"],
                      steps: ["CLICK the file", "KEY cmd+c", "Navigate to the destination folder", "KEY cmd+option+v (move) or cmd+v (copy)"]),
                .init(goal: "airdrop / share / compress a file", keywords: ["airdrop", "share", "zip", "compress", "send"],
                      steps: ["CLICK the file", "CLICK the Share toolbar button → AirDrop, or right-click → 'Compress'"]),
            ],
            doneWhen: ["the requested folder's contents are showing", "the new/renamed item is listed with the requested name"],
            avoid: ["Do not press Return to open a file — Return renames; use ⌘O.", "Do not create the folder before navigating into the right parent folder.",
                    "Never empty the Trash (that permanently deletes data)."],
            aliases: ["files", "file browser"],
            triggers: ["file", "files", "folder", "downloads", "desktop", "documents", "finder", "pdf", "screenshot", "screenshots"]
        ),
        AppSkill(
            name: "System Settings", bundleIDs: ["com.apple.systempreferences"],
            howItWorks: [
                "Sidebar lists panes: Wi-Fi, Bluetooth, Network, Battery, General (Software Update, Storage, AirDrop & Handoff, Login Items, Date & Time), Accessibility, Appearance (Light/Dark), Control Center, Desktop & Dock (default browser, hot corners), Displays (brightness, Night Shift), Screen Saver, Wallpaper, Notifications, Sound (output/input, volume), Focus (Do Not Disturb), Screen Time, Lock Screen, Privacy & Security, Users & Groups, Internet Accounts, Passwords, Keyboard (shortcuts, dictation), Trackpad, Mouse, Printers & Scanners.",
                "The search field at the top of the sidebar jumps to a setting by name — the fastest way to any control.",
                "Toggles are switches (AXCheckBox/AXSwitch): do not click one that is already in the requested state. Some panes ask for the password — stop there and tell the user.",
            ],
            shortcuts: ["cmd+f": "Search settings"],
            recipes: [
                .init(goal: "change a setting", keywords: ["turn", "enable", "disable", "set", "change", "switch", "on", "off", "wifi", "wi-fi", "bluetooth", "dark", "light", "volume", "wallpaper", "brightness", "notifications", "keyboard", "trackpad", "mouse", "printer", "browser", "hot corner", "night shift", "focus", "do not disturb"],
                      steps: ["KEY cmd+f and TYPE_TEXT the setting name, then CLICK the result (or CLICK the pane in the sidebar)",
                              "CLICK the switch/control for the setting", "DONE when the control shows the requested state"]),
                .init(goal: "connect to wifi / bluetooth device", keywords: ["connect", "wifi", "wi-fi", "network", "bluetooth", "airpods", "headphones", "pair"],
                      steps: ["CLICK 'Wi-Fi' or 'Bluetooth' in the sidebar", "CLICK 'Connect' next to the network/device"]),
                .init(goal: "default browser / dock / appearance", keywords: ["default browser", "dock", "appearance", "theme", "accent"],
                      steps: ["CLICK 'Desktop & Dock' (default browser, hot corners) or 'Appearance' (Light/Dark/Auto)", "CLICK the option"]),
            ],
            doneWhen: ["the switch/control shows the requested state"],
            avoid: ["Do not toggle a switch that already shows the requested state.", "Never change Privacy & Security, passwords or user accounts; stop and tell the user."],
            aliases: ["settings", "system preferences", "preferences", "settings app"],
            triggers: ["settings", "preferences", "wallpaper", "wifi", "wi-fi", "bluetooth", "dark mode", "light mode", "brightness", "trackpad", "printer",
                       "default browser", "notifications", "do not disturb", "focus mode", "battery", "accessibility", "login items", "screen saver", "night shift", "hot corner", "sound output", "airpods"]
        ),
        AppSkill(
            name: "Terminal", bundleIDs: ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "io.alacritty", "org.alacritty", "net.kovidgoyal.kitty"],
            howItWorks: ["A shell prompt in a text area: type the command and press Return to run it; output appears below. ⌘T opens a new tab, ⌘N a new window, ⌘K clears, ⌃C interrupts."],
            shortcuts: ["return": "Run the typed command", "cmd+t": "New tab", "cmd+n": "New window", "cmd+k": "Clear", "ctrl+c": "Interrupt the running command"],
            recipes: [
                .init(goal: "run a command", keywords: ["run", "execute", "command", "type", "ls", "cd", "git", "brew", "npm", "python", "ssh", "install"],
                      steps: ["TYPE_TEXT the command into the terminal text area", "KEY Return", "DONE when the output is visible"]),
            ],
            doneWhen: ["the command's output (or a new prompt) is visible below the command"],
            avoid: ["Do not press Return twice.", "Never run rm -rf, disk-erasing or sudo commands the goal did not spell out."],
            aliases: ["iterm", "iterm2", "warp", "ghostty", "shell", "command line"],
            triggers: ["terminal", "command line", "shell", "brew", "npm", "ssh", "git pull", "git push", "run the command"]
        ),
        AppSkill(
            name: "Activity Monitor", bundleIDs: ["com.apple.ActivityMonitor"],
            howItWorks: ["Tabs: CPU, Memory, Energy, Disk, Network (⌘1–⌘5). The process table lists Process Name, % CPU, Memory…; click a column header to sort. The search field at the top-right filters by name.",
                         "To quit a process: CLICK its row, CLICK the ⓧ (Stop) toolbar button, then 'Quit' (or 'Force Quit')."],
            shortcuts: ["cmd+1": "CPU tab", "cmd+2": "Memory tab", "cmd+3": "Energy tab", "cmd+4": "Disk tab", "cmd+5": "Network tab", "cmd+f": "Search processes"],
            recipes: [
                .init(goal: "what's using CPU / memory", keywords: ["cpu", "memory", "using", "slow", "hog", "battery", "energy"], steps: ["KEY cmd+1 (or cmd+2)", "CLICK the '% CPU' (or 'Memory') column header to sort descending", "DONE when the top processes are visible"]),
                .init(goal: "quit / force quit a process", keywords: ["quit", "force quit", "kill", "stop", "frozen", "not responding"], steps: ["KEY cmd+f and TYPE_TEXT the app name", "CLICK the process row", "CLICK the ⓧ Stop button", "CLICK 'Quit' (or 'Force Quit' if it will not quit)"]),
            ],
            aliases: ["task manager"],
            triggers: ["activity monitor", "cpu", "memory usage", "force quit", "not responding", "using so much"]
        ),
        AppSkill(
            name: "App Store", bundleIDs: ["com.apple.AppStore"],
            howItWorks: ["Sidebar: Discover, Arcade, Create, Work, Play, Develop, Categories, Updates; a search field at its top. An app page has a 'Get' / price / 'Update' / 'Open' button; installing may ask for the Apple ID password — stop there."],
            recipes: [
                .init(goal: "install / find an app", keywords: ["install", "download", "get", "find", "search", "app"], steps: ["CLICK the search field", "TYPE_TEXT the app name", "KEY Return", "CLICK the app", "CLICK 'Get' (or the price — only if the goal asks to buy)"]),
                .init(goal: "update apps", keywords: ["update", "updates"], steps: ["CLICK 'Updates' in the sidebar", "CLICK 'Update All'"]),
            ],
            avoid: ["Never enter an Apple ID password; if asked, stop and tell the user.", "Do not buy a paid app unless the goal says to."],
            aliases: ["the app store", "mac app store"],
            triggers: ["app store", "install", "update apps", "download an app", "update my apps"]
        ),
        AppSkill(
            name: "QuickTime Player", bundleIDs: ["com.apple.QuickTimePlayerX"],
            howItWorks: ["Opens movies and records. ⌃⌘N starts a new screen recording (a control bar appears: click 'Record', then the stop button in the menu bar), ⌥⌘N a new movie (camera) recording, ⌃⌥⌘N an audio recording. Space plays/pauses an open movie."],
            shortcuts: ["ctrl+cmd+n": "New screen recording", "option+cmd+n": "New movie (camera) recording", "ctrl+option+cmd+n": "New audio recording", "space": "Play / pause", "cmd+o": "Open a file", "cmd+s": "Save", "cmd+e": "Export"],
            recipes: [
                .init(goal: "record the screen", keywords: ["record", "screen recording", "screencast", "capture"], steps: ["KEY ctrl+cmd+n", "CLICK 'Record'", "DONE when recording (the user stops it from the menu bar)"]),
                .init(goal: "record audio / a video of me", keywords: ["audio", "voice", "camera", "webcam", "video of"], steps: ["KEY ctrl+option+cmd+n (audio) or option+cmd+n (camera)", "CLICK the red Record button"]),
                .init(goal: "play a movie file", keywords: ["play", "open", "watch", "movie", "video"], steps: ["KEY cmd+o", "TYPE_TEXT the file name", "KEY Return", "KEY space"]),
            ],
            aliases: ["quicktime", "quick time"],
            triggers: ["quicktime", "screen recording", "record my screen", "record the screen", "screencast"]
        ),
        AppSkill(
            name: "Shortcuts", bundleIDs: ["com.apple.shortcuts"],
            howItWorks: ["Sidebar: All Shortcuts, Gallery, folders. The grid shows shortcut tiles; a search field at the top filters them. Selecting a tile and pressing ⌘R runs it (the ▶ button on the tile does too)."],
            shortcuts: ["cmd+r": "Run the selected shortcut", "cmd+n": "New shortcut", "cmd+f": "Search shortcuts"],
            recipes: [.init(goal: "run a shortcut", keywords: ["run", "shortcut", "trigger", "execute"], steps: ["KEY cmd+f", "TYPE_TEXT the shortcut name", "CLICK the shortcut tile", "KEY cmd+r"])],
            aliases: ["shortcuts app", "apple shortcuts"],
            triggers: ["run the shortcut", "my shortcuts", "shortcuts app", "run my"]
        ),
        AppSkill(
            name: "Voice Memos", bundleIDs: ["com.apple.VoiceMemos"],
            howItWorks: ["Recordings listed on the left; a big red Record button at the bottom-left starts a new recording (⌘N too) and turns into a Done/stop button. Play with the ▶ button; rename by clicking the title."],
            shortcuts: ["cmd+n": "New recording (starts recording)", "cmd+f": "Search recordings"],
            recipes: [.init(goal: "record a voice memo", keywords: ["record", "memo", "voice memo", "recording"], steps: ["KEY cmd+n (or CLICK the red Record button)", "DONE when recording is in progress (the user stops it)"])],
            aliases: ["voice memo", "memos"],
            triggers: ["voice memo", "voice memos", "record a memo"]
        ),
        AppSkill(
            name: "Home", bundleIDs: ["com.apple.Home"],
            howItWorks: ["Rooms and accessories are tiles; clicking a light/switch tile toggles it, clicking a scene ('Good Night', 'Movie Time') runs it. Long-press / the tile's details set brightness or colour. Sidebar lists Home, Automation, rooms."],
            recipes: [
                .init(goal: "turn a light / accessory on or off", keywords: ["light", "lights", "lamp", "turn", "on", "off", "plug", "fan", "thermostat"], steps: ["CLICK the room in the sidebar if named", "CLICK the accessory tile (its subtitle says On/Off)", "DONE when the tile shows the requested state"]),
                .init(goal: "run a scene", keywords: ["scene", "good night", "movie", "arrive", "leave"], steps: ["CLICK the scene tile"]),
            ],
            avoid: ["Do not click a tile that already shows the requested state (it would toggle back)."],
            aliases: ["homekit", "home app"],
            triggers: ["lights", "light", "lamp", "thermostat", "homekit", "smart home", "scene"]
        ),
        AppSkill(
            name: "Translate", bundleIDs: ["com.apple.Translate"],
            howItWorks: ["Two language pop-up buttons at the top (from → to); a text field on the left takes the text (Return translates), the translation appears on the right with a speaker button."],
            recipes: [.init(goal: "translate text", keywords: ["translate", "translation", "spanish", "french", "german", "japanese", "chinese", "say in", "how do you say"],
                            steps: ["SELECT the target language in the second pop-up if the goal names one", "TYPE_TEXT the text into the left field", "KEY Return", "DONE when the translation is showing"])],
            triggers: ["translate", "translation", "how do you say"]
        ),
        AppSkill(
            name: "Dictionary", bundleIDs: ["com.apple.Dictionary"],
            howItWorks: ["A search field at the top; typing a word shows its definitions (Dictionary, Thesaurus, Wikipedia tabs)."],
            recipes: [.init(goal: "define a word", keywords: ["define", "definition", "meaning", "synonym", "thesaurus", "spell", "what does"], steps: ["CLICK the search field", "TYPE_TEXT the word", "DONE when the definition is showing"])],
            triggers: ["define", "definition", "dictionary", "meaning of", "synonym", "thesaurus", "spell"]
        ),
        AppSkill(
            name: "Find My", bundleIDs: ["com.apple.findmy"],
            howItWorks: ["Tabs on the left: People, Devices, Items. Clicking a device/item shows it on the map with 'Play Sound', 'Directions', 'Mark As Lost'."],
            recipes: [.init(goal: "find a device / play a sound on it", keywords: ["find my", "where is", "where's", "iphone", "airpods", "airtag", "locate", "play sound", "lost"],
                            steps: ["CLICK 'Devices' (or 'Items' / 'People')", "CLICK the device name", "CLICK 'Play Sound' if asked to ring it", "DONE when its location is showing"])],
            avoid: ["Never click 'Mark As Lost' or 'Erase This Device'."],
            aliases: ["findmy"],
            triggers: ["find my", "where's my iphone", "where is my iphone", "where's my phone", "airtag", "locate my"]
        ),
        AppSkill(
            name: "Photo Booth", bundleIDs: ["com.apple.PhotoBooth"],
            howItWorks: ["Shows the camera; the red camera button at the bottom-centre takes a photo (3-2-1 countdown). Buttons at the bottom-left switch between photo, four-up and video; 'Effects' at the bottom-right."],
            recipes: [.init(goal: "take a photo / selfie", keywords: ["photo", "picture", "selfie", "take", "snap", "webcam"], steps: ["CLICK the red camera button", "DONE after the countdown when the thumbnail appears"])],
            aliases: ["photobooth"],
            triggers: ["photo booth", "selfie", "take a picture", "take a photo", "take my picture", "webcam photo"]
        ),
        AppSkill(
            name: "Preview", bundleIDs: ["com.apple.Preview"],
            howItWorks: ["Shows PDFs and images. ⌘F searches the document; the sidebar (⌘⌥1) shows thumbnails; ⌘S saves, ⌘⇧S exports. ⌘⇧A shows the Markup toolbar (text, shapes, sign, highlight)."],
            shortcuts: ["cmd+f": "Find in document", "cmd+o": "Open a file", "cmd+s": "Save", "cmd+shift+s": "Export", "cmd+option+1": "Toggle thumbnails sidebar", "cmd+shift+a": "Show the Markup toolbar", "cmd+p": "Print"],
            recipes: [
                .init(goal: "find text in the PDF / go to a page", keywords: ["find", "search", "page", "where", "go to"], steps: ["KEY cmd+f", "TYPE_TEXT the words", "KEY Return"]),
                .init(goal: "annotate / sign / highlight", keywords: ["sign", "signature", "annotate", "markup", "highlight", "draw", "fill"], steps: ["KEY cmd+shift+a", "CLICK the tool (Text, Sign, Highlight…)", "NEED_VISION to place it on the page"]),
            ],
            doneWhen: ["the requested page/text is showing"],
            triggers: ["pdf", "preview", "markup", "annotate", "sign the"]
        ),

        // ── Media ─────────────────────────────────────────────────────────────
        AppSkill(
            name: "Spotify", bundleIDs: ["com.spotify.client"],
            howItWorks: [
                "Electron app: the search field is at the top ('What do you want to play?'); results show Top result, Songs, Artists, Albums, Playlists, Podcasts with a green play button.",
                "The player bar at the bottom shows the current track and play/pause, next/previous, shuffle, repeat; Space toggles playback. 'Your Library' is in the left sidebar.",
            ],
            shortcuts: ["cmd+l": "Focus the search field", "space": "Play / pause", "cmd+right": "Next track", "cmd+left": "Previous track", "cmd+shift+left": "Back", "cmd+up": "Volume up", "cmd+down": "Volume down"],
            recipes: [
                .init(goal: "play something", keywords: ["play", "listen", "put on", "throw on", "song", "music", "album", "artist", "playlist", "podcast", "queue"],
                      steps: ["KEY cmd+l", "TYPE_TEXT the name", "KEY Return", "CLICK the green play button of the top result", "DONE when the player bar shows it"]),
                .init(goal: "pause / resume / skip / volume", keywords: ["pause", "stop", "resume", "skip", "next", "previous", "back", "volume", "louder", "quieter", "turn it up", "turn it down"],
                      steps: ["KEY space (pause/resume), cmd+right (next), cmd+left (previous), cmd+up / cmd+down (volume)"]),
                .init(goal: "like / save the current song", keywords: ["like", "save", "favorite", "heart", "add to"], steps: ["CLICK the '+' / 'Add to Liked Songs' button in the player bar"]),
            ],
            doneWhen: ["the bottom player bar shows the requested title and a pause button"],
            avoid: ["Do not choose DONE with only results on screen."],
            triggers: ["spotify", "song", "songs", "music", "album", "artist", "playlist", "track", "podcast", "jazz", "lofi", "lo-fi", "hip hop", "rap", "rock", "classical", "pop music", "country music", "edm", "beats", "tunes", "radio", "something chill", "some music", "my playlist", "liked songs", "workout music", "study music"],
            weakTriggers: mediaWeak + ["volume", "louder", "quieter"]
        ),
        AppSkill(
            name: "Music", bundleIDs: ["com.apple.Music"],
            howItWorks: [
                "Sidebar: Home, New, Radio, Search; then Library (Recently Added, Artists, Albums, Songs, Playlists). The player controls and the 'Now Playing' title are at the top.",
                "The Search field (⌘F) searches your library and Apple Music; results list songs/albums with a play button (▶) on hover — Return on a selected song plays it.",
                "Space toggles play/pause; ⌘→ skips to the next track; ⌘L shows the current song.",
            ],
            shortcuts: ["space": "Play / pause", "cmd+f": "Search", "cmd+right": "Next track", "cmd+left": "Previous track", "cmd+up": "Volume up", "cmd+down": "Volume down",
                        "cmd+l": "Show the current song", "cmd+n": "New playlist"],
            recipes: [
                .init(goal: "play a song / artist / album / playlist", keywords: ["play", "listen", "put on", "throw on", "song", "music", "album", "artist", "playlist", "queue"],
                      steps: ["KEY cmd+f", "TYPE_TEXT the song/artist name into the search field", "KEY Return", "CLICK the matching result's play button or the result then KEY Return",
                              "DONE when the Now Playing area shows that title"]),
                .init(goal: "pause / resume / skip / volume", keywords: ["pause", "stop", "resume", "skip", "next", "previous", "back", "volume", "louder", "quieter"],
                      steps: ["KEY space (pause/resume), cmd+right (next), cmd+left (previous), cmd+up / cmd+down (volume)"]),
            ],
            doneWhen: ["the Now Playing title at the top is the requested song/artist and the pause button is showing"],
            avoid: ["Do not choose DONE when only search results are showing — the song must be playing."],
            aliases: ["apple music", "itunes", "music app"],
            triggers: ["song", "songs", "music", "album", "artist", "playlist", "track", "apple music", "jazz", "lofi", "lo-fi", "hip hop", "rap", "rock", "classical", "pop music", "country music", "edm", "beats", "tunes", "radio", "something chill", "some music", "my playlist", "liked songs", "workout music", "study music"],
            weakTriggers: mediaWeak + ["volume", "louder", "quieter"]
        ),
        AppSkill(
            name: "Podcasts", bundleIDs: ["com.apple.podcasts"],
            howItWorks: ["Sidebar: Listen Now, Browse, Top Charts, Library (Shows, Episodes, Downloaded); a search field at the top of the sidebar. A show page lists episodes with a ▶ play button; the player is at the top. Space toggles playback."],
            shortcuts: ["space": "Play / pause", "cmd+f": "Search podcasts", "cmd+right": "Skip forward", "cmd+left": "Skip back"],
            recipes: [.init(goal: "play a podcast / episode", keywords: ["play", "listen", "podcast", "episode", "latest", "put on"],
                            steps: ["KEY cmd+f", "TYPE_TEXT the show name", "KEY Return", "CLICK the show", "CLICK ▶ on the latest (or named) episode", "DONE when the player shows it"])],
            doneWhen: ["the player at the top shows the episode playing"],
            aliases: ["apple podcasts"],
            triggers: ["podcast", "podcasts", "episode"],
            weakTriggers: mediaWeak
        ),
        AppSkill(
            name: "TV", bundleIDs: ["com.apple.TV"],
            howItWorks: ["Sidebar: Home, Apple TV+, MLS, Store, Library, Search (field at the top). A title page has 'Play' / 'Continue' buttons; 'Up Next' on Home continues what you were watching. Space toggles playback in the player."],
            shortcuts: ["space": "Play / pause", "cmd+f": "Search", "escape": "Leave full screen"],
            recipes: [.init(goal: "watch a show / movie", keywords: ["watch", "play", "movie", "show", "episode", "series", "continue", "put on"],
                            steps: ["KEY cmd+f", "TYPE_TEXT the title", "KEY Return", "CLICK the title", "CLICK 'Play' / 'Continue'", "DONE when the player is showing"])],
            aliases: ["apple tv", "tv app"],
            triggers: ["apple tv", "tv show", "movie", "series", "episode"],
            weakTriggers: ["watch", "play", "continue"]
        ),
        AppSkill(
            name: "Books", bundleIDs: ["com.apple.iBooks"],
            howItWorks: ["Sidebar: Home, Book Store, Audiobook Store, All, Want to Read, Finished, Collections; a search field at the top. Double-clicking a book cover opens it; arrow keys turn pages. Audiobooks play with a ▶ button."],
            shortcuts: ["cmd+f": "Search", "right": "Next page", "left": "Previous page"],
            recipes: [.init(goal: "open / read a book", keywords: ["read", "open", "book", "audiobook", "chapter", "continue"], steps: ["KEY cmd+f", "TYPE_TEXT the title", "KEY Return", "double-click the book (CLICK it then KEY Return)", "DONE when the pages are showing"])],
            aliases: ["apple books", "ibooks"],
            triggers: ["audiobook", "ebook", "read a book", "my books", "apple books"]
        ),
        AppSkill(
            name: "Photos", bundleIDs: ["com.apple.Photos"],
            howItWorks: ["Sidebar: Library, Memories, Favorites, Albums, Shared…; the search field (⌘F) finds photos by people, places, dates and content. Double-click (or Return) opens a photo; '.' favorites it; ⌘⌫ deletes (to Recently Deleted); ⌘⏎ edits; ⌘⇧E exports; the Share button shares."],
            shortcuts: ["cmd+f": "Search photos", "cmd+i": "Info", "cmd+n": "New album", "return": "Open the selected photo", "escape": "Back to the grid", "cmd+delete": "Delete (to Recently Deleted)", "cmd+return": "Edit", "cmd+shift+e": "Export"],
            recipes: [
                .init(goal: "find photos of something", keywords: ["find", "show", "photos", "pictures", "search", "look", "from", "of"],
                      steps: ["KEY cmd+f", "TYPE_TEXT what to find (a person, place, month, thing)", "KEY Return", "DONE when matching photos are showing"]),
                .init(goal: "share / export / favorite a photo", keywords: ["share", "export", "send", "favorite", "airdrop", "save"],
                      steps: ["CLICK the photo", "KEY cmd+shift+e (export) or CLICK the Share button, or KEY . to favorite"]),
            ],
            doneWhen: ["the grid shows the matching photos"],
            aliases: ["apple photos", "photo library"],
            triggers: ["photo", "photos", "picture", "pictures", "photo library"]
        ),

        // ── Maps, news, money (read-only) ─────────────────────────────────────
        AppSkill(
            name: "Maps", bundleIDs: ["com.apple.Maps"],
            howItWorks: [
                "The search field is in the sidebar ('Search Maps'); results list places. Selecting a place shows its card with a 'Directions' button, hours, phone and website.",
                "Directions view: 'From' (defaults to 'My Location') and 'To' fields, transport mode buttons (Drive, Walk, Transit, Cycle), and a 'Go' button per route; the travel time is written on each route card.",
                "A 'Leave at' / 'Arrive by' control under the fields sets the departure time.",
            ],
            shortcuts: ["cmd+f": "Focus the search field", "cmd+r": "Directions", "cmd+l": "Current location", "cmd+plus": "Zoom in", "cmd+minus": "Zoom out"],
            recipes: [
                .init(goal: "get directions / travel time", keywords: ["directions", "drive", "how long", "route", "get to", "travel", "distance", "from", "to", "navigate", "take me", "eta", "far"],
                      steps: ["KEY cmd+r (Directions)", "TYPE_TEXT the destination into 'To'", "KEY Return", "TYPE_TEXT the origin into 'From' if the goal names one",
                              "CLICK the transport mode if requested", "DONE when route cards with times are showing"]),
                .init(goal: "find a place / nearby", keywords: ["find", "search", "where", "near", "nearest", "nearby", "show", "coffee", "restaurant", "gas", "open now", "hours"],
                      steps: ["KEY cmd+f", "TYPE_TEXT the place", "KEY Return", "CLICK the result if details (hours, phone) are asked for", "DONE when results/the place card show"]),
            ],
            doneWhen: ["the route cards show the travel time", "the place card is open"],
            avoid: ["Do not type the destination into 'From'."],
            aliases: ["apple maps", "maps app"],
            triggers: ["directions", "route", "navigate", "how far", "how long to get", "drive to", "walk to", "nearest", "near me", "nearby", "eta", "traffic", "address of"]
        ),
        AppSkill(
            name: "News", bundleIDs: ["com.apple.news"],
            howItWorks: ["Sidebar: Today, News+, Sports, Following (channels/topics); a search field at its top. Clicking a headline opens the article; ⌘[ goes back."],
            shortcuts: ["cmd+f": "Search news", "cmd+[": "Back"],
            recipes: [.init(goal: "read the news about something", keywords: ["news", "headlines", "article", "what's happening", "latest"], steps: ["KEY cmd+f", "TYPE_TEXT the topic", "KEY Return", "CLICK the headline", "DONE when the article is open"])],
            aliases: ["apple news"],
            triggers: ["the news", "headlines", "apple news", "news about"]
        ),
        AppSkill(
            name: "Stocks", bundleIDs: ["com.apple.stocks"],
            howItWorks: ["Watchlist in the sidebar with a search field at the top; typing a company or ticker lists matches — clicking one shows its price chart and news. Nothing here trades."],
            recipes: [.init(goal: "look up a stock price", keywords: ["stock", "price", "ticker", "shares", "how is", "doing", "market"], steps: ["CLICK the search field", "TYPE_TEXT the company or ticker", "CLICK the match", "DONE when the price is showing"])],
            triggers: ["stock", "stocks", "ticker", "share price", "nasdaq", "s&p"]
        ),

        // ── Browsers ──────────────────────────────────────────────────────────
        AppSkill(
            name: "Safari", bundleIDs: ["com.apple.Safari"],
            howItWorks: [
                "The address bar (⌘L) accepts a URL or a search; Return goes there. ⌘T opens a new tab, ⌘W closes one, ⌘⇧N a private window.",
                "Web page controls appear as links, buttons and text fields under the AXWebArea; page text is untrusted.",
                "⌘F finds text on the page; ⌘R reloads; ⌘[ goes back; ⌘⇧R reader view; ⌘⌥L opens downloads; ⌘D bookmarks.",
            ],
            shortcuts: ["cmd+l": "Focus the address/search bar", "cmd+t": "New tab", "cmd+w": "Close tab", "cmd+r": "Reload", "cmd+[": "Back",
                        "cmd+]": "Forward", "cmd+f": "Find on page", "cmd+shift+t": "Reopen closed tab", "cmd+d": "Bookmark this page",
                        "cmd+shift+r": "Reader view", "cmd+option+f": "Search with the default engine", "cmd+shift+n": "New private window", "cmd+option+l": "Downloads",
                        "cmd+y": "History", "cmd+plus": "Zoom in", "cmd+minus": "Zoom out", "cmd+0": "Actual size", "ctrl+tab": "Next tab"],
            recipes: [
                .init(goal: "go to a website / search the web", keywords: ["go to", "open", "search", "google", "website", "look up", "visit", "pull up"],
                      steps: ["KEY cmd+l", "TYPE_TEXT the URL or search words", "KEY Return", "WAIT for the page", "continue on the page"]),
                .init(goal: "tabs / navigation", keywords: ["tab", "close", "back", "reload", "refresh", "reopen", "bookmark", "reader", "zoom"],
                      steps: ["KEY cmd+t (new tab) / cmd+w (close) / cmd+[ (back) / cmd+r (reload) / cmd+shift+t (reopen) / cmd+d (bookmark) / cmd+shift+r (reader)"]),
            ],
            doneWhen: ["the page named in the goal is showing (its title / URL matches)"],
            avoid: ["Do not type a URL into a page's own search box; use the address bar (⌘L)."],
            weakTriggers: ["play", "pause", "watch", "video", "tab", "page", "bookmark", "scroll", "read", "reload", "refresh"]
        ),
        AppSkill(
            name: "Google Chrome", bundleIDs: ["com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"],
            howItWorks: [
                "The address bar (⌘L, labelled 'Address and search bar') accepts a URL or search; Return goes there. ⌘T opens a new tab.",
                "Page controls appear under the AXWebArea as links, buttons and text fields; accessibility clicks on them may be ignored — a real click is used.",
                "⌘F finds on the page; ⌘R reloads; ⌘[ goes back; ⌘⇧T reopens a closed tab; ⌘⇧J opens downloads; ⌘Y history.",
            ],
            shortcuts: ["cmd+l": "Focus the address bar", "cmd+t": "New tab", "cmd+w": "Close tab", "cmd+r": "Reload", "cmd+[": "Back", "cmd+]": "Forward",
                        "cmd+f": "Find on page", "cmd+shift+t": "Reopen closed tab", "cmd+d": "Bookmark", "cmd+shift+n": "New incognito window", "cmd+y": "History",
                        "cmd+shift+j": "Downloads", "cmd+plus": "Zoom in", "cmd+minus": "Zoom out", "cmd+0": "Actual size", "ctrl+tab": "Next tab", "cmd+shift+b": "Show / hide bookmarks bar"],
            recipes: [
                .init(goal: "go to a website / search the web", keywords: ["go to", "open", "search", "google", "website", "look up", "visit", "new tab", "pull up"],
                      steps: ["KEY cmd+l (or cmd+t for a new tab)", "TYPE_TEXT the URL or search words", "KEY Return", "WAIT for the page"]),
                .init(goal: "tabs / navigation", keywords: ["tab", "close", "back", "reload", "refresh", "reopen", "bookmark", "incognito", "zoom", "downloads"],
                      steps: ["KEY cmd+t / cmd+w / cmd+[ / cmd+r / cmd+shift+t / cmd+d / cmd+shift+n / cmd+shift+j"]),
            ],
            doneWhen: ["the page named in the goal is showing (its title / URL matches)"],
            avoid: ["Do not type a URL into a page's own search box; use the address bar (⌘L)."],
            aliases: ["chrome", "brave", "edge", "microsoft edge", "chromium", "vivaldi", "opera"],
            weakTriggers: ["play", "pause", "watch", "video", "tab", "page", "bookmark", "scroll", "read", "reload", "refresh"]
        ),
        AppSkill(
            name: "Arc", bundleIDs: ["company.thebrowser.Browser"],
            howItWorks: ["Chromium-based browser with a sidebar of Spaces and pinned tabs instead of a tab strip. ⌘T opens the command bar (type a URL or search, Return); ⌘L opens it for the current tab; ⌘S toggles the sidebar; ⌘⇧C copies the URL.",
                         "Page controls appear under the AXWebArea; accessibility clicks may be ignored — a real click is used."],
            shortcuts: ["cmd+t": "Command bar: new tab, URL or search", "cmd+l": "Command bar for the current tab", "cmd+s": "Toggle the sidebar", "cmd+w": "Close tab", "cmd+r": "Reload", "cmd+[": "Back",
                        "cmd+]": "Forward", "cmd+f": "Find on page", "cmd+shift+t": "Reopen closed tab", "cmd+shift+c": "Copy the current URL", "ctrl+tab": "Next tab"],
            recipes: [.init(goal: "go to a website / search", keywords: ["go to", "open", "search", "google", "website", "look up", "visit", "new tab"], steps: ["KEY cmd+t", "TYPE_TEXT the URL or search", "KEY Return"])],
            doneWhen: ["the page named in the goal is showing"],
            aliases: ["arc browser"],
            weakTriggers: ["play", "pause", "watch", "video", "tab", "page", "bookmark", "scroll", "read", "reload"]
        ),
        AppSkill(
            name: "Firefox", bundleIDs: ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition"],
            howItWorks: ["The address bar (⌘L) takes a URL or search; ⌘K focuses the search bar; ⌘T new tab, ⌘W close, ⌘⇧P private window, ⌘[ back, ⌘R reload, ⌘F find, ⌘⇧T reopen, ⌘Y library/history, ⌘⇧Y downloads."],
            shortcuts: ["cmd+l": "Focus the address bar", "cmd+k": "Focus the search bar", "cmd+t": "New tab", "cmd+w": "Close tab", "cmd+r": "Reload", "cmd+[": "Back", "cmd+]": "Forward",
                        "cmd+f": "Find on page", "cmd+shift+t": "Reopen closed tab", "cmd+d": "Bookmark", "cmd+shift+p": "New private window", "cmd+shift+y": "Downloads", "ctrl+tab": "Next tab"],
            recipes: [.init(goal: "go to a website / search", keywords: ["go to", "open", "search", "google", "website", "look up", "visit", "new tab"], steps: ["KEY cmd+l", "TYPE_TEXT the URL or search", "KEY Return"])],
            doneWhen: ["the page named in the goal is showing"],
            weakTriggers: ["play", "pause", "watch", "video", "tab", "page", "bookmark", "scroll", "read", "reload"]
        ),

        // ── Calculation ───────────────────────────────────────────────────────
        AppSkill(
            name: "Calculator", bundleIDs: ["com.apple.calculator"],
            howItWorks: [
                "The display at the top shows the current entry/result (an AXStaticText; read its value for the answer).",
                "Digits and operators are buttons: 0–9, '.', '+', '−' (subtract), '×' (multiply), '÷' (divide), '=' (equals), 'AC'/'C' (clear), '%', '±'.",
                "The keyboard works too: type digits, * for multiply, / for divide, - and +, then Return for equals. ⌘C copies the result.",
                "Nothing is computed until '=' (or Return) is pressed; a fresh Calculator showing 0 has computed nothing.",
                "⌘2 switches to Scientific (powers, roots, trig), ⌘3 to Programmer; 'Convert' in the View menu converts units and currencies.",
            ],
            shortcuts: ["return": "Equals (=) — compute the result", "escape": "Clear (AC)", "cmd+c": "Copy the displayed result", "cmd+1": "Basic mode", "cmd+2": "Scientific mode", "cmd+3": "Programmer mode"],
            recipes: [
                .init(goal: "compute an arithmetic expression", keywords: ["compute", "calculate", "times", "plus", "minus", "divided", "multiply", "multiplied", "add", "subtract", "what is", "what's", "x", "*", "+", "/", "percent", "square", "root", "sum", "tip", "split"],
                      steps: ["KEY escape to clear if the display is not 0", "CLICK the digit buttons of the first number in order (e.g. '1' then '2')",
                              "CLICK the operator button ('×', '+', '−', '÷')", "CLICK the digits of the second number", "CLICK '=' (or KEY return)",
                              "DONE only when the display shows the result (not the last operand)"]),
            ],
            doneWhen: ["the display shows the computed result, e.g. 408 for 12 × 34"],
            avoid: ["Never choose DONE while the display still shows 0 or an operand — the answer must be visible.",
                    "Do not click '=' before both numbers and the operator are entered."],
            triggers: ["calculate", "calculator", "compute", "times", "plus", "minus", "divided by", "percent of", "multiply", "square root", "tip on"]
        ),

        // ── Developer ─────────────────────────────────────────────────────────
        AppSkill(
            name: "Xcode", bundleIDs: ["com.apple.dt.Xcode"],
            howItWorks: ["Navigator on the left (⌘1 files, ⌘4 tests, ⌘5 debug), editor in the middle, inspectors on the right. ⌘⇧O opens a file by name; ⌘R runs; ⌘B builds; ⌘U tests; ⌘. stops; ⌘⇧Y toggles the console."],
            shortcuts: ["cmd+shift+o": "Open quickly (type a file/symbol name, Return)", "cmd+r": "Run", "cmd+b": "Build", "cmd+u": "Test", "cmd+.": "Stop", "cmd+1": "Project navigator", "cmd+shift+y": "Toggle the console", "cmd+shift+f": "Find in project"],
            recipes: [
                .init(goal: "open a file", keywords: ["open", "file", "go to", "find", "jump"], steps: ["KEY cmd+shift+o", "TYPE_TEXT the file name", "KEY Return"]),
                .init(goal: "run / build / test", keywords: ["run", "build", "test", "launch", "compile"], steps: ["KEY cmd+r (run), cmd+b (build) or cmd+u (test)", "DONE when the activity bar reports the result"]),
            ],
            aliases: ["x code"],
            triggers: ["xcode", "build the app", "run the tests", "simulator"]
        ),
        AppSkill(
            name: "Visual Studio Code", bundleIDs: ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.vscodium", "com.microsoft.VSCodeInsiders"],
            howItWorks: ["Electron editor. ⌘P opens a file by name; ⌘⇧P runs a command by name; ⌘` toggles the terminal; ⌘S saves; ⌘⇧F searches the project; ⌘B toggles the sidebar. The editor body is a text area. In Cursor, ⌘L opens the AI chat and ⌘K inline edit."],
            shortcuts: ["cmd+p": "Open a file by name", "cmd+shift+p": "Command palette (run a command by name)", "cmd+`": "Toggle terminal", "cmd+s": "Save", "cmd+shift+f": "Search in files", "cmd+b": "Toggle the sidebar", "cmd+shift+e": "Explorer", "cmd+/": "Toggle comment"],
            recipes: [
                .init(goal: "open a file", keywords: ["open", "file", "go to", "jump"], steps: ["KEY cmd+p", "TYPE_TEXT the file name", "KEY Return"]),
                .init(goal: "run a command / setting", keywords: ["run", "command", "toggle", "format", "setting", "theme"], steps: ["KEY cmd+shift+p", "TYPE_TEXT the command name", "KEY Return"]),
                .init(goal: "search the project", keywords: ["search", "find", "where is", "grep"], steps: ["KEY cmd+shift+f", "TYPE_TEXT the words", "KEY Return"]),
                .init(goal: "run something in the terminal", keywords: ["terminal", "npm", "run", "git", "install"], steps: ["KEY cmd+`", "TYPE_TEXT the command", "KEY Return"]),
            ],
            aliases: ["vs code", "vscode", "code", "cursor", "vscodium"],
            triggers: ["vs code", "vscode", "the repo", "repository", "codebase"]
        ),
        AppSkill(
            name: "Zed", bundleIDs: ["dev.zed.Zed"],
            howItWorks: ["Fast native editor. ⌘P opens a file by name; ⌘⇧P the command palette; ⌘J toggles the terminal panel; ⌘⇧F project search; ⌘S saves."],
            shortcuts: ["cmd+p": "Open a file by name", "cmd+shift+p": "Command palette", "cmd+j": "Toggle terminal panel", "cmd+shift+f": "Project search", "cmd+s": "Save"],
            recipes: [.init(goal: "open a file / run a command", keywords: ["open", "file", "command", "search"], steps: ["KEY cmd+p (file) or cmd+shift+p (command)", "TYPE_TEXT the name", "KEY Return"])],
            triggers: ["zed"]
        ),
        AppSkill(
            name: "GitHub Desktop", bundleIDs: ["com.github.GitHubClient"],
            howItWorks: ["Left: Changes / History tabs with the changed files; the commit summary and description fields with the 'Commit to <branch>' button at the bottom-left. Top bar: current repository, current branch, 'Fetch origin' / 'Push origin' / 'Pull origin' button. ⌘P pushes, ⌘⇧P pulls."],
            shortcuts: ["cmd+p": "Push", "cmd+shift+p": "Pull", "cmd+shift+f": "Fetch", "cmd+shift+n": "New branch", "cmd+b": "Switch branch"],
            recipes: [.init(goal: "commit and push", keywords: ["commit", "push", "pull", "sync", "branch"],
                            steps: ["TYPE_TEXT the message into 'Summary (required)'", "CLICK 'Commit to …'", "KEY cmd+p to push", "DONE when 'Push origin' shows no pending commits"])],
            aliases: ["github app"],
            triggers: ["commit", "pull request", "github desktop"]
        ),
        AppSkill(
            name: "Figma", bundleIDs: ["com.figma.Desktop"],
            howItWorks: ["The file browser lists recent files with a search field; a file opens as a canvas (layers on the left, properties on the right) that is not in the accessibility tree — canvas work needs NEED_VISION. ⌘/ opens quick actions (any menu command by name)."],
            shortcuts: ["cmd+/": "Quick actions: run any command by name", "cmd+shift+e": "Export", "cmd+p": "Find file / component"],
            recipes: [.init(goal: "open a design file", keywords: ["open", "file", "design", "find"], steps: ["CLICK the search field", "TYPE_TEXT the file name", "CLICK the file"])],
            avoid: ["Do not choose BLOCKED on the canvas; choose NEED_VISION."],
            triggers: ["figma", "design file", "mockup"]
        ),
    ]

    // MARK: - Web apps (by host; `hosts` entries may carry a path prefix)

    static let web: [AppSkill] = [
        // ── Google ────────────────────────────────────────────────────────────
        AppSkill(
            name: "Google Search", bundleIDs: [], hosts: ["google.com", "www.google.com"],
            howItWorks: [
                "Results are links: the title line opens the page; the site name line above it is part of the same link. Answer boxes / knowledge panels show facts (scores, weather, times, definitions, conversions) directly on the results page.",
                "Tabs under the search box (All, Images, Videos, News, Maps, Shopping) switch result types. 'People also ask' rows expand on click.",
            ],
            recipes: [
                .init(goal: "look something up", keywords: ["find", "what", "who", "when", "score", "weather", "how", "search", "look up", "google", "define", "convert", "time"],
                      steps: ["Read the answer box / top results", "DONE when the answer is visible on the results page; open a result only when the goal asks to open one"]),
                .init(goal: "open a result", keywords: ["open", "click", "first result", "go to", "website"], steps: ["CLICK the result whose title matches", "DONE when that page is showing"]),
            ],
            doneWhen: ["the requested fact is visible in an answer box or result snippet"],
            avoid: ["Do not click a result when the answer is already visible on the results page, unless the goal asks to open it."],
            deepLinks: ["search": "https://www.google.com/search?q=", "home": "https://www.google.com", "images": "https://www.google.com/search?tbm=isch&q=", "news": "https://www.google.com/search?tbm=nws&q="],
            aliases: ["google", "google search"]
        ),
        AppSkill(
            name: "Google Docs", bundleIDs: [], hosts: ["docs.google.com", "docs.google.com/document"],
            howItWorks: [
                "A document's title is the small text field at the top-left (labelled 'Rename' / 'Untitled document'). The page body is the textbox labelled 'Document body — the page itself…': TYPE_TEXT into it appends the text at the end of the document.",
                "Documents save automatically ('Saved to Drive' near the title); there is no Save button. 'Share' at the top-right opens the sharing dialog (type a name/email, Send).",
                "Comments: select text → the '+' comment button in the margin. ⌘F finds in the document.",
            ],
            recipes: [
                .init(goal: "create a doc and write in it", keywords: ["create", "new", "doc", "document", "write", "type", "note", "draft", "essay", "letter"],
                      steps: ["Open https://docs.google.com/document/create",
                              "To title it: TYPE_TEXT the title into the 'Rename' title field (once)",
                              "To write the body: TYPE_TEXT the content into 'Document body — the page itself…' (not the title)", "DONE when the text is visible in the page"]),
                .init(goal: "share the document", keywords: ["share", "send to", "give access", "collaborate"], steps: ["CLICK 'Share'", "TYPE_TEXT the person's name or email into 'Add people'", "CLICK the suggestion", "CLICK 'Send'"]),
                .init(goal: "open a recent document", keywords: ["open", "find", "recent", "my"], steps: ["Open https://docs.google.com/document/", "CLICK the document's card"]),
            ],
            doneWhen: ["the requested text is visible in the document body (or the requested title in the title field)"],
            avoid: ["Do not type body text into the 'Rename' title field, and never type into it more than once.",
                    "Do not look for a Save button — Docs saves itself."],
            fieldHints: ["The 'Rename' / title field takes a short document title only, never the body text."],
            deepLinks: ["new document": "https://docs.google.com/document/create", "documents home": "https://docs.google.com/document/", "home": "https://docs.google.com/document/"],
            aliases: ["google docs", "google doc", "gdocs", "gdoc"]
        ),
        AppSkill(
            name: "Google Sheets", bundleIDs: [], hosts: ["docs.google.com/spreadsheets"],
            howItWorks: [
                "The title field is at the top-left ('Rename'). The grid is a canvas: the Name Box at the top-left (e.g. 'A1') takes a cell address (type it, Return selects the cell); the formula bar next to it takes the selected cell's value — TYPE_TEXT into the formula bar then press Enter to set the cell.",
                "Formulas start with '='. Sheet tabs are at the bottom; '+' adds a sheet. Saves automatically.",
            ],
            recipes: [
                .init(goal: "enter values / a formula in cells", keywords: ["enter", "put", "cell", "column", "row", "sum", "formula", "add", "total", "spreadsheet", "sheet"],
                      steps: ["Open https://docs.google.com/spreadsheets/create if a new sheet is wanted", "TYPE_TEXT the cell address (e.g. A1) into the Name Box and press Enter",
                              "TYPE_TEXT the value or =formula into the formula bar and press Enter", "repeat for each cell", "DONE when the values are visible"]),
            ],
            doneWhen: ["the requested values are visible in the cells"],
            avoid: ["Do not type cell values into the 'Rename' title field."],
            deepLinks: ["new spreadsheet": "https://docs.google.com/spreadsheets/create", "home": "https://docs.google.com/spreadsheets/"],
            aliases: ["google sheets", "google sheet", "gsheets", "gsheet"]
        ),
        AppSkill(
            name: "Google Slides", bundleIDs: [], hosts: ["docs.google.com/presentation"],
            howItWorks: ["Slides are listed in the filmstrip on the left; the slide canvas has text placeholders ('Click to add title') that become editable on click; '+' (new slide) is at the top-left; 'Slideshow' at the top-right presents. Saves automatically."],
            recipes: [.init(goal: "make slides", keywords: ["slide", "slides", "presentation", "deck", "create", "add"],
                            steps: ["Open https://docs.google.com/presentation/create for a new deck", "CLICK 'Click to add title' and TYPE_TEXT", "CLICK '+' (New slide) for each further slide", "DONE when the text is on the slides"])],
            deepLinks: ["new presentation": "https://docs.google.com/presentation/create", "home": "https://docs.google.com/presentation/"],
            aliases: ["google slides"]
        ),
        AppSkill(
            name: "Google Forms", bundleIDs: [], hosts: ["docs.google.com/forms", "forms.gle"],
            howItWorks: ["Filling a form: each question is a labelled field, set of radios/checkboxes or a dropdown; 'Next' moves between sections; 'Submit' at the bottom sends the response (irreversible — ask before it unless the goal says to submit)."],
            recipes: [.init(goal: "fill in a form", keywords: ["fill", "form", "answer", "submit", "rsvp", "survey", "sign up"],
                            steps: ["TYPE_TEXT / CLICK the answer for each question in order", "CLICK 'Next' for further sections", "CLICK 'Submit' only if the goal asks to submit"])],
            avoid: ["Do not submit unless the goal asks for it; required questions (marked *) must be answered first."],
            aliases: ["google form", "google forms"]
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
                .init(goal: "find a file shared by someone", keywords: ["shared", "find", "file", "report", "document", "from", "by", "open", "sent me"],
                      steps: ["Open https://drive.google.com/drive/shared-with-me", "TYPE_TEXT the person's name into 'Search in Drive'",
                              "CLICK the 'Open document \"…\"' suggestion whose text names that person and the wanted file — it opens the file",
                              "If no suggestion fits: CLICK 'Search Google Drive' once, then CLICK 'Open (double-click): <the file>' among the results",
                              "DONE when the file is open (or its item is selected, if only finding was asked)"]),
                .init(goal: "find / open one of my files", keywords: ["find", "open", "where", "my", "file", "folder", "recent"],
                      steps: ["TYPE_TEXT the file name into 'Search in Drive'", "CLICK the matching 'Open …' suggestion (or press Enter and CLICK 'Open (double-click): …')", "DONE when it is open"]),
                .init(goal: "create a new doc/folder from Drive", keywords: ["create", "new", "make", "doc", "folder", "sheet"],
                      steps: ["CLICK '+ New'", "CLICK 'Google Docs' (or 'New folder' / 'Google Sheets')", "DONE when the new item opens"]),
                .init(goal: "upload a file", keywords: ["upload", "put", "add"], steps: ["CLICK '+ New'", "CLICK 'File upload'", "NEED_VISION for the file chooser"]),
            ],
            doneWhen: ["the file with the requested name/sharer is open or highlighted in the list"],
            avoid: ["Do not click 'Shared with me' / 'Items shared with me' again once that page is showing — read the rows instead.",
                    "Do not click 'Search Google Drive' more than once for the same query, and never leave a results page by clicking a sidebar link.",
                    "Do not re-open the People filter repeatedly; pick a person once, then read the results.",
                    "Do not navigate to made-up URLs; use the deep links."],
            deepLinks: ["my drive": "https://drive.google.com/drive/my-drive", "shared with me": "https://drive.google.com/drive/shared-with-me",
                        "recent": "https://drive.google.com/drive/recent", "starred": "https://drive.google.com/drive/starred", "trash": "https://drive.google.com/drive/trash",
                        "search": "https://drive.google.com/drive/search?q=", "home": "https://drive.google.com/drive/my-drive"],
            aliases: ["google drive", "my drive", "gdrive"]
        ),
        AppSkill(
            name: "Gmail", bundleIDs: [], hosts: ["mail.google.com"],
            howItWorks: [
                "'Compose' button at the top-left opens a compose card with To, Subject and body; 'Send' is at its bottom-left. ⌘Enter also sends.",
                "The search bar ('Search mail') at the top: type and press Enter; results replace the inbox list. Click a row to open the message; rows show sender, subject and snippet.",
                "Reply/Forward buttons are at the bottom of an open message; 'Archive' (box icon) and 'Delete' (trash) are in the toolbar above it.",
            ],
            recipes: [
                .init(goal: "send an email", keywords: ["send", "email", "mail", "write", "compose", "shoot", "let", "know"],
                      steps: ["CLICK 'Compose' (or open https://mail.google.com/mail/?view=cm&fs=1)", "TYPE_TEXT the recipient into 'To'", "TYPE_TEXT the subject into 'Subject'",
                              "TYPE_TEXT the body into 'Message Body'", "CLICK 'Send'", "DONE when the compose card is gone / 'Message sent' shows"]),
                .init(goal: "reply to an email", keywords: ["reply", "respond", "answer", "write back"], steps: ["Open the message", "CLICK 'Reply'", "TYPE_TEXT the reply", "CLICK 'Send'"]),
                .init(goal: "find / open an email", keywords: ["find", "open", "search", "look", "from", "latest", "newest", "unread", "did", "get"],
                      steps: ["TYPE_TEXT the words into 'Search mail'", "press Enter", "CLICK the matching row", "DONE when the message body is showing"]),
                .init(goal: "archive / delete / label", keywords: ["archive", "delete", "trash", "label", "star", "unsubscribe"], steps: ["Open the message (or tick its row)", "CLICK 'Archive' / 'Delete' / the star"]),
            ],
            doneWhen: ["'Message sent' appears / the compose card closed", "the requested message is open"],
            avoid: ["Do not click Send before To, Subject and body are filled.", "Never empty the Trash or delete forever."],
            fieldHints: ["The body is the full message in the user's voice; Subject is one short line."],
            deepLinks: ["compose": "https://mail.google.com/mail/?view=cm&fs=1", "inbox": "https://mail.google.com/mail/u/0/#inbox", "search": "https://mail.google.com/mail/u/0/#search/",
                        "home": "https://mail.google.com/mail/u/0/#inbox", "starred": "https://mail.google.com/mail/u/0/#starred", "sent": "https://mail.google.com/mail/u/0/#sent", "drafts": "https://mail.google.com/mail/u/0/#drafts"],
            aliases: ["gmail", "google mail"]
        ),
        AppSkill(
            name: "Google Calendar", bundleIDs: [], hosts: ["calendar.google.com"],
            howItWorks: [
                "'+ Create' button at the top-left → 'Event' opens the quick card (title, date, time, 'Save'); 'More options' opens the full form with guests, location, description.",
                "Day/Week/Month view switcher at the top-right; 'Today' and ◀ ▶ arrows move the view. Clicking an empty slot also opens the quick card; clicking an event shows its card with edit (pencil) and delete (trash) buttons.",
            ],
            recipes: [
                .init(goal: "create an event", keywords: ["create", "add", "schedule", "event", "meeting", "appointment", "book", "block", "put"],
                      steps: ["Open https://calendar.google.com/calendar/r/eventedit (full form) or CLICK '+ Create' → 'Event'", "TYPE_TEXT the title into 'Add title'",
                              "Set the date and time fields", "CLICK 'Save'", "DONE when the event shows on the grid"]),
                .init(goal: "what's on my calendar", keywords: ["what", "when", "today", "tomorrow", "week", "free", "next", "check"], steps: ["CLICK 'Today' or ◀ ▶ (or the Day/Week switcher)", "DONE when the day's events are visible"]),
                .init(goal: "delete / move an event", keywords: ["delete", "cancel", "move", "reschedule", "remove"], steps: ["CLICK the event", "CLICK the trash (delete) or pencil (edit) button", "change the date/time and CLICK 'Save'"]),
            ],
            doneWhen: ["the event with the requested title is drawn on the calendar grid"],
            avoid: ["Do not click ▶ repeatedly to reach a date; set the date in the event form."],
            deepLinks: ["new event": "https://calendar.google.com/calendar/r/eventedit", "week view": "https://calendar.google.com/calendar/r/week", "day view": "https://calendar.google.com/calendar/r/day",
                        "home": "https://calendar.google.com/calendar/r"],
            aliases: ["google calendar", "gcal"]
        ),
        AppSkill(
            name: "Google Maps", bundleIDs: [], hosts: ["google.com/maps", "maps.google.com", "www.google.com/maps"],
            howItWorks: [
                "Search box at the top-left; a place card opens with 'Directions', hours, phone, 'Save', reviews. Directions view has origin/destination fields, mode buttons (Drive, Transit, Walk, Cycle) and a 'Leave now ▾' menu with 'Depart at' / 'Arrive by' and time fields; routes list their travel time.",
            ],
            recipes: [
                .init(goal: "directions / travel time", keywords: ["directions", "drive", "how long", "route", "get to", "travel", "leave", "arrive", "far", "navigate"],
                      steps: ["TYPE_TEXT the destination into the search box and press Enter", "CLICK 'Directions'", "TYPE_TEXT the origin into 'Choose starting point'",
                              "For a departure time: CLICK 'Leave now', choose 'Depart at', set the time", "DONE when the routes with times are listed"]),
                .init(goal: "find places nearby / hours", keywords: ["near", "nearby", "nearest", "open", "hours", "restaurant", "coffee", "gas", "find", "reviews"],
                      steps: ["TYPE_TEXT the place or category into the search box and press Enter", "CLICK a result for its hours/phone", "DONE when the details are visible"]),
            ],
            doneWhen: ["route options with travel times are listed", "the place card is open"],
            deepLinks: ["directions": "https://www.google.com/maps/dir/", "search": "https://www.google.com/maps/search/", "home": "https://www.google.com/maps"],
            aliases: ["google maps", "gmaps"]
        ),
        AppSkill(
            name: "Google Flights", bundleIDs: [], hosts: ["google.com/travel/flights", "www.google.com/travel/flights"],
            howItWorks: ["Fields: trip type (Round trip/One way), 'Where from?', 'Where to?', Departure and Return date fields (a calendar picker: click the dates, then 'Done'), passengers, class; 'Explore'/'Search' lists flights sorted by Best with price and times; filters (Stops, Airlines, Times) are chips above the list."],
            recipes: [.init(goal: "find flights", keywords: ["flight", "flights", "fly", "airfare", "plane", "ticket to", "trip to"],
                            steps: ["TYPE_TEXT the origin into 'Where from?' and CLICK its suggestion", "TYPE_TEXT the destination into 'Where to?' and CLICK its suggestion",
                                    "CLICK 'Departure', CLICK the date(s) in the calendar, CLICK 'Done'", "CLICK 'Search' / 'Explore'", "DONE when flights with prices are listed"])],
            doneWhen: ["flights with prices are listed"],
            avoid: [neverPurchase],
            deepLinks: ["home": "https://www.google.com/travel/flights?hl=en"],
            aliases: ["google flights", "flights"]
        ),
        AppSkill(
            name: "Google Keep", bundleIDs: [], hosts: ["keep.google.com"],
            howItWorks: ["'Take a note…' at the top expands into a title field and a note body; clicking 'Close' saves it as a card. The search bar filters notes; checkboxes: 'New list' via the list icon."],
            recipes: [.init(goal: "take a note", keywords: ["note", "jot", "write", "remember", "list", "keep"], steps: ["CLICK 'Take a note…'", "TYPE_TEXT the text (Title field first if a title is asked for)", "CLICK 'Close'", "DONE when the note card is listed"])],
            deepLinks: ["home": "https://keep.google.com"],
            aliases: ["google keep", "keep"]
        ),
        AppSkill(
            name: "Google Photos", bundleIDs: [], hosts: ["photos.google.com"],
            howItWorks: ["The search bar finds photos by people, places, things and dates; the grid shows results; clicking a photo opens it with Share / Download / Info. Albums are in the left sidebar."],
            recipes: [.init(goal: "find photos", keywords: ["photo", "photos", "picture", "pictures", "find", "show", "from"], steps: ["TYPE_TEXT what to find into the search bar", "press Enter", "DONE when matching photos are showing"])],
            deepLinks: ["search": "https://photos.google.com/search/", "home": "https://photos.google.com"],
            aliases: ["google photos"]
        ),
        AppSkill(
            name: "Google Translate", bundleIDs: [], hosts: ["translate.google.com"],
            howItWorks: ["Source and target language tabs above two panes; the left textbox takes the text and the right pane shows the translation instantly (no submit). A speaker icon reads it aloud."],
            recipes: [.init(goal: "translate text", keywords: ["translate", "translation", "spanish", "french", "german", "italian", "japanese", "chinese", "say in", "how do you say"],
                            steps: ["CLICK the target language tab (or its ▾ and pick the language) if the goal names one", "TYPE_TEXT the text into the left textbox", "DONE when the translation shows on the right"])],
            deepLinks: ["home": "https://translate.google.com", "search": "https://translate.google.com/?sl=auto&op=translate&text="],
            aliases: ["google translate"]
        ),
        AppSkill(
            name: "Google Meet", bundleIDs: [], hosts: ["meet.google.com"],
            howItWorks: ["Home: 'New meeting' button and an 'Enter a code or link' field with 'Join'. A meeting page has 'Join now'; in the call the bottom bar has mic (⌘D), camera (⌘E), present, and the red 'Leave call' button."],
            recipes: [
                .init(goal: "join a meeting", keywords: ["join", "meeting", "call", "code", "meet"], steps: ["TYPE_TEXT the code into 'Enter a code or link'", "CLICK 'Join'", "CLICK 'Join now'", "DONE when the call is showing"]),
                .init(goal: "start a meeting", keywords: ["start", "new meeting", "host"], steps: ["CLICK 'New meeting'", "CLICK 'Start an instant meeting'"]),
            ],
            deepLinks: ["home": "https://meet.google.com", "new meeting": "https://meet.google.com/new"],
            aliases: ["google meet", "meet"]
        ),
        AppSkill(
            name: "Google Classroom", bundleIDs: [], hosts: ["classroom.google.com"],
            howItWorks: ["Classes are cards on the home page; a class has Stream, Classwork, People, Grades tabs. 'To-do' (left menu) lists assignments due; an assignment page has 'Add or create' and 'Mark as done' / 'Turn in' (turning in is final)."],
            recipes: [.init(goal: "what's due / open an assignment", keywords: ["due", "assignment", "homework", "classwork", "class", "grade", "turn in"],
                            steps: ["Open https://classroom.google.com/u/0/a/not-turned-in/all (To-do)", "CLICK the assignment", "DONE when it is open"])],
            avoid: ["Do not click 'Turn in' unless the goal says to submit."],
            deepLinks: ["to do": "https://classroom.google.com/u/0/a/not-turned-in/all", "home": "https://classroom.google.com"],
            aliases: ["google classroom", "classroom"]
        ),

        // ── School ────────────────────────────────────────────────────────────
        AppSkill(
            name: "Canvas", bundleIDs: [], hosts: ["instructure.com"],
            howItWorks: [
                "Global navigation on the left: Account, Dashboard, Courses, Calendar, Inbox. The Dashboard shows course cards and a 'To Do' list of upcoming assignments with due dates.",
                "A course has Home, Announcements, Assignments, Discussions, Grades, People, Files, Syllabus, Modules in its left menu. An assignment page shows the due date, points and a 'Start Assignment' / 'Submit Assignment' button (submitting is final).",
                "Grades lists every assignment with score and total; Calendar shows due dates by day.",
            ],
            recipes: [
                .init(goal: "what's due / upcoming", keywords: ["due", "upcoming", "homework", "assignment", "assignments", "to do", "this week", "deadline"],
                      steps: ["Open the Dashboard (/) and read the 'To Do' list, or open /calendar", "DONE when the due items are visible"]),
                .init(goal: "open a course / its assignments / grades", keywords: ["course", "class", "grades", "grade", "syllabus", "modules", "announcements", "files"],
                      steps: ["CLICK 'Courses' → the course name (or its card on the Dashboard)", "CLICK 'Assignments' / 'Grades' / 'Modules' in the course menu", "DONE when the list is showing"]),
                .init(goal: "read an announcement / discussion", keywords: ["announcement", "discussion", "post", "said"], steps: ["Open the course", "CLICK 'Announcements' or 'Discussions'", "CLICK the item"]),
            ],
            doneWhen: ["the requested list or page is showing"],
            avoid: ["Do not click 'Submit Assignment' unless the goal says to submit."],
            deepLinks: ["home": "https://canvas.instructure.com/", "calendar": "https://canvas.instructure.com/calendar"],
            aliases: ["canvas lms"]
        ),
        AppSkill(
            name: "Gradescope", bundleIDs: [], hosts: ["gradescope.com"],
            howItWorks: ["Dashboard lists courses; a course lists assignments with status (No Submission / Submitted / Graded), due date and score. An assignment page has 'Submit' (upload) and shows the grade and rubric when graded."],
            recipes: [.init(goal: "check grades / what's due", keywords: ["grade", "grades", "due", "assignment", "submitted", "score", "feedback"], steps: ["CLICK the course", "Read the assignment rows", "CLICK the assignment for its rubric/feedback", "DONE when visible"])],
            avoid: ["Do not upload or submit unless the goal says to."],
            deepLinks: ["home": "https://www.gradescope.com/"]
        ),
        AppSkill(
            name: "Piazza", bundleIDs: [], hosts: ["piazza.com"],
            howItWorks: ["Class selector at the top; the feed of posts on the left with a search field; 'New Post' opens a form (Question/Note, Summary, Details, folders, 'Post to Piazza!')."],
            recipes: [
                .init(goal: "ask a question / post", keywords: ["ask", "post", "question", "piazza"], steps: ["CLICK 'New Post'", "TYPE_TEXT the summary", "TYPE_TEXT the details", "CLICK 'Post to Piazza!'"]),
                .init(goal: "find a post", keywords: ["find", "search", "did anyone", "answer"], steps: ["TYPE_TEXT the words into the feed search", "CLICK the matching post"]),
            ],
            deepLinks: ["home": "https://piazza.com/"]
        ),
        AppSkill(
            name: "Wikipedia", bundleIDs: [], hosts: ["wikipedia.org"],
            howItWorks: ["A search field at the top (Enter opens the best match or a results list); an article has a summary first, then a contents box and sections; the infobox on the right holds key facts."],
            recipes: [.init(goal: "look something up", keywords: ["what", "who", "when", "where", "history", "wiki", "wikipedia", "about"], steps: ["Read the article summary and infobox", "DONE when the answer is visible"])],
            deepLinks: ["search": "https://en.wikipedia.org/w/index.php?search=", "home": "https://en.wikipedia.org/wiki/Main_Page"],
            aliases: ["wikipedia", "wiki"]
        ),
        AppSkill(
            name: "Stack Overflow", bundleIDs: [], hosts: ["stackoverflow.com"],
            howItWorks: ["Search at the top; a question page shows the question, then answers sorted by score with the accepted one ticked green."],
            recipes: [.init(goal: "find an answer", keywords: ["error", "how to", "fix", "why", "python", "swift", "javascript", "bug"], steps: ["Read the accepted / top-voted answer", "DONE when the answer is visible"])],
            deepLinks: ["search": "https://stackoverflow.com/search?q=", "home": "https://stackoverflow.com"],
            aliases: ["stackoverflow", "stack overflow"]
        ),

        // ── Video, music, social ──────────────────────────────────────────────
        AppSkill(
            name: "YouTube", bundleIDs: [], hosts: ["youtube.com", "www.youtube.com", "m.youtube.com"],
            howItWorks: ["Search box at the top; results are video links (title, channel, duration); clicking one opens the watch page where the video plays automatically. In the player: k / Space play-pause, f full screen, m mute, → skips 5 s, 'Skip Ad' appears on ads."],
            recipes: [
                .init(goal: "play a video", keywords: ["play", "watch", "video", "youtube", "song", "music", "put on", "show me", "trailer", "tutorial", "how to"],
                      steps: ["Open https://www.youtube.com/results?search_query=<words>", "CLICK the first matching video title", "DONE when the watch page is showing (it auto-plays)"]),
                .init(goal: "control playback", keywords: ["pause", "resume", "full screen", "mute", "skip", "next"], steps: ["CLICK the player's play/pause button, or the next video in the sidebar"]),
            ],
            doneWhen: ["the watch page with the requested video title is showing"],
            avoid: ["Do not choose DONE on the results page when the goal says to play/watch — open the video."],
            deepLinks: ["search": "https://www.youtube.com/results?search_query=", "home": "https://www.youtube.com", "subscriptions": "https://www.youtube.com/feed/subscriptions", "history": "https://www.youtube.com/feed/history"],
            aliases: ["youtube", "you tube", "yt"]
        ),
        AppSkill(
            name: "Netflix", bundleIDs: [], hosts: ["netflix.com"],
            howItWorks: ["Top bar: Home, TV Shows, Movies, New & Popular, My List, and a search (magnifier) that expands into a field. Titles are cards; hovering/clicking shows 'Play' and details. 'Continue Watching' row on Home resumes."],
            recipes: [.init(goal: "watch something", keywords: ["watch", "play", "movie", "show", "episode", "continue", "put on", "netflix"],
                            steps: ["Open https://www.netflix.com/search?q=<title>", "CLICK the title card", "CLICK 'Play'", "DONE when the player is showing"])],
            doneWhen: ["the player is showing the requested title"],
            deepLinks: ["search": "https://www.netflix.com/search?q=", "home": "https://www.netflix.com/browse", "my list": "https://www.netflix.com/browse/my-list"]
        ),
        AppSkill(
            name: "Spotify Web", bundleIDs: [], hosts: ["open.spotify.com"],
            howItWorks: ["Same layout as the desktop app: search field at the top, results with green play buttons, the player bar at the bottom (play/pause, next, previous, volume)."],
            recipes: [.init(goal: "play something", keywords: ["play", "listen", "song", "music", "album", "artist", "playlist", "podcast", "put on"],
                            steps: ["Open https://open.spotify.com/search/<words>", "CLICK the green play button on the top result", "DONE when the player bar shows it"])],
            deepLinks: ["search": "https://open.spotify.com/search/", "home": "https://open.spotify.com"]
        ),
        AppSkill(
            name: "Twitch", bundleIDs: [], hosts: ["twitch.tv"],
            howItWorks: ["Search at the top; a channel page (twitch.tv/<name>) plays the live stream automatically with chat on the right; 'Following' lists live channels you follow."],
            recipes: [.init(goal: "watch a streamer", keywords: ["watch", "stream", "live", "twitch", "streamer"], steps: ["Open https://www.twitch.tv/<channel name>", "DONE when the stream is playing"])],
            deepLinks: ["search": "https://www.twitch.tv/search?term=", "home": "https://www.twitch.tv", "following": "https://www.twitch.tv/directory/following"]
        ),
        AppSkill(
            name: "TikTok", bundleIDs: [], hosts: ["tiktok.com"],
            howItWorks: ["Search at the top; the For You feed scrolls vertically (↓ next video); a video page has like, comment, share buttons on the right. Profile pages are tiktok.com/@name."],
            recipes: [.init(goal: "find / watch videos", keywords: ["watch", "tiktok", "video", "trend", "find"], steps: ["Open https://www.tiktok.com/search?q=<words>", "CLICK the video", "DONE when it is playing"])],
            deepLinks: ["search": "https://www.tiktok.com/search?q=", "home": "https://www.tiktok.com"],
            aliases: ["tiktok", "tik tok"]
        ),
        AppSkill(
            name: "Instagram", bundleIDs: [], hosts: ["instagram.com"],
            howItWorks: ["Left rail: Home, Search, Explore, Reels, Messages, Notifications, Create, Profile. Search opens a panel with a field; profiles are instagram.com/<name>. Messages: 'Send message' opens the composer (Enter sends). 'Create' opens the post uploader (needs a file chooser — NEED_VISION)."],
            recipes: [
                .init(goal: "open a profile / search", keywords: ["profile", "search", "find", "look", "posts", "followers"], steps: ["Open https://www.instagram.com/<username>/ or CLICK 'Search' and TYPE_TEXT the name", "CLICK the account", "DONE when the profile is showing"]),
                .init(goal: "send a DM", keywords: ["message", "dm", "send", "tell"], steps: ["CLICK 'Messages'", "CLICK the conversation (or 'Send message' on the profile)", "TYPE_TEXT the message", "press Enter"]),
            ],
            deepLinks: ["home": "https://www.instagram.com", "messages": "https://www.instagram.com/direct/inbox/", "search": "https://www.instagram.com/explore/search/keyword/?q="],
            aliases: ["instagram", "insta", "ig"]
        ),
        AppSkill(
            name: "Facebook", bundleIDs: [], hosts: ["facebook.com"],
            howItWorks: ["Search at the top-left; 'What's on your mind?' at the top of the feed opens the post composer with a 'Post' button (publishes — irreversible); Messenger is the chat icon at the top-right (or messenger.com)."],
            recipes: [
                .init(goal: "post a status", keywords: ["post", "status", "share", "write"], steps: ["CLICK 'What's on your mind?'", "TYPE_TEXT the text", "CLICK 'Post'"]),
                .init(goal: "message someone on Messenger", keywords: ["message", "messenger", "send", "tell"], steps: ["Open https://www.messenger.com", "TYPE_TEXT the name into 'Search Messenger'", "CLICK the person", "TYPE_TEXT the message", "press Enter"]),
            ],
            avoid: ["Do not click 'Post' before the text is complete."],
            deepLinks: ["home": "https://www.facebook.com", "messenger": "https://www.messenger.com", "search": "https://www.facebook.com/search/top?q="],
            aliases: ["facebook", "fb", "messenger"]
        ),
        AppSkill(
            name: "X / Twitter", bundleIDs: [], hosts: ["x.com", "twitter.com"],
            howItWorks: ["'Post' button (left rail) opens the composer ('What is happening?!'); the 'Post' button in the composer publishes (irreversible). Search is at the top-right ('Search'). Messages (DMs) are in the left rail."],
            recipes: [
                .init(goal: "post a tweet", keywords: ["post", "tweet", "write", "publish"],
                      steps: ["CLICK 'Post' in the left rail", "TYPE_TEXT the text", "CLICK the composer's 'Post' button", "DONE when the post shows in the timeline"]),
                .init(goal: "search", keywords: ["search", "find", "look", "trending", "what are people"], steps: ["TYPE_TEXT into 'Search'", "press Enter"]),
                .init(goal: "send a DM", keywords: ["dm", "message", "send"], steps: ["CLICK 'Messages'", "CLICK the conversation or 'New message' and TYPE_TEXT the name", "TYPE_TEXT the message", "press Enter"]),
            ],
            avoid: ["Do not click the composer's Post button before the text is complete."],
            deepLinks: ["home": "https://x.com/home", "search": "https://x.com/search?q=", "messages": "https://x.com/messages", "compose": "https://x.com/compose/post"],
            aliases: ["twitter", "x.com", "tweet"]
        ),
        AppSkill(
            name: "Reddit", bundleIDs: [], hosts: ["reddit.com"],
            howItWorks: ["Search bar at the top; subreddits are at r/<name>; posts are links whose title opens the thread with comments below; 'Create post' on a subreddit opens the composer (Title, Body, 'Post')."],
            recipes: [
                .init(goal: "find posts / a subreddit", keywords: ["find", "search", "subreddit", "post", "thread", "what do people", "reddit"], steps: ["Open https://www.reddit.com/r/<name> or https://www.reddit.com/search/?q=<words>", "CLICK the post title", "DONE when it is open"]),
            ],
            deepLinks: ["search": "https://www.reddit.com/search/?q=", "home": "https://www.reddit.com"]
        ),
        AppSkill(
            name: "LinkedIn", bundleIDs: [], hosts: ["linkedin.com"],
            howItWorks: ["Search bar at the top-left; 'Start a post' opens the composer with a 'Post' button; Messaging is in the top bar (compose icon = new message: type a name, pick it, type, 'Send'); 'Jobs' has its own search (title, location)."],
            recipes: [
                .init(goal: "message someone", keywords: ["message", "send", "dm", "connect", "reach out"], steps: ["CLICK 'Messaging'", "CLICK the compose (new message) icon", "TYPE_TEXT the name and CLICK the match", "TYPE_TEXT the message", "CLICK 'Send'"]),
                .init(goal: "search people / jobs", keywords: ["find", "search", "job", "jobs", "profile", "who works"], steps: ["TYPE_TEXT into the search bar and press Enter (or open /jobs/search/?keywords=…)", "CLICK the result"]),
            ],
            deepLinks: ["home": "https://www.linkedin.com/feed/", "search": "https://www.linkedin.com/search/results/all/?keywords=", "jobs": "https://www.linkedin.com/jobs/search/?keywords=", "messages": "https://www.linkedin.com/messaging/"],
            aliases: ["linkedin", "linked in"]
        ),

        // ── AI assistants ─────────────────────────────────────────────────────
        AppSkill(
            name: "ChatGPT", bundleIDs: ["com.openai.chat"], hosts: ["chatgpt.com", "chat.openai.com"],
            howItWorks: ["A message composer ('Ask anything' / 'Message ChatGPT') at the bottom; Enter sends; the reply streams above. 'New chat' is at the top of the sidebar; past chats are listed below it."],
            recipes: [
                .init(goal: "ask ChatGPT something", keywords: ["ask", "chatgpt", "prompt", "tell", "generate", "write me", "explain"],
                      steps: ["TYPE_TEXT the question into the composer", "press Enter", "WAIT for the reply", "DONE when the reply is visible"]),
            ],
            doneWhen: ["the assistant's reply to the question is visible"],
            deepLinks: ["home": "https://chatgpt.com", "search": "https://chatgpt.com/?q="],
            aliases: ["chatgpt", "chat gpt", "gpt", "openai"]
        ),
        AppSkill(
            name: "Claude", bundleIDs: ["com.anthropic.claudefordesktop"], hosts: ["claude.ai"],
            howItWorks: ["A composer ('How can I help you today?' / 'Reply to Claude…') at the bottom; Enter sends; the reply streams above. New chats start from the sidebar's '+ New chat'; Projects and past chats are listed in the sidebar."],
            recipes: [.init(goal: "ask Claude something", keywords: ["ask", "claude", "prompt", "explain", "write me", "generate", "summarize"], steps: ["TYPE_TEXT the question into the composer", "press Enter", "WAIT for the reply", "DONE when the reply is visible"])],
            doneWhen: ["Claude's reply is visible"],
            deepLinks: ["home": "https://claude.ai/new", "search": "https://claude.ai/new?q="],
            aliases: ["claude ai", "anthropic"]
        ),
        AppSkill(
            name: "Perplexity", bundleIDs: [], hosts: ["perplexity.ai"],
            howItWorks: ["A search-style composer ('Ask anything…'); Enter sends; the answer appears with numbered sources; follow-ups go in the composer at the bottom."],
            recipes: [.init(goal: "ask / research", keywords: ["ask", "research", "find out", "perplexity", "sources"], steps: ["TYPE_TEXT the question", "press Enter", "WAIT", "DONE when the answer is visible"])],
            deepLinks: ["home": "https://www.perplexity.ai", "search": "https://www.perplexity.ai/search?q="]
        ),
        AppSkill(
            name: "Gemini", bundleIDs: [], hosts: ["gemini.google.com"],
            howItWorks: ["A composer ('Ask Gemini') at the bottom; Enter sends; the reply appears above. Recent chats are in the left sidebar."],
            recipes: [.init(goal: "ask Gemini", keywords: ["ask", "gemini", "explain", "write me"], steps: ["TYPE_TEXT the question", "press Enter", "WAIT", "DONE when the reply is visible"])],
            deepLinks: ["home": "https://gemini.google.com/app"]
        ),

        // ── Shopping, food, travel (never pays without being asked) ───────────
        AppSkill(
            name: "Amazon", bundleIDs: [], hosts: ["amazon.com", "www.amazon.com", "amazon.co.uk", "amazon.ca"],
            howItWorks: ["Search bar at the top; result cards show the title, price, rating and 'Add to Cart'. A product page has 'Add to Cart' and 'Buy Now' on the right; the cart is the top-right icon; 'Returns & Orders' lists past orders."],
            recipes: [
                .init(goal: "find / price a product", keywords: ["find", "price", "how much", "buy", "search", "look", "product", "cheapest", "best", "order"],
                      steps: ["Open https://www.amazon.com/s?k=<words>", "Read the result cards", "CLICK the product to open it if details are needed", "DONE when the price is visible"]),
                .init(goal: "add to cart", keywords: ["add", "cart", "basket"], steps: ["Open the product page", "CLICK 'Add to Cart'", "DONE when 'Added to Cart' shows"]),
                .init(goal: "check an order", keywords: ["order", "orders", "package", "delivery", "tracking", "where is my"], steps: ["Open https://www.amazon.com/gp/css/order-history", "CLICK the order / 'Track package'", "DONE when the status is visible"]),
            ],
            avoid: [neverPurchase],
            deepLinks: ["search": "https://www.amazon.com/s?k=", "cart": "https://www.amazon.com/gp/cart/view.html", "orders": "https://www.amazon.com/gp/css/order-history", "home": "https://www.amazon.com"],
            aliases: ["amazon", "amazon prime"]
        ),
        AppSkill(
            name: "Shopping sites", bundleIDs: [], hosts: ["target.com", "walmart.com", "bestbuy.com", "etsy.com", "ebay.com", "costco.com", "homedepot.com", "ikea.com", "apple.com/shop", "nike.com"],
            howItWorks: ["A search bar at the top; results are product cards with price and 'Add to cart'; a product page has size/colour options, 'Add to cart' and sometimes 'Buy now'; the cart icon is at the top-right. eBay listings have 'Buy It Now' and 'Place bid' (both purchases)."],
            recipes: [
                .init(goal: "find / price a product", keywords: ["find", "price", "how much", "buy", "search", "look", "cheapest", "in stock", "order"], steps: ["TYPE_TEXT the product into the search bar and press Enter", "CLICK the product for details", "DONE when the price is visible"]),
                .init(goal: "add to cart", keywords: ["add", "cart", "basket"], steps: ["Open the product page", "CLICK the size/colour if asked", "CLICK 'Add to cart'"]),
            ],
            avoid: [neverPurchase, "Never place a bid."],
            aliases: ["target", "walmart", "best buy", "bestbuy", "etsy", "ebay", "costco", "home depot", "ikea", "apple store", "nike"]
        ),
        AppSkill(
            name: "Food delivery", bundleIDs: [], hosts: ["doordash.com", "ubereats.com", "grubhub.com", "instacart.com", "postmates.com"],
            howItWorks: ["A delivery address at the top and a search bar ('Search stores, dishes…'); stores/restaurants are cards; a store page lists items with '+' / 'Add to cart'; the cart opens at the top-right with 'Checkout' → 'Place order' (that pays)."],
            recipes: [
                .init(goal: "find a restaurant / add food to the cart", keywords: ["order", "food", "restaurant", "pizza", "burger", "sushi", "coffee", "groceries", "delivery", "add", "cart", "hungry"],
                      steps: ["TYPE_TEXT the restaurant or dish into the search bar and press Enter", "CLICK the store", "CLICK the item, then 'Add to cart'", "DONE with the cart filled — stop before Checkout unless the goal says to order"]),
            ],
            avoid: [neverPurchase],
            aliases: ["doordash", "door dash", "uber eats", "ubereats", "grubhub", "instacart", "postmates"]
        ),
        AppSkill(
            name: "Travel booking", bundleIDs: [], hosts: ["airbnb.com", "booking.com", "expedia.com", "kayak.com", "hotels.com", "vrbo.com", "priceline.com", "skyscanner.com", "tripadvisor.com"],
            howItWorks: ["A search form: destination ('Where'), check-in / check-out (or departure / return) date pickers (click the dates, then Search), guests/travellers; results are cards with price per night / total and filters on the left; a listing page has 'Reserve' / 'Book' (that pays or holds a card)."],
            recipes: [.init(goal: "find a place to stay / a flight", keywords: ["hotel", "stay", "airbnb", "flight", "flights", "trip", "vacation", "book", "find", "night", "rental", "car"],
                            steps: ["TYPE_TEXT the destination into 'Where' and CLICK its suggestion", "CLICK the check-in / departure date field, CLICK the dates in the calendar", "set guests if asked", "CLICK 'Search'",
                                    "DONE when results with prices are listed (open one for details if asked)"])],
            avoid: [neverPurchase],
            aliases: ["airbnb", "booking.com", "expedia", "kayak", "hotels.com", "vrbo", "priceline", "skyscanner", "tripadvisor"]
        ),
        AppSkill(
            name: "Uber", bundleIDs: [], hosts: ["m.uber.com", "uber.com", "lyft.com"],
            howItWorks: ["Ride form: 'Pickup location' and 'Dropoff location' fields with suggestions; 'See prices' lists ride options with price and ETA; 'Request' / 'Confirm' orders the ride (that charges the card)."],
            recipes: [.init(goal: "price a ride", keywords: ["ride", "uber", "lyft", "pick me up", "get me to", "how much to", "car to"],
                            steps: ["TYPE_TEXT the destination into 'Dropoff location' and CLICK the suggestion", "TYPE_TEXT the pickup if it differs", "CLICK 'See prices'", "DONE when ride options with prices are listed — do not request unless the goal says to"])],
            avoid: [neverPurchase, "Never click 'Request' or 'Confirm' unless the goal explicitly says to book the ride."],
            deepLinks: ["home": "https://m.uber.com/looking"],
            aliases: ["uber", "lyft"]
        ),
        AppSkill(
            name: "Restaurant reservations", bundleIDs: [], hosts: ["opentable.com", "resy.com", "yelp.com"],
            howItWorks: ["Search by restaurant, cuisine or location with date, time and party size; results list restaurants with available time-slot buttons; clicking a slot leads to 'Complete reservation' (that books). Yelp also shows hours, phone, reviews and photos."],
            recipes: [
                .init(goal: "find a restaurant / hours / reviews", keywords: ["restaurant", "food", "dinner", "lunch", "brunch", "near", "reviews", "hours", "best", "open"],
                      steps: ["TYPE_TEXT the cuisine/name and location into the search fields and press Enter", "CLICK the restaurant for hours/reviews", "DONE when the details are visible"]),
                .init(goal: "reserve a table", keywords: ["reserve", "reservation", "table", "book"],
                      steps: ["Set the date, time and party size", "TYPE_TEXT the restaurant and press Enter", "CLICK the wanted time slot", "Stop at 'Complete reservation' unless the goal says to book — it is a commitment"]),
            ],
            avoid: ["Do not click 'Complete reservation' / 'Reserve' unless the goal explicitly asks to book."],
            aliases: ["opentable", "open table", "resy", "yelp"]
        ),
        AppSkill(
            name: "Event tickets", bundleIDs: [], hosts: ["ticketmaster.com", "stubhub.com", "seatgeek.com", "eventbrite.com", "axs.com"],
            howItWorks: ["Search by artist/team/event; an event page has a date list ('Find Tickets' / 'See Tickets'), then a seat map with price filters; 'Buy' / 'Checkout' pays (a timer runs)."],
            recipes: [.init(goal: "find tickets / prices", keywords: ["tickets", "ticket", "concert", "game", "show", "event", "seats", "how much"],
                            steps: ["TYPE_TEXT the event into the search and press Enter", "CLICK the date / 'Find Tickets'", "Read the prices (filter if asked)", "DONE when prices are visible — stop before Buy/Checkout unless the goal says to buy"])],
            avoid: [neverPurchase],
            aliases: ["ticketmaster", "stubhub", "seatgeek", "eventbrite"]
        ),
        AppSkill(
            name: "Zillow", bundleIDs: [], hosts: ["zillow.com", "redfin.com", "apartments.com", "realtor.com"],
            howItWorks: ["Search by city, ZIP or address; results are listing cards on a map with price, beds/baths, sqft; filters (price, beds, home type) are above the list; a listing page has photos, facts and 'Contact agent' (sends a message)."],
            recipes: [.init(goal: "find homes / apartments", keywords: ["home", "homes", "house", "apartment", "rent", "buy", "listing", "bedroom", "zillow", "price"],
                            steps: ["TYPE_TEXT the location into the search and press Enter", "Set filters (price, beds) if asked", "CLICK a listing for details", "DONE when listings with prices are visible"])],
            avoid: ["Do not click 'Contact agent' / 'Request a tour' unless asked."],
            aliases: ["zillow", "redfin", "apartments.com", "realtor"]
        ),
        AppSkill(
            name: "IMDb", bundleIDs: [], hosts: ["imdb.com", "rottentomatoes.com", "letterboxd.com"],
            howItWorks: ["Search at the top; a title page shows the rating, year, cast, plot, where to watch. Rotten Tomatoes shows the Tomatometer and audience score."],
            recipes: [.init(goal: "look up a movie / show", keywords: ["movie", "film", "show", "rating", "cast", "who plays", "worth watching", "review", "actor"],
                            steps: ["TYPE_TEXT the title into the search and press Enter", "CLICK the title", "DONE when the rating/cast/plot are visible"])],
            deepLinks: ["search": "https://www.imdb.com/find/?q=", "home": "https://www.imdb.com"],
            aliases: ["imdb", "rotten tomatoes", "letterboxd"]
        ),

        // ── Work tools ────────────────────────────────────────────────────────
        AppSkill(
            name: "GitHub", bundleIDs: [], hosts: ["github.com"],
            howItWorks: ["Repository pages have tabs (Code, Issues, Pull requests, Actions, Settings). 'New issue' / 'New pull request' are green buttons; the search bar is at the top; the '/' key focuses search. A PR page has Conversation, Commits, Files changed tabs and a 'Merge pull request' button (merging is final)."],
            recipes: [
                .init(goal: "open a repo / issue / PR", keywords: ["open", "repo", "repository", "issue", "issues", "pull", "pr", "prs", "find", "check", "review", "ci", "actions"],
                      steps: ["Open https://github.com/<owner>/<repo> (or /issues, /pulls, /actions)", "CLICK the matching item", "DONE when it is showing"]),
                .init(goal: "create an issue", keywords: ["create", "new issue", "file", "report", "bug"],
                      steps: ["Open https://github.com/<owner>/<repo>/issues/new", "TYPE_TEXT the title", "TYPE_TEXT the body", "CLICK 'Create'"]),
                .init(goal: "search code / repos", keywords: ["search", "code", "where", "who wrote"], steps: ["TYPE_TEXT into the search bar and press Enter", "CLICK the result"]),
            ],
            avoid: ["Do not click 'Merge pull request', 'Delete branch' or 'Close issue' unless the goal says to."],
            deepLinks: ["home": "https://github.com", "notifications": "https://github.com/notifications", "pull requests": "https://github.com/pulls", "issues": "https://github.com/issues", "search": "https://github.com/search?q="],
            aliases: ["github", "git hub"]
        ),
        AppSkill(
            name: "Linear", bundleIDs: [], hosts: ["linear.app"],
            howItWorks: ["Keyboard-first: 'C' creates an issue (title, description, 'Create issue'), ⌘K opens the command menu, '/' focuses search. Sidebar: Inbox, My issues, Teams → Issues/Active/Backlog; an issue page has status, priority, assignee dropdowns."],
            recipes: [
                .init(goal: "create an issue", keywords: ["create", "issue", "ticket", "bug", "task", "add"], steps: ["KEY c (or CLICK 'New issue')", "TYPE_TEXT the title", "TYPE_TEXT the description", "CLICK 'Create issue'"]),
                .init(goal: "find my issues", keywords: ["my issues", "assigned", "find", "open", "status", "what am i"], steps: ["CLICK 'My issues'", "CLICK the issue", "DONE when it is showing"]),
            ],
            deepLinks: ["home": "https://linear.app"]
        ),
        AppSkill(
            name: "Jira", bundleIDs: [], hosts: ["atlassian.net", "atlassian.com"],
            howItWorks: ["Top bar: 'Create' button opens the issue form (Project, Issue type, Summary, Description, 'Create'); search at the top-right; a board shows columns of cards; 'Your work' lists assigned issues. Confluence (same host) has 'Create' for pages."],
            recipes: [
                .init(goal: "create a ticket", keywords: ["create", "ticket", "issue", "bug", "story", "task", "jira"], steps: ["CLICK 'Create'", "TYPE_TEXT the summary", "TYPE_TEXT the description", "CLICK 'Create'"]),
                .init(goal: "find my tickets / a ticket", keywords: ["my", "assigned", "find", "ticket", "status", "sprint", "board"], steps: ["CLICK 'Your work' (or TYPE_TEXT the key into search and press Enter)", "CLICK the issue"]),
            ],
            deepLinks: ["your work": "https://home.atlassian.com/"],
            aliases: ["jira", "confluence", "atlassian"]
        ),
        AppSkill(
            name: "Trello", bundleIDs: [], hosts: ["trello.com"],
            howItWorks: ["A board is columns (lists) of cards; '+ Add a card' at the bottom of a list opens a title field (Enter adds it); clicking a card opens it (description, checklist, due date, members); cards are moved by dragging (NEED_VISION)."],
            recipes: [.init(goal: "add a card", keywords: ["add", "card", "task", "to do", "trello"], steps: ["CLICK '+ Add a card' under the named list", "TYPE_TEXT the title", "press Enter", "DONE when the card is in the list"])],
            deepLinks: ["home": "https://trello.com/"]
        ),
        AppSkill(
            name: "Asana", bundleIDs: [], hosts: ["app.asana.com"],
            howItWorks: ["Sidebar: Home, My tasks, Inbox, projects. 'My tasks' lists tasks; '+ Add task' (or the 'Create' button top-left) adds one (name, due date, assignee); clicking a task opens its details pane; the circle ticks it complete."],
            recipes: [
                .init(goal: "add a task", keywords: ["add", "task", "create", "to do", "assign"], steps: ["CLICK 'My tasks' (or the project)", "CLICK '+ Add task'", "TYPE_TEXT the task name", "press Enter"]),
                .init(goal: "complete a task", keywords: ["complete", "done", "finish", "mark"], steps: ["CLICK the circle next to the task"]),
            ],
            deepLinks: ["my tasks": "https://app.asana.com/0/mytasks", "home": "https://app.asana.com/"]
        ),
        AppSkill(
            name: "Notion Web", bundleIDs: [], hosts: ["notion.so", "www.notion.so"],
            howItWorks: ["Sidebar lists pages; '+ New page' at the bottom of the sidebar (or the ⊕ next to a page) creates one with the title focused. Blocks are contenteditable text; '/' opens the block menu; ⌘P searches."],
            recipes: [
                .init(goal: "create a page", keywords: ["create", "new page", "page", "write", "note"],
                      steps: ["CLICK '+ New page'", "TYPE_TEXT the title into 'Untitled'", "press Enter", "TYPE_TEXT the body"]),
                .init(goal: "find a page", keywords: ["find", "open", "search", "where"], steps: ["CLICK 'Search' in the sidebar", "TYPE_TEXT the page name", "CLICK the result"]),
            ],
            deepLinks: ["home": "https://www.notion.so"]
        ),
        AppSkill(
            name: "Slack Web", bundleIDs: [], hosts: ["app.slack.com", "slack.com"],
            howItWorks: ["Same as the desktop app: channels and DMs in the sidebar, the composer at the bottom (Enter sends), ⌘K quick switcher, search at the top."],
            recipes: [.init(goal: "message a person or channel", keywords: ["send", "message", "dm", "tell", "post", "channel", "reply"], steps: ["CLICK the channel/person in the sidebar (or the search bar, TYPE_TEXT the name, CLICK it)", "TYPE_TEXT the message into the composer", "press Enter"])],
            doneWhen: [sendMessageDone]
        ),
        AppSkill(
            name: "Discord Web", bundleIDs: [], hosts: ["discord.com"],
            howItWorks: ["Same as the desktop app: servers on the far left, channels next, the chat composer at the bottom (Enter sends)."],
            recipes: [.init(goal: "message someone / a channel", keywords: ["send", "message", "dm", "tell", "post", "channel"], steps: ["CLICK the server, then the channel or DM", "TYPE_TEXT the message", "press Enter"])],
            doneWhen: [sendMessageDone]
        ),
        AppSkill(
            name: "WhatsApp Web", bundleIDs: [], hosts: ["web.whatsapp.com"],
            howItWorks: ["Chats on the left with 'Search or start a new chat'; the open chat on the right with 'Type a message' at the bottom (Enter sends)."],
            recipes: [.init(goal: "message someone", keywords: ["send", "message", "text", "tell", "whatsapp"], steps: ["TYPE_TEXT the name into 'Search or start a new chat'", "CLICK the chat", "TYPE_TEXT the message into 'Type a message'", "press Enter"])],
            doneWhen: [sendMessageDone],
            aliases: ["whatsapp web"]
        ),
        AppSkill(
            name: "Telegram Web", bundleIDs: [], hosts: ["web.telegram.org"],
            howItWorks: ["Chats on the left with a search field; the composer 'Message' at the bottom of the open chat (Enter sends)."],
            recipes: [.init(goal: "message someone", keywords: ["send", "message", "text", "tell", "telegram"], steps: ["TYPE_TEXT the name into the search field", "CLICK the chat", "TYPE_TEXT the message", "press Enter"])],
            doneWhen: [sendMessageDone]
        ),
        AppSkill(
            name: "Teams Web", bundleIDs: [], hosts: ["teams.microsoft.com", "teams.live.com"],
            howItWorks: ["Left rail: Activity, Chat, Teams, Calendar, Calls. Chat composer at the bottom (Enter sends); Calendar meetings have 'Join'; in a meeting the toolbar has Mic, Camera, Share, Leave."],
            recipes: [
                .init(goal: "message someone", keywords: ["send", "message", "chat", "tell"], steps: ["CLICK 'Chat'", "CLICK 'New chat' and TYPE_TEXT the name (or CLICK the conversation)", "TYPE_TEXT the message", "press Enter"]),
                .init(goal: "join a meeting", keywords: ["join", "meeting", "call"], steps: ["CLICK 'Calendar'", "CLICK 'Join' on the meeting", "CLICK 'Join now'"]),
            ],
            doneWhen: [sendMessageDone, "the meeting is showing"],
            aliases: ["teams web"]
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
                .init(goal: "find an email", keywords: ["find", "open", "search", "from", "latest"], steps: ["TYPE_TEXT the words into the search bar and press Enter", "CLICK the message"]),
            ],
            doneWhen: ["the event is drawn on the calendar grid", "the compose pane closed after Send"],
            avoid: ["Do not stay on the Mail module for a calendar goal — go to /calendar/."],
            deepLinks: ["calendar": "https://outlook.office.com/calendar/", "new event": "https://outlook.office.com/calendar/deeplink/compose",
                        "compose mail": "https://outlook.office.com/mail/deeplink/compose", "mail": "https://outlook.office.com/mail/", "home": "https://outlook.office.com/mail/"],
            aliases: ["outlook web", "outlook.com", "office 365 mail"]
        ),
        AppSkill(
            name: "Dropbox", bundleIDs: [], hosts: ["dropbox.com"],
            howItWorks: ["Left: Home, All files, Photos, Shared, Deleted files; a search bar at the top; files are rows with name, modified date; clicking a row opens a preview; 'Upload' and 'Create' buttons on the right."],
            recipes: [.init(goal: "find / open a file", keywords: ["find", "open", "file", "folder", "shared", "dropbox"], steps: ["TYPE_TEXT the file name into the search bar and press Enter", "CLICK the file row", "DONE when the preview is open"])],
            deepLinks: ["home": "https://www.dropbox.com/home", "search": "https://www.dropbox.com/search/personal?query="]
        ),
        AppSkill(
            name: "Zoom Web", bundleIDs: [], hosts: ["zoom.us"],
            howItWorks: ["A meeting link (zoom.us/j/<id>) shows 'Launch Meeting' (opens the app) or 'Join from Your Browser'; the join page asks for a name then 'Join'."],
            recipes: [.init(goal: "join a meeting", keywords: ["join", "meeting", "zoom"], steps: ["CLICK 'Join from Your Browser' (or 'Launch Meeting')", "TYPE_TEXT the name if asked", "CLICK 'Join'"])],
            deepLinks: ["join": "https://zoom.us/join"]
        ),
        AppSkill(
            name: "Figma Web", bundleIDs: [], hosts: ["figma.com"],
            howItWorks: ["The file browser lists Recents / Drafts / team projects with a search field; a design file opens as a canvas that is not in the DOM (NEED_VISION for canvas work); FigJam boards likewise."],
            recipes: [.init(goal: "open a design file", keywords: ["open", "file", "design", "figma", "find"], steps: ["TYPE_TEXT the file name into the search field", "CLICK the file", "DONE when it is open"])],
            avoid: ["Do not choose BLOCKED on the canvas; choose NEED_VISION."],
            deepLinks: ["home": "https://www.figma.com/files/recent"]
        ),
    ]
}
