import Foundation

/// Local, deterministic detector for personal identifiers — dates of birth,
/// street addresses, city + ZIP, phone numbers, card numbers, SSNs and
/// labelled ID numbers (member / policy / account / MRN…). Three users:
///
/// - `FrameTriage`: a frame that shows identifiers being entered (a sign-up,
///   checkout, patient or identity form) is marked sensitive before it is
///   stored, whatever Jev says — and without asking Jev at all.
/// - `Digester`: OCR is redacted before it reaches the digest model, and the
///   model's JSON is scrubbed after parsing (`scrub`).
/// - `PersonalDataCleanup`: finds what older builds already stored.
///
/// Regexes are tuned for precision on screen text: phone numbers need
/// separators or a label (a 10-digit unix timestamp is not a phone), card
/// numbers pass Luhn, street names must be capitalised ("3 files in the way" is
/// not an address), and informal birthday mentions only count for redaction.
///
/// What counts is the user's choice (`Policy`, Settings → Memory → Personal
/// information): a category they allow is neither blocked, redacted nor scrubbed.
/// Passwords and one-time codes are always blocked (`FrameTriage.hardSensitiveMarkers`).
enum PersonalData {
    enum Kind: String, CaseIterable, Sendable, Comparable {
        case cardNumber = "card_number", ssn, birthDate = "birth_date", idNumber = "id_number"
        case phone, address, postalCode = "postal_code"

        /// Alone enough to keep a frame out of memory.
        var isHard: Bool { [.cardNumber, .ssn, .birthDate, .idNumber].contains(self) }

        static func < (a: Kind, b: Kind) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }

