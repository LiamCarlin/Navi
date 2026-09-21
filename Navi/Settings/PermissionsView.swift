import SwiftUI
import AppKit

struct PermissionsView: View {
    var body: some View {
        FormPage(title: "Permissions", subtitle: "Navi asks only for what a feature needs. Status refreshes every two seconds.") {
            Section {
                PermissionsList()
            } footer: {
                Text("If a toggle in System Settings is on but Navi still shows Denied, quit and relaunch Navi — macOS applies Accessibility and Screen Recording grants at launch.")
            }
        }
    }
}

/// The four permission rows; reused by Onboarding.
struct PermissionsList: View {
    @StateObject private var model = PermissionsModel()

    var body: some View {
        PermissionRow(title: "Accessibility",
                      explanation: "Lets the agent click, type and read window titles in other apps.",
                      state: model.accessibility,
                      request: { Permissions.requestAccessibility() },
                      open: { Permissions.openSettings(.accessibility) })
            .task { await model.poll() }
        PermissionRow(title: "Screen Recording",
                      explanation: "Lets the agent see the screen and Screen Memory take snapshots.",
                      state: model.screenRecording,
                      request: { Permissions.requestScreenRecording() },
                      open: { Permissions.openSettings(.screenRecording) })
        PermissionRow(title: "Automation (Apple Events)",
                      explanation: "Lets Navi read the current browser tab and drive Finder, Safari and Chrome.",
                      state: model.automation,
                      request: { _ = Permissions.requestAutomation() },
                      open: { Permissions.openSettings(.automation) })
        PermissionRow(title: "Microphone",
                      explanation: "Lets voice control hear you. Speech is transcribed on this Mac; audio never leaves it.",
                      state: model.microphone,
                      request: { Task { _ = await Permissions.requestMicrophone(); await model.refresh() } },
                      open: { Permissions.openSettings(.microphone) })
        PermissionRow(title: "Notifications",
                      explanation: "Tells you when a background task or long agent run finishes.",
                      state: model.notifications,
                      request: { Task { _ = await Permissions.requestNotifications(); await model.refresh() } },
                      open: { Permissions.openSettings(.notifications) })
    }
}

struct PermissionRow: View {
    let title: String
    let explanation: String
    let state: Permissions.State
    let request: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            StatusDot(level: state.level)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title)
                    Text(state.label).font(.caption).foregroundStyle(.secondary)
                }
                Text(explanation).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if state != .granted {
                Button("Request", action: request).controlSize(.small)
                Button("Open Settings", action: open).controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }
}
