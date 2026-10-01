import AVFoundation
import CoreML
import Foundation

/// The user's voice, learned once (`VoiceEnrollment`) so voice control acts only on
/// what *they* say — not a roommate, a meeting next door, or someone leaning over.
///
/// A speaker model (WeSpeaker ResNet34, trained on VoxCeleb; bundled as
/// `SpeakerEmbedding.mlpackage`, int8) turns ~1–4 s of speech into a 256-number
/// voiceprint; two clips of the same person point the same way (cosine ≈ 0.6–0.85),
/// different people do not (≈ 0–0.3). Enrollment averages the user's prompts into one
/// centroid and sets the bar from how much their own clips vary. Live, each clause's
/// audio (`SpeechListener.voiceAudio`) is scored before Jev is asked; another voice is
/// dropped silently, like echo. Everything stays on this Mac (`VoicePrintStore`).
struct VoicePrint: Codable, Equatable, Sendable {
    /// Unit vector: the average of the user's enrollment embeddings, adapted slowly over use.
    var centroid: [Float]
    /// Accept a clip whose cosine with `centroid` is at least this.
    var threshold: Float
    /// How the user's own enrollment windows scored (mean, standard deviation).
    var selfMean: Float
    var selfSpread: Float
    /// Embeddings folded in (enrollment + adaptation).
    var count: Int
    var created: Date
    var updated: Date
    var model = VoicePrint.modelName

    static let modelName = "wespeaker-resnet34-lm-int8"
    static let dimension = 256
    /// The bar never goes below or above these, whatever enrollment measured.
    static let minThreshold: Float = 0.32
    static let maxThreshold: Float = 0.55
    /// Clips shorter than this carry less of the voice: the bar drops a little for them.
    static let shortClipSeconds = 1.2
    static let shortClipMargin: Float = 0.08

    // MARK: Math (pure)

    static func normalized(_ v: [Float]) -> [Float] {
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }

    static func mean(_ vs: [[Float]]) -> [Float] {
        guard let first = vs.first else { return [] }
        var m = [Float](repeating: 0, count: first.count)
        for v in vs { for i in m.indices { m[i] += v[i] } }
        return m.map { $0 / Float(vs.count) }
    }

    /// A voiceprint from enrollment: one embedding list per prompt (the whole prompt
    /// plus its 2-second windows). Each window is scored against the centroid of the
    /// *other* prompts — how a new clip of the user will score — and the bar sits
    /// three spreads below that, within `minThreshold…maxThreshold`.
    static func enroll(prompts: [[[Float]]], now: Date = Date()) -> VoicePrint? {
        let usable = prompts.filter { !$0.isEmpty }
        guard usable.count >= 2 else { return nil }
        let unit = usable.map { $0.map(normalized) }
        let centroid = normalized(mean(unit.flatMap { $0 }))
        var scores: [Float] = []
        for (i, p) in unit.enumerated() {
            let others = normalized(mean(unit.enumerated().filter { $0.offset != i }.flatMap(\.element)))
            scores += p.map { cosine($0, others) }
        }
        let mu = scores.reduce(0, +) / Float(scores.count)
        let sd = (scores.reduce(0) { $0 + ($1 - mu) * ($1 - mu) } / Float(max(1, scores.count - 1))).squareRoot()
        let t = min(maxThreshold, max(minThreshold, mu - 3 * sd))
        return VoicePrint(centroid: centroid, threshold: t, selfMean: mu, selfSpread: sd,
                          count: unit.reduce(0) { $0 + $1.count }, created: now, updated: now)
    }

    /// Prompts whose voice does not match the rest (someone else read it, or it was mostly
    /// noise): their whole-prompt embedding against the centroid of the others.
    static func outliers(prompts: [[Float]], below bar: Float = 0.45) -> [Int] {
        guard prompts.count >= 3 else { return [] }
        let unit = prompts.map(normalized)
        return unit.indices.filter { i in
            cosine(unit[i], normalized(mean(unit.enumerated().filter { $0.offset != i }.map(\.element)))) < bar
        }
    }

