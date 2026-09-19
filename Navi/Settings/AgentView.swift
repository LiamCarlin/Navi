import SwiftUI

struct AgentView: View {
    @EnvironmentObject private var settings: NaviSettings

    var body: some View {
        FormPage(title: "Agent", subtitle: "\"Open Chrome, search for X and click the first result\" — Claude drives, Jev watches.") {
            Section("Approval") {
                Picker("Ask me", selection: $settings.agentApprovalMode) {
                    ForEach(ApprovalMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text(modeExplanation).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Limits") {
                Stepper(value: $settings.agentMaxSteps, in: 5...200, step: 5) {
                    LabeledContent("Maximum steps per task") {
                        Text("\(settings.agentMaxSteps)").monospacedDigit()
                    }
                }
                Toggle("Show the live overlay while the agent works", isOn: $settings.agentShowLiveOverlay)
                Picker("Model", selection: $settings.agentModel) {
                    ForEach(ProvidersView.claudeModels, id: \.self) { Text($0).tag($0) }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    gate("Irreversible", "send, pay, delete, post",
                         "After every step Jev answers `is_irreversible` from the step log. With \"Ask only for risky actions\" this is the only time you're interrupted.")
                    gate("Prohibited", "credentials, payments, security settings",
                         "Always refused, in every approval mode. Navi hands the task back to you instead.")
                    gate("Stuck", "same screen, no progress",
                         "`is_stuck` and `task_complete` stop the loop early so a confused run doesn't burn steps.")
                }
                .padding(.vertical, 2)
            } header: {
                Text("What Jev gates")
            } footer: {
                Text("Each gate is one System One call (~100 ms) on the textual step log — no extra screenshots, no extra Claude tokens.")
            }
        }
    }

    private var modeExplanation: String {
        switch settings.agentApprovalMode {
        case .alwaysAsk: return "Every click and keystroke waits for your OK. Slowest, safest."
        case .askForRisky: return "Jev flags irreversible actions (send, pay, delete) and Navi pauses only for those."
        case .autonomous: return "No prompts. Prohibited categories are still refused."
        }
    }

    private func gate(_ title: String, _ examples: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shield.lefthalf.filled").foregroundStyle(.tint).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    Text(examples).font(.caption).foregroundStyle(.secondary)
                }
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
