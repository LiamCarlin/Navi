import Foundation

// MARK: - Tiers, entitlements, quotas (the `/v1/me` contract, docs/LAUNCH_ROADMAP.md §3.1)

/// The subscription tier as the cloud reports it.
enum Tier: String, Codable, Sendable, CaseIterable {
    case free
    case pro
    case proRecall = "pro_recall"

    var displayName: String {
        switch self {
        case .free: return "Free"
        case .pro: return "Pro"
        case .proRecall: return "Pro + Recall"
        }
    }

    /// What the plan buys, in one line (for the plan card).
    var summary: String {
        switch self {
        case .free: return "Local search, 20 answers and 5 tasks a day."
        case .pro: return "Unlimited answers, 300 tasks a month, voice control."
        case .proRecall: return "Everything in Pro plus screen memory."
        }
    }

    var includesRecall: Bool { self == .proRecall }
}

/// Feature flags granted to the account. Decoded from `/v1/me`, but also the
/// shape the app reasons about locally (developer mode grants everything).
struct Entitlements: Codable, Equatable, Sendable {
    var answers = false
    var tasks = false
    var voice = false
    var recall = false

    static let none = Entitlements()
    static let all = Entitlements(answers: true, tasks: true, voice: true, recall: true)

    /// Whether the entitlement behind a cloud feature is granted.
    func allows(_ feature: CloudFeature) -> Bool {
        switch feature {
        case .route: return true                 // routing is always on; the meter counts runs, not routes
        case .answer: return answers
        case .task: return tasks
        case .voice: return voice
        case .recallTriage, .recallDigest: return recall
        }
    }

    init(answers: Bool = false, tasks: Bool = false, voice: Bool = false, recall: Bool = false) {
        self.answers = answers; self.tasks = tasks; self.voice = voice; self.recall = recall
    }

    // Missing keys read as `false`: a server that drops a flag revokes it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        answers = try c.decodeIfPresent(Bool.self, forKey: .answers) ?? false
        tasks = try c.decodeIfPresent(Bool.self, forKey: .tasks) ?? false
        voice = try c.decodeIfPresent(Bool.self, forKey: .voice) ?? false
        recall = try c.decodeIfPresent(Bool.self, forKey: .recall) ?? false
    }
}

/// Per-tier caps. `nil` means unlimited (fair use).
struct Quotas: Codable, Equatable, Sendable {
    var answersPerDay: Int?
    var tasksPerDay: Int?
    var tasksPerMonth: Int?

    init(answersPerDay: Int? = nil, tasksPerDay: Int? = nil, tasksPerMonth: Int? = nil) {
        self.answersPerDay = answersPerDay; self.tasksPerDay = tasksPerDay; self.tasksPerMonth = tasksPerMonth
    }
}

/// Counters as of the last `/v1/me`.
struct Usage: Codable, Equatable, Sendable {
    var answersToday = 0
    var tasksToday = 0
    var tasksThisMonth = 0
    var resetsAt: Date?

    init(answersToday: Int = 0, tasksToday: Int = 0, tasksThisMonth: Int = 0, resetsAt: Date? = nil) {
        self.answersToday = answersToday; self.tasksToday = tasksToday
        self.tasksThisMonth = tasksThisMonth; self.resetsAt = resetsAt
    }

    private enum CodingKeys: String, CodingKey { case answersToday, tasksToday, tasksThisMonth, resetsAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        answersToday = try c.decodeIfPresent(Int.self, forKey: .answersToday) ?? 0
        tasksToday = try c.decodeIfPresent(Int.self, forKey: .tasksToday) ?? 0
        tasksThisMonth = try c.decodeIfPresent(Int.self, forKey: .tasksThisMonth) ?? 0
        resetsAt = try c.decodeLenientDateIfPresent(forKey: .resetsAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(answersToday, forKey: .answersToday)
        try c.encode(tasksToday, forKey: .tasksToday)
        try c.encode(tasksThisMonth, forKey: .tasksThisMonth)
        try c.encodeIfPresent(resetsAt.map(LenientDate.string), forKey: .resetsAt)
    }
}

// MARK: - Remote config (`/v1/me.config`)

/// Operator switches the cloud sends with `/v1/me`: kill switches per feature,
/// one banner notice, and the app versions it will serve. Every field is
/// optional and decoded leniently — an older server sends no `config` at all,
/// and a malformed field never fails the account decode.
struct CloudConfig: Codable, Equatable, Sendable {
    /// Kill switches. Unlike entitlements, a missing flag means *on*: the
    /// operator turns a feature off explicitly, a server that omits it doesn't.
    struct Features: Codable, Equatable, Sendable {
        var answers = true
        var tasks = true
        var voice = true
        var recall = true

