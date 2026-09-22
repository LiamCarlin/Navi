import SwiftUI
import AppKit

/// Settings → Account: who is signed in, the plan, usage against the plan's
/// caps, and the billing actions (Stripe Checkout / Customer Portal).
struct AccountView: View {
    @EnvironmentObject private var settings: NaviSettings
    @ObservedObject private var account = NaviAccount.shared

    var body: some View {
        FormPage(title: "Account", subtitle: "One account, one subscription. No API keys.") {
            if let toast = account.toast {
                Section {
                    Label(toast, systemImage: "party.popper.fill").foregroundStyle(.tint)
                        .onAppear {
                            Task { try? await Task.sleep(for: .seconds(6)); if account.toast == toast { account.toast = nil } }
                        }
                }
            }

            if account.isSignedIn {
                signedIn
            } else {
                signedOut
            }

            if let err = account.lastError {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }

            if NaviSettings.developerMode || !settings.useCloud {
                Section("Developer") {
                    Toggle(isOn: $settings.useCloud) {
                        ExplainedRow(title: "Use Navi Cloud",
                                     explanation: settings.useCloud ? "Calls go through your account." : "Off: the keys under AI Providers are used directly and nothing is metered.") { EmptyView() }
                    }
                    .toggleStyle(.switch)
                    HStack {
                        Text("Cloud URL")
                        Spacer()
                        TextField("https://api.navi.app", text: $settings.cloudBaseURL)
                            .textFieldStyle(.roundedBorder).frame(width: 280)
                            .font(.callout.monospaced())
                    }
                }
            }
        }
    }

    // MARK: Signed out

    @ViewBuilder private var signedOut: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    NaviMark(size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sign in to Navi").font(.headline)
                        Text("Answers, tasks and voice control need an account. 7-day free trial of Pro, no card to start.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        account.signIn()
                    } label: {
                        Label(account.isSigningIn ? "Waiting for your browser…" : "Sign in with your browser", systemImage: "safari")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.glassProminent).controlSize(.large)
                    if account.isSigningIn { ProgressView().controlSize(.small) }
                }
            }
            .padding(.vertical, 6)
        }
        if account.hasDeveloperKeys {
            Section {
                Label("Developer mode: your own keys are in use and every feature is on. Sign in to switch to your Navi plan.",
                      systemImage: "hammer")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Signed in

    @ViewBuilder private var signedIn: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 34)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.email ?? "Signed in").font(.headline)
                    Text(refreshLine).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { Task { await account.refreshMe(reason: "manual") } }
                    .controlSize(.small).disabled(account.isRefreshing)
                Button("Sign out") { account.signOut() }.controlSize(.small)
            }
        }

        Section("Plan") {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.planLabel).font(.title3.weight(.semibold))
                    Text(account.trialDaysLeft != nil
                         ? "\(account.tier.summary) After the trial, keep Pro for $20/mo or drop to Free."
                         : account.tier.summary)
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 2)

            HStack(spacing: 10) {
                if account.tier == .free || account.trialDaysLeft != nil {
                    Button(account.tier == .free ? "Upgrade to Pro · $20/mo" : "Keep Pro · $20/mo") { account.openCheckout(plan: .pro, interval: .month) }
                        .buttonStyle(.borderedProminent)
                    Button("Pro yearly · $192") { account.openCheckout(plan: .pro, interval: .year) }
                }
                if account.tier == .free {
                    Button("Pro + Recall · $30/mo") { account.openCheckout(plan: .proRecall, interval: .month) }
                        .buttonStyle(.bordered)
                } else if account.tier == .pro {
                    Button("Add Recall · $10/mo more") { account.openCheckout(plan: .proRecall, interval: .month) }
                        .buttonStyle(.borderedProminent)
                }
                Spacer()
                Button("Manage billing…") { account.openPortal() }
            }
            .controlSize(.regular)
        }

        Section("Usage") {
            usageRow(title: "Answers", used: account.usage.answersToday, cap: account.quotas.answersPerDay, period: "today")
            if let cap = account.quotas.tasksPerDay {
                usageRow(title: "Tasks", used: account.usage.tasksToday, cap: cap, period: "today")
            } else {
                usageRow(title: "Tasks", used: account.usage.tasksThisMonth, cap: account.quotas.tasksPerMonth, period: "this month")
            }
            featureRow("Voice control", on: account.entitlements.voice)
            featureRow("Recall (screen memory)", on: account.entitlements.recall)
            if let r = account.usage.resetsAt {
                Text("Counters reset \(r.formatted(date: .abbreviated, time: .shortened)).").font(.caption).foregroundStyle(.tertiary)
            }
        }

        if !account.entitlements.recall {
            Section {
                UpgradeCard.recall(account: account)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    private var refreshLine: String {
        if account.isRefreshing { return "Refreshing…" }
        if let t = account.lastRefreshAt { return "Updated \(t.relativeDescription)" }
        return "Not refreshed yet"
    }

    private func usageRow(title: String, used: Int, cap: Int?, period: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(cap.map { "\(used) of \($0) \(period)" } ?? "\(used) \(period) · unlimited")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            if let cap, cap > 0 {
                ProgressView(value: Double(min(used, cap)), total: Double(cap))
                    .tint(used >= cap ? .orange : .accentColor)
            }
        }
        .padding(.vertical, 2)
    }

    private func featureRow(_ title: String, on: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Label(on ? "Included" : "Not in plan", systemImage: on ? "checkmark.circle.fill" : "lock.fill")
                .font(.callout).foregroundStyle(on ? Color.green : Color.secondary)
        }
    }
}
