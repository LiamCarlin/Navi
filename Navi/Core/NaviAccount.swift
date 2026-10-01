import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers

/// Navi's public web addresses. One place, so the app and the site never disagree.
enum NaviLinks {
    static let site = URL(string: "https://navi.app")!
    static let privacy = URL(string: "https://navi.app/privacy")!
    static let terms = URL(string: "https://navi.app/terms")!
    static let supportEmail = "support@navi.app"

    /// `mailto:` for support, with a subject and (when known) the account's email in the body.
    static func supportMail(subject: String = "Navi account", account email: String? = nil) -> URL {
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = supportEmail
        var items = [URLQueryItem(name: "subject", value: subject)]
        let version = CloudTransport.appVersion
        let body = (email.map { "Account: \($0)\n" } ?? "") + "Navi \(version)\n\n"
        items.append(URLQueryItem(name: "body", value: body))
        comps.queryItems = items
        return comps.url ?? URL(string: "mailto:\(supportEmail)")!
    }
}

/// A one-line banner the account wants shown: an operator notice from
/// `/v1/me.config.notice`, or a state that blocks the cloud (update required,
/// account disabled).
struct AccountNotice: Equatable, Identifiable {
    enum Kind: Equatable { case config(url: URL?), updateRequired, accountDisabled }
    var id: String
    var message: String
    var level: CloudConfig.Notice.Level
    var kind: Kind

    /// The banner's button, if it has one.
    var actionTitle: String? {
        switch kind {
        case .config(let url): return url == nil ? nil : "Learn more"
        case .updateRequired: return "Update"
        case .accountDisabled: return "Contact support"
        }
    }
}

/// The signed-in Navi account: tier, entitlements, quotas, usage.
///
/// Sign-in is a browser round trip: `signIn()` opens
/// `<cloudBaseURL>/auth/start?redirect=navi`, the hosted page finishes with a
/// 302 to `navi://auth/callback?code=…`, `AppDelegate` hands the URL to
/// `handle(url:)`, which exchanges the code for tokens (Keychain) and fetches
/// `/v1/me`. `/v1/me` is refreshed on sign-in, on wake, every 10 minutes, and
/// after billing round trips; the last snapshot is cached in UserDefaults so the
/// tier is known at launch before the network answers.
///
/// `/v1/me.config` carries the operator's switches: features turned off for
/// now (`isAvailable`), a banner notice (`homeNotice` / `panelNotice`, dismissed
/// ids remembered) and the oldest app version the cloud serves. A 426, a 403
/// `account_disabled` or a 503 `feature_disabled` from any call lands here too
/// (`.naviCloudBlocked`), so the UI says what's wrong once instead of failing per call.
///
/// Developer mode: with `useCloud` off, or signed out but with vendor keys in
/// the Keychain, the app talks to the vendors directly and every feature is
/// entitled locally — there is nothing to meter.
@MainActor
final class NaviAccount: ObservableObject {
    static let shared: NaviAccount = {
        #if DEBUG
        if let d = DevCloud.defaults { return NaviAccount(cloud: .shared, defaults: d) }
        #endif
        return NaviAccount(cloud: .shared)
    }()

    let cloud: CloudTransport
    let defaults: UserDefaults

    @Published private(set) var isSignedIn = false
    @Published private(set) var info: AccountInfo?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSigningIn = false
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var lastError: String?
    /// The cloud refuses this app for now (update required / account disabled).
    @Published private(set) var block: CloudTransport.Block?
    /// `config.features` keys switched off by the operator ("answers", …).
    @Published private(set) var disabledFeatures: Set<String> = []
    @Published private(set) var isExporting = false
    @Published private(set) var isDeleting = false
    /// One-line notice for the UI ("Welcome to Pro"). Cleared by the view that shows it.
    @Published var toast: String?
    /// Bumped when a notice is dismissed so views re-read `homeNotice` / `panelNotice`.
    @Published private var noticeTick = 0

    static let snapshotKey = "naviAccountInfo"
    static let refreshInterval: TimeInterval = 10 * 60
    /// A sign-in that never comes back (browser closed) stops "waiting" after this long.
    static let signInTimeout: TimeInterval = 5 * 60

