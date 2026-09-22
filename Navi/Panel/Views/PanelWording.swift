import Foundation

/// Everything the ⌘Space panel says is Navi. The engines behind it (the
/// routing model, the language model, transports, latencies, probabilities)
/// are diagnostics: shown only when `DeveloperMode.isEnabled`.
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
