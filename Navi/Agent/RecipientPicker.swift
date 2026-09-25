import AppKit
import ApplicationServices
import Foundation

/// Recipient fields (Messages' To:, Mail/Outlook To/Cc/Bcc, FaceTime, invitees…)
/// do not take a name as text: the app looks the name up, shows a suggestion
/// list ~0.5 s later, and only picking a suggestion turns it into a contact —
/// the pill that opens the thread / addresses the email. Jev decides the next
/// step from the screen right after typing, before the list is there, so it
/// moved on to the message field with the name left as raw text (Messages
/// then sends nowhere; Outlook makes an unresolvable "mikey ku" chip).
///
/// So after TYPE_TEXT into such a field the driver does what a person does:
/// waits for the suggestions to settle, picks the one matching the name
/// (not blindly the highlighted one — for "Mik" Messages highlights Mike
/// Grandinetti above Mikey Ku), and checks that the pick took.
///
/// The name must also be *typed*: setting AXValue directly never starts the
/// app's contact search (measured in Messages), so `ActionExecutor.type`
/// skips its AXValue fast path for these fields.
enum RecipientPicker {

    // MARK: Which fields (pure)

    /// Exact labels (lower-cased, trailing ":" dropped) of recipient fields.
    static let recipientLabels: Set<String> = [
        "to", "cc", "bcc", "to recipients", "cc recipients", "bcc recipients", "recipients", "recipient",
        "add recipients", "send to", "invitees", "add invitees", "add guests", "guests", "attendees",
        "add people", "add members", "participants",
    ]
    /// Phrases that mark a recipient field anywhere in its label/placeholder.
    static let recipientPhrases: [String] = [
        "recipient", "add people", "add guests", "add invitees", "invite people", "add members",
        "name or email", "names or email", "name, email", "email or name", "type a name", "enter a name",
        "enter name", "search for people", "people or groups", "name, phone", "phone number or email",
        "email address or phone", "enter email", "add attendees",
    ]

    static func isRecipientLabel(_ label: String) -> Bool {
        var l = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while l.hasSuffix(":") || l.hasSuffix("…") { l.removeLast() }
        l = l.trimmingCharacters(in: .whitespaces)
        guard !l.isEmpty else { return false }
        if recipientLabels.contains(l) { return true }
        return recipientPhrases.contains { l.contains($0) }
    }

    /// A text input whose label says it takes people. The sidebar "Search" of
    /// Messages is not one (it filters conversations, it starts nothing).
    static func isRecipientField(_ el: AXElement) -> Bool {
        guard el.isTextInput, !el.isSecure else { return false }
        return isRecipientLabel(el.label)
    }

