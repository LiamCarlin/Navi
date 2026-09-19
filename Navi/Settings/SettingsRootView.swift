import SwiftUI
import AppKit

/// The main "Navi" window: a sidebar of sections and a detail pane.
/// Contract: keep this type name and its no-argument init — `NaviApp`
/// instantiates it inside `Window("Navi", id: "main")`.
struct SettingsRootView: View {
    @EnvironmentObject private var settings: NaviSettings
    @ObservedObject private var nav = SettingsNavigator.shared
    @State private var showOnboarding = !Onboarding.hasCompleted

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .preferredColorScheme(colorScheme)
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(isPresented: $showOnboarding)
                .environmentObject(settings)
        }
        .onReceive(NotificationCenter.default.publisher(for: .naviShowOnboarding)) { _ in showOnboarding = true }
    }

    private var sidebar: some View {
        List(selection: $nav.section) {
            ForEach(SettingsSection.allCases) { s in
                Label(s.title, systemImage: s.symbol).tag(s)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle").font(.caption2)
                Text("Navi \(shortVersion)")
                Spacer()
            }
            .font(.caption).foregroundStyle(.tertiary)
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    @ViewBuilder private var detail: some View {
        switch nav.section ?? .home {
        case .home: HomeView()
        case .general: GeneralView()
        case .providers: ProvidersView()
        case .permissions: PermissionsView()
        case .memory: MemoryView()
        case .agent: AgentView()
        case .usage: UsageView()
        case .about: AboutView()
        }
    }

    private var colorScheme: ColorScheme? {
        switch settings.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    private var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}

extension Notification.Name {
    /// Re-open the onboarding sheet (e.g. from Help or a "Run setup again" button).
    static let naviShowOnboarding = Notification.Name("navi.showOnboarding")
}
