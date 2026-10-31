import AppKit
import Combine
import SwiftUI

/// A ⌘Space task paused on a question asks from the notch: the island's black
/// shape drops down with the question, its answers as chips, a field for the
/// user's own words and Stop — the panel is never opened over the user's work.
/// While the panel is open the question is its card instead (`PanelController`
/// hides this island on `show()` and brings it back on `hide()` while the task
/// still waits). Answers go through `PanelViewModel.answerQuestion`, so the two
/// can never disagree; the island goes away once the question is answered.
///
/// Same window recipe as `VoiceIslandController`: a fixed, transparent,
/// non-activating panel at the notch whose clear parts let clicks through. It
/// may become key only so the answer field can take typing — the app the user
/// is in stays active.
@MainActor
final class NotchQuestionController {
    private let viewModel: PanelViewModel
    private let model = NotchQuestionModel()
    private var panel: NotchQuestionPanel?
    private var hideTask: Task<Void, Never>?
    private var cancellable: AnyCancellable?
    /// Opens the panel on the question (the island's "Open Navi" button).
    var onOpenPanel: (() -> Void)?

    init(viewModel: PanelViewModel) {
        self.viewModel = viewModel
        cancellable = viewModel.$pendingQuestion.sink { [weak self] q in
            if q == nil { self?.hide() }
        }
    }

    var isVisible: Bool { model.visible }

    /// Drops the island down on the task's pending question (nothing pending: nothing to show).
    func show() {
        guard let q = viewModel.pendingQuestion else { return }
        hideTask?.cancel()
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        let screen = VoiceIslandController.targetScreen()
        model.metrics = IslandMetrics(screen: screen)
        if model.question?.id != q.id { model.typed = "" }
        model.question = q
        model.task = viewModel.agentTaskTitle
        let size = VoiceIslandController.windowSize
        panel.setFrame(NSRect(x: (model.metrics.notchCenterX - size.width / 2).rounded(),
                              y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        withAnimation(IslandStyle.appear) { model.visible = true }
        Log.panel.info("question asked from the notch (\(q.choices.count) choices)")
    }

    func hide() {
        guard model.visible else { return }
        withAnimation(IslandStyle.disappear) { model.visible = false }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard let self, !Task.isCancelled, !self.model.visible else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NotchQuestionPanel {
        let p = NotchQuestionPanel(contentRect: NSRect(origin: .zero, size: VoiceIslandController.windowSize),
                                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                   backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.becomesKeyOnlyIfNeeded = true
        let root = NotchQuestionView(model: model,
                                     onAnswer: { [weak self] reply in self?.viewModel.answerQuestion(reply) },
                                     onOpenPanel: { [weak self] in self?.onOpenPanel?() })
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        return p
    }
}

/// Key only for the answer field (`becomesKeyOnlyIfNeeded`), never main.
final class NotchQuestionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchQuestionModel: ObservableObject {
    @Published var visible = false
    @Published var metrics: IslandMetrics = .fallback
    /// Kept after the answer so the island animates away with its content.
    @Published var question: AgentQuestion?
    @Published var task = ""
    @Published var typed = ""
}

/// The island's content for a paused task: what it is asking, the answers to
/// click (the likeliest filled), the user's own answer, Stop.
struct NotchQuestionView: View {
    @ObservedObject var model: NotchQuestionModel
    var onAnswer: (String?) -> Void
    var onOpenPanel: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            if model.visible, let q = model.question {
                island(q)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.5, anchor: .top).combined(with: .opacity),
                        removal: .scale(scale: 0.7, anchor: .top).combined(with: .opacity)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private var width: CGFloat {
        max(IslandStyle.wideWidth, model.metrics.notchWidth + 56) + 2 * IslandStyle.fillet
    }

    private func island(_ q: AgentQuestion) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.metrics.collarHeight)
            content(q)
                .padding(.horizontal, IslandStyle.hPad + IslandStyle.fillet)
                .padding(.top, model.metrics.hasNotch ? 9 : 12)
                .padding(.bottom, 14)
        }
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            IslandShape()
                .fill(Color.black)
                .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 12)
                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
        }
        .overlay {
            IslandShape()
                .strokeBorder(LinearGradient(colors: [.clear, .white.opacity(0.10), .white.opacity(0.16)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .contentShape(IslandShape())
        .animation(IslandStyle.resize, value: q.id)
    }

    private func content(_ q: AgentQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(model.task.isEmpty ? "Navi has a question" : "Navi has a question · \(model.task)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Button(action: onOpenPanel) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help("Open in Navi")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(q.question)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                if !q.detail.isEmpty {
                    Text(q.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            FlowChips(spacing: 6) {
                ForEach(Array(q.choices.enumerated()), id: \.offset) { i, choice in
                    Button { onAnswer(choice) } label: {
                        Text(choice).font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 12).frame(height: 28)
                            .background(Capsule().fill(i == 0 ? Color.orange.opacity(0.9) : Color.white.opacity(0.16)))
                            .foregroundStyle(i == 0 ? Color.black : Color.white)
                    }
                    .buttonStyle(.plain)
                }
                Button { onAnswer(nil) } label: {
                    Text("Stop task").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(Capsule().strokeBorder(Color.white.opacity(0.22)))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
            if q.allowsOther { ownAnswer }
        }
    }

    /// The user's own words (the panel's bar does the same job there).
    private var ownAnswer: some View {
        HStack(spacing: 8) {
            TextField("Or type your own answer", text: $model.typed)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(.white)
                .onSubmit(sendTyped)
            if !typedAnswer.isEmpty {
                Button(action: sendTyped) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.orange))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 12).padding(.trailing, 4)
        .frame(height: 30)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
    }

    private var typedAnswer: String { model.typed.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func sendTyped() {
        guard !typedAnswer.isEmpty else { return }
        onAnswer(typedAnswer)
    }
}
