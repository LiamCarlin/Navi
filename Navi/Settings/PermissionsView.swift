import SwiftUI
import AppKit

struct PermissionsView: View {
    var body: some View {
        FormPage(title: "Permissions", subtitle: "Navi asks only for what a feature needs.") {
            Section {
                PermissionsList()
            } footer: {
                Text("Turned a permission on in System Settings but Navi still says it's off? Quit and reopen Navi — macOS applies Accessibility and Screen Recording when an app starts.")
            }
        }
    }
}

/// The four permission rows; reused by Onboarding.
struct PermissionsList: View {
    @StateObject private var model = PermissionsModel()

    var body: some View {
        PermissionRow(title: "Accessibility",
                      explanation: "Lets Navi click, type and read window titles in other apps when it does a task for you.",
                      state: model.accessibility,
                      request: { Permissions.requestAccessibility() },
                      open: { Permissions.openSettings(.accessibility) })
            .task { await model.poll() }
        PermissionRow(title: "Screen Recording",
                      explanation: "Lets Navi see the screen during tasks, and Recall take snapshots.",
                      state: model.screenRecording,
                      request: { Permissions.requestScreenRecording() },
                      open: { Permissions.openSettings(.screenRecording) })
        PermissionRow(title: "Automation",
                      explanation: "Lets Navi read the current browser tab and control Finder, Safari and Chrome.",
                      state: model.automation,
                      request: { _ = Permissions.requestAutomation() },
                      open: { Permissions.openSettings(.automation) })
        PermissionRow(title: "Microphone",
                      explanation: "Lets voice control hear you. Speech is transcribed on this Mac; audio never leaves it.",
                      state: model.microphone,
                      request: { Task { _ = await Permissions.requestMicrophone(); await model.refresh() } },
                      open: { Permissions.openSettings(.microphone) })
        PermissionRow(title: "Notifications",
                      explanation: "Tells you when a task running in the background finishes.",
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
            if state == .notDetermined || state == .unknown {
                Button("Allow…", action: request).controlSize(.small)
            } else if state != .granted {
                Button("Open System Settings…", action: open).controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }
}
