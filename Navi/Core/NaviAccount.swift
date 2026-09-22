import Foundation
import AppKit
import Combine

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
/// Developer mode: with `useCloud` off, or signed out but with vendor keys in
/// the Keychain, the app talks to the vendors directly and every feature is
/// entitled locally — there is nothing to meter.
@MainActor
final class NaviAccount: ObservableObject {
    static let shared = NaviAccount()

    let cloud: CloudTransport

    @Published private(set) var isSignedIn = false
    @Published private(set) var info: AccountInfo?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSigningIn = false
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var lastError: String?
    /// One-line notice for the UI ("Welcome to Pro"). Cleared by the view that shows it.
    @Published var toast: String?

    static let snapshotKey = "naviAccountInfo"
    static let refreshInterval: TimeInterval = 10 * 60

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(cloud: CloudTransport = .shared) {
        self.cloud = cloud
        isSignedIn = cloud.isSignedIn
        if let data = UserDefaults.standard.data(forKey: Self.snapshotKey), let cached = try? AccountInfo.decode(data) {
            info = cached
        }
    }

    // MARK: Derived

    var email: String? { info?.user.email }
    var tier: Tier { usesCloud ? (info?.tier ?? .free) : .free }
    var quotas: Quotas { info?.quotas ?? Quotas() }
    var usage: Usage { info?.usage ?? Usage() }
    var trialEndsAt: Date? { info?.trialEndsAt }
    var trialDaysLeft: Int? { info?.trialDaysLeft() }

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
                if (note.userInfo?["signedOut"] as? Bool) == true { self.clearState(reason: "session expired") }
            }
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

    // MARK: Sign-in

    /// Opens the hosted sign-in page; the app resumes in `handle(url:)`.
    func signIn() {
        isSigningIn = true
        lastError = nil
        var comps = URLComponents(url: cloud.url("/auth/start"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "redirect", value: "navi")]
        guard let url = comps.url else { return }
        Log.app.info("account: opening sign-in")
        NSWorkspace.shared.open(url)
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
            guard path == "callback" || path.isEmpty else { return false }
            if let err = query("error") {
                isSigningIn = false
                lastError = "Sign-in failed: \(err)"
                Log.app.error("account: sign-in callback error \(err, privacy: .public)")
                return true
            }
            guard let code = query("code"), !code.isEmpty else {
                isSigningIn = false
                lastError = "Sign-in failed: the callback carried no code."
                return true
            }
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

    private func completeSignIn(code: String) async {
        do {
            try await cloud.exchange(code: code)
            isSignedIn = true
            isSigningIn = false
            lastError = nil
            NotificationCenter.default.post(name: .naviAccountChanged, object: nil)
            await refreshMe(reason: "sign-in")
            bringWindowForward()
        } catch {
            isSigningIn = false
            lastError = "Sign-in failed: \(error.localizedDescription)"
            Log.app.error("account: exchange failed: \(error.localizedDescription, privacy: .public)")
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
        defer { isRefreshing = false }
        do {
            let me = try await cloud.me()
            let changed = me != info
            info = me
            lastRefreshAt = Date()
            lastError = nil
            if let data = try? JSONEncoder().encode(me) { UserDefaults.standard.set(data, forKey: Self.snapshotKey) }
            Log.app.info("account: /v1/me ok (\(reason, privacy: .public)) tier=\(me.tier.rawValue, privacy: .public) recall=\(me.entitlements.recall) answers=\(me.usage.answersToday)/\(me.quotas.answersPerDay.map(String.init) ?? "∞", privacy: .public)")
            if changed { NotificationCenter.default.post(name: .naviAccountChanged, object: nil) }
        } catch NaviError.signedOut {
            clearState(reason: "session expired")
        } catch {
            lastError = error.localizedDescription
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
        isSignedIn = false
        isSigningIn = false
        info = nil
        lastRefreshAt = nil
        UserDefaults.standard.removeObject(forKey: Self.snapshotKey)
        Log.app.info("account: cleared (\(reason, privacy: .public))")
        NotificationCenter.default.post(name: .naviAccountChanged, object: nil)
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
                lastError = "Couldn't open checkout: \(error.localizedDescription)"
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
            } catch {
                lastError = "Couldn't open billing: \(error.localizedDescription)"
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
