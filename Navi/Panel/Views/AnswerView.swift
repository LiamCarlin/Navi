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
