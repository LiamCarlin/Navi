import SwiftUI

/// Streamed answer below the bar. Grows with the text up to ~60 % of the
/// screen, then scrolls (and follows the stream).
struct AnswerView: View {
    @EnvironmentObject private var vm: PanelViewModel
    @State private var contentHeight: CGFloat = 0

    private var height: CGFloat {
        min(max(contentHeight, 48), PanelStyle.maxScrollHeight)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if let earlier = earlierQuestion {
                        ThreadCaption(question: earlier, turns: vm.answerThread.count)
                            .padding(.bottom, 10)
                    }
                    if vm.answerText.isEmpty && vm.isAnswering {
                        ThinkingRow()
                    } else {
                        MarkdownText(text: vm.answerText, streaming: vm.isAnswering)
                    }
                    Color.clear.frame(height: 1).id("answer-bottom")
                }
                .padding(.horizontal, PanelStyle.hPad + 2)
                .padding(.top, 14)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollIndicators(.automatic)
            .frame(height: height)
            .onChange(of: vm.answerText) { _, _ in
                guard vm.isAnswering, contentHeight > PanelStyle.maxScrollHeight else { return }
                proxy.scrollTo("answer-bottom", anchor: .bottom)
            }
        }
    }
}

extension AnswerView {
    /// The question the thread started from, shown above a follow-up's answer
    /// (not while the follow-up is still being written: the answer below is that question's).
    fileprivate var earlierQuestion: String? {
        guard !vm.isFollowingUp, let first = vm.answerThread.first,
              let q = first.split(separator: "”", maxSplits: 1).first else { return nil }
        return String(q.drop(while: { $0 == "“" }))
    }
}

/// "↳ Following up on “why is the sky blue”" above a follow-up's answer.
struct ThreadCaption: View {
    let question: String
    let turns: Int
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 9.5, weight: .semibold))
            Text(turns > 1 ? "Following up on “\(question)” and \(turns - 1) more" : "Following up on “\(question)”")
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.tertiary)
    }
}

/// Shimmering "Thinking…" line shown before the first token arrives.
struct ThinkingRow: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let phase = CGFloat((t.truncatingRemainder(dividingBy: 1.6)) / 1.6)
            HStack(spacing: 8) {
                StreamingCaret()
                ZStack(alignment: .leading) {
                    Text("Thinking…")
                        .foregroundStyle(.tertiary)
                    Text("Thinking…")
                        .foregroundStyle(.primary)
                        .mask {
                            LinearGradient(colors: [.clear, .white, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 50)
                                .offset(x: -50 + phase * 140)
                        }
                }
                .font(.system(size: 14, weight: .medium))
            }
        }
        .frame(height: 20)
    }
}
