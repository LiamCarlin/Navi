import Testing
import Foundation
@testable import Navi

// All identifiers below are made up (555-01xx phones, Luhn test cards, never-issued SSN ranges).

private let signUpForm = """
Create your account
First name  Jordan
Last name  Example
Date of birth
MM/DD/YYYY
03/14/2001
Mobile phone
(617) 555-0142
ZIP code
02139
Continue
"""

// MARK: - Detection

struct PersonalDataDetectionTests {
    private func kinds(_ s: String) -> Set<PersonalData.Kind> { PersonalData.kinds(in: s) }

    @Test func birthDates() {
        #expect(kinds("Date of birth: 03/14/2001") == [.birthDate])
        #expect(kinds("DOB 2001-03-14") == [.birthDate])
        #expect(kinds("Date of Birth\nMM / DD / YYYY\n03 / 14 / 2001") == [.birthDate])
        #expect(kinds("Birth date March 14, 2001") == [.birthDate])
        // A label without a value (an empty form, an article) is not a birth date.
        #expect(kinds("Date of birth\nMM/DD/YYYY") == [])
        #expect(kinds("Why sites ask for your date of birth") == [])
        // "birthday" / "born" only count when redacting prose, not to judge a frame.
        #expect(kinds("Mom's birthday May 3") == [])
        #expect(PersonalData.redact("Mom's birthday May 3").text == "Mom's birthday [redacted]")
    }

    @Test func phones() {
        #expect(kinds("Call (617) 555-0142") == [.phone])
        #expect(kinds("617-555-0142") == [.phone])
        #expect(kinds("+1 617.555.0142") == [.phone])
        #expect(kinds("+44 20 7946 0958") == [.phone])
        #expect(kinds("Mobile number: 6175550142") == [.phone])
        // Unix timestamps, versions and bare ids are not phones.
        #expect(kinds("created_at 1727600000") == [])
        #expect(kinds("id 6175550142") == [])
        #expect(kinds("Xcode 26.6 build 17A5241") == [])
    }

    @Test func cardsAndSSNs() {
        #expect(kinds("Card 4111 1111 1111 1111 exp 12/29") == [.cardNumber])
        #expect(kinds("4242-4242-4242-4242") == [.cardNumber])
        #expect(kinds("378282246310005") == [.cardNumber])                  // Amex test number
        #expect(kinds("4111 1111 1111 1112") == [])                          // fails Luhn
        #expect(kinds("ts=1727600000123") == [])                              // ms timestamp
        #expect(kinds("instagram.com/p/3456789012345678901") == [])           // 19-digit post id, Luhn-valid
        #expect(kinds("4111111111111111") == [.cardNumber])
        #expect(kinds("SSN 123-45-6789") == [.ssn])
        #expect(kinds("Social security number: 123456789") == [.ssn])
        #expect(kinds("released 2026-09-29") == [])
        #expect(kinds("666-12-3456") == [])                                   // never issued
    }

