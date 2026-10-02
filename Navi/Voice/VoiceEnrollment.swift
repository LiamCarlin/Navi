import AppKit
import SwiftUI

/// "Teach Navi your voice": the user reads six short lines, the way they talk to Navi
/// (about a minute), and Navi builds their voiceprint (`VoicePrint`) so voice control
/// acts only on them. Offered in setup, in Settings → Voice, and once on the first voice
/// start without one.
///
/// It runs the same `SpeechListener` voice control uses — same microphone, same echo
/// cancellation — so the voiceprint is learned from audio exactly like what it will
/// later judge. The recognizer also shows which words of the line were heard, finds
/// where the line was said (word times), and moves on once most of the line was read
/// and the user paused.
@MainActor
final class VoiceEnrollmentModel: ObservableObject {
    enum Phase: Equatable {
        case intro
        case starting(String)
        case reading
        case learning
        case done
        case failed(String)
    }

    static let prompts = [
        "Hey Navi, open Safari and search for the weather in Boston this weekend.",
        "Text my mom that I'm running about ten minutes late, and open my calendar.",
        "Pull up the last document I was working on and make the title bigger.",
        "Play something relaxing on Spotify, then turn the volume down a little.",
        "Email the team that Thursday's meeting moved to three thirty in the library.",
        "What's on my schedule tomorrow morning? Remind me to call the dentist at noon.",
    ]
    /// Of the line's words, the share heard before a pause moves on.
    static let coverageToAdvance = 0.6
    /// A pause this long after the line counts as done.
    static let pauseToAdvance: TimeInterval = 0.8
    static let minClipSeconds = 1.5
    static let minPrompts = 4

    @Published private(set) var phase: Phase = .intro
    @Published private(set) var index = 0
    @Published private(set) var level: Float = 0
    /// The words heard for the current line.
    @Published private(set) var heard = ""
    @Published private(set) var coverage = 0.0
    @Published private(set) var note: String?
    @Published private(set) var completed: Set<Int> = []

    private let listener = SpeechListener()
    /// The recognizer's clock when the current line began.
    private var lineStart: Double = 0
    private var clips: [Int: [Float]] = [:]
    private var lastLoud = Date.distantPast
    private var spoke = false
    private var resumeVoice = false

    var prompt: String { Self.prompts[min(index, Self.prompts.count - 1)] }

    // MARK: Flow

