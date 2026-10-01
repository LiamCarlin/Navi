import SwiftUI
import AppKit

/// Settings → Account: who is signed in, the plan, usage against the plan's
/// caps, the billing actions (checkout / customer portal), your data (export,
/// delete) and the legal links. Nothing here names a vendor outside the
/// Developer section.
struct AccountView: View {
    @EnvironmentObject private var settings: NaviSettings
    @ObservedObject private var account = NaviAccount.shared
    @State private var showDeleteSheet = false
    @State private var confirmDelete = false
    @State private var eraseLocalData = false

    var body: some View {
        FormPage(title: "Account", subtitle: "One account, one subscription. No API keys.") {
            if let toast = account.toast {
                Section {
                    Label(toast, systemImage: "checkmark.circle.fill").foregroundStyle(.tint)
                        .onAppear {
                            Task { try? await Task.sleep(for: .seconds(6)); if account.toast == toast { account.toast = nil } }
                        }
                }
            }

            if account.isSignedIn {
                blockSection
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

            if account.isSignedIn {
                dataSection
            }

            linksSection

            if NaviSettings.developerMode || !settings.useCloud {
                Section("Developer") {
                    Toggle(isOn: $settings.useCloud) {
                        ExplainedRow(title: "Use Navi Cloud",
                                     explanation: settings.useCloud ? "Calls go through your account." : "Off: the keys under Developer are used directly and nothing is metered.") { EmptyView() }
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
        .sheet(isPresented: $showDeleteSheet) {
            DeleteAccountSheet(email: account.email ?? "your account",
                               canEraseLocalData: account.canEraseLocalData,
                               eraseLocalData: $eraseLocalData,
                               cancel: { showDeleteSheet = false },
                               proceed: { showDeleteSheet = false; confirmDelete = true })
        }
        .alert("Delete \(account.email ?? "your account") for good?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete account", role: .destructive) {
                let erase = eraseLocalData
                Task { await account.deleteAccount(alsoEraseLocalData: erase) }
            }
        } message: {
            Text("Your subscription ends and your Navi account and its data are erased. This can't be undone.")
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
                        Text("Answers, tasks and voice control run on your Navi account. Apps, files, math and system commands work without one. 7-day free trial of Pro, no card to start.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                SignInButton(account: account)
            }
            .padding(.vertical, 6)
        }
        if account.hasDeveloperKeys {
            Section {
                Label("Developer mode: your own keys are in use and every feature is on. Sign in to switch to your Navi plan.",
                      systemImage: "hammer")
                    .font(.callout).foregroundStyle(.secondary)
                LocalUsageRow()
            }
        }
    }

    // MARK: Blocked (update required / account disabled)

    @ViewBuilder private var blockSection: some View {
        if account.isAccountDisabled {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Your account is disabled", systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.headline).foregroundStyle(.orange)
                    Text(NaviError.accountDisabled(message: blockMessage).errorDescription ?? "")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Answers, tasks and voice control are paused until it's sorted out. Apps, files and math keep working, and you can still export or delete your data below.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Contact support") { account.contactSupport() }.buttonStyle(.borderedProminent)
                        Button("Check again") { Task { await account.refreshMe(reason: "manual") } }
                            .disabled(account.isRefreshing)
                    }
                }
                .padding(.vertical, 4)
            }
        } else if account.isUpdateRequired {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 26)).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Update Navi to keep using it").font(.headline)
                        Text("This version is no longer supported for answers, tasks and voice control.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Update") { account.updateApp() }.buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 4)
            }
        } else if account.isUpdateAvailable {
            Section {
                HStack {
                    Label("A new version of Navi is available.", systemImage: "arrow.down.circle")
                        .font(.callout)
                    Spacer()
                    Button("Update") { account.updateApp() }.controlSize(.small)
                }
            }
        }
    }

    private var blockMessage: String? {
        if case .accountDisabled(let m) = account.block { return m }
        return nil
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

            if let days = account.trialDaysLeft, let ends = account.trialEndsAt {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(max(0, 7 - days)), total: 7)
                        .tint(days <= 2 ? .orange : .accentColor)
                    Text("Trial ends \(ends.formatted(date: .abbreviated, time: .omitted)) — \(days) day\(days == 1 ? "" : "s") left.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

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
            .disabled(account.isAccountDisabled)
        }

        Section("Usage") {
            usageRow(title: "Answers", used: account.usage.answersToday, cap: account.quotas.answersPerDay, period: "today",
                     available: account.isAvailable(.answer))
            if let cap = account.quotas.tasksPerDay {
                usageRow(title: "Tasks", used: account.usage.tasksToday, cap: cap, period: "today", available: account.isAvailable(.task))
            } else {
                usageRow(title: "Tasks", used: account.usage.tasksThisMonth, cap: account.quotas.tasksPerMonth, period: "this month",
                         available: account.isAvailable(.task))
            }
            LocalUsageRow()
            featureRow("Voice control", on: account.entitlements.voice, available: account.isAvailable(.voice))
            featureRow("Recall", on: account.entitlements.recall, available: account.isAvailable(.recallDigest))
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

    // MARK: Your data

    @ViewBuilder private var dataSection: some View {
        Section {
            ExplainedRow(title: "Export my data",
                         explanation: "Your account, plan and usage history as a JSON file.") {
                Button {
                    account.exportData()
                } label: {
                    if account.isExporting { ProgressView().controlSize(.small) } else { Text("Export…") }
                }
                .disabled(account.isExporting)
            }
            ExplainedRow(title: "Delete account",
                         explanation: "Ends your subscription and erases your Navi account. Can't be undone.") {
                Button(role: .destructive) {
                    eraseLocalData = false
                    showDeleteSheet = true
                } label: {
                    if account.isDeleting { ProgressView().controlSize(.small) } else { Text("Delete account…") }
                }
                .disabled(account.isDeleting)
            }
        } header: {
            Text("Your data")
        }
    }

    private var linksSection: some View {
        Section {
            HStack(spacing: 16) {
                LinkPill(title: "Privacy policy", url: NaviLinks.privacy.absoluteString)
                LinkPill(title: "Terms of service", url: NaviLinks.terms.absoluteString)
                Spacer()
                Button {
                    account.contactSupport()
                } label: {
                    HStack(spacing: 4) { Text("Contact support"); Image(systemName: "envelope").font(.caption2) }
                }
                .buttonStyle(.link)
            }
            .font(.callout)
        }
    }

    // MARK: Rows

    private var refreshLine: String {
        if account.isRefreshing { return "Refreshing…" }
        if let t = account.lastRefreshAt { return "Updated \(t.relativeDescription)" }
        return "Not refreshed yet"
    }

    private func usageRow(title: String, used: Int, cap: Int?, period: String, available: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                if !available {
                    Label("Temporarily unavailable", systemImage: "pause.circle").font(.callout).foregroundStyle(.orange)
                } else {
                    Text(cap.map { "\(used) of \($0) \(period)" } ?? "\(used) \(period) · unlimited")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let cap, cap > 0 {
                ProgressView(value: Double(min(used, cap)), total: Double(cap))
                    .tint(used >= cap ? .orange : .accentColor)
            }
        }
        .padding(.vertical, 2)
    }

    private func featureRow(_ title: String, on: Bool, available: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            if on && !available {
                Label("Temporarily unavailable", systemImage: "pause.circle").font(.callout).foregroundStyle(.orange)
            } else {
                Label(on ? "Included" : "Not in plan", systemImage: on ? "checkmark.circle.fill" : "lock.fill")
                    .font(.callout).foregroundStyle(on ? Color.green : Color.secondary)
            }
        }
    }
}