    @Test func addressesAndPostalCodes() {
        #expect(kinds("123 Main Street, Apt 4") == [.address])
        #expect(kinds("77 MASSACHUSETTS AVE") == [.address])
        #expect(kinds("Cambridge, MA 02139") == [.postalCode])
        #expect(kinds("ZIP code: 02139") == [.postalCode])
        #expect(kinds("Postal code K1A 0B1") == [.postalCode])
        #expect(kinds("3 files in the way of the build") == [])
        #expect(kinds("Chassis 2026 Google Drive") == [])
        #expect(kinds("Comp 2025 BAJA Drive") == [])
        #expect(kinds("1000 OLIN WAY") == [.address])
        #expect(kinds("500 Test Drive Lane") == [.address])
        #expect(kinds("Ticket ID 48213") == [])
        #expect(kinds("zip -r archive.zip 12345 files") == [])
        // "home town" is prose-only (redaction), with a capitalised value.
        #expect(PersonalData.redact("home town Springfield").text == "home town [redacted]")
        #expect(!PersonalData.redact("entered their home town and ZIP").changed)
        // Digest prose seen in the wild.
        #expect(PersonalData.redact("personal details including address in Winchester (01890), mobile number").text
                == "personal details including address in [redacted], mobile number")
        #expect(PersonalData.redact("shipping address at 12 Farnsworth Street").text == "shipping address at [redacted]")
        #expect(!PersonalData.redact("the logic lives in Digester and the email address in the header").changed)
        #expect(!PersonalData.redact("Build (12345) passed").changed)
    }

    @Test func labelledIDNumbers() {
        #expect(kinds("Member ID: XJH123456789") == [.idNumber])
        #expect(kinds("Policy number 00012345") == [.idNumber])
        #expect(kinds("MRN 4829103") == [.idNumber])
        #expect(kinds("groupId: com.example.app") == [])
        #expect(kinds("account settings") == [])
    }

    @Test func redactKeepsLabelsAndIsIdempotent() {
        let r = PersonalData.redact("DOB 03/14/2001, phone (617) 555-0142, card 4111 1111 1111 1111.")
        #expect(r.text == "DOB [redacted], phone [redacted], card [redacted].")
        #expect(r.kinds == [.birthDate, .phone, .cardNumber])
        #expect(r.values.count == 3)
        #expect(!PersonalData.redact(r.text).changed)
        #expect(!PersonalData.redact("Refactored MemoryStore.swift and ran 42 tests").changed)
    }

    @Test func luhn() {
        #expect(PersonalData.luhn("4111111111111111"))
        #expect(!PersonalData.luhn("4111111111111112"))
    }
}

// MARK: - Frame guard

struct PersonalDataFrameGuardTests {
    @Test func signUpFormIsSensitive() {
        let s = PersonalData.signals(text: signUpForm, title: "Create account", url: "https://example.com/signup")
        #expect(s.page == .signUp)
        #expect(s.kinds == [.birthDate, .phone, .postalCode])
        #expect(s.formMarkers.contains("date of birth"))
        #expect(s.isSensitive)
        // The state line names kinds, never values.
        #expect(s.stateLine.contains("page: account_sign_up"))
        #expect(s.stateLine.contains("identifier_values: birth_date, phone, postal_code"))
        #expect(!s.stateLine.contains("0142"))
    }

    @Test func softIdentifiersNeedAForm() {
        // A phone number in an email signature or a business address on a map: stored.
        let email = PersonalData.signals(text: "Thanks!\nSam\n(617) 555-0142", title: "Re: lunch", url: nil)
        #expect(!email.isSensitive)
        let maps = PersonalData.signals(text: "Flour Bakery\n12 Farnsworth Street\nOpen until 6 PM", title: "Maps", url: nil)
        #expect(!maps.isSensitive)
        // …but typed into a checkout or a personal-details form: not stored.
        let checkout = PersonalData.signals(text: "Shipping\n12 Farnsworth Street", title: "Checkout", url: "https://shop.example/checkout")
        #expect(checkout.isSensitive)
        let form = PersonalData.signals(text: "First name\nLast name\nPhone number\n(617) 555-0142", title: "Profile", url: nil)
        #expect(form.isSensitive)
    }

    @Test func patientPortalsAreAlwaysSensitive() {
        #expect(PersonalData.pageKind(url: "https://my.questdiagnostics.com/web/home", title: nil) == .medical)
        #expect(PersonalData.pageKind(url: "https://mychart.example.org/", title: nil) == .medical)
        #expect(PersonalData.signals(text: "Welcome back", title: "MyQuest", url: nil).isSensitive)
        #expect(PersonalData.pageKind(url: "https://github.com/LiamCarlin/Navi", title: "Navi") == nil)
        #expect(PersonalData.pageKind(url: "https://id.me/verify", title: nil) == .identity)
    }