        init(answers: Bool = true, tasks: Bool = true, voice: Bool = true, recall: Bool = true) {
            self.answers = answers; self.tasks = tasks; self.voice = voice; self.recall = recall
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            answers = (try? c.decodeIfPresent(Bool.self, forKey: .answers)) ?? true
            tasks = (try? c.decodeIfPresent(Bool.self, forKey: .tasks)) ?? true
            voice = (try? c.decodeIfPresent(Bool.self, forKey: .voice)) ?? true
            recall = (try? c.decodeIfPresent(Bool.self, forKey: .recall)) ?? true
        }

        /// Whether the switch behind a cloud feature is on. Routing has no switch.
        func allows(_ feature: CloudFeature) -> Bool {
            guard let key = Self.key(for: feature) else { return true }
            switch key {
            case "answers": return answers
            case "tasks": return tasks
            case "voice": return voice
            default: return recall
            }
        }

        /// The `config.features` key for a metered feature (`feature_disabled.feature` uses the same names).
        static func key(for feature: CloudFeature) -> String? {
            switch feature {
            case .route: return nil
            case .answer: return "answers"
            case .task: return "tasks"
            case .voice: return "voice"
            case .recallTriage, .recallDigest: return "recall"
            }
        }

        /// Names of the switches that are off ("answers", "tasks", …).
        var disabled: Set<String> {
            var s = Set<String>()
            if !answers { s.insert("answers") }
            if !tasks { s.insert("tasks") }
            if !voice { s.insert("voice") }
            if !recall { s.insert("recall") }
            return s
        }
    }

    /// A one-line banner from the operator ("Answers are slow right now").
    struct Notice: Codable, Equatable, Sendable, Identifiable {
        enum Level: String, Codable, Sendable { case info, warning, critical }
        var id: String
        var message: String
        var level: Level
        var url: URL?

        init(id: String, message: String, level: Level = .info, url: URL? = nil) {
            self.id = id; self.message = message; self.level = level; self.url = url
        }

        private enum CodingKeys: String, CodingKey { case id, message, level, url }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            message = try c.decode(String.self, forKey: .message)
            // An unknown level (a future "maintenance") reads as info rather than dropping the notice.
            let rawLevel: String? = (try? c.decodeIfPresent(String.self, forKey: .level)) ?? nil
            level = rawLevel.flatMap(Level.init(rawValue:)) ?? .info
            let rawURL: String? = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? nil
            url = rawURL.flatMap(URL.init(string:))
        }
    }

    var features = Features()
    var notice: Notice?
    /// Oldest app version the cloud still serves; older builds get 426 `upgrade_required`.
    var minAppVersion: String?
    /// Newest released version (for an "update available" hint).
    var latestVersion: String?
    /// Where to download the latest build when the updater can't help.
    var downloadURL: URL?

    init(features: Features = Features(), notice: Notice? = nil, minAppVersion: String? = nil,
         latestVersion: String? = nil, downloadURL: URL? = nil) {
        self.features = features; self.notice = notice; self.minAppVersion = minAppVersion
        self.latestVersion = latestVersion; self.downloadURL = downloadURL
    }

    private enum CodingKeys: String, CodingKey { case features, notice, minAppVersion, latestVersion, downloadURL }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        features = (try? c.decodeIfPresent(Features.self, forKey: .features)) ?? Features()
        notice = (try? c.decodeIfPresent(Notice.self, forKey: .notice)) ?? nil
        if let n = notice, n.id.isEmpty || n.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { notice = nil }
        minAppVersion = Self.nonEmpty((try? c.decodeIfPresent(String.self, forKey: .minAppVersion)) ?? nil)
        latestVersion = Self.nonEmpty((try? c.decodeIfPresent(String.self, forKey: .latestVersion)) ?? nil)
        downloadURL = ((try? c.decodeIfPresent(String.self, forKey: .downloadURL)) ?? nil).flatMap(URL.init(string:))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(features, forKey: .features)
        try c.encodeIfPresent(notice, forKey: .notice)
        try c.encodeIfPresent(minAppVersion, forKey: .minAppVersion)
        try c.encodeIfPresent(latestVersion, forKey: .latestVersion)
        try c.encodeIfPresent(downloadURL?.absoluteString, forKey: .downloadURL)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// This build is older than the oldest version the cloud serves.
    func requiresUpdate(currentVersion: String) -> Bool {
        guard let min = minAppVersion, let need = SemanticVersion(min), let have = SemanticVersion(currentVersion) else { return false }
        return have < need
    }

    /// A newer release exists (informational).
    func updateAvailable(currentVersion: String) -> Bool {
        guard let latest = latestVersion, let l = SemanticVersion(latest), let have = SemanticVersion(currentVersion) else { return false }
        return have < l
    }
}

