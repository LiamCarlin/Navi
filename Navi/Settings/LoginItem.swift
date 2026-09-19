import Foundation
import ServiceManagement

/// Launch-at-login via `SMAppService` (macOS 13+). The user can also toggle
/// this in System Settings → General → Login Items; `status` reflects both.
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    static var requiresApproval: Bool { status == .requiresApproval }

    static func set(enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        Log.settings.info("Login item \(enabled ? "registered" : "unregistered"); status=\(status.rawValue)")
    }

    static func describe(_ s: SMAppService.Status) -> String {
        switch s {
        case .enabled: return "Navi starts when you log in"
        case .requiresApproval: return "Waiting for approval in System Settings → Login Items"
        case .notRegistered: return "Navi will not start automatically"
        case .notFound: return "Not available for this build (run from /Applications)"
        @unknown default: return "Unknown"
        }
    }

    static func level(_ s: SMAppService.Status) -> StatusLevel {
        switch s {
        case .enabled: return .ok
        case .requiresApproval: return .warn
        default: return .off
        }
    }

    static func openSettings() { Permissions.openSettings(.loginItems) }
}
