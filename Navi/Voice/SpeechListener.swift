import AVFoundation
import Foundation
import Speech

/// Continuous, on-device transcription of the microphone (or, for the debug
/// probe, of an audio file played back in real time).
///
/// Built on macOS 26's `SpeechAnalyzer` + `SpeechTranscriber`: the model runs
/// locally, has no session length limit and reports *volatile* results (the
/// words it is still revising) every ~100–300 ms while you speak, then
/// *finalizes* them at pauses. Navi acts on volatile text — waiting for
/// finalization would add a second or two of lag — so the transcript is
/// exposed as two parts: `finalized` (stable, append-only) and `volatile`
/// (the tail that may still change).
///
/// Speech recognition authorization is not needed for the on-device analyzer;
/// only the microphone permission is. Every event is delivered on the main actor.
@MainActor
final class SpeechListener {
    enum Event: Sendable {
        /// The model is being downloaded (first use of a locale); 0…1.
        case downloading(Double)
        /// Audio is flowing and the model is ready. Carries the locale in use.
        case ready(String)
        /// The transcript changed. `finalized` is everything the recognizer
        /// has committed; `volatile` is the tail it may still revise.
        case transcript(finalized: String, volatile: String)
        /// Microphone level 0…1, ~25 times per second (for the waveform).
        case level(Float)
        /// Recognition stopped on its own (device change, model error). The
        /// session decides whether to restart.
        case failed(String)
    }

    var onEvent: ((Event) -> Void)?

    /// Words the recognizer should favour (app names, "Navi"); improves
    /// recognition of proper nouns like "Xcode" or "Obsidian".
    var contextualStrings: [String] = []

    private let engine = AVAudioEngine()
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var pipe: AudioPipe?
    private var resultsTask: Task<Void, Never>?
    private var fileTask: Task<Void, Never>?
    private var configObserver: NSObjectProtocol?
    private var finalized = ""
    /// The last volatile text shown for the audio that is not yet finalized.
    private var lastVolatile = ""
    private(set) var isRunning = false

    // MARK: Permission

