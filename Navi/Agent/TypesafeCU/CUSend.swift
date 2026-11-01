import Foundation

// Navi's own rule (not in typesafe_computer_use): a message is sent once.
//
// After a chat composer sends, it is empty again and the screen changed (a new bubble), so
// neither "the field already holds it" nor "already tried on this screen" stops Jev from
// typing it again — "text bella my schedule" once sent the same text seven times. Code decides
// the fact instead: every send is remembered, the writer reads the screen right after it (it
// usually says achieved), and a text that repeats one already sent is never typed again.

enum CUSend {
    /// Jev's `is_irreversible` at or above this marks a submit as a send.
    static let irreversible = 0.5
    /// Two texts sharing this much of their words are the same message reworded.
    static let sameMessage = 0.8

    /// Words of a field where a message is written, in the apps people message from.
    private static let composerWords = ["message", "imessage", "reply", "chat", "write", "type a", "send"]
    private static let searchWords = ["search", "find", "filter", "go to", "jump to"]

    /// Text typed into this field and submitted with Return: is that a send?
    static func isTypedSend(role: String, label: String, placeholder: String, bundleID: String?, irreversible p: Double) -> Bool {
        if role == "AXSearchField" || RecipientPicker.isRecipientLabel(label) { return false }
        let words = (label + " " + placeholder).lowercased()
        if searchWords.contains(where: words.contains) { return false }
        if p >= irreversible { return true }
        return RecipientPicker.contactApps.contains(bundleID ?? "") && composerWords.contains(where: words.contains)
    }

    /// A click on a control that sends what was written ("Send", "Post").
    static func isSendControl(label: String, irreversible p: Double) -> Bool {
        guard p >= irreversible, let first = words(label).first else { return false }
        return ["send", "post", "tweet", "publish"].contains(first)
    }

    /// Would typing `text` send again a message the run already sent (or the same one reworded)?
    static func repeats(_ text: String, sent: [String]) -> Bool {
        let w = Set(words(text))
        guard !w.isEmpty else { return false }
        return sent.contains { s in
            let o = Set(words(s))
            if o == w { return true }
            guard w.count >= 3, o.count >= 3 else { return false }
            return Double(w.intersection(o).count) / Double(w.union(o).count) >= sameMessage
        }
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
}
