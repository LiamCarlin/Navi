import Foundation

/// Everything the ⌘Space panel says is Navi. The engines behind it (the
/// routing model, the language model, transports, latencies, probabilities)
/// are diagnostics: shown only when `DeveloperMode.showsEngineDetails`.
///
/// Pure functions, unit-tested in `NaviTests/BrandingTests.swift`.
enum PanelWording {

    /// Words that name a vendor, model or transport rather than Navi.
    static let vendorTokens: [String] = [
        "jev", "claude", "anthropic", "typesafe", "gemini", "haiku", "sonnet", "opus",
        "vercel", "ai gateway", "openai", "gpt",
    ]

    private static let latency = try! NSRegularExpression(pattern: #"\b\d+(\.\d+)?\s?ms\b"#)
    private static let percent = try! NSRegularExpression(pattern: #"\b\d{1,3}\s?%"#)
    private static let vendorWord = try! NSRegularExpression(
        pattern: #"\b(jev|claude|anthropic|typesafe|gemini|haiku|sonnet|opus|vercel)\b"#, options: [.caseInsensitive])

    /// Whole phrases other modules emit (router rows, agent status) and what
    /// the user should read instead. Checked before the word-level rewrite.
    static let phraseRewrites: [(String, String)] = [
        ("Answer with Claude", "Answer this question"),
        ("Add an Anthropic key in Navi → AI Providers", "Finish setting up Navi first"),
    ]

    /// A result row's subtitle as the user should see it: other modules'
    /// rows may still name an engine; developers see them as emitted.
    static func resultSubtitle(_ subtitle: String?, developer: Bool) -> String? {
        guard let subtitle, !subtitle.isEmpty else { return nil }
        guard !developer, mentionsVendor(subtitle) else { return subtitle }
        return userFacing(subtitle)
    }

    /// True when `text` names a vendor, model or transport.
    static func mentionsVendor(_ text: String) -> Bool {
        let lower = text.lowercased()
        return vendorTokens.contains { lower.contains($0) }
    }

    /// True for lines meant for an engineer: vendor names, latencies,
    /// probabilities, element counts. Hidden from the panel unless developer
    /// mode is on.
    static func isDiagnostic(_ text: String) -> Bool {
        if mentionsVendor(text) { return true }
        let range = NSRange(text.startIndex..., in: text)
        if latency.firstMatch(in: text, range: range) != nil { return true }
        if percent.firstMatch(in: text, range: range) != nil { return true }
        let lower = text.lowercased()
        return lower.contains("candidates on screen") || lower.contains("text helper")
            || lower.contains("vision fallback") || lower.contains("elements ·")
    }

    /// Rewrites a line so it reads as Navi: the gate's "Jev flags this as
    /// irreversible (94%): …" becomes "This may be hard to undo: …", vendor
    /// names become "Navi", latencies and probabilities are dropped.
    static func userFacing(_ text: String) -> String {
        var s = text
        for (engine, navi) in phraseRewrites { s = s.replacingOccurrences(of: engine, with: navi) }
        s = s.replacingOccurrences(
            of: #"^\s*Jev flags this as irreversible\s*\(\d{1,3}\s?%\):\s*"#,
            with: "This may be hard to undo: ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"\s*[·(]\s*\d+(\.\d+)?\s?ms\)?"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*\(\d{1,3}\s?%\)"#, with: "", options: .regularExpression)
        let ns = NSMutableString(string: s)
        vendorWord.replaceMatches(in: ns, range: NSRange(location: 0, length: ns.length), withTemplate: "Navi")
        s = ns as String
        s = s.replacingOccurrences(of: "Navi-first", with: "Navi")
        s = s.replacingOccurrences(of: "Navi-only", with: "Navi")
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Run timeline

    /// A step as the user reads it: what Navi did, in plain words — "Clicked
    /// Quick Add — 10 Wings", "Scrolled" — or what it is doing while `live`.
    /// Element ids, coordinates, the driver's notes ("(no change)"), who drove
    /// the step and probabilities are dropped.
    static func stepText(_ step: String, live: Bool) -> String {
        var s = userFacing(step)
        // Who took the step ("Claude: click ‘Continue’" → after the vendor rewrite, "Navi: …").
        s = s.replacingOccurrences(of: #"^\s*Navi\s*[:·]\s*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+at \(\s*-?\d+(\.\d+)?\s*,\s*-?\d+(\.\d+)?\s*\)"#, with: "", options: .regularExpression)
        // Trailing driver notes, possibly nested: "(could not be clicked (covered or off-screen); no longer offered)".
        while let r = s.range(of: #"\s*\((?:[^()]|\([^()]*\))*\)\s*$"#, options: .regularExpression) {
            s.removeSubrange(r)
        }
        s = s.replacingOccurrences(of: #"\s*\[\d+\]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^(Scroll(?: up| down| left| right)?) \d+$"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^Wait [\d.]+\s?s$"#, with: "Wait for the page", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^Open URL (?:https?://)?(?:www\.)?([^/\s]+)\S*"#, with: "Open $1", options: .regularExpression)
        let lookOnly = ["Take screenshot", "Zoom into region", "Read cursor position", "Mouse down", "Mouse up"]
        if lookOnly.contains(s) || s.hasPrefix("Move mouse") { s = "Look at the screen" }
        if s.hasPrefix("Tool: ") || s.hasPrefix("Computer action: ") || s == "Run AppleScript" { s = "Work in the app" }
        s = s.trimmingCharacters(in: .whitespaces)
        guard let first = s.first else { return live ? "Working…" : "Done a step" }
        s = String(first).uppercased() + s.dropFirst()
        return tensed(s, live: live)
    }

    /// The imperative verbs the drivers start steps with, as -ing / past forms.
    private static let verbForms: [(String, String, String)] = [
        ("Double-click", "Double-clicking", "Double-clicked"), ("Right-click", "Right-clicking", "Right-clicked"),
        ("Triple-click", "Triple-clicking", "Triple-clicked"), ("Middle-click", "Middle-clicking", "Middle-clicked"),
        ("Click", "Clicking", "Clicked"), ("Type", "Typing", "Typed"), ("Select", "Selecting", "Selected"),
        ("Scroll", "Scrolling", "Scrolled"), ("Press", "Pressing", "Pressed"), ("Open", "Opening", "Opened"),
        ("Wait", "Waiting", "Waited"), ("Drag", "Dragging", "Dragged"), ("Copy", "Copying", "Copied"),
        ("Look", "Looking", "Looked"), ("Work", "Working", "Worked"), ("Hold", "Holding", "Held"),
        ("Search", "Searching", "Searched"), ("Fill", "Filling", "Filled"), ("Go", "Going", "Went"),
        ("Add", "Adding", "Added"), ("Check", "Checking", "Checked"), ("Read", "Reading", "Read"),
    ]

    private static func tensed(_ s: String, live: Bool) -> String {
        for (verb, ing, past) in verbForms {
            guard s.hasPrefix(verb) else { continue }
            let rest = s.dropFirst(verb.count)
            guard rest.isEmpty || rest.first == " " else { continue }
            return (live ? ing : past) + rest
        }
        return s
    }

    /// How a run that did not finish reads: calm, plain, never the engine's
    /// reasoning ("the classifier was not confident…"), transports ("HTTP 400")
    /// or internals ("Element 12 is no longer on screen"). Real reasons the user
    /// can act on (a permission, a sign-in, a missing contact) pass through.
    static func outcomeText(_ message: String) -> String {
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = m.lowercased()
        if m.isEmpty { return couldNotFinish }
        if let r = m.range(of: #"^Step (\d+) of (\d+) failed:\s*"#, options: .regularExpression) {
            let head = m[r].replacingOccurrences(of: "failed:", with: "didn’t work:")
            return head + outcomeText(String(m[r.upperBound...]))
        }
        if let r = m.range(of: #"^You declined (‘[^’]*’)"#, options: .regularExpression), lower.contains("again") {
            return "\(m[r]), so Navi stopped."
        }
        if lower.contains("step limit") || lower.contains("every step it was allowed") {
            return "This took more steps than Navi allows. Try asking for one part at a time."
        }
        if lower.contains("found nothing on this screen") {
            return "Navi couldn’t find a way to do this from here."
        }
        if lower.contains("cannot be read") || lower.contains("nothing readable") {
            return "Navi couldn’t read part of this screen, so it stopped."
        }
        if lower.contains("already achieved") {
            return "It looks like this is already done."
        }
        if lower.contains("not confident") || lower.contains("is stuck") || lower.contains("changed nothing") {
            return "Navi couldn’t make progress here, so it stopped."
        }
        if internals.contains(where: { lower.contains($0) })
            || m.range(of: #"\bHTTP \d{3}\b|\b(element|control) \d+\b|\(\d+\)\.|\b[a-z]+_[a-z_]+\b"#,
                       options: [.regularExpression, .caseInsensitive]) != nil {
            return couldNotFinish
        }
        return userFacing(m)
    }

    static let couldNotFinish = "Navi couldn’t finish this one. Try again in a moment."

    /// Words that only show up when an internal error leaked into a message.
    private static let internals: [String] = [
        "no action executed", "connection failed", "runner", "traceback", "errno", "exception", "invalid typesafe",
        "invalid response", "could not take over", "output tokens", "decision service", "unavailable (", "decoding error",
        "vision fallback", "unsupported", "malformed", "unknown key", "unknown modifier", "unknown tool",
        "missing coordinate", "needs text", "encode screenshot", "applescript", "status code", "classifier",
        "the writer", "takeover", "take over", "hand off", "handing", "the agent",
    ]

    /// The finished line: the summary without the run's step count and time.
    static func doneText(_ summary: String) -> String {
        let s = summary.replacingOccurrences(of: #"\s*\(\d+ steps? · [\d.]+\s?s\)\s*$"#, with: "", options: .regularExpression)
        return userFacing(s)
    }

    /// Footer text after a query has been routed. Empty for users (the footer
    /// then says "Navi"); the full decision for developers.
    static func routingStatus(_ d: RouteDecision, developer: Bool) -> String {
        guard developer else { return "" }
        let pct = Int(((d.probabilities[d.intent] ?? d.confidence) * 100).rounded())
        switch d.source {
        case .jev: return "Jev · \(d.intent.displayName) \(pct)% · \(d.latencyMs) ms"
        case .cache: return "Jev (cached) · \(d.intent.displayName) \(pct)%"
        case .heuristic: return "local · \(d.intent.displayName)"
        }
    }

    /// What the pill at the right of the search bar says. Users only ever see
    /// the safety affordance ("Asks first" when the request looks irreversible);
    /// developers see the decided intent and its probability.
    static func pillText(_ d: RouteDecision, developer: Bool) -> String? {
        if developer {
            if d.source == .heuristic { return "local" }
            let pct = Int(((d.probabilities[d.intent] ?? d.confidence) * 100).rounded())
            return "\(d.intent.displayName) · \(pct)%"
        }
        return d.isRisky ? "Asks first" : nil
    }
}