    @Test func triageUsesTheGuard() {
        let i = FrameTriage.Input(bundleID: "com.google.Chrome", appName: "Chrome", windowTitle: "Create account",
                                  url: "https://example.com/signup", timestamp: Date(), ocrText: signUpForm,
                                  previousApp: nil, previousTitle: nil)
        #expect(FrameTriage.heuristic(i).isSensitive)
        let s = FrameTriage.state(for: i)
        #expect(s.contains("[FORM_SIGNALS] page: account_sign_up · personal_fields: "))
        #expect(s.contains("identifier_values: birth_date, phone, postal_code"))

        var code = i
        code.ocrText = String(repeating: "let className = view.className\n", count: 5)
        code.windowTitle = "View.swift"; code.url = nil
        #expect(!FrameTriage.heuristic(code).isSensitive)
        #expect(FrameTriage.state(for: code).contains("[FORM_SIGNALS] none"))
    }

    @Test func shortHardMarkersAreWholeWords() {
        #expect(!FrameTriage.containsHardSensitive("let className = \"x\""))
        #expect(!FrameTriage.containsHardSensitive("classname cvvx"))
        #expect(FrameTriage.containsHardSensitive("Enter your SSN"))
        #expect(FrameTriage.containsHardSensitive("CVV: 123"))
        #expect(FrameTriage.containsHardSensitive("Your verification code is 482911"))
    }

    @Test func sensitiveQuestionIsStructured() throws {
        let data = try JSONEncoder().encode(FrameTriage.questions["is_sensitive"]!)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["type"] as? String == "noul")
        let instr = try #require(obj["instructions"] as? [String: Any])
        let when = try #require(instr["sensitive_when"] as? [String])
        #expect(when.contains { $0.contains("date of birth") && $0.contains("phone number") })
        #expect(when.contains { $0.contains("sign-up") && $0.contains("checkout") })
        #expect(when.contains { $0.contains("insurance") })
        #expect((instr["not_sensitive_when"] as? [String])?.isEmpty == false)
        #expect(FrameTriage.sensitiveThreshold < 0.5)
    }
}

// MARK: - Digest

struct PersonalDataDigestTests {
    @Test func scrubRemovesIdentifiersAndWhatRepeatsThem() {
        let d = DigestResult(
            title: "Quest Diagnostics account creation",
            summary: "Created a MyQuest account. Entered date of birth 03/14/2001, home town Springfield, Cambridge, MA 02139 and phone (617) 555-0142.",
            topics: ["account creation", "springfield"],
            entities: [EntityRef(name: "Quest Diagnostics", type: "company"), EntityRef(name: "Springfield", type: "concept")],
            keyFacts: ["Date of birth entered as 03/14/2001", "Account created on MyQuest", "Phone number verified by SMS"],
            links: ["https://my.questdiagnostics.com/", "https://example.com/?phone=617-555-0142"])
        let (clean, removed) = PersonalData.scrub(d)
        #expect(clean.title == d.title)
        #expect(clean.summary == "Created a MyQuest account. Entered date of birth [redacted], home town [redacted], [redacted] and phone [redacted].")
        #expect(clean.keyFacts == ["Account created on MyQuest"])
        #expect(clean.entities.map(\.name) == ["Quest Diagnostics"])
        #expect(clean.topics == ["account creation"])
        #expect(clean.links == ["https://my.questdiagnostics.com/"])
        #expect(removed >= 8)

        // Coding "test results" / "failure diagnosis" are not medical facts.
        let tests = DigestResult(title: "t", summary: "s", topics: [], entities: [],
                                 keyFacts: ["All test results green", "Failure diagnosis: stale cache"], links: [])
        #expect(PersonalData.scrub(tests).removed == 0)

        let plain = DigestResult(title: "Refactored Digester", summary: "Moved parsing into Digester.parse.", topics: ["swift"],
                                 entities: [EntityRef(name: "Navi", type: "project")], keyFacts: ["42 tests pass"], links: [])
        #expect(PersonalData.scrub(plain).removed == 0)
        #expect(PersonalData.scrub(plain).0 == plain)
    }