    /// Erases everything Navi keeps on this Mac (Recall, the journal, task logs,
    /// recent searches) — `PrivacyData.deleteAllLocalData()`. Delete account offers
    /// it as "Also erase this Mac's data". Replaceable so tests never erase for real.
    static var eraseLocalData: (@MainActor () async -> Void)? = {
        let report = await PrivacyData.deleteAllLocalData()
        Log.app.info("account: local data erased with the account (\(report.summary, privacy: .public))")
    }

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var signInTimeoutTask: Task<Void, Never>?
    private var dismissedThisSession: Set<String> = []
    private var notices: NoticeMemory { NoticeMemory(defaults: defaults) }

    init(cloud: CloudTransport = .shared, defaults: UserDefaults = .navi) {
        self.cloud = cloud
        self.defaults = defaults
        isSignedIn = cloud.isSignedIn
        if let data = defaults.data(forKey: Self.snapshotKey), let cached = try? AccountInfo.decode(data) {
            info = cached
            // Kill switches and the minimum version are known before the network answers.
            if isSignedIn { cloud.apply(cached) }
        }
        syncFromCloud()
    }

    // MARK: Derived

    var email: String? { info?.user.email }
    var tier: Tier { usesCloud ? (info?.tier ?? .free) : .free }
    var quotas: Quotas { info?.quotas ?? Quotas() }
    var usage: Usage { info?.usage ?? Usage() }
    var trialEndsAt: Date? { info?.trialEndsAt }
    var trialDaysLeft: Int? { info?.trialDaysLeft() }
    var config: CloudConfig { info?.config ?? CloudConfig() }

    /// Calls go through Navi Cloud (signed in and `useCloud`).
    var usesCloud: Bool { cloud.isActive }

    /// Developer mode: not on the cloud, but vendor keys exist.
    var hasDeveloperKeys: Bool {
        Keychain.has(.anthropic) || Keychain.has(.typesafe) || Keychain.has(.vercelGateway)
    }

    /// What the app may do right now. Cloud: the server's flags. Developer
    /// mode: everything. Signed out without keys: nothing that costs money.
    var entitlements: Entitlements {
        if usesCloud { return info?.entitlements ?? .none }
        return hasDeveloperKeys ? .all : .none
    }

    /// Whether the user can be asked to upgrade (there is an account to bill).
    var canUpgrade: Bool { isSignedIn && tier != .proRecall }

    var isAccountDisabled: Bool { if case .accountDisabled = block { return true }; return false }
    var isUpdateRequired: Bool { if case .upgradeRequired = block { return true }; return false }

    /// A newer Navi is out (from `/v1/me.config.latestVersion`); informational.
    var isUpdateAvailable: Bool { usesCloud && config.updateAvailable(currentVersion: CloudTransport.appVersion) }

    /// `/v1/me.tier` is the *effective* tier: during the 7-day trial it is
    /// `pro` with a `trialEndsAt`. "Pro trial · 6 days left" / "Pro" / "Free".
    var planLabel: String {
        if let days = trialDaysLeft { return "\(tier.displayName) trial · \(days) day\(days == 1 ? "" : "s") left" }
        return tier.displayName
    }

    /// The menu-bar line: "liam@example.com · Pro", or nil when signed out.
    var menuTitle: String? {
        guard isSignedIn else { return nil }
        if isAccountDisabled { return "\(email ?? "Navi account") · Disabled" }
        return "\(email ?? "Signed in") · \(planLabel)"
    }

    // MARK: Availability

    /// Why `feature` can't run right now, or nil when it can. Checked before
    /// starting an answer or a task, so the user sees one line and one button
    /// instead of a failed call.
    func blocker(for feature: CloudFeature) -> NaviError? {
        Self.blocker(for: feature, usesCloud: usesCloud, isSignedIn: isSignedIn,
                     hasDeveloperKeys: hasDeveloperKeys, block: block, disabled: disabledFeatures)
    }

    /// Pure core of `blocker(for:)`.
    nonisolated static func blocker(for feature: CloudFeature, usesCloud: Bool, isSignedIn: Bool, hasDeveloperKeys: Bool,
                                    block: CloudTransport.Block?, disabled: Set<String>) -> NaviError? {
        guard usesCloud else {
            // Developer mode (own keys, or the cloud switched off while signed in) decides per call.
            return hasDeveloperKeys || isSignedIn ? nil : .signedOut
        }
        if let block { return block.error }
        if let key = CloudConfig.Features.key(for: feature), disabled.contains(key) {
            return .featureDisabled(feature: key, message: nil)
        }
        return nil
    }

