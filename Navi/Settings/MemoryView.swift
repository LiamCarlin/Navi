import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MemoryView: View {
    @EnvironmentObject private var settings: NaviSettings
    @State private var status = MemoryStatus()
    @State private var digesting = false
    @State private var newBundleID = ""

    private var memory: MemoryServicing? { AppDelegate.shared?.services.memory }

    var body: some View {
        FormPage(title: "Screen Memory", subtitle: "Snapshots → on-device OCR → Jev triage → cheap LLM digest → Obsidian notes.") {
            Section {
                Toggle(isOn: $settings.memoryCaptureEnabled) {
                    ExplainedRow(title: "Remember what I see", explanation: settings.memoryCaptureEnabled ? "Capturing in the background." : "Off. Nothing is captured.") { EmptyView() }
                }
                .toggleStyle(.switch)
                if settings.memoryCaptureEnabled {
                    pauseRow
                }
            }

            Section("Status") {
                statusGrid
                HStack {
                    Button {
                        Task { await digestNow() }
                    } label: {
                        if digesting { ProgressView().controlSize(.small).frame(width: 70) } else { Text("Digest now") }
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
                Picker("Digest every", selection: $settings.memoryDigestIntervalMinutes) {
                    Text("5 min").tag(5); Text("10 min").tag(10); Text("30 min").tag(30)
                }
                Picker("Keep raw frames for", selection: $settings.memoryRetentionDays) {
                    Text("7 days").tag(7); Text("14 days").tag(14); Text("30 days").tag(30); Text("90 days").tag(90)
                }
                Toggle("Keep screenshots (not just text)", isOn: $settings.memoryKeepScreenshots)
            }

            Section("Vault") {
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(displayPath(settings.memoryVaultPath)).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…", action: chooseVault).controlSize(.small)
                }
                HStack(spacing: 8) {
                    Button("Open in Obsidian", action: openInObsidian)
                    Button("Reveal in Finder") { revealVault() }
                    Spacer()
                }
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
                    TextField("Bundle identifier, e.g. com.apple.Passwords", text: $newBundleID)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addTypedBundleID)
                    Button("Add", action: addTypedBundleID).disabled(newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Choose App…", action: chooseApp)
                }
            } header: {
                Text("Never capture these apps")
            } footer: {
                Text("Frames from excluded apps are dropped before OCR. Jev also drops any frame it flags as sensitive (passwords, banking, private messages), and password fields are never stored.")
            }

            Section {
                Label {
                    Text("Everything stays on this Mac. Raw frames and OCR text live in ~/Library/Application Support/Navi; only frames Jev marks important are sent to the digest model, and only the digest is written to your vault.")
                        .font(.callout).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
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

    @ViewBuilder private var pauseRow: some View {
        HStack(spacing: 8) {
            if settings.memoryIsPaused, let until = settings.memoryPausedUntil {
                StatusDot(level: .warn)
                Text("Paused until \(until.formatted(date: .omitted, time: .shortened))")
                Spacer()
                Button("Resume") { settings.memoryPausedUntil = nil }
            } else {
                StatusDot(level: .ok)
                Text("Capturing")
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
                stat("Service", status.isRunning ? "Running" : (settings.memoryIsPaused ? "Paused" : "Stopped"),
                     status.isRunning ? .ok : (settings.memoryIsPaused ? .warn : .off))
                stat("Frames today", "\(status.framesToday)", nil)
                stat("Notes in vault", "\(status.vaultNoteCount)", nil)
            }
            GridRow {
                stat("Last capture", status.lastCaptureAt?.relativeDescription ?? "—", nil)
                stat("Last digest", status.lastDigestAt?.relativeDescription ?? "—", nil)
                stat("Digested frames", "\(settings.usageDigestFrames)", nil)
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
        p.prompt = "Use as Vault"
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
        p.prompt = "Exclude"
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
