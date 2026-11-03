import Foundation

/// Who a message is for. "send a text to jonathan saying hi" is Jonathan *alone*: a conversation
/// that lists him among others ("Jonathan & +1", "Jack, Dhvan, Lena, Premkumar, Reja & Jonathan",
/// Messages' "New Message to Jonathan, Kieran & …") is a group, never his chat.
///
/// Live (2026-11-02): four runs of "text jonathan" — the user's path followed the group row
/// "Jonathan & +1" (his name was on it, and opening it was counted as reaching him), a routine
/// clicked the five-person group, and the recipient picker took the To: suggestion
/// "Jonathan, Kieran & +1 (925) …" over the contact Jonathan Sun (the member's number read as
/// the entry's own phone). "hi" went to three people and the writer called it achieved.
///
/// Code decides these facts; every layer asks the same two questions here.
enum MessageAudience {

    // MARK: The task

    /// Verbs and nouns of a task that sends someone a message.
    private static let messageVerbs = #"\b(text|txt|message|msg|imessage|dm|pm|email|e-mail|mail|ping|whatsapp|reply|respond|tell|send|write)\b"#
    /// Words that address several people at once.
    private static let groupWords: Set<String> = [
        "group", "groupchat", "gc", "everyone", "everybody", "all", "team", "guys", "both", "them", "us",
        "family", "squad", "crew", "club", "class", "channel", "chats", "people", "friends",
    ]
    /// Words of the addressee phrase that are not the person ("send a text to …", "on whatsapp").
    private static let fillerWords: Set<String> = [
        "send", "sending", "write", "text", "txt", "message", "msg", "imessage", "dm", "pm", "email", "e-mail", "mail", "ping", "whatsapp",
        "reply", "respond", "tell", "a", "an", "the", "to", "on", "in", "via", "over", "through", "with", "only", "just", "alone", "directly",
        "privately", "me", "please", "can", "could", "you", "navi", "quick", "new", "imessages", "messages", "slack", "outlook", "gmail",
        "telegram", "signal", "messenger", "teams", "discord", "app", "from", "my", "back", "of", "for", "real", "quickly",
    ]