/// Which notice ids the user has dismissed. Persisted so a dismissed banner
/// stays gone across launches; capped so the list can't grow forever.
struct NoticeMemory {
    static let key = "naviDismissedNoticeIDs"
    static let limit = 50
    let defaults: UserDefaults

    init(defaults: UserDefaults = .navi) { self.defaults = defaults }

    var dismissed: [String] { defaults.stringArray(forKey: Self.key) ?? [] }

    func isDismissed(_ id: String) -> Bool { dismissed.contains(id) }

    func dismiss(_ id: String) {
        guard !id.isEmpty, !isDismissed(id) else { return }
        defaults.set(Array((dismissed + [id]).suffix(Self.limit)), forKey: Self.key)
    }

    /// The notice to show, or nil when there is none or it was dismissed.
    func visible(_ notice: CloudConfig.Notice?) -> CloudConfig.Notice? {
        guard let notice, !isDismissed(notice.id) else { return nil }
        return notice
    }
}

/// `GET /v1/me`.
struct AccountInfo: Codable, Equatable, Sendable {
    struct User: Codable, Equatable, Sendable {
        var id: String
        var email: String
    }

    var user: User
    var tier: Tier
    var trialEndsAt: Date?
    var entitlements: Entitlements
    var quotas: Quotas
    var usage: Usage
    /// Operator config; nil when the server sends none (everything on, no notice).
    var config: CloudConfig?

    private enum CodingKeys: String, CodingKey { case user, tier, trialEndsAt, entitlements, quotas, usage, config }

    init(user: User, tier: Tier, trialEndsAt: Date? = nil, entitlements: Entitlements,
         quotas: Quotas = Quotas(), usage: Usage = Usage(), config: CloudConfig? = nil) {
        self.user = user; self.tier = tier; self.trialEndsAt = trialEndsAt
        self.entitlements = entitlements; self.quotas = quotas; self.usage = usage; self.config = config
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = try c.decode(User.self, forKey: .user)
        // An unknown tier string (a future plan) reads as Pro rather than failing the whole decode.
        let tierRaw = try c.decode(String.self, forKey: .tier)
        tier = Tier(rawValue: tierRaw) ?? (tierRaw.contains("recall") ? .proRecall : .pro)
        trialEndsAt = try c.decodeLenientDateIfPresent(forKey: .trialEndsAt)
        entitlements = try c.decodeIfPresent(Entitlements.self, forKey: .entitlements) ?? .none
        quotas = try c.decodeIfPresent(Quotas.self, forKey: .quotas) ?? Quotas()
        usage = try c.decodeIfPresent(Usage.self, forKey: .usage) ?? Usage()
        config = (try? c.decodeIfPresent(CloudConfig.self, forKey: .config)) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(user, forKey: .user)
        try c.encode(tier, forKey: .tier)
        try c.encodeIfPresent(trialEndsAt.map(LenientDate.string), forKey: .trialEndsAt)
        try c.encode(entitlements, forKey: .entitlements)
        try c.encode(quotas, forKey: .quotas)
        try c.encode(usage, forKey: .usage)
        try c.encodeIfPresent(config, forKey: .config)
    }

    static func decode(_ data: Data) throws -> AccountInfo {
        do { return try JSONDecoder().decode(AccountInfo.self, from: data) }
        catch { throw NaviError.decoding("Account info: \(error.localizedDescription)") }
    }

    /// Days of trial left, or nil when there is no trial / it has ended.
    func trialDaysLeft(now: Date = Date()) -> Int? {
        guard let end = trialEndsAt, end > now else { return nil }
        return max(1, Int((end.timeIntervalSince(now) / 86400).rounded(.up)))
    }
}

// MARK: - Dates as the cloud sends them

/// The contract says timestamps are ISO-8601; a JS backend may add fractional
/// seconds, and a quick mock may send epoch seconds or milliseconds. Accept all.
enum LenientDate {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    static func parse(_ s: String) -> Date? {
        if let d = plain.date(from: s) ?? withFraction.date(from: s) { return d }
        if let n = Double(s) { return parse(n) }
        return nil
    }

    static func parse(_ n: Double) -> Date? {
        guard n > 0 else { return nil }
        // Anything past the year 2286 in seconds is really milliseconds.
        return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n)
    }

    static func string(_ d: Date) -> String { plain.string(from: d) }
}

extension KeyedDecodingContainer {
    func decodeLenientDateIfPresent(forKey key: Key) throws -> Date? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return LenientDate.parse(s) }
        if let n = try? decodeIfPresent(Double.self, forKey: key) { return LenientDate.parse(n) }
        return nil
    }
}
