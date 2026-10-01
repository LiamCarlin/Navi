import Foundation

/// How the user reaches the people in their life, read from screen memory —
/// not "this name was on screen in Messages" (every name in a chat sidebar is)
/// but signs that they actually dealt with that person there:
///   - a conversation was *open*: Messages titles its window with the chat;
///     a click on a chat row ("João Pedro Mendes", "r2 gang fall 26, 2 unread
///     messages") or a bubble ("…, Received from João Pedro Mendes") in any
///     chat app (`ActionJournal`);
///   - an email address shown next to their name (`Meera Baswan <mb128@…>`)
///     in a mail app or web mail — the address the user has mailed them at.
///
/// Pure parsing lives here; `UserKnowledge` loads the rows and folds the
/// signals into its people, so "text dhvan" goes where the user opens Dhvan's
/// chat and "email meera" addresses the email they have used before.
enum UserContacts {
    /// A conversation with `name` was open in an app (or on a site).
    struct Opened: Sendable, Equatable {
        var name: String
        var key: String
        var app: String
        var isWeb: Bool
        var at: Date
    }

    /// `address` was shown as `name`'s in a mail app or on a mail site.
    struct Address: Sendable, Equatable {
        var name: String
        var address: String
        var key: String
        var app: String
        var isWeb: Bool
        var at: Date
    }

    struct Signals: Sendable, Equatable {
        var opened: [Opened] = []
        var addresses: [Address] = []
        var isEmpty: Bool { opened.isEmpty && addresses.isEmpty }
    }

    // MARK: Which apps

    /// Skills whose windows and rows are conversations with people.
    static let channelKinds: Set<String> = ["texting", "email", "video calls"]

    /// Bundle ids of the apps one talks to people in (Messages, WhatsApp, Slack, Mail, FaceTime…).
    static var channelBundles: Set<String> {
        Set(UserHabits.kinds.filter { channelKinds.contains($0.kind) }.flatMap(\.skills)
            .compactMap { name in AppSkills.all.first { $0.name == name } }.flatMap(\.bundleIDs))
    }

    /// Apps that title their window with the open conversation.
    static let titledByConversation: Set<String> = ["com.apple.MobileSMS"]

    /// Mail apps and sites: where `Name <address>` is someone's address.
    static func isMailPlace(bundleID: String, url: String?) -> Bool {
        if let u = url, let s = AppSkills.skill(url: u), mailSkills.contains(s.name) { return true }
        if let s = AppSkills.skill(bundleID: bundleID), mailSkills.contains(s.name) { return true }
        return extraMailBundles.contains(bundleID)
    }

    static var mailSkills: Set<String> { Set(UserHabits.kinds.first { $0.kind == "email" }?.skills ?? []) }

    /// Mail clients without a playbook of their own.
    static let extraMailBundles: Set<String> = [
        "com.readdle.smartemail-Mac", "it.bloop.airmail2", "com.superhuman.electron", "com.mimestream.Mimestream",
        "com.canarymail.mac", "com.freron.MailMate",
    ]

    // MARK: Conversation names (pure)

