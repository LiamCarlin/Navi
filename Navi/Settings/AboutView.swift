import SwiftUI
import AppKit

struct AboutView: View {
    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        FormPage(title: "About", subtitle: "Navi \(version)") {
            Section {
                HStack(spacing: 16) {
                    NaviMark(size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Navi").font(.title2.weight(.semibold))
                        Text("A Jev-powered Spotlight replacement for macOS 26.").foregroundStyle(.secondary)
                        Text("System One decisions by Jev (TypeSafe) · System Two by Claude (Anthropic)")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Links") {
                LinkPill(title: "Jev / TypeSafe docs", url: "https://docs.typesafe.ai")
                LinkPill(title: "TypeSafe console", url: "https://console.typesafe.ai")
                LinkPill(title: "Claude API docs", url: "https://platform.claude.com/docs")
                LinkPill(title: "Navi source", url: "https://github.com/liamcarlin/Navi")
            }

            Section("Diagnostics") {
                LabeledContent("Bundle") { Text(Bundle.main.bundleIdentifier ?? "—").textSelection(.enabled) }
                LabeledContent("Data") { Text(NaviSettings.dataDirectory.path).textSelection(.enabled).lineLimit(1).truncationMode(.middle) }
                LabeledContent("Logs") {
                    Text("log stream --predicate 'subsystem == \"com.liamcarlin.navi\"'")
                        .font(.caption.monospaced()).textSelection(.enabled)
                }
            }

            Section {
                HStack {
                    Button("Quit Navi", role: .destructive) { NSApp.terminate(nil) }
                    Text("Stops the hotkey and background capture.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }
}

/// The Navi mark: a sparkle on a soft gradient tile.
struct NaviMark: View {
    var size: CGFloat = 64
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.55)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: Color.accentColor.opacity(0.3), radius: size * 0.15, y: size * 0.06)
    }
}
