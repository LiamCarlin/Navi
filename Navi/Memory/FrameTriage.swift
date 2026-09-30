import Foundation

/// Per-frame triage: what is the user doing, is it sensitive, is it a new
/// context, how important is it. Jev answers all four in one ~200 ms call from
/// the local OCR text; when Jev is not configured cheap heuristics stand in.
struct TriageResult: Sendable, Equatable {
    var activity: String
    var isSensitive: Bool
    var isNewContext: Bool
    /// 0 idle/trivial · 1 routine · 2 substantive · 3 key moment
    var importance: Double
    var source: Source
    enum Source: String, Sendable { case jev, heuristic }
}

struct FrameTriage: Sendable {
    /// Compact description of the frame we're triaging.
    struct Input: Sendable {
        var bundleID: String
        var appName: String
        var windowTitle: String?
        var url: String?
        var timestamp: Date
        var ocrText: String
        /// app / title of the previous stored frame (nil on the first frame).
        var previousApp: String?
        var previousTitle: String?
    }

    static let activities: [String: String] = [
        "coding": "Writing or reading source code in an editor or IDE.",
        "browsing": "Browsing the web: news, docs, search results, social feeds.",
        "writing": "Composing prose: a document, notes, blog post, essay.",
        "chat": "Instant messaging or team chat (Slack, iMessage, Discord, WhatsApp).",
        "email": "Reading or writing email.",
        "meeting": "A video call or meeting (Zoom, Meet, Teams, FaceTime).",
        "media": "Watching video, listening to music, viewing photos.",
        "design": "Design or creative tools (Figma, Sketch, Photoshop, CAD).",
        "terminal": "A terminal / shell / command-line session.",
        "reading": "Reading a long article, PDF, book or documentation page.",
        "shopping": "Browsing products, carts, or checkout pages.",
        "other": "Anything else (desktop, settings, file browser, loading screen).",
    ]

    static let importanceLevels = [
        "Idle or trivial (desktop, loading screen, empty window)",
        "Routine activity",
        "Substantive work or reading",
        "Key moment: decision, message sent, document created",
    ]

    static let questions: [String: JevClient.Question] = [
        "activity": .choice(instructions: "What kind of activity is shown on this screen?", criteria: activities),
        "is_sensitive": .noulJSON(instructions: JevClient.JSONValue(any: sensitiveInstructions)),
        "is_new_context": .noul(instructions: "The user has switched to a different task/topic than the previous frame."),
        "importance": .score(instructions: "How important is this moment for later recall?", criteria: importanceLevels),
    ]

    /// Jev's `is_sensitive` probability at or above which a frame is stored as a
    /// stub. Below a coin flip on purpose: a missed sign-up form costs far more
    /// than a routine frame left out of memory.
    static let sensitiveThreshold = 0.4

    /// Structured instructions for `is_sensitive` (docs.typesafe.ai/primitives/advanced).
    static let sensitiveInstructions: [String: Any] = [
        "question": "Would storing this screen keep private data the user would not want recorded?",
        "sensitive_when": [
            "a password, passcode or PIN field, or 2FA / verification / one-time codes",
            "personal identifiers entered into or shown in a form: date of birth, home or street address, city + ZIP, phone number, SSN or other government ID, driver's licence or passport number",
            "account sign-up / registration, checkout or payment forms that collect name, address, phone or card details",
            "card, bank, routing or account numbers; balances and statements",
            "patient portals and medical records: lab or test results, diagnoses, prescriptions, insurance member / policy / group IDs",
            "identity verification (ID.me, login.gov, IRS, SSA, DMV, KYC selfie or ID upload)",
        ],
        "not_sensitive_when": [
            "an article, documentation, code or search results that only mention these topics",
            "a sign-in page showing just the email / username field",
            "a business's public address or phone number on a map, store or contact page",
        ],
        "signals": "FORM_SIGNALS is computed locally from the screen: page kind, personal-field labels present and kinds of identifier values found (values never shown). identifier_values on a sign-up, checkout, medical or identity page means sensitive.",
    ]

