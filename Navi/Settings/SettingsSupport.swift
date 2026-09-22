import SwiftUI
import AppKit

// MARK: - Sections & navigation

/// The sidebar sections of the Navi window.
///
/// `.providers` is the hidden **Developer** section (keys, models, agent
/// tuning, browser runtime, token usage — see `DeveloperView`). It is listed
/// only while `DeveloperMode.isEnabled`; `SettingsRootView` still renders it
/// through `ProvidersView`, which now shows `DeveloperView`.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case home, account, general, providers, permissions, memory, agent, voice, usage, about, developer

    var id: String { rawValue }

    /// Sidebar order. The Developer section appears last, and only in developer mode.
    static var allCases: [SettingsSection] {
        var all: [SettingsSection] = [.home, .general, .permissions, .memory, .agent, .voice, .usage, .about]
        if DeveloperMode.isEnabled { all.append(.providers) }
        return all
    }

    var title: String {
        switch self {
        case .home: return "Home"
        case .account: return "Account"
        case .general: return "General"
        case .providers: return "Developer"
        case .permissions: return "Permissions"
        case .memory: return "Screen Memory"
        case .agent: return "Agent"
        case .voice: return "Voice"
        case .usage: return "Usage"
        case .about: return "About"
        case .developer: return "Developer"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "sparkle"
        case .account: return "person.crop.circle"
        case .general: return "gearshape"
        case .providers: return "hammer"
        case .permissions: return "lock.shield"
        case .memory: return "brain"
        case .agent: return "cursorarrow.click.2"
        case .voice: return "waveform"
        case .usage: return "chart.bar"
        case .about: return "info.circle"
        case .developer: return "hammer"
        }
    }

    /// Sections a user sees; `developer` only with `defaults write com.liamcarlin.navi developerMode -bool YES`.
    var isVisible: Bool { self != .developer || NaviSettings.developerMode }
}

/// Shared selection state so any view (status cards, onboarding, the panel's
/// "settings" intent) can jump to a section.
@MainActor
final class SettingsNavigator: ObservableObject {
    static let shared = SettingsNavigator()
    @Published var section: SettingsSection? = .home
    func go(_ s: SettingsSection) { section = s }
}

// MARK: - Status primitives

enum StatusLevel {
    case ok, warn, bad, off

    var color: Color {
        switch self {
        case .ok: return .green
        case .warn: return .orange
        case .bad: return .red
        case .off: return .secondary
        }
    }
}

struct StatusDot: View {
    let level: StatusLevel
    var body: some View {
        Circle()
            .fill(level.color)
            .frame(width: 9, height: 9)
            .shadow(color: level.color.opacity(level == .off ? 0 : 0.5), radius: 3)
    }
}

/// A compact status card used on Home: dot + title + detail + optional Fix.
struct StatusCard: View {
    let title: String
    let detail: String
    let level: StatusLevel
    var fixTitle: String = "Fix"
    var fix: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(level: level).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if level != .ok, let fix {
                Button(fixTitle, action: fix)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

/// Small inline status pill ("Saved", "Missing", ...).
struct StatusPill: View {
    let text: String
    let level: StatusLevel
    var body: some View {
        HStack(spacing: 5) {
            StatusDot(level: level)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }
}

// MARK: - Page scaffolding

/// Standard page header used at the top of each section.
struct SectionHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.largeTitle.weight(.semibold))
            Text(subtitle).font(.body).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }
}

/// A grouped-form page with a consistent header.
struct FormPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        Form {
            Section { SectionHeader(title: title, subtitle: subtitle) }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            content
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

/// A row with a leading title/explanation and trailing controls.
struct ExplainedRow<Trailing: View>: View {
    let title: String
    let explanation: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(explanation).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

struct LinkPill: View {
    let title: String
    let url: String
    var body: some View {
        Button {
            Opener.open(url)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "arrow.up.right").font(.caption2)
            }
        }
        .buttonStyle(.link)
    }
}

// MARK: - Helpers

enum Opener {
    static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
    static func reveal(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

/// Runs a command-line tool off the main thread and returns its exit status + output.
enum Shell {
    struct Result { var status: Int32; var stdout: String; var stderr: String }

    static func run(_ launchPath: String, _ args: [String]) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: launchPath)
                p.arguments = args
                let out = Pipe(), err = Pipe()
                p.standardOutput = out; p.standardError = err
                do {
                    try p.run()
                } catch {
                    cont.resume(returning: Result(status: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }
                let o = out.fileHandleForReading.readDataToEndOfFile()
                let e = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: Result(status: p.terminationStatus,
                                              stdout: String(data: o, encoding: .utf8) ?? "",
                                              stderr: String(data: e, encoding: .utf8) ?? ""))
            }
        }
    }
}

extension Date {
    var relativeDescription: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: self, relativeTo: Date())
    }
}

/// Format helpers for the Usage page.
enum Fmt {
    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1e3) }
        return "\(n)"
    }
    static func usd(_ d: Double) -> String {
        d < 0.01 && d > 0 ? String(format: "$%.4f", d) : String(format: "$%.2f", d)
    }
}