    /// The operator hasn't switched `feature` off (config or a 503 since the last `/v1/me`).
    func isAvailable(_ feature: CloudFeature) -> Bool {
        guard let key = CloudConfig.Features.key(for: feature) else { return true }
        return !disabledFeatures.contains(key)
    }

    /// "Sign in to use answers." — the signed-out line for a feature.
    nonisolated static func signInLine(for feature: CloudFeature?) -> String {
        guard let feature, let key = CloudConfig.Features.key(for: feature) else { return "Sign in to Navi to keep going." }
        return "Sign in to use \(NaviError.featureNoun(key))."
    }

    // MARK: Notices

    /// The banner for Home: a block first, else the operator's notice unless dismissed.
    var homeNotice: AccountNotice? { _ = noticeTick; return notice(minimumLevel: .info) }

    /// The banner for the ⌘Space panel: blocks and `critical` notices only.
    var panelNotice: AccountNotice? { _ = noticeTick; return notice(minimumLevel: .critical) }

    private func notice(minimumLevel: CloudConfig.Notice.Level) -> AccountNotice? {
        guard isSignedIn else { return nil }
        switch block {
        case .upgradeRequired:
            let n = AccountNotice(id: "navi.update-required", message: NaviError.upgradeRequired(minAppVersion: nil, downloadURL: nil).errorDescription ?? "",
                                  level: .critical, kind: .updateRequired)
            return dismissedThisSession.contains(n.id) ? nil : n
        case .accountDisabled(let m):
            let n = AccountNotice(id: "navi.account-disabled", message: NaviError.accountDisabled(message: m).errorDescription ?? "",
                                  level: .critical, kind: .accountDisabled)
            return dismissedThisSession.contains(n.id) ? nil : n
        case nil:
            break
        }
        guard let n = notices.visible(config.notice) else { return nil }
        if minimumLevel == .critical, n.level != .critical { return nil }
        return AccountNotice(id: n.id, message: n.message, level: n.level, kind: .config(url: n.url))
    }

    /// Hides a banner. Operator notices stay hidden for good (by id); a block's
    /// banner only until relaunch — the state itself is still shown on Account.
    func dismiss(_ notice: AccountNotice) {
        switch notice.kind {
        case .config: notices.dismiss(notice.id)
        case .updateRequired, .accountDisabled: dismissedThisSession.insert(notice.id)
        }
        noticeTick &+= 1
    }

    /// The banner's button.
    func perform(_ notice: AccountNotice) {
        switch notice.kind {
        case .config(let url): if let url { NSWorkspace.shared.open(url) }
        case .updateRequired: updateApp()
        case .accountDisabled: contactSupport()
        }
    }

    // MARK: Lifecycle