    nonisolated static var microphoneStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    nonisolated static func requestMicrophone() async -> Bool {
        switch microphoneStatus {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: Locale

    /// The locale the transcriber will use for `preferred` (Settings), falling
    /// back to the system locale, then US English.
    nonisolated static func resolveLocale(preferred: String?) async -> Locale {
        var candidates: [Locale] = []
        if let preferred, !preferred.isEmpty { candidates.append(Locale(identifier: preferred)) }
        candidates.append(Locale.current)
        candidates.append(Locale(identifier: "en_US"))
        for c in candidates {
            if let l = await SpeechTranscriber.supportedLocale(equivalentTo: c) { return l }
        }
        return Locale(identifier: "en_US")
    }

    /// Whether the on-device model for `locale` is installed (Settings status).
    nonisolated static func modelStatus(for locale: Locale) async -> AssetInventory.Status {
        let t = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        return await AssetInventory.status(forModules: [t])
    }

    // MARK: Start / stop

    /// Starts listening. `audioFile` replaces the microphone with a file played
    /// back at real-time pace (debug probe). Throws `NaviError` when the
    /// microphone is denied, the locale is unsupported or the engine can't start.
    func start(locale: Locale, audioFile: URL? = nil) async throws {
        guard !isRunning else { return }
        if audioFile == nil {
            guard await Self.requestMicrophone() else {
                throw NaviError.permissionDenied("Microphone — allow Navi in System Settings → Privacy & Security → Microphone")
            }
        }
        guard SpeechTranscriber.isAvailable else {
            throw NaviError.other("On-device speech recognition isn't available on this Mac")
        }
        var reporting: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
        if UserDefaults.standard.object(forKey: "voiceFastResults") == nil || UserDefaults.standard.bool(forKey: "voiceFastResults") {
            reporting.insert(.fastResults)
        }
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: reporting,
                                            attributeOptions: [])
        try await ensureModel(transcriber, locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !contextualStrings.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings[.general] = Array(contextualStrings.prefix(400))
            try? await analyzer.setContext(ctx)
        }
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NaviError.other("The speech model reports no usable audio format")
        }
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.finalized = ""
        self.lastVolatile = ""

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, !Task.isCancelled else { return }
                    let text = String(result.text.characters)
                    #if DEBUG
                    DebugTrace.log("voice asr | \(result.isFinal ? "FINAL" : "volatile") audio=\(String(format: "%.2f", result.range.start.seconds))–\(String(format: "%.2f", result.range.end.seconds))s “\(text.suffix(50))”")
                    #endif
                    if result.isFinal {
                        self.append(final: text)
                        self.lastVolatile = ""
                        self.onEvent?(.transcript(finalized: self.finalized, volatile: ""))
                    } else {
                        self.lastVolatile = text
                        self.onEvent?(.transcript(finalized: self.finalized, volatile: text))
                    }
                }
                // The stream ended on its own (it never does while the analyzer is
                // healthy): the session restarts the recognizer.
                guard let self, self.isRunning, !Task.isCancelled else { return }
                Log.voice.error("speech results stream ended unexpectedly")
                self.onEvent?(.failed("Speech recognition stopped"))
            } catch is CancellationError {
            } catch {
                guard let self, self.isRunning else { return }
                Log.voice.error("speech results stream failed: \(error.localizedDescription, privacy: .public)")
                self.onEvent?(.failed(error.localizedDescription))
            }
        }
        try await analyzer.start(inputSequence: stream)

        let onLevel: @Sendable (Float) -> Void = { [weak self] l in
            Task { @MainActor in self?.onEvent?(.level(l)) }
        }
        if let audioFile {
            try startFilePlayback(audioFile, analyzerFormat: analyzerFormat, continuation: continuation, onLevel: onLevel)
        } else {
            try startEngine(analyzerFormat: analyzerFormat, continuation: continuation, onLevel: onLevel)
        }
        isRunning = true
        #if DEBUG
        DebugTrace.log("voice listener ready (\(locale.identifier), \(audioFile == nil ? "microphone" : "file"))")
        #endif
        Log.voice.info("listening (\(locale.identifier, privacy: .public), \(audioFile == nil ? "microphone" : "file", privacy: .public))")
        onEvent?(.ready(locale.identifier))
    }

    func stop() async {
        guard isRunning || analyzer != nil else { return }
        isRunning = false
        if let configObserver { NotificationCenter.default.removeObserver(configObserver); self.configObserver = nil }
        fileTask?.cancel(); fileTask = nil
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        pipe?.finish()
        pipe = nil
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer {
            // Don't wait on a stuck model; give it a moment to flush and move on.
            let t = Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
            _ = await withTaskGroup(of: Void.self) { group in
                group.addTask { await t.value }
                group.addTask { try? await Task.sleep(for: .milliseconds(600)) }
                await group.next()
                group.cancelAll()
            }
        }
        analyzer = nil
        transcriber = nil
        Log.voice.info("stopped listening")
    }

    // MARK: Model

    private func ensureModel(_ transcriber: SpeechTranscriber, locale: Locale) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])
        switch status {
        case .installed:
            return
        case .unsupported:
            throw NaviError.other("On-device speech recognition doesn't support \(locale.identifier)")
        default:
            _ = try? await AssetInventory.reserve(locale: locale)
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
            onEvent?(.downloading(0))
            let observation = request.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] p, _ in
                let f = p.fractionCompleted
                Task { @MainActor in self?.onEvent?(.downloading(f)) }
            }
            defer { observation.invalidate() }
            Log.voice.info("downloading speech model for \(locale.identifier, privacy: .public)")
            try await request.downloadAndInstall()
        }
    }

    // MARK: Audio engine (microphone)

    private func startEngine(analyzerFormat: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
                             onLevel: @escaping @Sendable (Float) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NaviError.other("No microphone input device is available")
        }
        let pipe = AudioPipe(input: format, output: analyzerFormat, continuation: continuation, onLevel: onLevel)
        self.pipe = pipe
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            pipe.ingest(buffer)   // audio thread
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw NaviError.other("Couldn't start the microphone: \(error.localizedDescription)")
        }
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                Log.voice.info("audio configuration changed — restarting the microphone")
                self.onEvent?(.failed("The audio input device changed"))
            }
        }
    }

    // MARK: File playback (debug probe)

    /// Feeds an audio file at real-time pace so the segmenter's timing
    /// (debounce, silence) behaves as it would with a person speaking.
    private func startFilePlayback(_ url: URL, analyzerFormat: AVAudioFormat,
                                   continuation: AsyncStream<AnalyzerInput>.Continuation,
                                   onLevel: @escaping @Sendable (Float) -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let pipe = AudioPipe(input: format, output: analyzerFormat, continuation: continuation, onLevel: onLevel)
        self.pipe = pipe
        let chunk = AVAudioFrameCount(format.sampleRate / 10)   // 100 ms
        fileTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
                do { try file.read(into: buffer, frameCount: chunk) } catch { break }
                if buffer.frameLength == 0 { break }
                pipe.ingest(buffer)
                try? await Task.sleep(for: .milliseconds(100))
            }
            // Trailing silence, then a flush, so the recognizer delivers the last words.
            if let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) {
                silence.frameLength = chunk
                for _ in 0..<15 where !Task.isCancelled {
                    pipe.ingest(silence)
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// Asks the model to finalize everything heard so far. The session calls
    /// this after a short acoustic pause so the words the recognizer is still
    /// holding (it reports in ~1 s windows) arrive now instead of a second later.
    func flush() async {
        guard let analyzer, isRunning else { return }
        #if DEBUG
        DebugTrace.log("voice flush")
        #endif
        try? await analyzer.finalize(through: nil)
    }

    // MARK: Transcript bookkeeping

    private func append(final text: String) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A flush mid-utterance can finalize the audio as punctuation alone
        // ("....." for "Make a new document."): the words the user already saw
        // must not vanish, so the last volatile text stands in for them.
        if Self.wordCount(t) == 0, Self.wordCount(lastVolatile) > 0 {
            Log.voice.info("final result had no words (\(t, privacy: .public)); keeping the volatile text")
            t = lastVolatile.trimmingCharacters(in: .whitespacesAndNewlines) + t
        }
        guard !t.isEmpty else { return }
        if finalized.isEmpty { finalized = t }
        else { finalized += " " + t }
        // Keep the running transcript bounded; the segmenter only needs the tail.
        if finalized.count > 4000 { finalized = String(finalized.suffix(3000)) }
    }

    /// Words with at least one letter or digit.
    nonisolated static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
    }
}

