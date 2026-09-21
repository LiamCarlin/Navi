import SwiftUI

/// The island's content: a live waveform, what Navi is doing, the words it
/// hasn't acted on yet, approvals, and streamed answers. Pure renderer of
/// `VoiceSession`; sizing follows the content and animates in place, anchored
/// to the notch.
struct VoiceIslandView: View {
    @ObservedObject var session: VoiceSession
    @ObservedObject var model: IslandModel
    var onStop: () -> Void
    var onTogglePause: () -> Void

    @State private var hovering = false
    @State private var answerHeight: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            if model.visible {
                island
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.5, anchor: .top).combined(with: .opacity),
                        removal: .scale(scale: 0.7, anchor: .top).combined(with: .opacity)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Island

    private var island: some View {
        VStack(spacing: 0) {
            // The band shared with the notch: black, hidden behind the cut-out.
            Color.clear.frame(height: model.metrics.collarHeight)
            content
                .padding(.horizontal, IslandStyle.hPad + IslandStyle.fillet)
                .padding(.top, model.metrics.hasNotch ? 9 : 12)
                .padding(.bottom, 13)
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
        .onHover { hovering = $0 }
        .onTapGesture { if session.phase == .paused { onTogglePause() } }
        .animation(IslandStyle.resize, value: layoutKey)
    }

    private var width: CGFloat {
        let body: CGFloat
        if !session.answerText.isEmpty || session.isAnswering { body = IslandStyle.answerWidth }
        else if session.approval != nil || session.phase.isError || hasTranscript || session.activity != nil { body = IslandStyle.wideWidth }
        else { body = IslandStyle.compactWidth }
        return max(body, model.metrics.notchWidth + 56) + 2 * IslandStyle.fillet
    }

    private var hasTranscript: Bool { !session.pendingText.isEmpty || !session.committed.isEmpty }

    private var layoutKey: String {
        "\(width)|\(session.activity?.label ?? "")|\(session.approval?.description ?? "")|\(hasTranscript)|\(Int(answerHeight))|\(session.phase)|\(session.lastOutcome?.text ?? "")|\(hovering)"
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if hasTranscript, session.approval == nil {
                transcript
            }
            if let a = session.approval {
                approvalRow(a.description, risk: a.risk)
            }
            if !session.answerText.isEmpty || session.isAnswering {
                answer
            }
            if case .error(let msg) = session.phase {
                errorRow(msg)
            }
            if case .downloadingModel(let p) = session.phase {
                ProgressView(value: p).tint(.white).controlSize(.small)
            }
            #if DEBUG
            if !session.jevStatus.isEmpty {
                Text(session.jevStatus)
                    .font(.system(size: 10, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
            }
            #endif
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            WaveformBars(level: session.level, state: waveState)
                .frame(width: 28, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if session.activity?.isRisky == true {
                        Image(systemName: "exclamationmark.shield.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.orange)
                    }
                    if let o = session.lastOutcome, session.activity == nil {
                        Image(systemName: o.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(o.ok ? Color.green : Color.orange)
                    }
                    Text(primaryLine)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                if let s = secondaryLine, !s.isEmpty {
                    Text(s)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            if hovering || session.phase == .paused || session.phase.isError {
                controls.transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: hovering)
        .animation(.easeInOut(duration: 0.2), value: primaryLine)
    }

    private var waveState: WaveformBars.State {
        switch session.phase {
        case .listening: return session.activity != nil ? .acting : .listening
        case .paused: return .paused
        case .starting, .downloadingModel: return .starting
        case .off, .error: return .paused
        }
    }

    private var primaryLine: String {
        switch session.phase {
        case .starting: return "Starting voice control…"
        case .downloadingModel(let p): return "Downloading the speech model · \(Int(p * 100))%"
        case .error: return "Voice control stopped"
        case .paused: return "Paused"
        case .off: return session.activity?.label ?? "Finishing…"
        case .listening: break
        }
        if let a = session.activity { return a.label }
        if session.approval != nil { return "Say “yes” or “no”" }
        if let o = session.lastOutcome { return o.text }
        return "Listening"
    }

    private var secondaryLine: String? {
        if let a = session.activity {
            var s = a.detail ?? (a.isAnswer ? "" : "Jev is deciding each step")
            if session.queueCount > 0 { s = (s.isEmpty ? "" : s + " · ") + "\(session.queueCount) more queued" }
            return s
        }
        if let a = session.approval { return a.risk }
        if case .error = session.phase { return nil }
        if session.phase == .paused { return "Click to resume, or say “resume”" }
        if session.queueCount > 0 { return "\(session.queueCount) queued" }
        if !session.pendingText.isEmpty { return session.hint.hasPrefix("waiting") ? "waiting for the rest…" : nil }
        return session.committed.isEmpty ? "Talk naturally — Navi acts as you go" : nil
    }

    private var controls: some View {
        HStack(spacing: 6) {
            if !session.phase.isError {
                IslandButton(symbol: session.phase == .paused ? "play.fill" : "pause.fill",
                             help: session.phase == .paused ? "Resume listening" : "Pause listening", action: onTogglePause)
            }
            IslandButton(symbol: "xmark", help: "Stop voice control", action: onStop)
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        let last = session.committed.last ?? ""
        let pending = session.pendingText
        var text = AttributedString()
        if !last.isEmpty {
            var a = AttributedString(last + (pending.isEmpty ? "" : "  "))
            a.foregroundColor = .white.opacity(0.38)
            text += a
        }
        if !pending.isEmpty {
            var b = AttributedString(pending)
            b.foregroundColor = .white.opacity(0.92)
            text += b
        }
        return Text(text)
            .font(.system(size: 15, weight: .regular))
            .lineLimit(2)
            .truncationMode(.head)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .animation(nil, value: pending)
    }

    // MARK: Approval

    private func approvalRow(_ description: String, risk: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange).font(.system(size: 13, weight: .semibold))
            Text(description)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { session.approve(true) } label: {
                Text("Yes").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).frame(height: 26)
                    .background(Capsule().fill(Color.green.opacity(0.85)))
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            Button { session.approve(false) } label: {
                Text("No").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).frame(height: 26)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.12)))
    }

    // MARK: Answer

    /// The text itself never animates (a streaming paragraph crossfading with
    /// itself looks doubled); only the scroll frame's height does, measured
    /// from the content like the panel's `AnswerView`.
    private var answer: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if session.answerText.isEmpty { ThinkingRow() } else { MarkdownText(text: session.answerText, streaming: session.isAnswering) }
                    Color.clear.frame(height: 1).id("island-answer-bottom")
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transaction { $0.animation = nil }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { answerHeight = $0 }
            }
            .scrollIndicators(.automatic)
            .frame(height: min(max(answerHeight, 28), IslandStyle.maxAnswerHeight))
            .onChange(of: session.answerText) { _, _ in
                if session.isAnswering, answerHeight > IslandStyle.maxAnswerHeight { proxy.scrollTo("island-answer-bottom", anchor: .bottom) }
            }
        }
    }

    // MARK: Error

    private func errorRow(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if message.localizedCaseInsensitiveContains("microphone") {
                    Button("Open System Settings") { Permissions.openSettings(.microphone) }
                }
                Button("Try again") { session.start() }
            }
            .controlSize(.small)
        }
    }
}

