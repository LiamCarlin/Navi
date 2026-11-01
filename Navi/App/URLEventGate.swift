import Foundation

/// What `AppDelegate` does with `navi://` URL events and Dock/Finder reopens.
///
/// Two launch-time races, kept pure so they can be tested with a fake clock:
/// - **Cold launch**: macOS delivers `application(_:open:)` for the URL that launched
///   Navi *before* `applicationDidFinishLaunching` has built the panel. URLs that
///   arrive early are queued and handed back once launch finishes (`finishLaunching`).
/// - **Reopen next to a URL**: `open navi://run?q=…` on a running Navi makes
///   LaunchServices send a reopen ('rapp') alongside the URL event, in either order.
///   That reopen is not the user asking for the main window — showing it covered the
///   screen and made Navi "the app Navi was invoked over" for a task run from a link.
///   A reopen within `window` of a URL event shows nothing; a plain Dock/Finder
///   reopen still opens the main window. The delegate decides after a short hop
///   (`reopenDecisionDelay`) so a URL that lands just after the reopen counts too.
struct URLEventGate {
    /// A reopen this close to a URL event (either side) belongs to that URL.
    static let window: TimeInterval = 1.0
    /// How long the delegate waits before asking `reopenShowsMainWindow`.
    static let reopenDecisionDelay: TimeInterval = 0.2

    private let now: () -> Date
    private(set) var didFinishLaunching = false
    private(set) var pending: [URL] = []
    private(set) var lastURLEvent: Date?

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// A URL event arrived. Returns the URLs to handle now — none while still
    /// launching (they wait for `finishLaunching`).
    mutating func receive(_ urls: [URL]) -> [URL] {
        lastURLEvent = now()
        guard didFinishLaunching else {
            pending += urls
            return []
        }
        return urls
    }

    /// Launch finished: from now on URLs are handled as they come. Returns the
    /// ones that arrived early, in order.
    mutating func finishLaunching() -> [URL] {
        didFinishLaunching = true
        defer { pending = [] }
        return pending
    }

    /// The time to stamp a reopen with (pass it back to `reopenShowsMainWindow`).
    func timestamp() -> Date { now() }

    /// Should the reopen that arrived at `reopenedAt` open the main window? Asked
    /// `reopenDecisionDelay` later; not when a URL event came within `window` of it.
    func reopenShowsMainWindow(reopenedAt: Date) -> Bool {
        guard let last = lastURLEvent else { return true }
        return abs(last.timeIntervalSince(reopenedAt)) > Self.window
    }
}