    /// Structured state block for Jev (labelled sections, not prose).
    static func state(for i: Input, ocrLimit: Int = 3000) -> String {
        state(for: i, signals: PersonalData.signals(text: i.ocrText, title: i.windowTitle, url: i.url), ocrLimit: ocrLimit)
    }

    static func state(for i: Input, signals: PersonalData.FrameSignals, ocrLimit: Int = 3000) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let prev = i.previousApp.map { "\($0)\(i.previousTitle.map { " — \($0)" } ?? "")" } ?? "(none)"
        return """
        [APP] \(i.appName) (\(i.bundleID))
        [TITLE] \(i.windowTitle ?? "")
        [URL] \(i.url ?? "")
        [TIME] \(f.string(from: i.timestamp))
        [PREVIOUS_CONTEXT] \(prev)
        [FORM_SIGNALS] \(signals.stateLine)
        [SCREEN_TEXT]
        \(String(i.ocrText.prefix(ocrLimit)))
        """
    }

    // MARK: Heuristics

    /// High-precision markers that should never be stored, Jev or not.
    static let hardSensitiveMarkers: [String] = [
        "cvv", "cvc", "card number", "security code", "social security", "ssn", "iban", "routing number",
        "one-time code", "one time code", "verification code", "2fa code", "authentication code",
        "account balance", "passcode",
    ]

    /// Broader markers used only when Jev is unavailable.
    static let softSensitiveMarkers: [String] = [
        "password", "credit card", "debit card", "bank account", "sort code", "expiry", "expiration date",
        "medical record", "diagnosis", "prescription", "tax return", "1password", "keychain", "recovery phrase",
        "seed phrase", "private key",
    ]

    static func containsHardSensitive(_ text: String) -> Bool {
        let t = text.lowercased()
        return hardSensitiveMarkers.contains { containsMarker(t, $0) }
    }

    /// Short markers ("ssn", "cvv", "iban") must be whole words: `className`
    /// contains "ssn" and used to drop every screen of code that said it.
    static func containsMarker(_ lowered: String, _ marker: String) -> Bool {
        guard marker.count <= 4 else { return lowered.contains(marker) }
        var search = lowered.startIndex..<lowered.endIndex
        while let r = lowered.range(of: marker, range: search) {
            let before = r.lowerBound == lowered.startIndex ? nil : lowered[lowered.index(before: r.lowerBound)]
            let after = r.upperBound == lowered.endIndex ? nil : lowered[r.upperBound]
            if !(before?.isLetter ?? false) && !(after?.isLetter ?? false) { return true }
            search = r.upperBound..<lowered.endIndex
        }
        return false
    }

    static func containsSoftSensitive(_ text: String) -> Bool {
        let t = text.lowercased()
        return softSensitiveMarkers.contains { t.contains($0) } || containsHardSensitive(t)
    }

    /// Bundle-ID / title based activity guess.
    static func guessActivity(bundleID: String, title: String?, url: String?) -> String {
        let b = bundleID.lowercased()
        let t = (title ?? "").lowercased()
        if b.contains("xcode") || b.contains("vscode") || b.contains("visualstudio") || b.contains("jetbrains") || b.contains("cursor") || b.contains("zed") || b.contains("sublimetext") || b.contains("nova") { return "coding" }
        if b.contains("terminal") || b.contains("iterm") || b.contains("warp") || b.contains("ghostty") || b.contains("alacritty") || b.contains("kitty") { return "terminal" }
        if b.contains("slack") || b.contains("discord") || b.contains("messages") || b.contains("whatsapp") || b.contains("telegram") || b.contains("signal") { return "chat" }
        if b.contains("mail") || b.contains("outlook") || b.contains("spark") || b.contains("superhuman") || t.contains("gmail") { return "email" }
        if b.contains("zoom") || b.contains("teams") || b.contains("facetime") || t.contains("meet.google") || (url ?? "").contains("meet.google") { return "meeting" }
        if b.contains("figma") || b.contains("sketch") || b.contains("photoshop") || b.contains("affinity") || b.contains("onshape") || b.contains("blender") { return "design" }
        if b.contains("music") || b.contains("spotify") || b.contains("tv") || b.contains("vlc") || b.contains("photos") || (url ?? "").contains("youtube.com/watch") { return "media" }
        if b.contains("preview") || b.contains("books") || b.contains("kindle") || (url ?? "").hasSuffix(".pdf") { return "reading" }
        if b.contains("pages") || b.contains("word") || b.contains("notion") || b.contains("obsidian") || b.contains("bear") || b.contains("craft") || b.contains("ulysses") || b.contains("textedit") { return "writing" }
        if let u = url?.lowercased(), u.contains("amazon.") || u.contains("/cart") || u.contains("checkout") || u.contains("ebay.") { return "shopping" }
        if b.contains("safari") || b.contains("chrome") || b.contains("firefox") || b.contains("brave") || b.contains("edge") || b.contains("arc") || b.contains("vivaldi") { return "browsing" }
        if b == "com.apple.finder" || b.contains("systempreferences") || b.contains("systemsettings") { return "other" }
        return "other"
    }

    /// Deterministic guard, Jev or not: hard markers ("cvv", "one-time code"…)
    /// or personal identifiers in a form (`PersonalData.FrameSignals.isSensitive`).
    static func locallySensitive(_ i: Input, signals: PersonalData.FrameSignals) -> Bool {
        signals.isSensitive || containsHardSensitive(i.ocrText) || containsHardSensitive(i.windowTitle ?? "")
    }

    static func heuristic(_ i: Input) -> TriageResult {
        heuristic(i, signals: PersonalData.signals(text: i.ocrText, title: i.windowTitle, url: i.url))
    }

    static func heuristic(_ i: Input, signals: PersonalData.FrameSignals) -> TriageResult {
        let appChanged = i.previousApp != nil && i.previousApp != i.bundleID
        let isBrowser = FrameCapture.browserBundleIDs.contains(i.bundleID)
        let titleChanged = i.previousTitle != nil && i.previousTitle != i.windowTitle
        let newContext = i.previousApp == nil ? false : (appChanged || (titleChanged && !isBrowser))
        let trivial = i.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).count < 40
        return TriageResult(activity: guessActivity(bundleID: i.bundleID, title: i.windowTitle, url: i.url),
                            isSensitive: locallySensitive(i, signals: signals)
                                || containsSoftSensitive(i.ocrText) || containsSoftSensitive(i.windowTitle ?? ""),
                            isNewContext: newContext,
                            importance: trivial ? 0 : 1,
                            source: .heuristic)
    }

    // MARK: Jev

    /// One Jev call per frame; falls back to heuristics on any error. A frame
    /// the local guard already calls sensitive never leaves the Mac.
    static func triage(_ i: Input, jev: JevClient) async -> TriageResult {
        let signals = PersonalData.signals(text: i.ocrText, title: i.windowTitle, url: i.url)
        let fallback = heuristic(i, signals: signals)
        if locallySensitive(i, signals: signals) {
            Log.memory.info("Personal data on screen (\(signals.stateLine, privacy: .public)); frame kept local")
            return fallback
        }
        guard jev.isConfigured else { return fallback }
        do {
            let r = try await jev.ask(state: state(for: i, signals: signals), questions: questions, cacheable: false)
            let activity = r["activity"]?.choice ?? fallback.activity
            let sensitive = (r["is_sensitive"]?.noul ?? 0) >= sensitiveThreshold
            let newCtx = (r["is_new_context"]?.noul ?? 0) > 0.5
            let importance = r["importance"]?.score ?? 1
            return TriageResult(activity: activities[activity] == nil ? "other" : activity,
                                isSensitive: sensitive || containsHardSensitive(i.ocrText),
                                isNewContext: i.previousApp == nil ? false : newCtx,
                                importance: max(0, min(3, importance)),
                                source: .jev)
        } catch {
            Log.memory.warning("Jev triage failed, using heuristics: \(error.localizedDescription)")
            return fallback
        }
    }
}