    enum Verdict: Equatable, Sendable {
        case user(Float)
        case other(Float)
        /// Too little audio to tell: the clause is not held back.
        case unsure
    }

    /// The verdict for one clip's embedding.
    func verdict(_ embedding: [Float], seconds: Double) -> Verdict {
        let s = Self.cosine(embedding, centroid)
        let bar = threshold - (seconds < Self.shortClipSeconds ? Self.shortClipMargin : 0)
        return s >= bar ? .user(s) : .other(s)
    }

    /// Clearly the user, on a clip long enough to trust: fold it in, slowly, so the
    /// voiceprint follows a new microphone or a cold without drifting to anyone else.
    mutating func adapt(_ embedding: [Float], score: Float, seconds: Double, now: Date = Date()) -> Bool {
        guard seconds >= 1.5, score >= threshold + 0.15, embedding.count == centroid.count else { return false }
        let w: Float = 0.97
        centroid = Self.normalized(zip(centroid, Self.normalized(embedding)).map { w * $0 + (1 - w) * $1 })
        count += 1
        updated = now
        return true
    }
}

// MARK: - Storage

/// `voiceprint.json` in Navi's data folder, readable by this user only. Deleted with
/// "Forget my voice" and with "Delete everything Navi has stored".
enum VoicePrintStore {
    static var fileURL: URL { NaviSettings.dataDirectory.appendingPathComponent("voiceprint.json") }

    static func load(from url: URL = fileURL) -> VoicePrint? {
        guard let data = try? Data(contentsOf: url), let p = try? JSONDecoder().decode(VoicePrint.self, from: data),
              p.model == VoicePrint.modelName, p.centroid.count == VoicePrint.dimension else { return nil }
        return p
    }

    static func save(_ p: VoicePrint, to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(p).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        NotificationCenter.default.post(name: .naviVoicePrintChanged, object: nil)
    }

    static func delete(at url: URL = fileURL) {
        try? FileManager.default.removeItem(at: url)
        NotificationCenter.default.post(name: .naviVoicePrintChanged, object: nil)
    }

    static var exists: Bool { load() != nil }
}

extension Notification.Name {
    static let naviVoicePrintChanged = Notification.Name("naviVoicePrintChanged")
}

// MARK: - Model

/// The bundled speaker model. Thread-safe; loaded on first use (~50 ms), CPU + GPU
/// (the Neural Engine compiler rejects its flexible input length).
final class SpeakerModel: @unchecked Sendable {
    static let shared = SpeakerModel()
    private let lock = NSLock()
    /// Predictions one at a time: Core ML does not promise a model is safe to share across threads.
    private let predictLock = NSLock()
    private var model: MLModel?
    private var failed = false

    /// Shortest clip worth embedding, and the longest used (the most recent part).
    static let minSeconds = 0.5
    static let maxSeconds = 8.0

    var isAvailable: Bool { loaded() != nil }