// MARK: - Pieces

struct IslandButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(hover ? 1 : 0.8))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(hover ? 0.24 : 0.13)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Five bars that follow the microphone level; a gradient while Navi acts.
struct WaveformBars: View {
    enum State { case listening, acting, paused, starting }
    var level: Float
    var state: State

    private static let multipliers: [CGFloat] = [0.5, 0.85, 1.0, 0.7, 0.45]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: state != .starting)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule()
                        .fill(fill)
                        .frame(width: 3.5, height: height(i, time: t))
                }
            }
            .frame(height: 22)
            .animation(.easeOut(duration: 0.08), value: level)
        }
    }

    private var fill: AnyShapeStyle {
        switch state {
        case .listening: return AnyShapeStyle(Color.white)
        case .acting: return AnyShapeStyle(PanelStyle.accentGradient)
        case .paused: return AnyShapeStyle(Color.white.opacity(0.35))
        case .starting: return AnyShapeStyle(Color.white.opacity(0.6))
        }
    }

    private func height(_ i: Int, time: Double) -> CGFloat {
        switch state {
        case .paused: return 4
        case .starting:
            // gentle idle wave while the model loads
            return 5 + 5 * CGFloat(0.5 + 0.5 * sin(time * 4 + Double(i) * 0.9))
        case .listening, .acting:
            let l = CGFloat(min(1, max(0, level)))
            return 4 + 18 * l * Self.multipliers[i]
        }
    }
}
