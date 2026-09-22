import Foundation

/// Hidden developer switch. On: the Developer section appears in the Navi
/// window (keys, models, agent tuning, token usage, browser runtime) and the
/// ⌘Space panel shows routing diagnostics (confidence, latency, transport).
/// Off (the default): everything the user sees is Navi.
///
/// Toggle with `defaults write com.liamcarlin.navi developerMode -bool YES`
/// or ⌥-click the version on the About page.
enum DeveloperMode {
    static let defaultsKey = "developerMode"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: .naviDeveloperModeChanged, object: nil)
        }
    }
}

extension Notification.Name {
    /// Posted after `DeveloperMode.isEnabled` changes so sidebars can re-list their sections.
    static let naviDeveloperModeChanged = Notification.Name("navi.developerModeChanged")
}