    /// Invisible marks chat apps put around names (WhatsApp wraps them in U+202A…U+202C).
    static func stripMarks(_ s: String) -> String {
        s.unicodeScalars.filter { !(0x200B...0x200F).contains($0.value) && !(0x202A...0x202E).contains($0.value) && $0.value != 0xFEFF }
            .map(String.init).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Window titles that are the app, not a conversation.
    static let nonConversationTitles: Set<String> = ["", "messages", "quick look", "new message", "whatsapp", "facetime", "mail", "slack", "inbox"]

    /// The conversation a Messages window shows ("Bella Chen"), or nil for the app itself.
    static func conversation(windowTitle: String?) -> String? {
        guard let t = windowTitle.map(stripMarks), !nonConversationTitles.contains(t.lowercased()) else { return nil }
        return t
    }

    /// The chat a click in a chat app opened: a row or button named for it
    /// ("r2 gang fall 26, 2 unread messages" → "r2 gang fall 26"), or a bubble that
    /// says whose it is ("…, Received from João Pedro Mendes"). nil for controls.
    static func conversation(clickedLabel label: String, role: String) -> String? {
        let l = stripMarks(label)
        if let r = l.range(of: #"Received (?:from|in) (.+)$"#, options: .regularExpression) {
            let tail = String(l[r]).replacingOccurrences(of: #"^Received (?:from|in) "#, with: "", options: .regularExpression)
            return clean(tail)
        }
        guard ["button", "row", "cell", "text", "static text", "group"].contains(role.lowercased()) else { return nil }
        let first = l.split(separator: ",", maxSplits: 1).first.map(String.init) ?? l
        return clean(first)
    }

    /// Labels of controls, never chats.
    static let controlWords: Set<String> = [
        "close", "minimize", "zoom", "back", "search", "new message", "compose", "send", "message", "clear text", "emoji",
        "chats", "calls", "updates", "communities", "settings", "archived", "starred", "unread", "favorites", "media",
        "more", "info", "details", "add", "attach", "record audio", "voice message", "video call", "audio call", "call",
        "mute", "pin", "delete", "edit", "reply", "forward", "copy", "react", "thumbs up", "thumbs down", "heart",
        "meta ai", "new chat", "filter", "all", "groups", "contacts", "status", "camera", "photos", "stickers", "gif",
    ]

    private static func clean(_ raw: String) -> String? {
        let n = stripMarks(raw).trimmingCharacters(in: CharacterSet(charactersIn: " ~·•"))
        guard n.count >= 2, n.count <= 50, !controlWords.contains(n.lowercased()), n.contains(where: \.isLetter),
              !n.contains("@"), n.filter(\.isNumber).count < 6 else { return nil }
        // A sentence (a message's text), not a name.
        guard n.split(separator: " ").count <= 6, !n.hasSuffix("?"), !n.hasSuffix(".") || n.count < 6 else { return nil }
        return n
    }

    // MARK: Email addresses (pure)

    private static let pairPattern = try! NSRegularExpression(
        pattern: #"([\p{Lu}][\p{L}\p{M}'’.\-]*(?:[ ,]+[\p{L}][\p{L}\p{M}'’.\-]*){0,4})\s*<\s*([A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,})\s*>"#)

    /// `Display Name <address>` pairs in OCR text, cleaned: column junk before the
    /// name dropped ("Results  O Nuray Molla" → "Nuray Molla"), OCR's capital I in a
    /// lower-case address read as l ("Icarlin" → "lcarlin").
    static func pairs(in text: String) -> [(name: String, address: String)] {
        var out: [(String, String)] = []
        for line in text.split(separator: "\n") {
            let s = String(line)
            let ns = s as NSString
            for m in pairPattern.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                guard let name = displayName(ns.substring(with: m.range(at: 1))),
                      let addr = address(ns.substring(with: m.range(at: 2))) else { continue }
                out.append((name, addr))
            }
        }
        return out
    }

    /// Words OCR glues in front of a name from the column beside it.
    static let junkWords: Set<String> = [
        "am", "pm", "to", "from", "cc", "bcc", "results", "pinned", "emails", "other", "focused", "inbox", "today", "yesterday",
        "last", "week", "month", "sent", "drafts", "archive", "reply", "all", "forward", "re", "fw", "fwd", "on", "wrote",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "top", "saved", "searches", "rss", "feeds",
    ]

    static func displayName(_ raw: String) -> String? {
        // Two spaces separate OCR columns: the name is the last one.
        var n = raw.components(separatedBy: "  ").last ?? raw
        n = n.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:\"'"))
        var words = n.split(separator: " ").map(String.init)
        // An avatar's initial ("O Nuray Molla") and a time's AM/PM ("PM, Yoi Tanaka").
        while let f = words.first, words.count > 1,
              (f.count == 1 && f.uppercased() == f) || junkWords.contains(f.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            words.removeFirst()
        }
        n = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        guard n.count >= 2, n.count <= 50, !words.isEmpty, words.count <= 5,
              !words.allSatisfy({ junkWords.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) }) else { return nil }
        return n
    }

    static func address(_ raw: String) -> String? {
        let parts = raw.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        func fixI(_ s: String) -> String {
            // OCR reads a lower-case l as a capital I: in an otherwise lower-case part it is an l.
            let uppers = s.filter(\.isUppercase)
            return !uppers.isEmpty && uppers.allSatisfy({ $0 == "I" }) ? s.replacingOccurrences(of: "I", with: "l") : s
        }
        let a = (fixI(parts[0]) + "@" + fixI(parts[1])).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard a.range(of: #"^[a-z0-9._%+\-]+@[a-z0-9\-]+(\.[a-z0-9\-]+)*\.[a-z]{2,}$"#, options: .regularExpression) != nil,
              !a.hasPrefix("noreply"), !a.hasPrefix("no-reply"), !a.hasPrefix("donotreply"), !a.contains("@users.noreply.") else { return nil }
        return a
    }

    /// The one address in "Meera Baswan <mb128@wellesley.edu>" (nil for none, or several).
    static func soleAddress(in text: String) -> String? {
        let pattern = #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}"#
        guard let r = text.range(of: pattern, options: .regularExpression),
              text[r.upperBound...].range(of: pattern, options: .regularExpression) == nil else { return nil }
        return String(text[r])
    }

    /// Does the address look like it belongs to the name? "cphillips" ~ Crawford
    /// Phillips, "mb128" ~ Meera Baswan, "carpediem" ~ Carpe Diem. A pair seen
    /// once without this is OCR pairing a name with the next column's address.
    static func belongs(_ address: String, to name: String) -> Bool {
        let local = String(address.split(separator: "@").first ?? "").filter(\.isLetter)
        let words = UserKnowledge.tokens(name.folding(options: .diacriticInsensitive, locale: nil)).map { $0.filter(\.isLetter) }.filter { !$0.isEmpty }
        guard !local.isEmpty, !words.isEmpty else { return false }
        if words.contains(where: { $0.count >= 3 && local.contains($0) }) { return true }
        if local.contains(words.joined()) { return true }
        let initials = String(words.compactMap(\.first))
        if initials.count >= 2, local.hasPrefix(initials) { return true }
        if let first = words.first?.first, let last = words.last, words.count >= 2, local.hasPrefix(String(first) + last.prefix(3)) { return true }
        return false
    }
}
