import SwiftUI

/// The card that drops down under the bar when the query asks to put
/// something on the calendar: the day's timeline for you and each guest, the
/// times everyone is free, and the event with its length, video link and Book.
/// With only an event word typed ("meeting"), a few examples to start from.
struct SchedulerCardView: View {
    @ObservedObject var model: SchedulerModel
    /// An example was clicked: it becomes the query.
    var onExample: (String) -> Void

    static let nameColumn: CGFloat = 150
    static let columnGap: CGFloat = 12
    static let rowHeight: CGFloat = 40
    static let rowGap: CGFloat = 8
    static var trackWidth: CGFloat { PanelStyle.width - PanelStyle.hPad * 2 - nameColumn - columnGap }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !model.request.hasDetails {
                ScheduleExamplesView(names: model.exampleNames, onPick: onExample)
            } else {
                header
                timeline
                if !model.suggestions.isEmpty { suggestionsRow }
                if model.contactsAccess != .granted, !model.people.isEmpty { contactsPrompt }
                eventCard
            }
        }
        .padding(.horizontal, PanelStyle.hPad)
        .padding(.top, 16)
        .padding(.bottom, 18)
        .animation(PanelStyle.resize, value: layoutSignature)
    }

    private var layoutSignature: [Int] {
        [model.people.count, model.suggestions.isEmpty ? 0 : 1, model.editingVideoLink ? 1 : 0,
         model.request.hasDetails ? 1 : 0, model.contactsAccess == .granted ? 1 : 0]
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(model.dayTitle)
                .font(.system(size: 16, weight: .semibold))
            Text(model.daySubtitle)
                .font(.system(size: 16))
                .foregroundStyle(.tertiary)
            if model.isLoading {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
            Spacer()
            RoundIconButton(symbol: "chevron.left", help: "Previous day (⌘[)") { model.shiftDay(-1) }
                .disabled(model.calendar.isDateInToday(model.day))
            RoundIconButton(symbol: "chevron.right", help: "Next day (⌘])") { model.shiftDay(1) }
        }
        .contentTransition(.numericText())
        .animation(PanelStyle.quickSpring, value: model.day)
    }

    // MARK: Timeline

    private var selectionColor: Color { model.hasConflict ? .red : .accentColor }

    private var timeline: some View {
        let window = model.window
        let rows = 1 + model.people.count
        let rowsHeight = CGFloat(rows) * Self.rowHeight + CGFloat(rows - 1) * Self.rowGap
        let trackX = Self.nameColumn + Self.columnGap
        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                HourLabels(window: window)
                    .frame(width: Self.trackWidth, height: 18)
                if let start = model.start {
                    SlotBubble(text: start.formatted(date: .omitted, time: .shortened), color: selectionColor)
                        .position(x: Self.x(for: start.addingTimeInterval(TimeInterval(model.duration * 30)), in: window),
                                  y: 9)
                }
            }
            .frame(width: Self.trackWidth, height: 18)
            .padding(.leading, trackX)

            ZStack(alignment: .topLeading) {
                VStack(spacing: Self.rowGap) {
                    PersonRow(person: model.me, isYou: true, subtitle: Self.yourPlace,
                              window: window, busy: model.myBusy, known: true, slot: slot) { pick($0) }
                    ForEach(model.people) { person in
                        PersonRow(person: person, isYou: false, subtitle: person.email ?? (person.isContact ? "No email" : "Not in Contacts"),
                                  window: window, busy: model.availability[person.id]?.busy ?? [],
                                  known: Self.isKnown(model.availability[person.id]), slot: slot) { pick($0) }
                    }
                }
                if let start = model.start {
                    let x0 = Self.x(for: start, in: window)
                    let x1 = Self.x(for: start.addingTimeInterval(TimeInterval(model.duration * 60)), in: window)
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(selectionColor.opacity(0.09))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selectionColor.opacity(0.85), lineWidth: 2))
                        .frame(width: max(8, x1 - x0), height: rowsHeight + 8)
                        .offset(x: trackX + x0, y: -4)
                        .allowsHitTesting(false)
                }
            }
        }
        .animation(PanelStyle.quickSpring, value: model.start)
        .animation(PanelStyle.quickSpring, value: model.duration)
    }

    private var slot: ScheduleInterval? {
        guard let start = model.start, let end = model.end else { return nil }
        return ScheduleInterval(start: start, end: end)
    }

    /// A click or drag on a timeline, as a fraction of its width: centre the slot there.
    private func pick(_ fraction: CGFloat) {
        let window = model.window
        let span = window.end.timeIntervalSince(window.start)
        let at = window.start.addingTimeInterval(span * Double(fraction) - Double(model.duration * 30))
        model.select(start: at)
    }

    static func x(for date: Date, in window: ScheduleInterval) -> CGFloat {
        let span = window.end.timeIntervalSince(window.start)
        guard span > 0 else { return 0 }
        let f = min(1, max(0, date.timeIntervalSince(window.start) / span))
        return CGFloat(f) * trackWidth
    }

    static func isKnown(_ a: PersonAvailability?) -> Bool {
        if case .known = a { return true }
        return false
    }

    /// "Kolkata" — where you are, from the time zone.
    static var yourPlace: String {
        let id = TimeZone.current.identifier
        return String(id.split(separator: "/").last ?? Substring(id)).replacingOccurrences(of: "_", with: " ")
    }

    // MARK: Suggestions

    private var suggestionsRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.yellow)
            Text(model.people.isEmpty ? "You're free at" : "Everyone's free at")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            ForEach(model.suggestions, id: \.self) { time in
                let selected = model.start == time
                Button { model.select(start: time) } label: {
                    Text(time.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Capsule().fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)))
                        .overlay(Capsule().strokeBorder(selected ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Contacts

    private var contactsPrompt: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .foregroundStyle(.secondary)
            Text("Allow Contacts so Navi can find emails and invite people")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Button(model.contactsAccess == .denied ? "Open Settings" : "Allow") { model.requestContactsAccess() }
                .controlSize(.small)
        }
    }

    // MARK: Event

    private var accent: Color {
        guard model.start != nil else { return Color.primary.opacity(0.15) }
        return model.calendarColor.map { Color(nsColor: $0) } ?? .accentColor
    }

    private var eventCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(accent)
                    .frame(width: 4, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.title)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                    Text(model.slotSummary ?? "Pick a time")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                AvatarStack(people: model.people)
            }

            HStack(spacing: 8) {
                RoundIconButton(symbol: "video.fill", help: videoHelp, isOn: model.videoOn, size: 36) { model.toggleVideo() }
                RoundIconButton(symbol: "minus", help: "Shorter (⌘-)", size: 36) { model.changeDuration(-1) }
                    .disabled(model.duration <= 15)
                Text(SchedulePlanner.durationLabel(model.duration))
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .frame(minWidth: 76)
                    .frame(height: 36)
                    .background(Capsule().fill(Color.primary.opacity(0.04)))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                    .contentTransition(.numericText())
                RoundIconButton(symbol: "plus", help: "Longer (⌘=)", size: 36) { model.changeDuration(1) }
                    .disabled(model.duration >= 480)
                Spacer()
                BookButton(model: model)
            }

            if model.editingVideoLink { videoLinkRow }

            statusLine
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var videoHelp: String {
        if SchedulerModel.videoLink.isEmpty { return "Add your meeting link (Zoom, Meet, FaceTime…)" }
        return model.videoOn ? "Video link on — click to leave it off" : "Add your video link to the event"
    }

    private var videoLinkRow: some View {
        HStack(spacing: 8) {
            TextField("Paste your meeting link — Zoom, Meet, FaceTime…", text: $model.videoLinkDraft)
                .textFieldStyle(.roundedBorder)
            Button("Save") { model.saveVideoLink() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel") { model.editingVideoLink = false }
        }
        .controlSize(.small)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var statusLine: some View {
        let status = model.status
        let tint: Color = switch status.tone {
        case .good: .green
        case .warning: .orange
        case .neutral: .secondary
        }
        return HStack(spacing: 8) {
            Image(systemName: status.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            Text(status.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(status.tone == .warning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                .lineLimit(2)
            Spacer(minLength: 8)
            if model.calendarAccess != .granted {
                Button(model.calendarAccess == .denied ? "Open Settings" : "Allow Calendar") { model.requestCalendarAccess() }
                    .controlSize(.small)
            }
        }
        .animation(.easeOut(duration: 0.2), value: status)
    }
}

// MARK: - Pieces

/// One timeline row: avatar, name and where/who, then the day's busy blocks.
private struct PersonRow: View {
    let person: SchedulePerson?
    let isYou: Bool
    let subtitle: String
    let window: ScheduleInterval
    let busy: [ScheduleInterval]
    let known: Bool
    let slot: ScheduleInterval?
    let onPick: (CGFloat) -> Void

    var body: some View {
        HStack(spacing: SchedulerCardView.columnGap) {
            HStack(spacing: 10) {
                ScheduleAvatar(person: person, isYou: isYou, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(isYou ? "You" : (person?.firstName ?? ""))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(width: SchedulerCardView.nameColumn, alignment: .leading)

            TimelineTrack(window: window, busy: busy, known: known, slot: slot, onPick: onPick)
                .frame(width: SchedulerCardView.trackWidth, height: SchedulerCardView.rowHeight)
        }
    }
}

/// The day's hours with the busy blocks; blocks that clash with the slot turn red.
private struct TimelineTrack: View {
    let window: ScheduleInterval
    let busy: [ScheduleInterval]
    let known: Bool
    let slot: ScheduleInterval?
    let onPick: (CGFloat) -> Void

    var body: some View {
        let hours = max(1, Int((window.end.timeIntervalSince(window.start) / 3600).rounded()))
        let width = SchedulerCardView.trackWidth
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
            ForEach(1..<hours, id: \.self) { i in
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 1)
                    .offset(x: width * CGFloat(i) / CGFloat(hours))
            }
            ForEach(Array(busy.enumerated()), id: \.offset) { _, block in
                let x0 = SchedulerCardView.x(for: block.start, in: window)
                let x1 = SchedulerCardView.x(for: block.end, in: window)
                let clash = slot.map { block.overlaps($0.start, $0.end) } ?? false
                if x1 > x0 {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(clash ? Color.red.opacity(0.3) : Color.primary.opacity(0.13))
                        .frame(width: max(4, x1 - x0), height: SchedulerCardView.rowHeight - 12)
                        .offset(x: x0)
                }
            }
            if !known {
                Text("Calendar not shared")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.quaternary)
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            onPick(min(1, max(0, value.location.x / width)))
        })
        .help("Click or drag to pick a time")
    }
}

/// "9 10 11 12 1 2 …" over the tracks.
private struct HourLabels: View {
    let window: ScheduleInterval

    var body: some View {
        let hours = max(1, Int((window.end.timeIntervalSince(window.start) / 3600).rounded()))
        let width = SchedulerCardView.trackWidth
        return ZStack(alignment: .topLeading) {
            ForEach(0...hours, id: \.self) { i in
                Text(Self.label(window.start.addingTimeInterval(TimeInterval(i * 3600))))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .position(x: width * CGFloat(i) / CGFloat(hours), y: 9)
            }
        }
    }

    private static let uses24Hour: Bool =
        DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("H") ?? false

    static func label(_ date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        if uses24Hour { return "\(hour)" }
        return "\(hour % 12 == 0 ? 12 : hour % 12)"
    }
}

/// The picked time, over the hour labels: "12:30 PM".
private struct SlotBubble: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(color))
            .fixedSize()
    }
}