    private func loaded() -> MLModel? {
        lock.lock(); defer { lock.unlock() }
        if let model { return model }
        if failed { return nil }
        guard let url = Bundle.main.url(forResource: "SpeakerEmbedding", withExtension: "mlmodelc") else {
            failed = true
            Log.voice.error("speaker model missing from the app bundle")
            return nil
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU
        do { model = try MLModel(contentsOf: url, configuration: config) } catch {
            failed = true
            Log.voice.error("speaker model failed to load: \(error.localizedDescription, privacy: .public)")
        }
        return model
    }

    /// The voiceprint of 16 kHz mono samples (−1…1), or nil for too little audio.
    func embedding(_ samples: [Float]) -> [Float]? {
        let maxN = Int(Self.maxSeconds * Double(VoiceFbank.sampleRate))
        let clip = samples.count > maxN ? Array(samples.suffix(maxN)) : samples
        guard Double(clip.count) >= Self.minSeconds * Double(VoiceFbank.sampleRate), let model = loaded() else { return nil }
        let (values, frames) = VoiceFbank.features(clip)
        guard frames >= 40,
              let input = try? MLMultiArray(shape: [1, NSNumber(value: frames), NSNumber(value: VoiceFbank.melBins)], dataType: .float32) else { return nil }
        let ptr = input.dataPointer.bindMemory(to: Float.self, capacity: values.count)
        values.withUnsafeBufferPointer { ptr.update(from: $0.baseAddress!, count: values.count) }
        predictLock.lock()
        let out = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["fbank": input]))
        predictLock.unlock()
        guard let e = out?.featureValue(for: "embedding")?.multiArrayValue else { return nil }
        return (0..<e.count).map { e[$0].floatValue }
    }

    /// Whole-clip embedding plus overlapping `window`-second windows (enrollment statistics).
    func embeddings(_ samples: [Float], window: Double = 2, hop: Double = 1) -> [[Float]] {
        var out: [[Float]] = []
        if let whole = embedding(samples) { out.append(whole) }
        let w = Int(window * Double(VoiceFbank.sampleRate)), h = Int(hop * Double(VoiceFbank.sampleRate))
        var start = 0
        while start + w <= samples.count {
            if let e = embedding(Array(samples[start..<(start + w)])) { out.append(e) }
            start += h
        }
        return out
    }
}

// MARK: - Recent audio

/// The last `capacity` seconds of what the recognizer heard, at 16 kHz, indexed by the
/// recognizer's own clock (seconds since it started) so a clause's word times map to
/// its samples. Written on the audio thread, read on any.
final class VoiceAudioRing: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [Float]
    private var written = 0          // samples ever written
    private let capacity: Int
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(VoiceFbank.sampleRate), channels: 1, interleaved: false)!

    init(seconds: Double = 30) {
        capacity = Int(seconds * Double(VoiceFbank.sampleRate))
        buffer = [Float](repeating: 0, count: capacity)
    }

    /// Appends one buffer the recognizer is fed (any format; resampled to 16 kHz mono float).
    func append(_ b: AVAudioPCMBuffer) {
        guard let mono = Self.toFormat(b, converter: &converter, source: &converterSource) else { return }
        lock.lock(); defer { lock.unlock() }
        for s in mono {
            buffer[written % capacity] = s
            written += 1
        }
    }

    /// Samples between `start` and `end` seconds of the recognizer's clock; nil when that
    /// audio is gone from the ring or was never heard.
    func samples(from start: Double, to end: Double) -> [Float]? {
        let sr = Double(VoiceFbank.sampleRate)
        lock.lock(); defer { lock.unlock() }
        let a = max(0, Int(start * sr)), b = min(written, Int(end * sr))
        guard b > a, a >= written - capacity else { return nil }
        return (a..<b).map { buffer[$0 % capacity] }
    }

    var seconds: Double { lock.lock(); defer { lock.unlock() }; return Double(written) / Double(VoiceFbank.sampleRate) }

    private static func toFormat(_ b: AVAudioPCMBuffer, converter: inout AVAudioConverter?, source: inout AVAudioFormat?) -> [Float]? {
        let n = Int(b.frameLength)
        guard n > 0 else { return nil }
        let f = b.format
        if f.sampleRate == Double(VoiceFbank.sampleRate), f.channelCount == 1 {
            if let d = b.floatChannelData { return Array(UnsafeBufferPointer(start: d[0], count: n)) }
            if let d = b.int16ChannelData { return UnsafeBufferPointer(start: d[0], count: n).map { Float($0) / 32768 } }
        }
        if converter == nil || source != f { converter = AVAudioConverter(from: f, to: format); source = f }
        guard let converter, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(n) * 16_000 / f.sampleRate) + 32) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return b
        }
        guard let d = out.floatChannelData, out.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: d[0], count: Int(out.frameLength)))
    }
}

