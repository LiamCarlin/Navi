import SwiftUI

/// The ⌘Space panel. A single Liquid Glass card, 680 pt wide, whose height
/// follows its content: just the search bar when idle; results, a streamed
/// answer or a live agent run below it; a status/key-hint footer whenever
/// there is content.
///
/// This view is a pure renderer of `PanelViewModel`. It reports its rendered
/// height through `vm.onContentHeightChange` so `PanelController` can size and
/// re-anchor the transparent `NSPanel` that hosts it.
struct NaviPanelView: View {
    @EnvironmentObject private var vm: PanelViewModel
    @EnvironmentObject private var settings: NaviSettings

    var body: some View {
        GlassEffectContainer(spacing: 16) {
            card
        }
        .frame(width: PanelStyle.width)
        .padding(PanelStyle.shadowInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(colorScheme)
    }

    // MARK: Card

    private var card: some View {
        VStack(spacing: 0) {
            SearchBarView()

            if vm.hasContent {
                Hairline()
                content
                    .frame(width: PanelStyle.width)
            }

            if let err = vm.errorMessage {
                ErrorBanner(message: err) { vm.clearError() }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if vm.hasContent {
                PanelFooterView()
            }
        }
        .frame(width: PanelStyle.width)
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(PanelStyle.shape)
        .glassEffect(.regular, in: PanelStyle.shape)
        .background(CardShadow())
        .overlay(innerHighlight)
        .overlay(alignment: .bottom) { toastOverlay }
        .animation(PanelStyle.spring, value: layoutKey)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
            vm.onContentHeightChange?(h)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.mode {
        case .results:
            if vm.results.isEmpty {
                AskNaviHintRow(query: vm.query.trimmingCharacters(in: .whitespacesAndNewlines))
                    .transition(.opacity)
            } else {
                ResultsListView()
                    .transition(.opacity)
            }
        case .answer:
            AnswerView()
                .transition(.opacity)
        case .agent:
            AgentView()
                .transition(.opacity)
        }
    }

    /// 1 px inner highlight that gives the glass its edge.
    private var innerHighlight: some View {
        PanelStyle.shape
            .strokeBorder(
                LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.10), .white.opacity(0.04), .white.opacity(0.16)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 1)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var toastOverlay: some View {
        ZStack {
            if let toast = vm.toast, vm.hasContent {
                ToastView(text: toast)
                    .padding(.bottom, PanelStyle.footerHeight + 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(PanelStyle.pillSpring, value: vm.toast)
    }

    /// Anything that changes the card's height. Animating on this key gives
    /// the whole card a single, coherent spring instead of per-view jitter.
    private var layoutKey: PanelLayoutKey {
        PanelLayoutKey(mode: vm.mode,
                       hasContent: vm.hasContent,
                       rows: min(vm.results.count, PanelStyle.maxVisibleRows + 1),
                       answerLength: vm.answerText.count,
                       agentEvents: vm.agentEvents.count,
                       approval: vm.pendingApproval != nil,
                       hasScreenshot: vm.agentScreenshot != nil,
                       error: vm.errorMessage)
    }

    private var colorScheme: ColorScheme? {
        switch settings.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Soft drop shadow drawn *around* the card only: the card's own area is
/// punched out so the glass keeps sampling the desktop behind the window.
struct CardShadow: View {
    var body: some View {
        PanelStyle.shape
            .fill(Color.black)
            .shadow(color: .black.opacity(0.32), radius: 30, x: 0, y: 14)
            .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 2)
            .mask {
                ZStack {
                    Rectangle().padding(-160)
                    PanelStyle.shape.fill(Color.black).blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .allowsHitTesting(false)
    }
}

struct PanelLayoutKey: Equatable {
    var mode: PanelViewModel.Mode
    var hasContent: Bool
    var rows: Int
    var answerLength: Int
    var agentEvents: Int
    var approval: Bool
    var hasScreenshot: Bool
    var error: String?
}

extension PanelViewModel {
    /// True when something should render under the search bar.
    var hasContent: Bool {
        mode != .results || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
