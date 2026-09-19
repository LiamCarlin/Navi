import AppKit
import ApplicationServices
import UserNotifications

/// Permission probes and requests. Every probe is cheap and non-prompting so
/// the UI can poll it; the `request*` calls trigger the system dialog once.
enum Permissions {
    enum State: Equatable {
        case granted, denied, notDetermined, unknown

        var level: StatusLevel {
            switch self {
            case .granted: return .ok
            case .denied: return .bad
            case .notDetermined: return .warn
            case .unknown: return .off
            }
        }
        var label: String {
            switch self {
            case .granted: return "Granted"
            case .denied: return "Denied"
            case .notDetermined: return "Not requested"
            case .unknown: return "Unknown"
            }
        }
    }

    enum Pane {
        case accessibility, screenRecording, automation, notifications, loginItems, keyboardShortcuts

        var url: String {
            switch self {
            case .accessibility: return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            case .screenRecording: return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            case .automation: return "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
            case .notifications: return "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
            case .loginItems: return "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
            case .keyboardShortcuts: return "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts"
            }
        }
    }

    static func openSettings(_ pane: Pane) { Opener.open(pane.url) }

    // MARK: Accessibility

    static var accessibility: State { AXIsProcessTrusted() ? .granted : .denied }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: Screen Recording

    static var screenRecording: State { ScreenCapture.hasPermission ? .granted : .denied }

    static func requestScreenRecording() { ScreenCapture.requestPermission() }

    // MARK: Automation (Apple Events → System Events)

    /// Non-prompting probe via `AEDeterminePermissionToAutomateTarget`.
    static var automation: State {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
        guard let desc = target.aeDesc else { return .unknown }
        let status = AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
        switch status {
        case noErr: return .granted
        case -1743: return .denied                 // errAEEventNotPermitted
        case -1744: return .notDetermined          // errAEEventWouldRequireUserConsent
        case -600: return .unknown                 // procNotFound (System Events not running)
        default: return .unknown
        }
    }

    /// Runs a trivial AppleScript against System Events, which triggers the
    /// consent prompt if needed. Returns the resulting state.
    @MainActor
    static func requestAutomation() -> State {
        guard let script = NSAppleScript(source: "tell application \"System Events\" to return name of first process") else {
            return .unknown
        }
        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        if let err {
            let code = (err[NSAppleScript.errorNumber] as? Int) ?? 0
            Log.settings.info("Automation test failed: \(code)")
            return code == -1743 ? .denied : .unknown
        }
        return result.stringValue != nil ? .granted : .unknown
    }

    // MARK: Notifications

    static func notifications() async -> State {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        switch s.authorizationStatus {
        case .authorized, .provisional: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    static func requestNotifications() async -> State {
        do {
            let ok = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            return ok ? .granted : .denied
        } catch {
            Log.settings.error("Notification auth failed: \(error.localizedDescription)")
            return .unknown
        }
    }
}

/// Observable snapshot of all permission states, polled while a view is visible.
@MainActor
final class PermissionsModel: ObservableObject {
    @Published var accessibility: Permissions.State = .unknown
    @Published var screenRecording: Permissions.State = .unknown
    @Published var automation: Permissions.State = .unknown
    @Published var notifications: Permissions.State = .unknown

    func refresh() async {
        accessibility = Permissions.accessibility
        screenRecording = Permissions.screenRecording
        automation = Permissions.automation
        notifications = await Permissions.notifications()
    }

    /// Poll every `interval` seconds until the task is cancelled (tie to `.task`).
    func poll(every interval: Double = 2) async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    var allGranted: Bool {
        accessibility == .granted && screenRecording == .granted && automation == .granted
    }
}
