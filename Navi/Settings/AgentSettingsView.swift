import SwiftUI

/// Settings → Agent: when Navi asks before acting, and whether it works
/// behind your windows. Engine tuning (driver, confidence threshold, fallback
/// budget, model) lives in the Developer section.
struct AgentSettingsView: View {
    @EnvironmentObject private var settings: NaviSettings

    var body: some View {
        FormPage(title: "Agent", subtitle: "\"Open Chrome, search for X and click the first result\" — Navi does it for you.") {
            Section {
                Picker("Ask me", selection: $settings.agentApprovalMode) {
                    ForEach(ApprovalMode.allCases) { Text(Self.label(for: $0)).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text(modeExplanation).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Approval")
            } footer: {
                Text("Whatever you choose, Navi never enters passwords or payment details and never touches security settings — it hands those back to you.")
            }

            Section {
                Toggle("Run tasks in the background", isOn: $settings.agentRunInBackground)
                Text(settings.agentRunInBackground
                     ? "Navi works in the app behind your windows: your cursor, keyboard and frontmost app stay yours. For keyboard shortcuts like ⌘S the app comes forward for a split second and focus comes straight back."
                     : "Navi brings the app to the front and uses the real cursor and keyboard. Best for drawing apps and menus; keep your hands off while it works.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Show the result when a task finishes", isOn: $settings.agentRevealWhenDone)
                    .disabled(!settings.agentRunInBackground)
                Text("When a background task makes something — a note, an event, a document, a tab — Navi brings that window to the front once it's done. Lookups stay in the background; their answer is in the panel.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("While it works")
            }

            Section("Limits") {
                Stepper(value: $settings.agentMaxSteps, in: 5...200, step: 5) {
                    LabeledContent("Maximum steps per task") {
                        Text("\(settings.agentMaxSteps)").monospacedDigit()
                    }
                }
                Toggle("Show the live overlay while Navi works", isOn: $settings.agentShowLiveOverlay)
            }
        }
    }

    /// Plain wording for the approval modes (the enum's own labels are engine-facing).
    static func label(for mode: ApprovalMode) -> String {
        switch mode {
        case .askForRisky: return "Ask before risky actions"
        case .alwaysAsk: return "Ask before every step"
        case .autonomous: return "Never ask"
        }
    }

    private var modeExplanation: String {
        switch settings.agentApprovalMode {
        case .alwaysAsk: return "Every click and keystroke waits for your OK. Slowest, safest."
        case .askForRisky: return "Navi pauses only before something hard to undo — sending, paying, deleting, posting."
        case .autonomous: return "No prompts. Passwords, payments and security settings are still off-limits."
        }
    }
}