    /// Does the task send a message to someone (text, email, DM, reply)?
    static func isMessage(_ task: String) -> Bool {
        let t = task.lowercased()
        guard t.range(of: messageVerbs, options: .regularExpression) != nil else { return false }
        // "send" alone is a message only with something message-like or a person ("send jonathan a text").
        if t.range(of: #"\b(text|txt|message|msg|imessage|dm|pm|email|e-mail|mail|ping|whatsapp|reply|respond|tell)\b"#, options: .regularExpression) != nil { return true }
        return t.range(of: #"\bsend\s+(a\s+)?(note|line)\b"#, options: .regularExpression) != nil
    }

    /// The words that name who the message is for ("text jonathan saying hi" → ["jonathan"];
    /// "message jonathan and kieran" → ["jonathan", "and", "kieran"]). Nil when the task sends nothing.
    static func addressee(of task: String) -> [String]? {
        guard isMessage(task) else { return nil }
        var t = TaskGrounding.withoutDictation(task).lowercased()
        // What the message is about is not who it is for ("about the assignment", "that I'm late").
        t = t.replacingOccurrences(of: #"\b(about|regarding|re|that|asking|letting|when|if|whether|to say|to ask|to let)\b.*$"#,
                                   with: "", options: .regularExpression)
        let words = t.replacingOccurrences(of: "&", with: " and ")
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "," }
            .flatMap { w -> [String] in
                // Keep a comma as its own word: it lists people ("jonathan, kieran").
                let s = String(w)
                return s.hasSuffix(",") ? [String(s.dropLast()), ","] : [s]
            }
            .map { $0.replacingOccurrences(of: "'s", with: "") }
            .filter { !$0.isEmpty }
        return words.filter { !fillerWords.contains($0) }
    }

    /// The task messages exactly one person: an addressee, and no second name, list or group word.
    /// "text jonathan saying hi", "send a message to only jonathan", "email the registrar" → true;
    /// "text jonathan and kieran", "message the group", "text everyone" → false.
    static func isOnePerson(_ task: String) -> Bool {
        guard let words = addressee(of: task), !words.isEmpty else { return false }
        if words.contains(where: groupWords.contains) { return false }
        if words.contains("and") || words.contains(",") || words.contains("plus") { return false }
        return true
    }

    // MARK: Conversations

    /// A conversation (chat row, window title, recipient suggestion) that lists several people:
    /// "Jonathan & +1", "Jonathan, Kieran & +1 (925) 548-3198", "Jack,  Dhvan,  Lena & Jonathan, Unread, son, 10:04 AM",
    /// "New Message to Jonathan, Kieran & [redacted]". A group with a name of its own ("THE GANG")
    /// is not a member list and is not flagged: the task names it when it means it.
    static func isGroupConversation(_ label: String) -> Bool {
        var s = label.replacingOccurrences(of: "\u{200E}", with: "").replacingOccurrences(of: "\u{200F}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespaces)
        if let r = s.range(of: #"^new (message|group|imessage)( to)?\s*"#, options: [.regularExpression, .caseInsensitive]) {
            s.removeSubrange(r)
        }
        // The member list comes first: name-like parts, the last joined with "&". A row's status
        // ("Unread", "Pinned") ends it: an "&" in the preview after it is someone's text.
        for part in s.split(separator: ",").prefix(12).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if rowMarkers.contains(part.lowercased()) { return false }
            if part.contains("&") {
                let sides = part.split(separator: "&").map { $0.trimmingCharacters(in: .whitespaces) }
                return sides.count >= 2 && sides.allSatisfy(isMember)
            }
            guard isMember(part) else { return false }
        }
        return false
    }

    private static let rowMarkers: Set<String> = ["unread", "pinned", "muted", "read", "delivered", "sent", "draft", "typing"]

    /// One member of a member list: a short, capitalised name, "+1", a phone number, or a redaction.
    static func isMember(_ part: String) -> Bool {
        let p = part.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, p.count <= 40 else { return false }
        if p == "[redacted]" { return true }
        if p.range(of: #"^\+\d{1,3}(\s*[\d()\-.\s…]*)?$"#, options: .regularExpression) != nil { return true }   // "+1", "+1 (925) 548-3198", "+1 (9…"
        if RecipientPicker.looksLikeAddress(p) { return true }
        // WhatsApp marks a name it only knows from the member's own profile with "~ ".
        let words = p.split(separator: " ").filter { $0 != "~" }
        guard (1...4).contains(words.count) else { return false }
        return words.allSatisfy { w in
            w == "[redacted]" || (w.first?.isUppercase == true && w.allSatisfy { $0.isLetter || "'’-.".contains($0) })
        }
    }

    /// Recipients a To: field holds: Messages draws each picked contact as one U+FFFC.
    static func pillCount(_ value: String?) -> Int {
        (value ?? "").filter { $0 == "\u{FFFC}" }.count
    }

    // MARK: Who to tell

    /// For Jev's state and the writer's packet when the task is for one person.
    static func fact(task: String, person: String?) -> [String: Any]? {
        guard isOnePerson(task) else { return nil }
        var d: [String: Any] = [
            "only_this_person": true,
            "rule": "This message is for one person alone. A conversation or suggestion that lists other people too "
                + "(“Jonathan & +1”, “Jack, Dhvan & Jonathan”, “New Message to Jonathan, Kieran & …”) is a group, not theirs: "
                + "never open it, pick it or send in it. Start a new message to them (their own name in To:) instead. "
                + "A message sent into a group is not achieved.",
        ]
        if let person, !person.isEmpty { d["person"] = person }
        return d
    }
}
