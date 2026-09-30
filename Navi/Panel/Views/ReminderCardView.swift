import SwiftUI

/// The card that drops down under the bar when the query asks to be reminded
/// of something: the reminder as it will be saved, quick due-date chips, the
/// repeat and list, the other reminders already due that day, and Add ⏎.
/// With only "remind me" typed, a few examples to start from.
struct ReminderCardView: View {
    @ObservedObject var model: ReminderModel
    /// An example was clicked: it becomes the query.
    var onExample: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.request.title.isEmpty && !model.request.hasWhen {
                examples
            } else {
                reminderRow
                chips
                controls
                if !model.alsoDue.isEmpty { alsoDue }
                statusLine
            }
        }
        .padding(.horizontal, PanelStyle.hPad)
        .padding(.top, 16)
        .padding(.bottom, 18)
        .animation(PanelStyle.resize, value: [model.alsoDue.count, model.request.title.isEmpty ? 0 : 1])
    }

    private var tint: Color {
        model.list?.color.map { Color(nsColor: $0) } ?? .orange
    }

    // MARK: The reminder

    private var reminderRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .strokeBorder(tint, lineWidth: 2)
                .frame(width: 22, height: 22)
                .overlay {
                    if model.isAdded {
                        Circle().fill(tint).padding(4)
                    }
                }
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if model.highPriority {
                        Text("!!!").font(.system(size: 17, weight: .bold)).foregroundStyle(tint)
                    }
                    Text(model.title.isEmpty ? "New reminder" : model.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(model.title.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        .lineLimit(2)
                }
                Text(model.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(model.due.map { $0 <= Date() } == true ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            listMenu
        }
    }

    private var listMenu: some View {
        Menu {
            ForEach(model.lists) { list in
                Button {
                    model.selectList(list.id)
                } label: {
                    let name = menuName(list)
                    if list.id == model.list?.id { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text(model.list?.title ?? "Reminders")
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(Color.primary.opacity(0.04)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.lists.count < 2)
        .help("Reminders list")
    }

    /// Lists with the same name in two accounts ("Tasks" in Outlook and iCloud) get the account.
    private func menuName(_ list: ReminderList) -> String {
        let sameName = model.lists.filter { $0.title == list.title }.count > 1
        return sameName && !list.account.isEmpty ? "\(list.title) · \(list.account)" : list.title
    }

    // MARK: When

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(model.options.enumerated()), id: \.offset) { _, option in
                    let selected = option.date == model.due
                    Button { model.select(option) } label: {
                        HStack(spacing: 5) {
                            if option.date == nil { Image(systemName: "calendar.badge.minus").font(.system(size: 11)) }
                            Text(option.label)
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selected ? tint : .secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Capsule().fill(selected ? tint.opacity(0.13) : Color.primary.opacity(0.04)))
                        .overlay(Capsule().strokeBorder(selected ? tint.opacity(0.4) : Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Repeat, priority, add

    private static let repeatChoices: [ReminderRequest.Repeat] = [.never, .daily, .weekdays, .weekly(weekday: nil), .monthly]

    private var controls: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(Array(Self.repeatChoices.enumerated()), id: \.offset) { _, rule in
                    Button(rule.label) { model.setRepeat(rule) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "repeat").font(.system(size: 12, weight: .semibold))
                    Text(model.repeatRule == .never ? "Repeat" : model.repeatRule.label)
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(model.repeatRule == .never ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Capsule().fill(Color.primary.opacity(0.04)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Repeat")

            RoundIconButton(symbol: "exclamationmark", help: "High priority", isOn: model.highPriority, size: 34) {
                model.togglePriority()
            }

            Spacer()

            Button { model.add() } label: {
                HStack(spacing: 6) {
                    if model.adding == .adding {
                        ProgressView().controlSize(.small).scaleEffect(0.7).tint(.white)
                    }
                    Text(model.isAdded ? "Added" : "Add")
                    Image(systemName: model.isAdded ? "checkmark" : "return")
                        .font(.system(size: 13, weight: .bold))
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(model.canAdd || model.isAdded ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                .padding(.horizontal, 20)
                .frame(height: 38)
                .background(Capsule().fill(model.isAdded ? .green : (model.canAdd ? tint : Color.primary.opacity(0.03))))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(model.canAdd || model.isAdded ? 0 : 0.08)))
            }
            .buttonStyle(.plain)
            .disabled(!model.canAdd)
            .help("Add to Reminders (⏎)")
        }
    }

    // MARK: Context

    private var alsoDue: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(alsoDueTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            ForEach(model.alsoDue.prefix(3)) { item in
                HStack(spacing: 8) {
                    Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5).frame(width: 12, height: 12)
                    Text(item.title)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if let due = item.due {
                        Text(due.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            if model.alsoDue.count > 3 {
                Text("+\(model.alsoDue.count - 3) more")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 20)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }

    private var alsoDueTitle: String {
        guard let due = model.due else { return "Also due" }
        if model.calendar.isDateInToday(due) { return "ALSO DUE TODAY" }
        if model.calendar.isDateInTomorrow(due) { return "ALSO DUE TOMORROW" }
        return "ALSO DUE \(due.formatted(.dateTime.weekday(.wide)).uppercased())"
    }

    private var statusLine: some View {
        let status = model.status
        let color: Color = switch status.tone {
        case .good: .green
        case .warning: .orange
        case .neutral: .secondary
        }
        return HStack(spacing: 8) {
            Image(systemName: status.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
            Text(status.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(status.tone == .warning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                .lineLimit(2)
            Spacer(minLength: 8)
            if model.access != .granted {
                Button(model.access == .denied ? "Open Settings" : "Allow Reminders") { model.requestAccess() }
                    .controlSize(.small)
            } else if model.isAdded {
                Button("Open Reminders") { ReminderStore.openRemindersApp() }
                    .controlSize(.small)
            }
        }
        .animation(.easeOut(duration: 0.2), value: status)
    }

    // MARK: Examples

    static let exampleQueries = [
        "Remind me to call Mom tomorrow at 5pm",
        "Remind me to stretch in 45 min",
        "Remind me to water the plants every Sunday morning",
    ]

    private var examples: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Try one")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.leading, 8)
                .padding(.bottom, 4)
            ForEach(Self.exampleQueries, id: \.self) { example in
                ReminderExampleRow(text: example) { onExample(example) }
            }
        }
    }
}

private struct ReminderExampleRow: View {
    let text: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "sparkle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.yellow)
                Text(ScheduleTokenStyle.attributed(text, tokens: ReminderParser.parse(text)?.tokens ?? []) { token, run in
                    if let c = ScheduleTokenStyle.color(token.kind) { run.foregroundColor = c }
                })
                .font(.system(size: 15))
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(PanelStyle.rowShape.fill(hover ? PanelStyle.selectionFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
