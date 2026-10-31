import Foundation

/// Hidden developer switch. On: the Developer section appears in the Navi
/// window (keys, models, agent tuning, token usage, browser runtime).
/// Off (the default): everything the user sees is Navi.
///
/// The panel, the voice island and the run pill stay Navi even in developer
/// mode: engine diagnostics there (model names, confidences, latencies, the
/// driver's status chatter) need `showsEngineDetails` as well — a separate
/// switch in Settings → Developer, off by default.
///
/// Toggle with `defaults write com.liamcarlin.navi developerMode -bool YES`
/// or ⌥-click the version on the About page.
enum DeveloperMode {
    static let defaultsKey = "developerMode"

    static var isEnabled: Bool {
        get { UserDefaults.navi.bool(forKey: defaultsKey) }
        set {
            UserDefaults.navi.set(newValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: .naviDeveloperModeChanged, object: nil)
        }
    }

    static let engineDetailsKey = "developerShowsEngineDetails"

    /// Engine diagnostics in the panel, island and pill: only in developer mode, and only when asked for.
    static var showsEngineDetails: Bool {
        get { isEnabled && UserDefaults.navi.bool(forKey: engineDetailsKey) }
        set { UserDefaults.navi.set(newValue, forKey: engineDetailsKey) }
    }
}

extension Notification.Name {
    /// Posted after `DeveloperMode.isEnabled` changes so sidebars can re-list their sections.
    static let naviDeveloperModeChanged = Notification.Name("navi.developerModeChanged")
}
