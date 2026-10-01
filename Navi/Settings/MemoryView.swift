import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MemoryView: View {
    @EnvironmentObject private var settings: NaviSettings
    @ObservedObject private var account = NaviAccount.shared
    @State private var status = MemoryStatus()
    @State private var digesting = false
    @State private var newBundleID = ""
    @State private var cleanupPlan: PersonalDataCleanup.Plan?
    @State private var cleanupBusy = false
    @State private var cleanupMessage: String?

    private var memory: MemoryServicing? { AppDelegate.shared?.services.memory }
    /// Recall gate (account workstream): the toggle is replaced by the upsell without the entitlement.
    private var entitled: Bool { account.entitlements.recall }

    var body: some View {
        FormPage(title: "Recall", subtitle: "A private journal of what you do on your Mac, so you can ask \u{201C}what was I doing yesterday?\u{201D}") {
            if entitled {
                Section {
                    Toggle(isOn: $settings.memoryCaptureEnabled) {
                        ExplainedRow(title: "Remember what I see", explanation: settings.memoryCaptureEnabled ? "Navi takes a snapshot of your screen every so often and writes what mattered into your journal." : "Off. Nothing is captured.") { EmptyView() }
                    }
                    .toggleStyle(.switch)
                    if settings.memoryCaptureEnabled {
                        pauseRow
                    }
                }
            } else {
                Section {
                    UpgradeCard.recall(account: account)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if entitled {
                Section("Status") {
                    statusGrid
                    HStack {
                        Button {
                            Task { await digestNow() }
                        } label: {
                            if digesting { ProgressView().controlSize(.small).frame(width: 70) } else { Text("Summarize now") }
                        }
                        .disabled(digesting || memory == nil)
                        Spacer()
                        if let err = status.lastError {
                            Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                                .lineLimit(2).textSelection(.enabled)
                        }
                    }
                }

                Section("Capture") {
                    Picker("Snapshot every", selection: $settings.memoryCaptureIntervalSeconds) {
                        Text("15 s").tag(15); Text("30 s").tag(30); Text("60 s").tag(60); Text("2 min").tag(120)
                    }
                    Picker("Summarize every", selection: $settings.memoryDigestIntervalMinutes) {
                        Text("5 min").tag(5); Text("10 min").tag(10); Text("30 min").tag(30)
                    }
                    Picker("Keep snapshots for", selection: $settings.memoryRetentionDays) {
                        Text("7 days").tag(7); Text("14 days").tag(14); Text("30 days").tag(30); Text("90 days").tag(90)
                    }
                    Toggle("Keep screenshots, not just their text", isOn: $settings.memoryKeepScreenshots)
                }

                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(displayPath(settings.memoryVaultPath)).font(.callout).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…", action: chooseVault).controlSize(.small)
                    }
                    HStack(spacing: 8) {
                        Button("Open in Obsidian", action: openInObsidian)
                        Button("Show in Finder") { revealVault() }
                        Spacer()
                    }
                } header: {
                    Text("Journal")
                } footer: {
                    Text("Your journal is a folder of linked Markdown notes — open it in Obsidian to browse it as a graph.")
                }

                Section {
                    ForEach(settings.memoryExcludedBundleIDs, id: \.self) { bid in
                        HStack {
                            AppIconView(bundleID: bid)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(appName(for: bid))
                                Text(bid).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                settings.memoryExcludedBundleIDs.removeAll { $0 == bid }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 8) {
                        Button("Add App…", action: chooseApp)
                        TextField("or a bundle ID, e.g. com.apple.Passwords", text: $newBundleID)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addTypedBundleID)
                        Button("Add", action: addTypedBundleID).disabled(newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Never capture these apps")
                } footer: {
                    Text("Navi never looks at these apps. It also skips any screen it judges sensitive — passwords, one-time codes and the personal information you block below.")
                }

                personalDataSection

                Section {
                    Label {
                        Text("Snapshots and their text stay on this Mac (in ~/Library/Application Support/Navi); summaries go to your journal folder. To decide what matters and to write summaries, screen text — and for summaries, the screenshot — is sent to Navi's AI models. Only the summary is kept in your journal.")
                            .font(.callout).foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                if let m = memory { status = m.status }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Pieces

    /// Settings → Recall → Personal information: one switch per category (on = Navi may keep it).
    @ViewBuilder private var personalDataSection: some View {
        Section {
            ForEach(PersonalData.Category.allCases) { c in
                Toggle(isOn: Binding(get: { settings.allowsPersonalData(c) },
                                     set: { settings.setPersonalData(c, allowed: $0) })) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: c.symbol).foregroundStyle(.secondary).frame(width: 18)
                        ExplainedRow(title: c.title, explanation: c.detail) { EmptyView() }
                    }
                }
                .toggleStyle(.switch)
            }
            HStack(spacing: 8) {
                Button("Allow all") { for c in PersonalData.Category.allCases { settings.setPersonalData(c, allowed: true) } }
                Button("Block all") { for c in PersonalData.Category.allCases { settings.setPersonalData(c, allowed: false) } }
                Button("Defaults") {
                    for c in PersonalData.Category.allCases { settings.setPersonalData(c, allowed: PersonalData.Category.allowedByDefault.contains(c)) }
                }
                Spacer()
                if cleanupBusy { ProgressView().controlSize(.small) }
                Button("Remove Blocked Details Already Saved…") { Task { await planCleanup() } }
                    .disabled(cleanupBusy || settings.personalDataPolicy.blocked.isEmpty || memory as? MemoryService == nil)
            }
            .controlSize(.small)
            if let cleanupMessage {
                Text(cleanupMessage).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Personal information Navi may remember")
        } footer: {
            Text("On: Navi may keep it in your journal. Off: Navi keeps only the app and the time of that screen and leaves the detail out of summaries — it is removed on this Mac before anything is sent for summarizing. Passwords and one-time codes are never kept.")
        }
        .confirmationDialog(cleanupTitle, isPresented: Binding(get: { cleanupPlan != nil }, set: { if !$0 { cleanupPlan = nil } })) {
            Button("Redact", role: .destructive) { Task { await applyCleanup() } }
            Button("Cancel", role: .cancel) { cleanupPlan = nil }
        } message: {
            Text("Matching snapshots keep only the app and time; summaries, key facts, links and screenshots in your journal are rewritten. This can't be undone.")
        }
    }

    private var cleanupTitle: String {
        guard let p = cleanupPlan else { return "" }
        return "Redact \(p.sessions.count) of \(p.sessionsScanned) summaries and \(p.frameIDs.count) snapshots?"
    }

    private func planCleanup() async {
        guard let service = memory as? MemoryService else { return }
        cleanupBusy = true; cleanupMessage = nil
        defer { cleanupBusy = false }
        do {
            let plan = try await service.planPersonalDataCleanup()
            if plan.sessions.isEmpty && plan.frameIDs.isEmpty {
                cleanupMessage = "Nothing saved contains the details you block."
            } else {
                cleanupPlan = plan
            }
        } catch {
            cleanupMessage = error.localizedDescription
        }
    }

    private func applyCleanup() async {
        guard let service = memory as? MemoryService, let plan = cleanupPlan else { return }
        cleanupPlan = nil
        cleanupBusy = true
        defer { cleanupBusy = false }
        do {
            let r = try await service.applyPersonalDataCleanup(plan)
            cleanupMessage = "Redacted \(r.sessionsRedacted) summaries and \(r.framesRedacted) snapshots; removed \(r.attachmentsDeleted) screenshots."
        } catch {
            cleanupMessage = "Cleanup failed: \(error.localizedDescription)"
        }
    }

    @ViewBuilder private var pauseRow: some View {
        HStack(spacing: 8) {
            if settings.memoryIsPaused, let until = settings.memoryPausedUntil {
                StatusDot(level: .warn)
                Text("Paused until \(until.formatted(date: .omitted, time: .shortened))")
                Spacer()
                Button("Resume") { settings.memoryPausedUntil = nil }
            } else {
                StatusDot(level: status.isRunning ? .ok : .warn)
                Text(status.isRunning ? "Capturing" : "Not running yet — Recall needs Screen Recording")
                if !status.isRunning {
                    Button("Permissions") { SettingsNavigator.shared.go(.permissions) }.buttonStyle(.link)
                }
                Spacer()
                Button("Pause 1 hour") { settings.memoryPausedUntil = Date().addingTimeInterval(3600) }
                Button("Pause until tomorrow") {
                    settings.memoryPausedUntil = Calendar.current.startOfDay(for: Date().addingTimeInterval(86400))
                }
            }
        }
        .controlSize(.small)
    }

    private var statusGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
            GridRow {
                stat("Snapshots today", "\(status.framesToday)", nil)
                stat("Last snapshot", status.lastCaptureAt?.relativeDescription ?? "—", nil)
                stat("Journal notes", "\(status.vaultNoteCount)", nil)
            }
            GridRow {
                stat("Snapshots summarized", "\(settings.usageDigestFrames)", nil)
                stat("Last summary", status.lastDigestAt?.relativeDescription ?? "—", nil)
            }
        }
    }

    private func stat(_ label: String, _ value: String, _ level: StatusLevel?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                if let level { StatusDot(level: level) }
                Text(value).font(.callout.weight(.medium)).monospacedDigit()
            }
        }
        .frame(minWidth: 120, alignment: .leading)
    }

    // MARK: Actions

    private func digestNow() async {
        guard let memory else { return }
        digesting = true
        await memory.digestNow()
        status = memory.status
        digesting = false
    }

    private func chooseVault() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "Use as Journal"
        p.directoryURL = URL(fileURLWithPath: settings.memoryVaultPath).deletingLastPathComponent()
        if p.runModal() == .OK, let url = p.url { settings.memoryVaultPath = url.path }
    }

    private func openInObsidian() {
        let path = settings.memoryVaultPath
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let hasObsidian = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "obsidian://open")!) != nil
        if hasObsidian, let enc = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: "obsidian://open?path=\(enc)") {
            NSWorkspace.shared.open(url)
        } else {
            revealVault()
        }
    }

    private func revealVault() {
        let path = settings.memoryVaultPath
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func addTypedBundleID() {
        let id = newBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        if !settings.memoryExcludedBundleIDs.contains(id) { settings.memoryExcludedBundleIDs.append(id) }
        newBundleID = ""
    }

    private func chooseApp() {
        let p = NSOpenPanel()
        p.canChooseDirectories = false; p.canChooseFiles = true; p.allowsMultipleSelection = true
        p.allowedContentTypes = [.applicationBundle]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.prompt = "Never Capture"
        guard p.runModal() == .OK else { return }
        for url in p.urls {
            if let bid = Bundle(url: url)?.bundleIdentifier, !settings.memoryExcludedBundleIDs.contains(bid) {
                settings.memoryExcludedBundleIDs.append(bid)
            }
        }
    }

    private func displayPath(_ p: String) -> String {
        let home = NSHomeDirectory()
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    private func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID.split(separator: ".").last.map(String.init)?.capitalized ?? bundleID
    }
}

struct AppIconView: View {
    let bundleID: String
    var body: some View {
        Group {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary).padding(3)
            }
        }
        .frame(width: 22, height: 22)
    }
}