    @Test func promptRedactsScreenText() {
        let f = FrameRecord(timestamp: Date(timeIntervalSince1970: 1_700_000_000), bundleID: "com.google.Chrome", appName: "Chrome",
                            windowTitle: "Create account", url: "https://example.com/signup", ocrText: signUpForm,
                            activity: "browsing", importance: 2)
        let (text, _) = Digester.buildPrompt(for: [f])
        #expect(!text.contains("03/14/2001"))
        #expect(!text.contains("555-0142"))
        #expect(!text.contains("02139"))
        #expect(text.contains("[redacted]"))
        #expect(Digester.systemPrompt.contains("dates of birth"))
        #expect(Digester.systemPrompt.contains("phone numbers"))
    }
}

// MARK: - Cleanup

struct PersonalDataCleanupTests {
    private func tempDir(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("navi-pii-tests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func redactsStoreAndVault() throws {
        let dir = tempDir("cleanup")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MemoryStore(directory: dir.appendingPathComponent("db"))
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let vault = VaultWriter(root: dir.appendingPathComponent("vault"), calendar: cal)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        // The form frame (with a thumbnail), a frame of the same session, and an unrelated one.
        let thumb = dir.appendingPathComponent("form.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: thumb)
        let formID = try store.insertFrame(FrameRecord(timestamp: start, bundleID: "com.google.Chrome", appName: "Chrome",
                                                       windowTitle: "MyQuest", url: "https://my.questdiagnostics.com/signup",
                                                       ocrText: signUpForm, thumbPath: thumb.path, importance: 2))
        let codeID = try store.insertFrame(FrameRecord(timestamp: start.addingTimeInterval(-7200), bundleID: "com.apple.dt.Xcode",
                                                       appName: "Xcode", windowTitle: "View.swift", url: nil,
                                                       ocrText: "let className = view.className // build 1727600000", importance: 2))

        let digest = DigestResult(
            title: "Quest Diagnostics account creation",
            summary: "Created a MyQuest account. Entered date of birth 03/14/2001, home town Springfield and phone (617) 555-0142.",
            topics: ["account creation", "springfield"],
            entities: [EntityRef(name: "Quest Diagnostics", type: "company"), EntityRef(name: "Springfield", type: "concept")],
            keyFacts: ["Date of birth entered as 03/14/2001", "Account created on MyQuest"], links: [])
        var session = SessionRecord(start: start, end: start.addingTimeInterval(300), bundleID: "com.google.Chrome", appName: "Chrome",
                                    url: nil, title: digest.title, summary: digest.summary, topics: digest.topics,
                                    entities: digest.entities, importance: 2)
        session.id = try store.insertSession(session)
        let frames = [try #require(try store.frame(id: formID))]
        let rel = try vault.write(session: session, digest: digest, frames: frames, keepScreenshots: true)
        try store.updateSessionNotePath(sessionID: session.id, notePath: rel)
        let fm = FileManager.default
        let attachment = vault.root.appendingPathComponent("attachments/" + ((rel as NSString).lastPathComponent as NSString).deletingPathExtension + ".jpg")
        #expect(fm.fileExists(atPath: attachment.path))
        #expect(fm.fileExists(atPath: vault.root.appendingPathComponent("Entities/Springfield.md").path))
        #expect(try store.search(query: "Springfield", limit: 5).isEmpty == false)

        let cleanup = PersonalDataCleanup(store: store, vaultRoot: vault.root)
        let plan = try cleanup.plan()
        #expect(plan.frameIDs == [formID])
        #expect(plan.sessions.count == 1)
        #expect(plan.sessions.first?.kinds.contains(.birthDate) == true)
        // plan() is read-only.
        #expect(try store.frame(id: formID)?.ocrText == signUpForm)

        let report = try cleanup.apply(plan)
        #expect(report.framesRedacted == 1)
        #expect(report.sessionsRedacted == 1)
        #expect(report.notesRewritten == 1)
        #expect(report.attachmentsDeleted == 1)
        #expect(report.hubNotesDeleted == 2)                 // Springfield entity + topic hubs

        let form = try #require(try store.frame(id: formID))
        #expect(form.ocrText.isEmpty && form.windowTitle == nil && form.thumbPath == nil)
        #expect(!fm.fileExists(atPath: thumb.path))
        #expect(try store.frame(id: codeID)?.ocrText.isEmpty == false)

        let stored = try #require(try store.recentSessions(limit: 5).first)
        #expect(stored.summary == "Created a MyQuest account. Entered date of birth [redacted], home town [redacted] and phone [redacted].")
        #expect(stored.entities.map(\.name) == ["Quest Diagnostics"])
        #expect(stored.topics == ["account creation"])
        #expect(try store.search(query: "Springfield", limit: 5).isEmpty)
        #expect(try store.search(query: "0142", limit: 5).isEmpty)

        let note = try String(contentsOf: vault.root.appendingPathComponent(rel), encoding: .utf8)
        for leak in ["03/14/2001", "555-0142", "Springfield", "## Screenshot", "Date of birth entered"] { #expect(!note.contains(leak)) }
        #expect(note.contains("## Key facts\n- Account created on MyQuest"))
        #expect(note.contains("title: \"Quest Diagnostics account creation\""))
        #expect(note.contains("entities: [\"Quest Diagnostics\"]"))
        #expect(note.contains("- Entities: [[Entities/Quest Diagnostics]]"))
        #expect(note.contains("[redacted]"))
        #expect(!fm.fileExists(atPath: attachment.path))
        #expect(!fm.fileExists(atPath: vault.root.appendingPathComponent("Entities/Springfield.md").path))
        #expect(fm.fileExists(atPath: vault.root.appendingPathComponent("Entities/Quest Diagnostics.md").path))

        let daily = try String(contentsOf: vault.root.appendingPathComponent("Daily/2023-11-14.md"), encoding: .utf8)
        #expect(!daily.contains("Springfield") && !daily.contains("springfield"))
        #expect(daily.contains("[[Entities/Quest Diagnostics]]"))

        // A second pass finds nothing left.
        let again = try cleanup.plan()
        #expect(again.frameIDs.isEmpty && again.sessions.isEmpty)
    }

    @Test func keyFactsParsing() {
        let note = "# T\n\nSummary.\n\n## Key facts\n- one\n- two\n\n## Links\n- https://x\n"
        #expect(PersonalDataCleanup.keyFacts(in: note) == ["one", "two"])
        #expect(PersonalDataCleanup.keyFacts(in: "# T\n") == [])
    }
}

// MARK: - User choices (Settings → Recall → Personal information)

struct PersonalDataPolicyTests {
    private let contactsAllowed = PersonalData.Policy(allowed: [.phoneNumbers, .addresses])

    @Test func policyConstruction() {
        #expect(PersonalData.Policy.strict.allowed.isEmpty)
        #expect(PersonalData.Policy.default.allowed == [.phoneNumbers, .addresses])
        #expect(PersonalData.Policy(allowedRawValues: ["phoneNumbers", "bogus"]).allowed == [.phoneNumbers])
        #expect(contactsAllowed.blocks(.birthDate) && !contactsAllowed.blocks(.phone) && !contactsAllowed.blocks(.postalCode))
    }

    @Test func allowedKindsAreNeitherSignalsNorRedacted() {
        let r = PersonalData.redact("DOB 03/14/2001, phone (617) 555-0142, ZIP code 02139", policy: contactsAllowed)
        #expect(r.text == "DOB [redacted], phone (617) 555-0142, ZIP code 02139")
        #expect(PersonalData.redact("anything 03/14/2001", policy: PersonalData.Policy(allowed: Set(PersonalData.Category.allCases))).changed == false)

        // A checkout with only a phone and an address is fine once contacts are allowed…
        let checkout = PersonalData.signals(text: "Shipping\n12 Farnsworth Street\n(617) 555-0142", title: "Checkout",
                                            url: "https://shop.example/checkout", policy: contactsAllowed)
        #expect(checkout.kinds.isEmpty && !checkout.isSensitive)
        #expect(!checkout.stateLine.contains("identifier_values"))
        // …but the sign-up form still has a date of birth.
        let form = PersonalData.signals(text: signUpForm, title: "Create account", url: "https://example.com/signup", policy: contactsAllowed)
        #expect(form.kinds == [.birthDate] && form.isSensitive)
        // Patient portals follow the health switch.
        let portal = PersonalData.Policy(allowed: [.health])
        #expect(!PersonalData.signals(text: "Welcome back", title: "MyQuest", url: nil, policy: portal).isSensitive)
        #expect(!PersonalData.signals(text: "Welcome back", title: "MyQuest", url: nil, policy: portal).stateLine.contains("medical"))
    }

    @Test func keywordMarkersFollowTheirCategory() {
        let cards = PersonalData.Policy(allowed: [.cardNumbers])
        #expect(!FrameTriage.containsHardSensitive("CVV: 123", policy: cards))
        #expect(FrameTriage.containsHardSensitive("Your verification code is 482911", policy: PersonalData.Policy(allowed: Set(PersonalData.Category.allCases))))
        #expect(!FrameTriage.containsSoftSensitive("Prescription refill ready", policy: PersonalData.Policy(allowed: [.health])))
        #expect(FrameTriage.containsSoftSensitive("Password: ••••", policy: PersonalData.Policy(allowed: Set(PersonalData.Category.allCases))))
    }

    @Test func jevAndDigestWordingFollowThePolicy() throws {
        let everything = PersonalData.Policy(allowed: Set(PersonalData.Category.allCases))
        let open = FrameTriage.sensitiveInstructions(for: everything)
        #expect((open["sensitive_when"] as? [String])?.count == 1)          // passwords / codes only
        #expect((open["not_sensitive_when"] as? [String])?.last?.contains("phone numbers") == true)
        let contacts = try #require(FrameTriage.sensitiveInstructions(for: contactsAllowed)["sensitive_when"] as? [String])
        #expect(contacts.contains { $0.contains("date of birth") && !$0.contains("phone number") })

        #expect(!Digester.systemPrompt(policy: everything).contains("Privacy"))
        let p = Digester.systemPrompt(policy: contactsAllowed)
        #expect(p.contains("dates of birth") && !p.contains("phone numbers"))

        let d = DigestResult(title: "Call", summary: "Called (617) 555-0142 about the order.", topics: [], entities: [],
                             keyFacts: ["Phone number on file"], links: [])
        #expect(PersonalData.scrub(d, policy: contactsAllowed).removed == 0)
        #expect(PersonalData.scrub(d).removed == 2)
    }

    @Test func cleanupLeavesAllowedDetailsAlone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("navi-pii-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MemoryStore(directory: dir)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try store.insertSession(SessionRecord(start: start, end: start.addingTimeInterval(60), bundleID: "com.apple.MobileSMS",
                                                  appName: "Messages", url: nil, title: "Texted Sam",
                                                  summary: "Texted Sam at (617) 555-0142.", topics: [], entities: []))
        let lenient = PersonalDataCleanup(store: store, vaultRoot: dir, policy: contactsAllowed)
        #expect(try lenient.plan().sessions.isEmpty)
        #expect(try PersonalDataCleanup(store: store, vaultRoot: dir).plan().sessions.count == 1)
    }
}