    func start() {
        guard phase != .reading, phase != .learning else { return }
        phase = .starting("Getting the microphone ready…")
        // Voice control holds the microphone: pause it while the voice is learned.
        if let v = AppDelegate.shared?.voice, v.isListening { v.stop(); resumeVoice = true }
        clips = [:]; completed = []
        listener.recordsVoice = true
        listener.echoCancellation = NaviSettings.shared.voiceEchoCancellation
        listener.contextualStrings = ["Navi", "Safari", "Spotify", "Boston"]
        listener.onEvent = { [weak self] in self?.handle($0) }
        Task {
            let locale = await SpeechListener.resolveLocale(preferred: NaviSettings.shared.voiceLocale)
            do {
                try await listener.start(locale: locale)
                begin(0)
                phase = .reading
            } catch {
                phase = .failed((error as? NaviError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// Read the current line once more.
    func again() { clips[index] = nil; completed.remove(index); begin(index) }

    /// Move on: keep what was said if there is enough of it.
    func next() {
        if !capture(requireCoverage: false), heardWords().isEmpty { advance() }
    }

    func cancel() {
        Task { await listener.stop() }
        if phase != .done { phase = .intro }
        restoreVoice()
    }

    private func begin(_ i: Int) {
        index = i
        lineStart = listener.heardSeconds
        heard = ""; coverage = 0; spoke = false; note = nil
    }

    private func advance() {
        if index + 1 < Self.prompts.count { begin(index + 1) } else { Task { await learn() } }
    }

    private func handle(_ ev: SpeechListener.Event) {
        switch ev {
        case .downloading(let p):
            phase = .starting("Downloading the speech model… \(Int(p * 100))%")
        case .ready:
            break
        case .transcript:
            let words = heardWords()
            heard = words.map(\.word).joined(separator: " ")
            coverage = Self.coverage(of: prompt, heard: words.map(\.word))
        case .level(let l):
            level = l
            guard phase == .reading else { return }
            if l > 0.22 { lastLoud = Date(); spoke = true }
            if spoke, coverage >= Self.coverageToAdvance, Date().timeIntervalSince(lastLoud) >= Self.pauseToAdvance {
                _ = capture(requireCoverage: true)
            }
        case .failed(let msg):
            // Let go of the microphone so "Try again" starts from scratch.
            if phase == .reading || phase.isStarting { phase = .failed(msg); Task { await listener.stop() } }
        }
    }

    private func heardWords() -> [TimedWord] { listener.timedWords(since: lineStart) }

    /// Keeps the audio of the line as read; false when there is not enough of it.
    @discardableResult
    private func capture(requireCoverage: Bool) -> Bool {
        let words = heardWords()
        guard let first = words.first, let last = words.last else {
            if !requireCoverage { note = nil }
            return false
        }
        guard let samples = listener.voiceAudio(from: first.start - 0.2, to: last.end + 0.2),
              Double(samples.count) / Double(VoiceFbank.sampleRate) >= Self.minClipSeconds else {
            note = "That was a bit short — read the whole line."
            begin(index)
            return false
        }
        clips[index] = samples
        completed.insert(index)
        advance()
        return true
    }

    private func learn() async {
        phase = .learning
        await listener.stop()
        let ordered = clips.keys.sorted().compactMap { clips[$0] }
        guard ordered.count >= Self.minPrompts else {
            phase = .failed("Navi needs at least \(Self.minPrompts) of the lines read out loud. Try again somewhere a little quieter.")
            restoreVoice()
            return
        }
        let embeddings = await Task.detached(priority: .userInitiated) { ordered.map { SpeakerModel.shared.embeddings($0) } }.value
        var prompts = embeddings.filter { !$0.isEmpty }
        // A line that does not sound like the rest (someone else read it, or mostly noise) is left out.
        let odd = Set(VoicePrint.outliers(prompts: prompts.map { $0[0] }))
        if prompts.count - odd.count >= Self.minPrompts { prompts = prompts.enumerated().filter { !odd.contains($0.offset) }.map(\.element) }
        guard let print = VoicePrint.enroll(prompts: prompts) else {
            phase = .failed("Couldn't learn your voice from that. Try again somewhere a little quieter.")
            restoreVoice()
            return
        }
        do {
            try VoicePrintStore.save(print)
            NaviSettings.shared.voiceOnlyMyVoice = true
            Log.voice.info("voiceprint learned from \(prompts.count) lines (self \(print.selfMean, format: .fixed(precision: 2)) ± \(print.selfSpread, format: .fixed(precision: 2)), bar \(print.threshold, format: .fixed(precision: 2)))")
            phase = .done
        } catch {
            phase = .failed("Couldn't save your voiceprint: \(error.localizedDescription)")
        }
        restoreVoice()
    }

    private func restoreVoice() {
        guard resumeVoice else { return }
        resumeVoice = false
        AppDelegate.shared?.voice?.start()
    }

    // MARK: Pure

    /// The share of the line's words that were heard (any order, case and punctuation aside).
    nonisolated static func coverage(of line: String, heard: [String]) -> Double {
        let want = line.split(whereSeparator: { $0.isWhitespace }).map { TimedWord.key(String($0)) }.filter { !$0.isEmpty }
        guard !want.isEmpty else { return 0 }
        let got = Set(heard.map(TimedWord.key))
        return Double(want.filter(got.contains).count) / Double(want.count)
    }
}

private extension VoiceEnrollmentModel.Phase {
    var isStarting: Bool { if case .starting = self { return true }; return false }
}

// MARK: - View

struct VoiceEnrollmentView: View {
    @StateObject private var model = VoiceEnrollmentModel()
    var onClose: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(28)
        }
        .frame(width: 560, height: 420)
        .onDisappear { model.cancel() }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .intro: intro
        case .starting(let what): working(what)
        case .reading: reading
        case .learning: working("Learning your voice…")
        case .done: done
        case .failed(let msg): failed(msg)
        }
    }

    private var intro: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            Image(systemName: "person.wave.2.fill").font(.system(size: 46)).foregroundStyle(PanelStyle.accentGradient)
            Text("Teach Navi your voice").font(.system(size: 26, weight: .bold, design: .rounded))
            Text("Read \(VoiceEnrollmentModel.prompts.count) short lines out loud, the way you talk to Navi — about a minute. Then voice control acts only on you and ignores anyone else talking nearby.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Label("Your voiceprint stays on this Mac. Forget it any time in Settings → Voice.", systemImage: "lock.fill")
                .font(.caption).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            HStack {
                Button("Not now") { onClose() }
                Spacer()
                Button("Start") { model.start() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Line \(model.index + 1) of \(VoiceEnrollmentModel.prompts.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 5) {
                    ForEach(VoiceEnrollmentModel.prompts.indices, id: \.self) { i in
                        Circle().fill(model.completed.contains(i) ? Color.accentColor : i == model.index ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.25))
                            .frame(width: 7, height: 7)
                    }
                }
            }
            Text("Read this out loud:").font(.callout).foregroundStyle(.secondary)
            Text("“\(model.prompt)”")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
                .animation(.spring(duration: 0.3), value: model.index)
            HStack(spacing: 12) {
                LevelBars(level: model.level)
                ProgressView(value: min(1, model.coverage / VoiceEnrollmentModel.coverageToAdvance)).progressViewStyle(.linear)
            }
            Text(model.heard.isEmpty ? "Listening…" : model.heard)
                .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            if let note = model.note {
                Label(note, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            HStack {
                Button("Cancel") { model.cancel(); onClose() }
                Spacer()
                Button("Read it again") { model.again() }
                Button("Next line") { model.next() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func working(_ what: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView().controlSize(.large)
            Text(what).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var done: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.seal.fill").font(.system(size: 52)).foregroundStyle(.green)
            Text("Navi knows your voice").font(.system(size: 26, weight: .bold, design: .rounded))
            Text("Voice control now acts only on what you say. Other voices nearby are ignored. Turn it off or retrain in Settings → Voice.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            HStack {
                Spacer()
                Button("Done") { onClose() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func failed(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 42)).foregroundStyle(.orange)
            Text(msg).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Spacer()
            HStack {
                Button("Close") { onClose() }
                Spacer()
                Button("Try again") { model.start() }.buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Five bars that follow the microphone level.
private struct LevelBars: View {
    var level: Float
    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                let h = CGFloat(max(0.15, min(1, Double(level) * (1.4 - abs(Double(i) - 2) * 0.25))))
                Capsule().fill(Color.accentColor).frame(width: 4, height: 6 + 18 * h)
            }
        }
        .frame(height: 26)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

// MARK: - Window

/// The enrollment window, opened from setup, Settings → Voice, or the first voice start.
@MainActor
enum VoiceEnrollmentWindow {
    private static var window: NSWindow?

    static func show() {
        if let window, window.isVisible { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let host = NSHostingController(rootView: VoiceEnrollmentView(onClose: { close() }).environmentObject(NaviSettings.shared))
        let w = NSWindow(contentViewController: host)
        w.title = "Teach Navi your voice"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func close() {
        window?.close()
        window = nil
    }
}
