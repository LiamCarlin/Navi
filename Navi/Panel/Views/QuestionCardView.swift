import SwiftUI

/// A paused task's question, dropped under the bar: what Navi saw, the question, and its answers
/// as numbered rows (click, ↑↓ ⏎, or ⌘1–4). The bar above is the reply box — what the user types
/// is their own answer (or picks the choice it names). Stop ends the task.
struct QuestionCard: View {
    @EnvironmentObject private var vm: PanelViewModel
    let question: AgentQuestion

    private var typed: String { vm.query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var typedSelected: Bool { vm.questionSelection >= question.choices.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(question.question)
                        .font(.system(size: 14.5, weight: .medium))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if !question.detail.isEmpty {
                        Text(DeveloperMode.showsEngineDetails ? question.detail : PanelWording.userFacing(question.detail))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineSpacing(2)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            VStack(spacing: 1) {
                ForEach(Array(question.choices.enumerated()), id: \.offset) { i, choice in
                    QuestionChoiceRow(number: i + 1, text: choice, isSelected: vm.questionSelection == i)
                        .contentShape(Rectangle())
                        .onTapGesture { vm.answerSelectedChoice(i) }
                        .onHover { if $0, typed.isEmpty { vm.questionSelection = i } }
                }
                if question.allowsOther { typedRow }
            }
            HStack {
                Text("Navi is paused until you answer")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(action: { vm.answerQuestion(nil) }) {
                    Text("Stop the task").font(.system(size: 12, weight: .medium)).padding(.horizontal, 4)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.orange.opacity(0.22)))
        .animation(PanelStyle.quickSpring, value: vm.questionSelection)
    }

    /// The answer being typed in the bar (or a hint that typing works).
    private var typedRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "pencil.line")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(typedSelected && !typed.isEmpty ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                .frame(width: 22)
            Text(typed.isEmpty ? "Or type your own answer in the bar" : typed)
                .font(.system(size: 14, weight: typed.isEmpty ? .regular : .medium))
                .foregroundStyle(typed.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .lineLimit(2)
            Spacer(minLength: 8)
            if typedSelected, !typed.isEmpty { ShortcutHint(text: "⏎ Send").transition(.opacity) }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: PanelStyle.rowHeight - 6)
        .background {
            if typedSelected, !typed.isEmpty {
                PanelStyle.rowShape
                    .fill(PanelStyle.selectionFill)
                    .overlay(PanelStyle.rowShape.strokeBorder(Color.primary.opacity(0.06)))
            }
        }
    }
}

/// One answer: numbered badge (⌘n picks it), the words, ⏎ hint when selected.
struct QuestionChoiceRow: View {
    let number: Int
    let text: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(isSelected ? Color.orange : Color.primary.opacity(0.07)))
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            if isSelected {
                ShortcutHint(text: "⏎")
                    .transition(.opacity)
            } else if number <= AgentQuestion.maxChoices {
                Text("⌘\(number)").font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: PanelStyle.rowHeight - 6)
        .background {
            if isSelected {
                PanelStyle.rowShape
                    .fill(PanelStyle.selectionFill)
                    .overlay(PanelStyle.rowShape.strokeBorder(Color.primary.opacity(0.06)))
            }
        }
    }
}