/// A contact's photo, else their initials on a colour picked from their name.
struct ScheduleAvatar: View {
    let person: SchedulePerson?
    var isYou = false
    let size: CGFloat

    var body: some View {
        Group {
            if let data = person?.imageData, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(tint.gradient)
                    if isYou && person == nil {
                        Image(systemName: "person.fill").font(.system(size: size * 0.45)).foregroundStyle(.white)
                    } else {
                        Text(initials).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }

    private var initials: String {
        let parts = (person?.name ?? "").split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    private var tint: Color {
        let palette: [Color] = [.blue, .indigo, .purple, .pink, .orange, .teal, .green]
        let seed = (person?.name ?? "").unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[seed % palette.count]
    }
}

/// Guests' avatars, overlapping.
private struct AvatarStack: View {
    let people: [SchedulePerson]

    var body: some View {
        HStack(spacing: -10) {
            ForEach(people.prefix(4)) { p in
                ScheduleAvatar(person: p, size: 34)
                    .overlay(RoundedRectangle(cornerRadius: 34 * 0.28, style: .continuous).strokeBorder(.background, lineWidth: 2))
            }
        }
    }
}

/// Book ⏎ — filled once there is a slot to book.
private struct BookButton: View {
    @ObservedObject var model: SchedulerModel

    var body: some View {
        Button { model.book() } label: {
            HStack(spacing: 6) {
                if model.booking == .booking {
                    ProgressView().controlSize(.small).scaleEffect(0.7).tint(.white)
                }
                Text(model.isBooked ? "Booked" : "Book")
                Image(systemName: model.isBooked ? "checkmark" : "return")
                    .font(.system(size: 13, weight: .bold))
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(model.canBook || model.isBooked ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
            .padding(.horizontal, 20)
            .frame(height: 38)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(model.canBook || model.isBooked ? 0 : 0.08)))
        }
        .buttonStyle(.plain)
        .disabled(!model.canBook)
        .help("Book it and send the invites (⏎)")
    }

    private var fill: Color {
        if model.isBooked { return .green }
        return model.canBook ? .accentColor : Color.primary.opacity(0.03)
    }
}

/// A round glass-ish icon button: day arrows, video, ± length.
struct RoundIconButton: View {
    let symbol: String
    let help: String
    var isOn = false
    var size: CGFloat = 30
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .frame(width: size, height: size)
                .background(Circle().fill(isOn ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04)))
                .overlay(Circle().strokeBorder(isOn ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.08)))
                .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Examples

/// "Try one": what the card understands, coloured the way it reads a query.
struct ScheduleExamplesView: View {
    let names: [String]
    let onPick: (String) -> Void

    private var examples: [String] {
        let a = names.first ?? "Alex"
        let b = names.dropFirst().first ?? "Sam"
        return [
            "Sync with \(a) and \(b) tomorrow afternoon",
            "Coffee with \(a) Friday at 10am for 30 min",
            "Focus time tomorrow morning for 2h",
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Try one")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.leading, 8)
                .padding(.bottom, 4)
            ForEach(examples, id: \.self) { example in
                ExampleRow(text: example) { onPick(example) }
            }
        }
    }

    private struct ExampleRow: View {
        let text: String
        let action: () -> Void
        @State private var hover = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 12) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.yellow)
                    Text(ScheduleTokenStyle.colored(text))
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
}

/// Colours for what the parser recognised: people, days, times, lengths.
enum ScheduleTokenStyle {
    static func color(_ kind: ScheduleRequest.TokenKind) -> Color? {
        switch kind {
        case .person: return .blue
        case .day: return .purple
        case .partOfDay: return .brown
        case .time: return .orange
        case .duration: return .green
        case .recurrence: return .teal
        case .priority: return .red
        case .activity: return nil
        }
    }