// MARK: - Audio pipe (audio-thread side)

/// Owns what the capture thread needs: the sample-rate converter, the
/// analyzer's input continuation and the level meter. Everything here runs on
/// the thread that produces buffers (the audio tap or the file task) — never
/// on the main actor.
final class AudioPipe: @unchecked Sendable {
    private let output: AVAudioFormat
    private let converter: AVAudioConverter?
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let onLevel: @Sendable (Float) -> Void
    private var sampler = LevelSampler()

    init(input: AVAudioFormat, output: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
         onLevel: @escaping @Sendable (Float) -> Void) {
        self.output = output
        self.converter = input == output ? nil : AVAudioConverter(from: input, to: output)
        self.continuation = continuation
        self.onLevel = onLevel
    }

    func ingest(_ buffer: AVAudioPCMBuffer) {
        if let level = sampler.sample(buffer) { onLevel(level) }
        guard let converted = convert(buffer) else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    func finish() { continuation.finish() }

    /// Resamples a buffer to the analyzer's format (usually 16 kHz mono float).
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer.format == output ? buffer : nil }
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed { inputStatus.pointee = .noDataNow; return nil }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error { return nil }
        return out.frameLength > 0 ? out : nil
    }
}

// MARK: - Level metering

/// RMS → 0…1 with a little smoothing, throttled to ~25 Hz.
struct LevelSampler {
    private var smoothed: Float = 0
    private var lastEmit = Date.distantPast

    mutating func sample(_ buffer: AVAudioPCMBuffer) -> Float? {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        let ch = data[0]
        for i in stride(from: 0, to: n, by: 4) { sum += ch[i] * ch[i] }
        let rms = (sum / Float(max(1, n / 4))).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        // -55 dB (quiet room) … -12 dB (loud speech) → 0…1
        let norm = min(1, max(0, (db + 55) / 43))
        smoothed = norm > smoothed ? norm : smoothed * 0.75 + norm * 0.25
        let now = Date()
        guard now.timeIntervalSince(lastEmit) >= 0.04 else { return nil }
        lastEmit = now
        return smoothed
    }
}
