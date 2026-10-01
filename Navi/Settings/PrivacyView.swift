import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Settings → Privacy & Data: what Navi keeps on this Mac (measured live), what leaves it
/// and why, how long things are kept, what is never captured, and "Delete everything".
/// Plain words, no vendor names. The data layer is `DataInventory` / `PrivacyData` /
/// `TaskLogs` / `CaptureExclusions`; docs/PRIVACY.md is the engineering inventory.
struct PrivacyView: View {
    @EnvironmentObject private var settings: NaviSettings
    @State private var inventory: DataInventory?
    @State private var scanning = false
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var deleteResult: String?
    @State private var newSite = ""
    @State private var newBundleID = ""

    var body: some View {
        FormPage(title: "Privacy & Data", subtitle: "What Navi keeps, what leaves this Mac, and how to remove it.") {
            onThisMacSection
            leavesSection
            retentionSection
            recallControlsSection
            appsSection
            sitesSection
            deleteSection
        }
        .task { await rescan() }
        .confirmationDialog("Delete everything Navi has stored?", isPresented: $confirmDelete) {
            Button("Delete Everything", role: .destructive) { Task { await deleteEverything() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Screen memory, its screenshots, the journal notes Navi wrote, task logs, what Navi learned from past tasks and your recent searches are removed from this Mac. Your own notes, your settings and your sign-in stay. This can't be undone.")
        }
    }

    // MARK: On this Mac

    @ViewBuilder private var onThisMacSection: some View {
        Section {
            if let inventory {
                ForEach(inventory.items) { item in
                    inventoryRow(item)
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Measuring…").foregroundStyle(.secondary) }
            }
        } header: {
            HStack {
                Text("Stored on this Mac")
                Spacer()
                if let inventory {
                    Text(ByteCountFormatter.string(fromByteCount: inventory.totalBytes, countStyle: .file))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Button { Task { await rescan() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(scanning).help("Measure again")
            }
        } footer: {
            Text("Everything here is readable only by your macOS user account. Navi's servers keep none of it.")
        }
    }

    private func inventoryRow(_ item: DataInventory.Item) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kind.symbol).foregroundStyle(.secondary).frame(width: 18)
            ExplainedRow(title: item.kind.title, explanation: item.kind.explanation) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(detail(item)).font(.callout).monospacedDigit()
                    if let url = item.location, FileManager.default.fileExists(atPath: url.path) {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }
        }
    }

    private func detail(_ item: DataInventory.Item) -> String {
        let size = ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
        switch item.kind {
        case .screenMemory:
            guard item.count > 0 else { return item.bytes > 0 ? size : "Nothing" }
            var s = "\(item.count.formatted()) moments · \(size)"
            if let oldest = item.oldest { s += "\nsince \(oldest.formatted(date: .abbreviated, time: .omitted))" }
            return s
        case .screenshots: return item.count > 0 ? "\(item.count.formatted()) · \(size)" : "None"
        case .journal: return item.count > 0 ? "\(item.count.formatted()) notes · \(size)" : "None"
        case .taskLogs:
            if item.bytes == 0 { return settings.keepTaskLogs ? "None yet" : "Off" }
            return item.count > 0 ? "\(item.count) runs · \(size)" : size
        case .taskExperience: return item.count > 0 ? "\(item.count) tasks · \(size)" : (item.bytes > 0 ? size : "None")
        case .recentSearches: return item.count > 0 ? "\(item.count)" : "None"
        }
    }

    // MARK: What leaves this Mac

    @ViewBuilder private var leavesSection: some View {
        Section {
            leaves("text.bubble", "Questions and commands",
                   "What you type or say, the app you're in and its window title go to Navi's servers, which pass them to the AI services that answer.")
            leaves("cursorarrow.click.2", "Tasks Navi does for you",
                   "The text and buttons of the app Navi is working in, and sometimes a screenshot of that window, so it can choose each step and write what you asked for.")
            leaves("brain", "Recall",
                   "Each moment's on-screen text, app, window title and page address are checked to decide whether it's worth remembering. For moments that are, that text and up to two small screenshots are summarised into your journal. Moments with personal details you block are recognised on this Mac and never sent.")
            leaves("waveform", "Voice",
                   "Speech is turned into text on this Mac. Audio never leaves it — only the words of a command, like a typed one.")
        } header: {
            Text("What leaves this Mac, and why")
        } footer: {
            Text("Navi's servers forward these requests and keep only your account, your plan and a count of what you used — never the content. The AI services process requests to answer them and don't use them to train their models.")
        }
    }

    private func leaves(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            ExplainedRow(title: title, explanation: text) { EmptyView() }
        }
    }

    // MARK: Retention

    @ViewBuilder private var retentionSection: some View {
        Section {
            Picker("Keep screen memory for", selection: $settings.memoryRetentionDays) {
                if ![7, 30, 90, 0].contains(settings.memoryRetentionDays) {
                    Text("\(settings.memoryRetentionDays) days").tag(settings.memoryRetentionDays)
                }
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("Forever").tag(0)
            }
            Toggle(isOn: $settings.memoryRetentionIncludesVault) {
                ExplainedRow(title: "Also remove journal notes Navi wrote",
                             explanation: "Older session and daily notes Navi created go too. Notes you wrote yourself are never removed.") { EmptyView() }
            }
            .toggleStyle(.switch)
            .disabled(settings.memoryRetentionDays == 0)
            Toggle(isOn: $settings.memoryKeepScreenshots) {
                ExplainedRow(title: "Keep screenshots", explanation: "Off keeps only the text of each moment.") { EmptyView() }
            }
            .toggleStyle(.switch)
            Toggle(isOn: $settings.keepTaskLogs) {
                ExplainedRow(title: "Keep task logs for troubleshooting",
                             explanation: "Step-by-step records of tasks, including what was on screen and typed, kept 7 days on this Mac. Off by default; nothing is sent.") { EmptyView() }
            }
            .toggleStyle(.switch)
        } header: {
            Text("How long Navi keeps things")
        } footer: {
            Text("Older moments, their screenshots and summaries are removed once a day.")
        }
    }

    // MARK: Pause

    @ViewBuilder private var recallControlsSection: some View {
        Section("Pause Recall") {
            HStack(spacing: 8) {
                if !settings.memoryCaptureEnabled {
                    StatusDot(level: .off)
                    Text("Recall is off. Nothing is captured.")
                    Spacer()
                } else if settings.memoryIsPaused, let until = settings.memoryPausedUntil {
                    StatusDot(level: .warn)
                    Text("Paused until \(until.formatted(date: .omitted, time: .shortened))")
                    Spacer()
                    Button("Resume") { settings.memoryPausedUntil = nil }
                } else {
                    StatusDot(level: .ok)
                    Text("Remembering")
                    Spacer()
                    Button("15 minutes") { pause(minutes: 15) }
                    Button("1 hour") { pause(minutes: 60) }
                    Button("Until tomorrow") {
                        settings.memoryPausedUntil = Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400))
                    }
                }
            }
            .controlSize(.small)
            Text("Never captured: a locked or sleeping screen, the screen saver, another user's session, private browser windows, a focused password field, and Navi itself.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func pause(minutes: Int) { settings.memoryPausedUntil = Date().addingTimeInterval(Double(minutes) * 60) }

    // MARK: Apps

    @ViewBuilder private var appsSection: some View {
        Section {
            ForEach(settings.memoryExcludedBundleIDs.filter { !CaptureExclusions.builtInBundleIDs.contains($0) }, id: \.self) { bid in
                HStack {
                    AppIconView(bundleID: bid)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Self.appName(for: bid))
                        Text(bid).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { settings.memoryExcludedBundleIDs.removeAll { $0 == bid } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Allow again")
                }
            }
            HStack(spacing: 8) {
                TextField("App ID, e.g. com.example.bank", text: $newBundleID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTypedBundleID)
                Button("Add", action: addTypedBundleID).disabled(newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Choose App…", action: chooseApp)
            }
            DisclosureGroup("Always skipped (\(CaptureExclusions.builtInApps.count))") {
                Text(CaptureExclusions.builtInApps.map(\.name).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Apps Recall never captures")
        } footer: {
            Text("Their windows are left out of every snapshot, even behind other windows.")
        }
    }

    // MARK: Sites

    @ViewBuilder private var sitesSection: some View {
        Section {
            ForEach(settings.memoryExcludedSites, id: \.self) { site in
                HStack {
                    Image(systemName: "globe").foregroundStyle(.secondary).frame(width: 22)
                    Text(site)
                    Spacer()
                    Button { settings.memoryExcludedSites.removeAll { $0 == site } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Allow again")
                }
            }
            HStack(spacing: 8) {
                TextField("Site, e.g. mybank.com", text: $newSite)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addSite)
                Button("Add", action: addSite).disabled(CaptureExclusions.normalizeSite(newSite) == nil)
            }
        } header: {
            Text("Sites Recall never captures")
        } footer: {
            Text("Covers the site and its subdomains. Navi recognises the page once you allow it to read your browser's address (it asks the first time).")
        }
    }

    // MARK: Delete everything

    @ViewBuilder private var deleteSection: some View {
        Section {
            HStack {
                ExplainedRow(title: "Delete everything Navi has stored",
                             explanation: "Screen memory, screenshots, journal notes Navi wrote, task logs, task history and recent searches. Navi keeps working; Recall starts fresh.") { EmptyView() }
                if deleting { ProgressView().controlSize(.small) }
                Button("Delete…", role: .destructive) { confirmDelete = true }
                    .disabled(deleting)
            }
            if let deleteResult {
                Text(deleteResult).font(.caption).foregroundStyle(.secondary)
            }
        } footer: {
            Text("To also delete your Navi account and what our servers hold about it, use Account.")
        }
    }

    // MARK: Actions

    private func rescan() async {
        scanning = true
        defer { scanning = false }
        let paths = NaviDataPaths.live
        let searches = UserDefaults.standard.stringArray(forKey: "navi.recentQueries")?.count ?? 0
        inventory = await Task.detached(priority: .utility) { DataInventory.scan(paths, recentSearches: searches) }.value
    }

    private func deleteEverything() async {
        deleting = true
        deleteResult = nil
        let report = await PrivacyData.deleteAllLocalData()
        deleting = false
        deleteResult = report.errors.isEmpty ? report.summary : report.summary + " " + report.errors.joined(separator: " ")
        await rescan()
    }

    private func addSite() {
        guard let site = CaptureExclusions.normalizeSite(newSite) else { return }
        if !settings.memoryExcludedSites.contains(site) { settings.memoryExcludedSites.append(site) }
        newSite = ""
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

    static func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID.split(separator: ".").last.map(String.init)?.capitalized ?? bundleID
    }
}