// MARK: - Word times

/// One recognized word and when it was said (seconds on the recognizer's clock).
struct TimedWord: Equatable, Sendable {
    var word: String
    var start: Double
    var end: Double

    /// "Chrome," → "chrome": how words are compared.
    static func key(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// When the words of `head` were said: the last place they occur in `words`, in order
    /// (exactly, else its first and last word with at most a few words between — the
    /// recognizer revises a word now and then). nil when they cannot be found.
    static func span(of head: String, in words: [TimedWord]) -> (start: Double, end: Double)? {
        let want = head.split(whereSeparator: { $0.isWhitespace }).map { key(String($0)) }.filter { !$0.isEmpty }
        let have = words.map { key($0.word) }
        guard !want.isEmpty, have.count >= want.count else { return nil }
        for i in stride(from: have.count - want.count, through: 0, by: -1) where Array(have[i..<(i + want.count)]) == want {
            return (words[i].start, words[i + want.count - 1].end)
        }
        guard let first = want.first, let last = want.last else { return nil }
        for j in stride(from: have.count - 1, through: 0, by: -1) where have[j] == last {
            let lo = max(0, j - want.count - 3)
            if let i = (lo...j).first(where: { have[$0] == first }), j - i + 1 >= max(1, want.count - 2) {
                return (words[i].start, words[j].end)
            }
        }
        return nil
    }
}

// MARK: - Live gate

/// Voice control's check that a clause was said by the user (`VoiceSession`, before Jev
/// is asked). Silent: another voice's clause is dropped like echo.
@MainActor
final class SpeakerGate {
    private(set) var print: VoicePrint?
    private var enabled = true
    private var cache: [String: VoicePrint.Verdict] = [:]
    private var lastSaved = Date.distantPast

    /// A voiceprint exists and the user wants it used (a model that fails to load makes every
    /// verdict `.unsure`, never a deaf Navi).
    var isActive: Bool { enabled && print != nil }

    func reload(enabled: Bool) {
        self.enabled = enabled
        print = VoicePrintStore.load()
        cache = [:]
        // Load the model now, off the main thread, so the first clause does not wait for it.
        if isActive { Task.detached(priority: .utility) { _ = SpeakerModel.shared.isAvailable } }
    }

    /// Words anyone at the Mac may say and the user must never be locked out of:
    /// stopping a run is always safe.
    nonisolated static func alwaysHeard(_ head: String) -> Bool {
        let w = head.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        guard let first = w.first, w.count <= 3 else { return false }
        return ["stop", "cancel", "pause", "undo", "abort", "halt"].contains(first) || w == ["never", "mind"]
    }

    /// The verdict for a clause, from its own audio. `.unsure` (too little audio, words not
    /// found) lets it through: a voiceprint must never make Navi deaf to the user.
    func check(head: String, audio: (samples: [Float], seconds: Double)?) async -> VoicePrint.Verdict {
        guard isActive, let print, let audio, audio.seconds >= SpeakerModel.minSeconds else { return .unsure }
        let key = head + "|" + String(format: "%.1f", audio.seconds)
        if let v = cache[key] { return v }
        let samples = audio.samples
        guard let e = await Task.detached(priority: .userInitiated, operation: { SpeakerModel.shared.embedding(samples) }).value else { return .unsure }
        let v = print.verdict(e, seconds: audio.seconds)
        if cache.count > 64 { cache.removeAll() }
        cache[key] = v
        if case .user(let s) = v {
            var p = print
            if p.adapt(e, score: s, seconds: audio.seconds) {
                self.print = p
                // A slow drift needs no fsync per clause: at most once a minute.
                if Date().timeIntervalSince(lastSaved) > 60 { lastSaved = Date(); try? VoicePrintStore.save(p) }
            }
        }
        return v
    }
}