    /// Observers + the refresh schedule. Called once from `AppDelegate`.
    func start() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .naviKeysChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keysChanged() }
        })
        observers.append(nc.addObserver(forName: .naviAccountChanged, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                if (note.userInfo?["signedOut"] as? Bool) == true {
                    self.clearState(reason: "session expired")
                    self.lastError = "You were signed out. Sign in again to keep using answers and tasks."
                }
            }
        })
        observers.append(nc.addObserver(forName: .naviCloudTierSeen, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let raw = note.userInfo?["tier"] as? String else { return }
                // The proxy echoes the effective tier on every call: a change means /v1/me is stale.
                if Tier(rawValue: raw) != self.info?.tier { self.refreshIfSignedIn(reason: "tier header \(raw)") }
            }
        })
        observers.append(nc.addObserver(forName: .naviCloudBlocked, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.cloudBlocked(note.userInfo?["error"] as? NaviError) }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfSignedIn(reason: "wake") }
        })
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfSignedIn(reason: "timer") }
        }
        keysChanged()
    }

    private func keysChanged() {
        let now = cloud.isSignedIn
        if now != isSignedIn {
            isSignedIn = now
            NotificationCenter.default.post(name: .naviAccountChanged, object: nil)
        }
        if now, info == nil || lastRefreshAt == nil { refreshIfSignedIn(reason: "launch") }
    }

    private func refreshIfSignedIn(reason: String) {
        guard isSignedIn, !isRefreshing else { return }
        Task { await refreshMe(reason: reason) }
    }

    /// Mirrors the transport's block and kill switches into published state.
    private func syncFromCloud() {
        let b = cloud.block, d = cloud.disabledFeatures
        if b != block { block = b }
        if d != disabledFeatures { disabledFeatures = d }
    }

    private func cloudBlocked(_ error: NaviError?) {
        syncFromCloud()
        guard let error else { return }
        Log.app.info("account: cloud blocked (\(String(describing: error), privacy: .public))")
        switch error {
        case .featureDisabled:
            // The operator's notice (if any) explains it; fetch it, but not on every refused call.
            if (lastRefreshAt.map { Date().timeIntervalSince($0) > 60 } ?? true) { refreshIfSignedIn(reason: "feature disabled") }
        case .accountDisabled, .upgradeRequired:
            NotificationCenter.default.post(name: .naviAccountChanged, object: nil)
        default:
            break
        }
    }

    // MARK: Sign-in

    /// Opens the hosted sign-in page; the app resumes in `handle(url:)`.
    func signIn() {
        isSigningIn = true
        lastError = nil
        var comps = URLComponents(url: cloud.url("/auth/start"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "redirect", value: "navi")]
        guard let url = comps.url else { isSigningIn = false; return }
        Log.app.info("account: opening sign-in")
        NSWorkspace.shared.open(url)
        // The browser may be closed without finishing: stop "waiting" eventually (Sign in stays clickable).
        signInTimeoutTask?.cancel()
        signInTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.signInTimeout))
            guard !Task.isCancelled, let self, self.isSigningIn, !self.isSignedIn else { return }
            self.isSigningIn = false
        }
    }

    /// "Cancel" next to "Waiting for your browser…".
    func cancelSignIn() {
        signInTimeoutTask?.cancel()
        isSigningIn = false
    }

    /// `navi://auth/callback?code=…` and `navi://billing/{success,cancel}`.
    /// Returns false for URLs that are not the account's.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard url.scheme == "navi" else { return false }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        func query(_ name: String) -> String? { comps?.queryItems?.first { $0.name == name }?.value }
        switch url.host {
        case "auth":
            if path == "signout" { signOut(); return true }   // dev: `open navi://auth/signout`
            guard path == "callback" || path.isEmpty else { return false }
            signInTimeoutTask?.cancel()
            if let err = query("error") {
                // `navi://auth/callback?error=sign_in_failed&message=…` — no exchange, surface the message.
                isSigningIn = false
                lastError = Self.callbackErrorLine(error: err, message: query("message"))
                Log.app.error("account: sign-in callback error \(err, privacy: .public): \(query("message") ?? "", privacy: .public)")
                bringWindowForward()
                return true
            }
            guard let code = query("code"), !code.isEmpty else {
                isSigningIn = false
                lastError = "Sign-in didn't finish. Try signing in again."
                bringWindowForward()
                return true
            }
            isSigningIn = true
            Task { await completeSignIn(code: code) }
            return true
        case "billing":
            switch path {
            case "success":
                Log.app.info("account: billing success")
                Task {
                    await refreshMe(reason: "billing")
                    toast = "Welcome to \(tier.displayName)"
                }
            case "cancel":
                Log.app.info("account: billing cancelled")
            default:
                return false
            }
            bringWindowForward()
            return true
        default:
            return false
        }
    }

    /// The one line for `navi://auth/callback?error=…&message=…`.
    nonisolated static func callbackErrorLine(error: String, message: String?) -> String {
        let m = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let detail = m.isEmpty ? error.replacingOccurrences(of: "_", with: " ") : m
        if error == "access_denied" || detail.lowercased().contains("cancel") { return "Sign-in was cancelled." }
        let sentence = detail.hasSuffix(".") ? detail : detail + "."
        return "Couldn't sign you in: \(sentence.prefix(1).lowercased() + sentence.dropFirst()) Try again."
    }

    private func completeSignIn(code: String) async {
        do {
            cloud.clearBlocks()
            try await cloud.exchange(code: code)
            isSignedIn = true
            isSigningIn = false
            lastError = nil
            NotificationCenter.default.post(name: .naviAccountChanged, object: nil)
            await refreshMe(reason: "sign-in")
            bringWindowForward()
        } catch {
            isSigningIn = false
            lastError = "Couldn't sign you in. \(Self.userMessage(for: error))"
            Log.app.error("account: exchange failed: \(error.localizedDescription, privacy: .public)")
            bringWindowForward()
        }
    }

    private func bringWindowForward() {
        // The browser took focus; put the Navi window (onboarding / Account) back in front if it is open.
        guard AppActivation.mainWindow != nil else { return }
        AppDelegate.shared?.openMainWindow()
    }

    // MARK: /v1/me

    func refreshMe(reason: String = "manual") async {
        guard isSignedIn else { return }
        isRefreshing = true
        defer { isRefreshing = false; syncFromCloud() }
        do {
            let me = try await cloud.me()
            let changed = me != info
            info = me
            lastRefreshAt = Date()
            lastError = nil
            if let data = try? JSONEncoder().encode(me) { defaults.set(data, forKey: Self.snapshotKey) }
            Log.app.info("account: /v1/me ok (\(reason, privacy: .public)) tier=\(me.tier.rawValue, privacy: .public) recall=\(me.entitlements.recall) answers=\(me.usage.answersToday)/\(me.quotas.answersPerDay.map(String.init) ?? "∞", privacy: .public) off=\(me.config?.features.disabled.sorted().joined(separator: ",") ?? "", privacy: .public)")
            if changed { NotificationCenter.default.post(name: .naviAccountChanged, object: nil) }
        } catch NaviError.signedOut {
            clearState(reason: "session expired")
            lastError = "You were signed out. Sign in again to keep using answers and tasks."
        } catch NaviError.accountDisabled, NaviError.upgradeRequired {
            // Shown by the Account page and the banners from `block`, not as an error line.
            lastRefreshAt = Date()
        } catch {
            // Background refreshes fail quietly (offline on a train); a manual one says why.
            if reason == "manual" || reason == "sign-in" || info == nil { lastError = "Couldn't update your account. \(Self.userMessage(for: error))" }
            Log.app.error("account: /v1/me failed (\(reason, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Sign-out

    func signOut() {
        Log.app.info("account: sign out")
        cloud.tokens.clear()
        clearState(reason: "sign out")
    }

    private func clearState(reason: String) {
        signInTimeoutTask?.cancel()
        isSignedIn = false
        isSigningIn = false
        info = nil
        lastRefreshAt = nil
        lastError = nil
        dismissedThisSession = []
        cloud.clearBlocks()
        syncFromCloud()
        defaults.removeObject(forKey: Self.snapshotKey)
        Log.app.info("account: cleared (\(reason, privacy: .public))")
        NotificationCenter.default.post(name: .naviAccountChanged, object: nil)
    }

    // MARK: Your data

    /// `GET /v1/account/export` → a JSON file the user picks the place for.
    func exportData() {
        guard isSignedIn, !isExporting else { return }
        isExporting = true
        lastError = nil
        Task {
            defer { isExporting = false }
            do {
                let raw = try await cloud.exportAccount()
                let data = Self.prettyJSON(raw)
                let panel = NSSavePanel()
                panel.title = "Export your Navi data"
                panel.nameFieldStringValue = Self.exportFileName()
                panel.allowedContentTypes = [.json]
                panel.canCreateDirectories = true
                NSApp.activate(ignoringOtherApps: true)
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url, options: .atomic)
                Log.app.info("account: exported \(data.count) bytes")
                toast = "Saved \(url.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                lastError = "Couldn't export your data. \(Self.userMessage(for: error))"
                Log.app.error("account: export failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    nonisolated static func exportFileName(now: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return "Navi account data \(f.string(from: now)).json"
    }

    /// Indented when it parses; the server's bytes untouched otherwise.
    nonisolated static func prettyJSON(_ data: Data) -> Data {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return data }
        return out
    }

    /// Whether Delete account can also erase this Mac's data (the privacy hook is installed).
    var canEraseLocalData: Bool { Self.eraseLocalData != nil }

    /// `DELETE /v1/account`, then the signed-out state. Returns false (with `lastError`) on failure.
    @discardableResult
    func deleteAccount(alsoEraseLocalData: Bool) async -> Bool {
        guard isSignedIn, !isDeleting else { return false }
        isDeleting = true
        lastError = nil
        defer { isDeleting = false }
        do {
            try await cloud.deleteAccount()
        } catch {
            lastError = "Couldn't delete your account. \(Self.userMessage(for: error))"
            Log.app.error("account: delete failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        Log.app.info("account: deleted")
        cloud.tokens.clear()
        clearState(reason: "account deleted")
        if alsoEraseLocalData, let erase = Self.eraseLocalData {
            await erase()
            toast = "Your Navi account and this Mac's Navi data were deleted."
        } else {
            toast = "Your Navi account was deleted."
        }
        return true
    }

    // MARK: Recovery actions

    /// "Update": the built-in updater when it has (or can find) the release,
    /// else the download page the cloud named.
    func updateApp() {
        let updater = Updater.shared
        if updater.pending == nil, let url = downloadURL {
            NSWorkspace.shared.open(url)
        } else {
            updater.checkForUpdates(userInitiated: true)
        }
    }

    private var downloadURL: URL? {
        if case .upgradeRequired(_, let url?) = block { return url }
        return info?.config?.downloadURL
    }

    func contactSupport() {
        NSWorkspace.shared.open(NaviLinks.supportMail(subject: isAccountDisabled ? "My Navi account is disabled" : "Navi account", account: email))
    }

    /// Runs the button that goes with an error's message.
    func recover(_ recovery: NaviError.Recovery) {
        switch recovery {
        case .signIn: signIn()
        case .upgrade(let recall): openCheckout(plan: recall ? .proRecall : .pro, interval: .month)
        case .updateApp: updateApp()
        case .contactSupport: contactSupport()
        case .tryLater: break
        }
    }

    /// One plain sentence for an error from an account call: no status codes,
    /// no JSON, no vendor names.
    nonisolated static func userMessage(for error: Error) -> String {
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return "You're offline. Check your connection and try again."
            case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed:
                return "Navi couldn't be reached. Try again in a moment."
            default:
                return "Something went wrong. Try again."
            }
        }
        guard let e = error as? NaviError else { return "Something went wrong. Try again." }
        switch e {
        case .http(let status, let body):
            let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            // The cloud's own `message` is written for people; anything else (HTML, JSON, a stack) is not.
            if !text.isEmpty, text.count <= 200, !text.hasPrefix("{"), !text.hasPrefix("<"), text.contains(" ") {
                return text.hasSuffix(".") ? text : text + "."
            }
            return status >= 500 ? "Navi is having trouble right now. Try again in a moment." : "Something went wrong. Try again."
        case .decoding:
            return "Navi got a reply it didn't understand. Try again in a moment."
        default:
            return e.errorDescription ?? "Something went wrong. Try again."
        }
    }

    // MARK: Billing

    enum Plan: String, Sendable { case pro, proRecall = "pro_recall" }
    enum Interval: String, Sendable { case month, year }

    /// Stripe Checkout for a plan, in the browser. Signed out → sign in first.
    func openCheckout(plan: Plan, interval: Interval = .month) {
        guard isSignedIn else { signIn(); return }
        Task {
            do {
                let url = try await cloud.billingURL(path: "/billing/checkout",
                                                     json: ["plan": plan.rawValue, "interval": interval.rawValue])
                Log.app.info("account: checkout \(plan.rawValue, privacy: .public)/\(interval.rawValue, privacy: .public)")
                NSWorkspace.shared.open(url)
            } catch {
                lastError = "Couldn't open checkout. \(Self.userMessage(for: error))"
                Log.app.error("account: checkout failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Stripe Customer Portal (change plan, card, cancel).
    func openPortal() {
        guard isSignedIn else { signIn(); return }
        Task {
            do {
                let url = try await cloud.billingURL(path: "/billing/portal", json: [:])
                NSWorkspace.shared.open(url)
            } catch NaviError.http(400, _) {
                // `no_customer`: nothing bought yet, so there is no billing to manage.
                lastError = "There's no billing to manage yet — pick a plan first."
            } catch {
                lastError = "Couldn't open billing. \(Self.userMessage(for: error))"
                Log.app.error("account: portal failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Usage lines

    /// "12 of 20 answers today" / "Unlimited answers".
    var answersLine: String {
        if let cap = quotas.answersPerDay { return "\(usage.answersToday) of \(cap) answers today" }
        return "Unlimited answers"
    }

    var tasksLine: String {
        if let cap = quotas.tasksPerDay { return "\(usage.tasksToday) of \(cap) tasks today" }
        if let cap = quotas.tasksPerMonth { return "\(usage.tasksThisMonth) of \(cap) tasks this month" }
        return "Unlimited tasks"
    }
}