/// "Sign in with your browser", and while the browser round trip is out:
/// "Waiting for your browser…" with a way to start over.
struct SignInButton: View {
    @ObservedObject var account: NaviAccount
    var large = true

    var body: some View {
        HStack(spacing: 10) {
            Button {
                account.signIn()
            } label: {
                Label(account.isSigningIn ? "Waiting for your browser…" : "Sign in with your browser", systemImage: "safari")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(large ? .large : .regular)
            if account.isSigningIn {
                ProgressView().controlSize(.small)
                Button("Cancel") { account.cancelSignIn() }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
    }
}

/// Step one of deleting the account: what happens, and (when the privacy
/// hook exists) whether to erase this Mac's data too. Step two is an alert.
private struct DeleteAccountSheet: View {
    let email: String
    let canEraseLocalData: Bool
    @Binding var eraseLocalData: Bool
    let cancel: () -> Void
    let proceed: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Delete your Navi account?", systemImage: "trash").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                bullet("Your subscription is cancelled; no further charges.")
                bullet("Your account (\(email)), plan and usage history are erased from Navi's servers.")
                bullet("This Mac signs out. Apps, files and math keep working without an account.")
            }
            if canEraseLocalData {
                Toggle("Also erase Navi's data on this Mac (Recall, journal, history)", isOn: $eraseLocalData)
            } else {
                Text("What Recall saved on this Mac stays here; you can clear it under Recall.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Want a copy first? Use Export my data before you continue.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Continue…", role: .destructive, action: proceed)
            }
        }
        .padding(22)
        .frame(width: 440)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}