    /// The text with each recognised token in its colour.
    static func colored(_ text: String) -> AttributedString {
        let tokens = ScheduleParser.parse(text)?.tokens ?? []
        return attributed(text, tokens: tokens) { token, run in
            if let c = color(token.kind) { run.foregroundColor = c }
        }
    }

    /// Splits `text` at the tokens (Character offsets) and styles each token's run.
    static func attributed(_ text: String, tokens: [ScheduleRequest.Token],
                           style: (ScheduleRequest.Token, inout AttributedString) -> Void,
                           plain: (inout AttributedString) -> Void = { _ in }) -> AttributedString {
        let chars = Array(text)
        var out = AttributedString()
        var cursor = 0
        for token in tokens.sorted(by: { $0.start < $1.start })
        where token.start >= cursor && token.start + token.length <= chars.count {
            var before = AttributedString(String(chars[cursor..<token.start]))
            plain(&before)
            out += before
            var run = AttributedString(String(chars[token.start..<(token.start + token.length)]))
            style(token, &run)
            out += run
            cursor = token.start + token.length
        }
        var rest = AttributedString(String(chars[cursor...]))
        plain(&rest)
        out += rest
        return out
    }
}

/// Tints the recognised names behind the bar's text field ("meeting with ▌jilles▐").
/// Drawn in the field's font with clear text, so only the highlight shows.
struct QueryHighlightUnderlay: View {
    let text: String
    let tokens: [ScheduleRequest.Token]

    var body: some View {
        Text(ScheduleTokenStyle.attributed(text, tokens: tokens, style: { token, run in
            run.foregroundColor = .clear
            run.backgroundColor = (ScheduleTokenStyle.color(token.kind) ?? .blue).opacity(0.16)
        }, plain: { run in
            run.foregroundColor = .clear
        }))
        .font(.system(size: 26, weight: .light))
        .lineLimit(1)
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