        var category: Category {
            switch self {
            case .birthDate: return .birthDates
            case .phone: return .phoneNumbers
            case .address, .postalCode: return .addresses
            case .cardNumber: return .cardNumbers
            case .ssn: return .ssns
            case .idNumber: return .idNumbers
            }
        }
    }

    // MARK: Policy

    /// What the user can allow Navi to remember (Settings → Memory).
    enum Category: String, CaseIterable, Sendable, Identifiable {
        case birthDates, phoneNumbers, addresses, cardNumbers, ssns, idNumbers, health
        var id: String { rawValue }

        var title: String {
            switch self {
            case .birthDates: return "Dates of birth"
            case .phoneNumbers: return "Phone numbers"
            case .addresses: return "Home & street addresses, ZIP codes"
            case .cardNumbers: return "Credit & debit card numbers"
            case .ssns: return "Social Security numbers"
            case .idNumbers: return "Account, member, policy & ID numbers"
            case .health: return "Health portals & medical details"
            }
        }

        var detail: String {
            switch self {
            case .birthDates: return "“Date of birth 03/14/2001” on a form or profile."
            case .phoneNumbers: return "Numbers in chats, emails, signatures and forms."
            case .addresses: return "Shipping and billing addresses, “Cambridge, MA 02139”, event venues."
            case .cardNumbers: return "Card numbers, CVV and expiry fields at checkout."
            case .ssns: return "SSNs and the forms that ask for them."
            case .idNumbers: return "Bank, routing, insurance member/policy, passport, licence, patient IDs."
            case .health: return "MyChart, Quest, Labcorp and other patient portals; results, diagnoses, prescriptions."
            }
        }

        var symbol: String {
            switch self {
            case .birthDates: return "gift"
            case .phoneNumbers: return "phone"
            case .addresses: return "house"
            case .cardNumbers: return "creditcard"
            case .ssns: return "person.text.rectangle"
            case .idNumbers: return "number"
            case .health: return "cross.case"
            }
        }

        /// Prompt / Jev wording for "never keep this".
        var instruction: String {
            switch self {
            case .birthDates: return "dates of birth or ages"
            case .phoneNumbers: return "phone numbers"
            case .addresses: return "home/street addresses, home town, city + ZIP"
            case .cardNumbers: return "card numbers, CVV and expiry"
            case .ssns: return "Social Security numbers"
            case .idNumbers: return "bank/account/routing numbers, insurance member/policy/group IDs, passport/licence/patient numbers"
            case .health: return "medical details (conditions, test results, prescriptions) and patient-portal pages"
            }
        }

        /// Allowed out of the box: contact details live in every email and event.
        static let allowedByDefault: Set<Category> = [.phoneNumbers, .addresses]
    }

    /// Which categories Navi must keep out of memory.
    struct Policy: Sendable, Equatable {
        var blocked: Set<Category>

        /// Everything blocked — tests, and the cleanup when no settings exist.
        static let strict = Policy(blocked: Set(Category.allCases))
        static let `default` = Policy(allowed: Category.allowedByDefault)

        init(blocked: Set<Category>) { self.blocked = blocked }
        init(allowed: Set<Category>) { self.blocked = Set(Category.allCases).subtracting(allowed) }
        /// From the settings' raw values (unknown names ignored).
        init(allowedRawValues: [String]) { self.init(allowed: Set(allowedRawValues.compactMap(Category.init(rawValue:)))) }

        func blocks(_ kind: Kind) -> Bool { blocked.contains(kind.category) }
        func blocks(_ category: Category) -> Bool { blocked.contains(category) }
        var allowed: Set<Category> { Set(Category.allCases).subtracting(blocked) }
    }

    struct Finding: Sendable, Equatable {
        var kind: Kind
        var range: NSRange
        var value: String
    }

    static let placeholder = "[redacted]"

    // MARK: Patterns

    private struct Pattern: @unchecked Sendable {
        let kind: Kind
        let regex: NSRegularExpression
        /// Capture group holding the value (0 = whole match). Labels stay readable.
        let group: Int
        /// Only for redacting prose (digests, notes) — too loose to judge a frame by.
        let redactOnly: Bool
        let validate: (@Sendable (String) -> Bool)?

        init(_ kind: Kind, _ pattern: String, group: Int = 0, redactOnly: Bool = false,
             validate: (@Sendable (String) -> Bool)? = nil) {
            self.kind = kind
            self.regex = try! NSRegularExpression(pattern: pattern)
            self.group = group
            self.redactOnly = redactOnly
            self.validate = validate
        }
    }

    private static let months = "(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\\.?"
    private static let dateValue = """
    (\\d{1,2}\\s*[/.\\-]\\s*\\d{1,2}\\s*[/.\\-]\\s*(?:\\d{4}|\\d{2})(?!\\d)|\\d{4}-\\d{1,2}-\\d{1,2}|\
    \(months)\\s+\\d{1,2}(?:st|nd|rd|th)?(?:,?\\s+\\d{4})?|\\d{1,2}(?:st|nd|rd|th)?\\s+(?:of\\s+)?\(months)(?:,?\\s+\\d{4})?)
    """
    private static let states = "AL|AK|AZ|AR|CA|CO|CT|DE|DC|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY|PR"
    private static let streetSuffixes: String = {
        let s = ["Street", "St", "Avenue", "Ave", "Road", "Rd", "Boulevard", "Blvd", "Lane", "Ln", "Drive", "Dr",
                 "Court", "Ct", "Way", "Place", "Pl", "Terrace", "Ter", "Circle", "Cir", "Parkway", "Pkwy",
                 "Highway", "Hwy", "Square", "Sq", "Trail", "Trl", "Road", "Row", "Alley"]
        return Array(Set(s + s.map { $0.uppercased() })).sorted { $0.count > $1.count }.joined(separator: "|")
    }()

    private static let patterns: [Pattern] = [
        // Cards: 4-4-4-x groups (or Amex 4-6-5), Luhn-valid; unseparated only for 3/4/5/6 prefixes.
        Pattern(.cardNumber, "(?<![\\d-])(?:\\d{4}([ -]?)\\d{4}\\1\\d{4}\\1\\d{1,7}|3[47]\\d{2}([ -]?)\\d{6}\\2\\d{5})(?![\\d-])",
                validate: { v in
                    let digits = v.filter(\.isNumber)
                    guard (13...19).contains(digits.count), luhn(digits), Set(digits).count > 1 else { return false }
                    // Unseparated: only 15/16-digit Amex/Visa/MC/Discover shapes — long ids (posts, orders) are not cards.
                    return v.contains(" ") || v.contains("-") || ([15, 16].contains(digits.count) && "3456".contains(digits.first!))
                }),
        // SSN: 123-45-6789 (never-issued areas excluded), or a labelled 9-digit number.
        Pattern(.ssn, "(?<![\\d-])(?!000|666|9\\d\\d)\\d{3}-(?!00)\\d{2}-(?!0000)\\d{4}(?![\\d-])"),
        Pattern(.ssn, "(?i)(?<![a-z])(?:ssn|social\\s+security(?:\\s+(?:number|no\\.?|#))?)(?![a-z])[^\\da-z\\n]{0,6}(\\d{3}[ .-]?\\d{2}[ .-]?\\d{4})(?!\\d)", group: 1),
        // Date of birth: a formal label, then a date within a line or two (OCR puts values under labels).
        Pattern(.birthDate, "(?i)(?<![a-z])(?:date\\s+of\\s+birth|birth\\s*date|dob|d\\.o\\.b\\.?)(?![a-z])[\\s\\S]{0,40}?" + dateValue, group: 1),
        Pattern(.birthDate, "(?i)(?<![a-z])(?:birthday|born(?:\\s+on)?)(?![a-z])[^\\n]{0,20}?" + dateValue, group: 1, redactOnly: true),
        // Labelled ID numbers (need ≥ 4 digits in the value).
        Pattern(.idNumber, "(?i)(?<![a-z])(?:(?:account|acct|member|policy|group|subscriber|patient|insurance|passport|licen[cs]e|routing|tax|medical\\s+record)\\s*(?:number|num|no\\.?|#|id)|mrn|iban)(?![a-z])[\\s:#.]{0,6}([a-z0-9][a-z0-9-]{4,30})",
                group: 1, validate: { $0.filter(\.isNumber).count >= 4 }),
        // Phones: US with separators, international with +, or a bare number after a phone label.
        Pattern(.phone, "(?<![\\w+])(?:\\+?1[\\s.\\-]?)?(?:\\(\\s*[2-9]\\d{2}\\s*\\)\\s?|[2-9]\\d{2}[\\s.\\-])\\d{3}[\\s.\\-]\\d{4}(?![\\w-])"),
        Pattern(.phone, "(?<![\\w+])\\+[1-9]\\d{0,2}[\\s.\\-]?(?:\\(?\\d{1,4}\\)?[\\s.\\-]?){2,5}\\d{2,4}(?![\\w])",
                validate: { (8...15).contains($0.filter(\.isNumber).count) }),
        Pattern(.phone, "(?i)(?<![a-z])(?:phone|mobile|cell|tel|telephone)(?:\\s+(?:number|no\\.?|#))?(?![a-z])[\\s:#.]{0,4}(\\d{10,11})(?!\\d)", group: 1),
        // Street addresses: number + capitalised name words + suffix (+ unit).
        Pattern(.address, "(?<![\\w-])\\d{1,6}[A-Za-z]?\\s+(?:[NSEW]\\.?\\s+)?(?:[A-Z0-9][\\w'.-]*\\s+){1,4}(?:\(streetSuffixes))\\b\\.?(?:,?\\s*(?:Apt|APT|Apartment|Unit|UNIT|Suite|Ste|STE|#)\\.?\\s*[\\w-]+)?",
                validate: plausibleStreet),
        // Where someone lives, named in prose ("home town Springfield"): the capitalised words after the label.
        Pattern(.address, "(?i)(?<![a-z])(?:home\\s*town|home\\s+address|street\\s+address|mailing\\s+address|residential\\s+address)(?![a-z])[\\s:(\\-–—]*(?:is\\s+|of\\s+)?((?-i:(?:\\d{1,6}\\s+)?[A-Z][\\w'.-]*(?:\\s+[A-Z][\\w'.-]*){0,3}))",
                group: 1, redactOnly: true),
        // Prose: "address in Winchester (01890)" — the place after "address in/at", with a bare ZIP if one follows.
        Pattern(.address, "(?i)(?<![a-z])address(?:es)?(?:\\s+is)?\\s+(?:in|at)\\s+((?-i:(?:\\d{1,6}\\s+)?[A-Z][\\w'.-]*(?:\\s+[A-Z][\\w'.-]*){0,3})(?:\\s*\\(\\s*\\d{5}(?:-\\d{4})?\\s*\\)|,?\\s+\\d{5}(?:-\\d{4})?(?!\\d))?)",
                group: 1, redactOnly: true),
        // City, ST 12345 (the city is required: "Ticket ID 48213" is not Idaho) — or a labelled ZIP / postal code.
        Pattern(.postalCode, "(?<![\\w-])[A-Z][A-Za-z.'-]+(?:\\s[A-Z][A-Za-z.'-]+){0,2},\\s*(?:\(states))\\s+\\d{5}(?:-\\d{4})?(?!\\d)"),
        Pattern(.postalCode, "(?i)(?<![a-z./_-])(?:zip(?:\\s*code)?|postal\\s*code|postcode)(?![a-z])[\\s:#.]{0,6}(\\d{5}(?:-\\d{4})?|[a-z]\\d[a-z]\\s?\\d[a-z]\\d)(?![\\w])", group: 1),
    ]

    /// "2026 Google Drive" and "Comp 2025 BAJA Drive" are folders, not streets:
    /// no storage "drives", and a Title-case suffix never follows an all-caps name.
    @Sendable static func plausibleStreet(_ v: String) -> Bool {
        let words = v.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let suffixIndex = words.lastIndex(where: { w in
            streetSuffixes.split(separator: "|").contains { w.hasPrefix($0) && w.count <= $0.count + 1 }
        }) else { return true }
        let suffix = words[suffixIndex]
        let names = words[1..<suffixIndex].filter { $0.first?.isLetter == true }
        if suffix.lowercased().hasPrefix("dr"), let before = names.last?.lowercased(),
           ["google", "my", "shared", "hard", "test", "flash", "usb", "external", "team", "disk", "cloud", "one"].contains(before) {
            return false
        }
        let suffixIsTitle = suffix != suffix.uppercased()
        if suffixIsTitle, names.contains(where: { $0.count >= 2 && $0 == $0.uppercased() }) { return false }
        return true
    }

    static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard var d = ch.wholeNumberValue else { return false }
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }

    // MARK: Detection

    /// Every identifier in `text`, in order. `includeRedactOnly` adds the looser
    /// prose patterns (birthdays, "lives in …").
    static func findings(in text: String, includeRedactOnly: Bool = false, policy: Policy = .strict) -> [Finding] {
        guard !text.isEmpty, !policy.blocked.isEmpty else { return [] }
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var out: [Finding] = []
        for p in patterns where (includeRedactOnly || !p.redactOnly) && policy.blocks(p.kind) {
            for m in p.regex.matches(in: text, range: whole) {
                let r = m.range(at: p.group)
                guard r.location != NSNotFound, r.length > 0 else { continue }
                let value = ns.substring(with: r).trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty, value != placeholder, p.validate?(value) ?? true else { continue }
                out.append(Finding(kind: p.kind, range: r, value: value))
            }
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    static func kinds(in text: String, policy: Policy = .strict) -> Set<Kind> {
        Set(findings(in: text, policy: policy).map(\.kind))
    }

    struct Redaction: Sendable, Equatable {
        var text: String
        /// The values that were replaced (for dropping entities/topics that repeat them).
        var values: [String]
        var kinds: Set<Kind>
        var changed: Bool { !values.isEmpty }
    }

    /// Replaces every blocked identifier (prose patterns included) with `[redacted]`.
    static func redact(_ text: String, policy: Policy = .strict) -> Redaction {
        let found = findings(in: text, includeRedactOnly: true, policy: policy)
        guard !found.isEmpty else { return Redaction(text: text, values: [], kinds: []) }
        // Merge overlapping spans, then replace back to front.
        var spans: [NSRange] = []
        for f in found {
            if let last = spans.last, f.range.location < NSMaxRange(last) {
                spans[spans.count - 1] = NSUnionRange(last, f.range)
            } else {
                spans.append(f.range)
            }
        }
        let out = NSMutableString(string: text)
        for s in spans.reversed() { out.replaceCharacters(in: s, with: placeholder) }
        return Redaction(text: out as String, values: found.map(\.value), kinds: Set(found.map(\.kind)))
    }

    // MARK: Forms and pages

    /// Labels of a form that collects identity details. Two or more on one
    /// screen, plus a filled-in identifier, means the user is typing theirs.
    static let personalFormMarkers: [String] = [
        "first name", "last name", "full name", "legal name", "date of birth", "birth date", "phone number",
        "mobile number", "mobile phone", "cell phone", "street address", "address line", "zip code", "postal code",
        "social security", "insurance", "member id", "policy number", "card number", "cardholder",
        "expiration date", "billing address", "shipping address", "emergency contact", "sex assigned",
        "maiden name", "create account", "create an account", "create your account", "sign up", "confirm password",
    ]

    static func formMarkers(in text: String) -> [String] {
        let t = text.lowercased()
        return personalFormMarkers.filter { t.contains($0) }
    }

    enum PageKind: String, Sendable {
        case signUp = "account_sign_up", checkout, medical, identity
    }

    private static let medicalHosts = ["myquest", "questdiagnostics", "labcorp", "mychart", "patientportal",
                                       "followmyhealth", "healow", "myhealth", "onemedical", "zocdoc", "kp.org"]
    private static let identityHosts = ["id.me", "login.gov", "ssa.gov", "irs.gov", "withpersona", "onfido", "jumio", "dmv."]

    /// What kind of page the window is, from its URL and title (nil = ordinary).
    static func pageKind(url: String?, title: String?) -> PageKind? {
        let u = (url ?? "").lowercased()
        let host = URL(string: u)?.host ?? ""
        let t = (title ?? "").lowercased()
        if medicalHosts.contains(where: { host.contains($0) })
            || ["patient portal", "mychart", "lab results", "test results", "myquest"].contains(where: { t.contains($0) }) {
            return .medical
        }
        if identityHosts.contains(where: { host.contains($0) })
            || ["verify your identity", "identity verification"].contains(where: { t.contains($0) }) {
            return .identity
        }
        if ["checkout", "/payment", "/billing", "/pay/"].contains(where: { u.contains($0) })
            || ["checkout", "payment details", "payment method"].contains(where: { t.contains($0) }) {
            return .checkout
        }
        if ["signup", "sign-up", "sign_up", "/register", "registration", "create-account", "createaccount",
            "create_account", "/onboarding", "/enroll"].contains(where: { u.contains($0) })
            || ["sign up", "create account", "create an account", "create your account", "registration"].contains(where: { t.contains($0) }) {
            return .signUp
        }
        return nil
    }

    /// Local evidence about one frame; also rendered into Jev's state. `kinds`
    /// holds only what the policy blocks — an allowed phone number is no signal.
    struct FrameSignals: Sendable, Equatable {
        var kinds: Set<Kind>
        var formMarkers: [String]
        var page: PageKind?
        var policy: Policy = .strict

        /// Never store: a blocked hard identifier (DOB, card, SSN, ID number), a
        /// patient portal (unless health is allowed), or a blocked soft one (phone,
        /// address, ZIP) typed into a personal form or on a sign-up / checkout / identity page.
        var isSensitive: Bool {
            if kinds.contains(where: \.isHard) || (page == .medical && policy.blocks(.health)) { return true }
            let soft = kinds.contains(.phone) || kinds.contains(.address) || kinds.contains(.postalCode)
            return soft && (formMarkers.count >= 2 || page != nil)
        }

        /// One labelled line for Jev (`[FORM_SIGNALS]`). Kinds only, never values.
        var stateLine: String {
            var parts: [String] = []
            if let page, page != .medical || policy.blocks(.health) { parts.append("page: \(page.rawValue)") }
            if !formMarkers.isEmpty { parts.append("personal_fields: " + formMarkers.prefix(8).joined(separator: ", ")) }
            if !kinds.isEmpty { parts.append("identifier_values: " + kinds.sorted().map(\.rawValue).joined(separator: ", ")) }
            return parts.isEmpty ? "none" : parts.joined(separator: " · ")
        }
    }

    static func signals(text: String, title: String?, url: String?, policy: Policy = .strict) -> FrameSignals {
        let joined = [title ?? "", text].joined(separator: "\n")
        return FrameSignals(kinds: kinds(in: joined, policy: policy), formMarkers: formMarkers(in: joined),
                            page: pageKind(url: url, title: title), policy: policy)
    }

    // MARK: Digest scrub

    /// Key facts about these are dropped whole (when blocked): a redacted fact says nothing.
    static let personalFactMarkers: [Category: [String]] = [
        .birthDates: ["date of birth", "birthday", "birth date"],
        .phoneNumbers: ["phone number", "mobile number"],
        .addresses: ["home address", "street address", "hometown", "home town", "zip code", "postal code"],
        .cardNumbers: ["card number"],
        .ssns: ["social security", "ssn"],
        .idNumbers: ["insurance id", "member id", "policy number", "account number", "routing number"],
        .health: ["diagnosed with", "prescription", "lab result", "medical record"],
    ]

    static func mentionsPersonalFact(_ text: String, policy: Policy = .strict) -> Bool {
        let lower = text.lowercased()
        return personalFactMarkers.contains { cat, markers in policy.blocks(cat) && markers.contains { lower.contains($0) } }
    }

    /// Redacts identifiers from a parsed digest: title and summary are
    /// redacted in place; key facts, entities, topics and links that carry an
    /// identifier (or repeat a redacted value, e.g. a hometown entity) are dropped.
    /// Returns the clean digest and how many things were removed.
    static func scrub(_ d: DigestResult, policy: Policy = .strict) -> (DigestResult, removed: Int) {
        var removed = 0
        var values: [String] = []
        var out = d
        for keyPath in [\DigestResult.title, \DigestResult.summary] {
            let r = redact(d[keyPath: keyPath], policy: policy)
            if r.changed { out[keyPath: keyPath] = r.text; removed += r.values.count; values += r.values }
        }
        out.keyFacts = d.keyFacts.filter { fact in
            let r = redact(fact, policy: policy)
            values += r.values
            let keep = !r.changed && !mentionsPersonalFact(fact, policy: policy)
            if !keep { removed += 1 }
            return keep
        }
        func repeatsValue(_ name: String) -> Bool {
            let n = name.lowercased()
            guard n.count >= 3 else { return false }
            return values.contains { v in let v = v.lowercased(); return v.contains(n) || n.contains(v) }
        }
        out.entities = d.entities.filter { e in
            let keep = redact(e.name, policy: policy).values.isEmpty && !repeatsValue(e.name)
            if !keep { removed += 1 }
            return keep
        }
        out.topics = d.topics.filter { t in
            let keep = redact(t, policy: policy).values.isEmpty && !repeatsValue(t)
            if !keep { removed += 1 }
            return keep
        }
        out.links = d.links.filter { l in
            let keep = findings(in: l.removingPercentEncoding ?? l, policy: policy).isEmpty
            if !keep { removed += 1 }
            return keep
        }
        return (out, removed)
    }
}