    /// An email address or a phone number: the app accepts it as typed, a
    /// suggestion is a bonus, not a requirement.
    static func looksLikeAddress(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil { return true }
        let digits = t.filter(\.isNumber).count
        return digits >= 7 && t.range(of: #"^[+()\-.\s\d]+$"#, options: .regularExpression) != nil
    }

    // MARK: Matching (pure)

    struct Suggestion: @unchecked Sendable {
        var role: String
        var label: String
        var frame: CGRect
        var isSelected: Bool
        var pid: pid_t = 0
        var ref: AXUIElement?

        /// Identity across scans (frames move as a list scrolls or re-sorts).
        var key: String { role + "|" + label }
    }

    /// Lower-cased, diacritics and invisible marks (Messages prefixes numbers with U+200E) removed.
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "\u{200E}", with: "").replacingOccurrences(of: "\u{200F}", with: "")
    }

    static func words(_ s: String) -> [String] {
        fold(s).split { !$0.isLetter && !$0.isNumber && $0 != "@" && $0 != "." && $0 != "'" }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".'")) }.filter { !$0.isEmpty }
    }

    /// The person/place a suggestion names: its first comma-separated part
    /// ("Mikey Ku, +1 (774) 578-8428, Text Message" → "Mikey Ku").
    static func name(of label: String) -> String {
        let first = label.split(separator: ",", maxSplits: 1).first.map(String.init) ?? label
        return first.trimmingCharacters(in: .whitespaces)
    }

    static func parts(_ label: String) -> [String] {
        label.split(separator: ",").map { fold(String($0)).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A person entry: "Name, <phone or email>, …" ("Mikey Ku, +1 (774) 578-8428, Text Message").
    /// Only the part right after the name counts — a group lists members and
    /// may carry an unsaved member's number further on ("Mikey, Bhar, …, +14257800416").
    static func hasHandle(_ label: String) -> Bool {
        let p = parts(label)
        guard p.count >= 2 else { return false }
        return p[1].contains("@") || p[1].filter(\.isNumber).count >= 7
    }

    /// Several people in one entry ("Mikey, Dhvan & David", "Bhar, Mikey, Zach, Kilan…").
    static func isGroup(_ label: String) -> Bool {
        if hasHandle(label) { return false }
        return label.contains("&") || parts(label).count >= 3
    }

    /// How well `label` answers the typed text; nil when it does not match at all.
    /// Every typed word must begin a word of the suggestion's name ("mik" ⊂ "Mikey"),
    /// or — for an address — the suggestion must contain it.
    /// `recent`: folded text that was on screen before typing (recent conversations,
    /// the open email): a name seen there is the person the user deals with.
    static func score(typed: String, label: String, isSelected: Bool, recent: String = "") -> Double? {
        let typedFolded = fold(typed).trimmingCharacters(in: .whitespaces)
        guard !typedFolded.isEmpty, !label.isEmpty else { return nil }
        let labelFolded = fold(label)
        if looksLikeAddress(typed) {
            let digits = typed.filter(\.isNumber)
            let matched = labelFolded.contains(typedFolded)
                || (digits.count >= 7 && label.filter(\.isNumber).contains(digits.suffix(10)))
            return matched ? 3 + (isSelected ? 0.5 : 0) : nil
        }
        let nameWords = words(name(of: label))
        let typedWords = words(typed)
        guard !typedWords.isEmpty, !nameWords.isEmpty else { return nil }
        // Each typed word begins a distinct name word.
        var used = Set<Int>()
        var exactWords = 0
        for t in typedWords {
            guard let i = nameWords.indices.first(where: { !used.contains($0) && nameWords[$0].hasPrefix(t) }) else { return nil }
            used.insert(i)
            if nameWords[i] == t { exactWords += 1 }
        }
        var s = 1.0
        s += Double(exactWords) / Double(typedWords.count)                 // "mikey" = "Mikey" beats "mike" ⊂ "Mikey"
        let group = isGroup(label)
        let wholeName = used.count == nameWords.count
        let typedExactly = wholeName && exactWords == nameWords.count
        // The whole name was typed — exactly ("the gang" = "THE GANG") far more than as
        // prefixes ("Theo Gangi"). A group's "name" may just be its first member
        // ("Mikey, Bhar, Zach…"), so for a group only an exact name of 2+ words counts.
        let namedGroup = group && typedExactly && typedWords.count >= 2
        if wholeName, !group || namedGroup { s += typedExactly ? 3 : 1 }
        if hasHandle(label) { s += 1 }                                     // a person with a number/email
        if group, !namedGroup { s -= 2 }                                   // not a group, unless it is all that matches
        if isSelected { s += 0.5 }                                         // the app's own best guess
        let fullName = fold(name(of: label))
        if !recent.isEmpty, fullName.count >= 3, recent.contains(fullName) { s += 0.75 }
        return s
    }

    /// The suggestion to pick, best score first; list order (the app's ranking) breaks ties.
    static func best(typed: String, among suggestions: [Suggestion], recent: String = "") -> Suggestion? {
        var top: (Suggestion, Double)?
        for s in suggestions {
            guard let sc = score(typed: typed, label: s.label, isSelected: s.isSelected, recent: recent) else { continue }
            if top == nil || sc > top!.1 + 1e-9 { top = (s, sc) }
        }
        return top?.0
    }

    /// Scan result → the suggestions that were not on screen before typing.
    static func fresh(_ scan: [Suggestion], baseline: Set<String>, typed: String) -> [Suggestion] {
        let t = fold(typed).trimmingCharacters(in: .whitespaces)
        return scan.filter { !baseline.contains($0.key) && fold($0.label).trimmingCharacters(in: .whitespaces) != t }
    }

    // MARK: Outcome

    enum Outcome: Equatable, Sendable {
        /// A suggestion was picked (its name).
        case picked(String)
        /// Nothing matched but the text is an address the app takes as typed.
        case keptAddress
        /// No suggestion appeared at all.
        case noSuggestions
        /// Suggestions appeared, none matching (the first few names).
        case noMatch([String])
        /// Picked, but the list stayed open — the pick may not have taken.
        case unconfirmed(String)

        /// Appended to the step's history entry, so Jev (and the coach) know the recipient is set.
        func note(typed: String) -> String {
            switch self {
            case .picked(let n): return " → picked the contact ‘\(n)’ from the suggestions (recipient set)"
            case .keptAddress: return " → kept as typed (an address)"
            case .noSuggestions: return " → error: no contact suggestion came up for ‘\(typed)’ (recipient NOT set)"
            case .noMatch(let seen): return " → error: no suggestion matches ‘\(typed)’ (saw: \(seen.prefix(3).joined(separator: "; "))) — recipient NOT set"
            case .unconfirmed(let n): return " → clicked the suggestion ‘\(n)’ but the list stayed open"
            }
        }

        var isResolved: Bool {
            switch self {
            case .picked, .keptAddress: return true
            default: return false
            }
        }

        /// No contact is behind the name: in a messaging/email app the run stops here.
        var stopsContactApp: Bool {
            switch self {
            case .noSuggestions, .noMatch: return true
            default: return false
            }
        }

        /// Why the run stops, in the user's terms.
        func failure(typed: String, field: String, app: String?) -> String {
            let where_ = app.map { " in \($0)" } ?? ""
            switch self {
            case .noMatch(let seen) where !seen.isEmpty:
                return "Typed ‘\(typed)’ into \(field)\(where_), but none of the suggestions (\(seen.prefix(3).joined(separator: ", "))) is that person, so I stopped before writing anything. Say their full name, number or email."
            default:
                return "Typed ‘\(typed)’ into \(field)\(where_), but no matching contact came up, so I stopped before writing anything. Say their full name, number or email."
            }
        }
    }

    /// Apps where an unresolved recipient means the message goes nowhere (or to the
    /// wrong person): the run stops instead of writing the message.
    static let contactApps: Set<String> = [
        "com.apple.MobileSMS", "com.apple.iChat", "com.apple.mail", "com.microsoft.Outlook", "com.apple.FaceTime",
        "com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp", "WhatsApp", "com.facebook.archon", "ru.keepcoder.Telegram",
    ]

    // MARK: Where suggestions appear (pure)

    /// Suggestion lists drop down from the field: at most ~480 pt below it and
    /// roughly under it. Looking only there keeps an app's sidebar or message
    /// list (Messages' conversations, Outlook's inbox) out of the candidates.
    static func searchRegion(for field: CGRect) -> CGRect {
        CGRect(x: field.minX - 20, y: field.minY - 4, width: max(field.width, 320) + 60, height: field.height + 480)
    }

    /// The field's own row: where the picked contact's pill/chip shows up.
    static func tokenRegion(for field: CGRect) -> CGRect {
        field.insetBy(dx: -24, dy: -8)
    }

    /// When no entry matches by name, the app's own pick is still the person a
    /// human would take — the highlighted entry, else the topmost when it is a
    /// person (Outlook offers "Michael Ku Jr, mkujr@…" for "mikey ku") — as long
    /// as it does not contradict what was typed.
    static func appChoice(typed: String, among candidates: [Suggestion]) -> Suggestion? {
        let rows = candidates.filter { ($0.role != "AXStaticText" || hasHandle($0.label)) && compatible(typed: typed, label: $0.label) }
        if let s = rows.first(where: \.isSelected), !isGroup(s.label) { return s }
        guard let top = rows.min(by: { $0.frame.minY < $1.frame.minY }), hasHandle(top.label) else { return nil }
        return top
    }

    /// Could `label` be a nickname spelling of `typed`? Every typed word needs a
    /// name word with the same first letter ("mikey ku" ~ "Michael Ku Jr";
    /// "mikey smith" is not "Mikey Ku").
    static func compatible(typed: String, label: String) -> Bool {
        let nameWords = words(name(of: label))
        let typedWords = words(typed)
        guard !typedWords.isEmpty else { return false }
        var used = Set<Int>()
        for t in typedWords {
            guard let i = nameWords.indices.first(where: { !used.contains($0) && nameWords[$0].first == t.first }) else { return false }
            used.insert(i)
        }
        return true
    }

    /// Words people use for family that contacts are rarely saved under.
    static let nicknames: [String: [String]] = [
        "mom": ["mama", "mum", "mother", "mommy", "ma", "mami"], "mum": ["mom", "mama", "mother", "mummy"],
        "mother": ["mom", "mama", "mum"], "mommy": ["mom", "mama"], "mama": ["mom", "mum", "mother"],
        "dad": ["papi", "papa", "father", "daddy", "pops", "pa"], "father": ["dad", "papa", "papi"],
        "daddy": ["dad", "papa", "papi"], "papa": ["dad", "papi", "father"],
        "grandma": ["nana", "granny", "grandmother", "abuela", "gma"], "grandmother": ["grandma", "nana", "granny"],
        "grandpa": ["granddad", "grandad", "grandfather", "abuelo", "gpa", "pop"], "grandfather": ["grandpa", "granddad"],
        "brother": ["bro"], "sister": ["sis"], "wife": ["wifey"], "husband": ["hubby"],
    ]

    /// Other names to try when the app suggests nothing for `typed` ("mom" → "Mama"),
    /// those already on screen (a pinned "Mama" conversation) first.
    static func alternatives(for typed: String, recent: String) -> [String] {
        var key = fold(typed).trimmingCharacters(in: .whitespaces)
        if key.hasPrefix("my ") { key = String(key.dropFirst(3)) }
        guard let alts = nicknames[key] else { return [] }
        let seen = Set(words(recent))
        let onScreen = alts.filter { seen.contains($0) }
        return (onScreen + alts.filter { !seen.contains($0) }).map { $0.prefix(1).uppercased() + $0.dropFirst() }
    }

    // MARK: Live (AX)

    static let settleMaxMs = 3000
    static let firstLookMs = 250
    static let pollMs = 100
    static let confirmMs = 1200
    /// How long a group may be the best match before it is taken (a person usually arrives by then).
    static let groupWaitMs = 2000

    /// Every pressable, labelled element inside `region` across the app's
    /// windows — suggestion lists are an overlay in the window (Messages), a
    /// popover or a separate borderless window (Mail), so the focused window alone
    /// misses some. Subtrees whose frame lies outside the region are skipped, so
    /// a huge window (Outlook) still scans in a few ms.
    static func scan(pid: pid_t, region: CGRect) async -> [Suggestion] {
        await AXQueue.run {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.15)
            var roots: [AXUIElement] = []
            if let w = AXSnapshotter.attr(app, kAXFocusedWindowAttribute) as! AXUIElement? { roots.append(w) }
            for w in (AXSnapshotter.elements(AXSnapshotter.attr(app, kAXWindowsAttribute)) ?? []).prefix(6) where !roots.contains(where: { CFEqual($0, w) }) {
                roots.append(w)
            }
            let deadline = Date().addingTimeInterval(0.25)
            var out: [Suggestion] = []
            var stack = roots.reversed().map { ($0, 0) }
            var visited = 0
            let attrs = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
                         "AXFrame", kAXChildrenAttribute, kAXSelectedAttribute, kAXHiddenAttribute] as [String]
            while let (el, depth) = stack.popLast(), visited < 4000, Date() < deadline {
                visited += 1
                let v = AXSnapshotter.multiple(el, attrs)
                if (v[7] as? Bool) == true { continue }
                let role = v[0] as? String ?? ""
                let f = AXSnapshotter.rect(v[4])
                // Off-region subtree: skip (containers with no frame are still walked).
                if depth > 0, let f, f.width > 0, f.height > 0, !f.intersects(region) { continue }
                if ["AXButton", "AXRow", "AXCell", "AXMenuItem", "AXStaticText", "AXListItem", "AXLink", "AXPopUpButton", "AXMenuButton"].contains(role),
                   let f, f.width >= 4, f.height >= 4, region.intersects(f) {
                    var label = [v[1] as? String ?? "", v[2] as? String ?? "", AXSnapshotter.stringValue(v[3]) ?? ""]
                        .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
                    if label.isEmpty, role != "AXStaticText" { label = childText(el) }
                    if !label.isEmpty {
                        out.append(Suggestion(role: role, label: String(label.prefix(120)), frame: f,
                                              isSelected: (v[6] as? Bool) == true, pid: pid, ref: el))
                    }
                }
                guard depth < 30, let kids = AXSnapshotter.elements(v[5]) else { continue }
                for k in kids.reversed() { stack.append((k, depth + 1)) }
            }
            return out
        }
    }

    /// The text drawn inside a row/cell without a label of its own ("Mikey Ku", "mikey@olin.edu").
    private static func childText(_ el: AXUIElement) -> String {
        var parts: [String] = []
        var queue: [(AXUIElement, Int)] = (AXSnapshotter.elements(AXSnapshotter.attr(el, kAXChildrenAttribute)) ?? []).map { ($0, 1) }
        while !queue.isEmpty, parts.count < 3 {
            let (n, d) = queue.removeFirst()
            if (AXSnapshotter.attr(n, kAXRoleAttribute) as? String) == "AXStaticText",
               let t = AXSnapshotter.stringValue(AXSnapshotter.attr(n, kAXValueAttribute)) ?? (AXSnapshotter.attr(n, kAXDescriptionAttribute) as? String),
               !t.trimmingCharacters(in: .whitespaces).isEmpty {
                parts.append(t.trimmingCharacters(in: .whitespaces))
            }
            if d < 3 { queue += (AXSnapshotter.elements(AXSnapshotter.attr(n, kAXChildrenAttribute)) ?? []).map { ($0, d + 1) } }
        }
        return parts.joined(separator: ", ")
    }

    /// Keys of what is around the field before typing: suggestions are what appears after.
    static func baseline(pid: pid_t, field: CGRect) async -> Set<String> {
        Set(await scan(pid: pid, region: searchRegion(for: field)).map(\.key))
    }

    /// Waits for the suggestion list the typing brought up, picks the entry for
    /// `typed` and confirms the list closed. `recent`: what was on screen before.
    /// `.noSuggestions` means nothing could be seen — the caller may try other
    /// names, then `acceptHighlighted`.
    static func resolve(typed: String, pid: pid_t, field: CGRect, baseline: Set<String>, recent: String,
                        executor: ActionExecutor, trace: ((String) -> Void)? = nil, keepGoing: () -> Bool) async -> Outcome {
        let start = Date()
        func elapsed() -> Int { Int(Date().timeIntervalSince(start) * 1000) }
        let recentFolded = fold(recent)
        let region = searchRegion(for: field)
        try? await Task.sleep(for: .milliseconds(firstLookMs))
        var lastKeys: [String] = []
        var candidates: [Suggestion] = []
        var stableScans = 0
        // The list fills in stages — conversations and groups from the local
        // database first, contacts a moment later, re-sorted as the lookup
        // finishes (Messages: "Mikey, Bhar, Zach…" before "Mikey Ku"). Accept it
        // once three scans in a row agree, and give a person time to show up
        // while the best match is still a group.
        while elapsed() < settleMaxMs, keepGoing() {
            candidates = fresh(await scan(pid: pid, region: region), baseline: baseline, typed: typed)
            let keys = candidates.map { $0.key + ($0.isSelected ? "*" : "") }
            stableScans = (!keys.isEmpty && keys == lastKeys) ? stableScans + 1 : 0
            lastKeys = keys
            let top = best(typed: typed, among: candidates, recent: recentFolded)
            trace?("\(elapsed()) ms · \(candidates.count) new · stable \(stableScans) · best \(top.map { name(of: $0.label) } ?? "none")")
            if stableScans == 2, let trace {
                for c in candidates { trace("    \(c.role) \(c.isSelected ? "*" : " ") \(c.label.prefix(80)) → \(score(typed: typed, label: c.label, isSelected: c.isSelected, recent: recentFolded).map { String(format: "%.2f", $0) } ?? "–")") }
            }
            if stableScans >= 2, let top, !isGroup(top.label) || elapsed() > groupWaitMs { break }
            // Nothing matching by name; a list that has settled is final after ~1.2 s.
            if stableScans >= 3, top == nil, elapsed() > 1200 { break }
            try? await Task.sleep(for: .milliseconds(pollMs))
        }
        if let pick = best(typed: typed, among: candidates, recent: recentFolded) {
            return await take(pick, pid: pid, region: region, executor: executor)
        }
        if let chosen = appChoice(typed: typed, among: candidates) {
            return await take(chosen, pid: pid, region: region, executor: executor)
        }
        if looksLikeAddress(typed) { return .keptAddress }
        let seen = candidates.filter { $0.role != "AXStaticText" }.map { name(of: $0.label) }
        return seen.isEmpty ? .noSuggestions : .noMatch(Array(seen.prefix(5)))
    }

    /// Last resort when no suggestion list could be seen (some apps draw it where
    /// Accessibility cannot reach): Return accepts whatever the app highlights,
    /// then the field's row is checked for the contact it became. A pill that
    /// just repeats the typed text is not a contact.
    static func acceptHighlighted(typed: String, pid: pid_t, field: CGRect, baseline: Set<String>,
                                  executor: ActionExecutor) async -> Outcome {
        let row = tokenRegion(for: field)
        let before = Set(await scan(pid: pid, region: row).map(\.key))
        await executor.pressReturn(pid: pid)
        try? await Task.sleep(for: .milliseconds(500))
        let t = fold(typed).trimmingCharacters(in: .whitespaces)
        let tokens = await scan(pid: pid, region: row).filter { !before.contains($0.key) && !baseline.contains($0.key) }
        if let chip = tokens.first(where: { fold(name(of: $0.label)).trimmingCharacters(in: .whitespaces) != t || hasHandle($0.label) }) {
            return .picked(name(of: chip.label))
        }
        return .noSuggestions
    }

    /// Picks `s`: Return when the app already highlights it (the most reliable
    /// commit), else press/click it. Confirmed when it leaves the screen.
    private static func take(_ s: Suggestion, pid: pid_t, region: CGRect, executor: ActionExecutor) async -> Outcome {
        let shown = name(of: s.label)
        func stillShown() async -> Bool { await scan(pid: pid, region: region).contains { $0.key == s.key } }
        func waitGone() async -> Bool {
            let t0 = Date()
            while Date().timeIntervalSince(t0) * 1000 < Double(confirmMs) {
                try? await Task.sleep(for: .milliseconds(pollMs))
                if await !stillShown() { return true }
            }
            return false
        }
        if s.isSelected {
            await executor.pressReturn(pid: pid)
        } else {
            await executor.clickSuggestion(s, realClick: false)
        }
        if await waitGone() { return .picked(shown) }
        // Second attempt: a real click on it. Never Return here when it is not the
        // highlighted row — Return would commit the app's choice, maybe someone else.
        await executor.clickSuggestion(s, realClick: true)
        return await waitGone() ? .picked(shown) : .unconfirmed(shown)
    }
}
