import SwiftUI

/// Structured follow-up below the bar: the question, 2–4 selectable
/// interpretations (each a complete request), and a free-text box. ↑↓ moves
/// between them, ⏎ answers, esc goes back to the results.
struct ClarifyView: View {
    @EnvironmentObject private var vm: PanelViewModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let c = vm.clarification {
                header(c.question)
                    .padding(.horizontal, PanelStyle.hPad)
                    .padding(.top, 14)
                    .padding(.bottom, 8)
                VStack(spacing: 1) {
                    ForEach(Array(c.options.enumerated()), id: \.offset) { i, option in
                        ClarifyOptionRow(number: i + 1, text: option, isSelected: vm.clarifySelection == i)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                vm.clarifySelection = i
                                vm.submitClarification()
                            }
                            .onHover { if $0, vm.clarifyAnswer.isEmpty { vm.clarifySelection = i } }
                    }
                    freeText(isSelected: vm.clarifySelection >= c.options.count)
                        .contentShape(Rectangle())
                        .onTapGesture { vm.clarifySelection = c.options.count; fieldFocused = true }
                }
                .padding(.horizontal, PanelStyle.listPad)
                .padding(.bottom, PanelStyle.listPad)
            } else {
                HStack(spacing: 8) {
                    ThinkingRow()
                    Text("· writing a quick follow-up")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, PanelStyle.hPad + 2)
                .padding(.vertical, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(PanelStyle.quickSpring, value: vm.clarifySelection)
        .onChange(of: vm.clarification, initial: true) { _, c in
            if c != nil { focusField() }
        }
    }

    private func header(_ question: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "questionmark.bubble.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(PanelStyle.tint(for: .answer))
                .padding(.top, 1)
            Text(question)
                .font(.system(size: 14.5, weight: .medium))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func freeText(isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "pencil.line")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? AnyShapeStyle(PanelStyle.tint(for: .answer)) : AnyShapeStyle(.tertiary))
                .frame(width: 22)
            TextField("Or type your own answer…", text: $vm.clarifyAnswer)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .tint(.indigo)
                .autocorrectionDisabled()
                .focused($fieldFocused)
                .lineLimit(1)
            Spacer(minLength: 8)
            if isSelected {
                ShortcutHint(text: vm.clarifyAnswer.trimmingCharacters(in: .whitespaces).isEmpty ? "⏎" : "⏎ Go")
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: PanelStyle.rowHeight - 6)
        .background {
            PanelStyle.rowShape
                .fill(isSelected ? PanelStyle.selectionFill : Color.primary.opacity(0.03))
                .overlay(PanelStyle.rowShape.strokeBorder(Color.primary.opacity(isSelected ? 0.08 : 0.05)))
        }
        .padding(.top, 4)
    }

    /// The bar's text field re-asserts focus a beat after the panel shows,
    /// so ask a couple of times to win.
    private func focusField() {
        fieldFocused = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            fieldFocused = true
        }
    }
}

/// One interpretation: numbered badge, the rewritten request, ⏎ hint when selected.
struct ClarifyOptionRow: View {
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
                .background(Circle().fill(isSelected ? PanelStyle.tint(for: .answer) : Color.primary.opacity(0.07)))
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            if isSelected {
                ShortcutHint(text: "⏎ Go")
                    .transition(.opacity)
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
