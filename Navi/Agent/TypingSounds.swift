import AVFoundation
import Foundation

// Soft mechanical key clicks while Navi types — after Screendrop's typing
// sounds (github.com/fayazara/Screendrop, CC0 1.0). Screendrop lays them under
// a recording; here they voice the agent's own keystrokes live, so the user can
// hear Navi working even when it drives an app behind their windows.
//
// Only Navi's synthesized input makes a sound (`InputController`, AXValue fills,
// browser fills); the user's own typing never does, and which key was pressed
// is never kept — only its coarse class.

// MARK: - Key classes

/// The coarse class of a keypress, enough to pick a believable sound.
enum TypingKeyKind: CaseIterable, Sendable {
    case key, space, returnKey, delete, modifier

    /// Classifies a key-down by virtual key code.
    static func kind(forKeyCode keyCode: UInt16) -> TypingKeyKind {
        switch keyCode {
        case 49: return .space
        case 36, 76: return .returnKey
        case 51, 117: return .delete
        case 54...63: return .modifier   // ⌘ ⇧ ⇪ ⌥ ⌃ (left and right), fn
        default: return .key
        }
    }

    /// Classifies a typed character (unicode key events carry no key code).
    static func kind(for character: Character) -> TypingKeyKind {
        switch character {
        case " ": return .space
        case "\n", "\r", "\r\n": return .returnKey
        default: return .key
        }
    }
}

/// One sound on a burst's timeline, `offset` seconds from its start.
struct TypingSoundEvent: Equatable, Sendable {
    var offset: TimeInterval
    var kind: TypingKeyKind
}

// MARK: - Pacing

/// Decides which keystrokes get a sound. `InputController` types a character
/// every 8 ms — 125 keys a second, a buzz if every one clicked — so a key is
/// voiced only when a person could have pressed it: at most one every
/// 70–130 ms (jittered so it never sounds metronomic), Return always. Long
/// text therefore sounds like fast typing for exactly as long as it goes in.
struct TypingSoundPacer {
    static let gap: ClosedRange<TimeInterval> = 0.07...0.13
    /// Return is the key you hear end a line; only a double press is merged.
    static let returnGap: TimeInterval = 0.03

    private var lastVoiced: TimeInterval = -.infinity
    private var nextGap: TimeInterval
    private var random: SeededRandom

    init(seed: UInt64 = 0x7E57_1C1C_0000_0001) {
        var random = SeededRandom(seed: seed)
        nextGap = random.next(in: Self.gap)
        self.random = random
    }

    mutating func shouldVoice(_ kind: TypingKeyKind, at time: TimeInterval) -> Bool {
        guard time - lastVoiced >= (kind == .returnKey ? Self.returnGap : nextGap) else { return false }
        lastVoiced = time
        nextGap = random.next(in: Self.gap)
        return true
    }

    /// Text that went in all at once (an AXValue set, a browser fill) has no
    /// keystrokes to follow, so it gets a short run of typing at a natural
    /// pace — a character every 60–110 ms, a little longer after a space —
    /// capped at `maxDuration` so a paragraph doesn't clatter on long after
    /// it appeared.
    static func burst(for text: String, maxDuration: TimeInterval = 0.9, seed: UInt64) -> [TypingSoundEvent] {
        var random = SeededRandom(seed: seed)
        var events: [TypingSoundEvent] = []
        var time: TimeInterval = 0
        for character in text.trimmingCharacters(in: .whitespaces) {
            if time > maxDuration { break }
            let kind = TypingKeyKind.kind(for: character)
            events.append(TypingSoundEvent(offset: time, kind: kind))
            time += kind == .key ? random.next(in: 0.06...0.11) : random.next(in: 0.12...0.2)
        }
        return events
    }
}

// MARK: - Synthesis

/// Builds key sounds from one recorded mechanical keystroke
/// (`TypingSoundSamples`): the press at the keypress and the release a moment
/// later. Each key class and variant gets its own pitch, level, release timing
/// and stereo position so fast typing never sounds looped. (Screendrop's
/// synthesizer, minus the profiles it no longer ships.)
enum TypingSoundSynthesizer {
    static let sampleRate: Double = 48_000
    static let variantsPerKind = 6

    /// One rendered keypress in stereo.
    struct Hit: Sendable {
        let left: [Float]
        let right: [Float]
        var frameCount: Int { left.count }
    }

    static func bank() -> [TypingKeyKind: [Hit]] {
        // The recording is quiet; bring the press up to a healthy peak and
        // scale the release by the same amount so their balance holds.
        let peak = TypingSoundSamples.keyDown.reduce(Int32(1)) { max($0, abs(Int32($1))) }
        let scale = 0.75 / Float(peak)
        let down = TypingSoundSamples.keyDown.map { Float($0) * scale }
        let up = TypingSoundSamples.keyUp.map { Float($0) * scale }
        let kinds: [TypingKeyKind] = [.key, .space, .returnKey, .delete, .modifier]
        var bank: [TypingKeyKind: [Hit]] = [:]
        for (kindIndex, kind) in kinds.enumerated() {
            bank[kind] = (0..<variantsPerKind).map { variant in
                var random = SeededRandom(seed: UInt64(kindIndex * 1_000 + variant + 1) &* 0x9E37_79B9_7F4A_7C15)
                return hit(kind: kind, down: down, up: up, random: &random)
            }
        }
        return bank
    }

    private static func hit(kind: TypingKeyKind, down: [Float], up: [Float], random: inout SeededRandom) -> Hit {
        // Bigger keys ring lower; modifiers are pressed lightly.
        let kindPitch: Double, kindGain: Float
        switch kind {
        case .key: kindPitch = 1; kindGain = 1
        case .space: kindPitch = 0.84; kindGain = 1.1
        case .returnKey: kindPitch = 0.9; kindGain = 1.05
        case .delete: kindPitch = 0.95; kindGain = 1
        case .modifier: kindPitch = 1.04; kindGain = 0.7
        }
        let level = kindGain * Float(random.next(in: 0.85...1.0))
        let pitch = kindPitch * random.next(in: 0.95...1.05)
        let upGain = level * Float(random.next(in: 0.75...0.95))
        let releaseDelay = random.next(in: 0.07...0.11) * (kind == .space ? 1.2 : 1)

        let pressed = resampled(down, pitch: pitch)
        let released = resampled(up, pitch: pitch)
        let releaseStart = Int(releaseDelay * sampleRate)
        var mono = [Float](repeating: 0, count: max(pressed.count, releaseStart + released.count))
        for i in pressed.indices { mono[i] += pressed[i] * level }
        for i in released.indices { mono[releaseStart + i] += released[i] * upGain }

        // Keys sit slightly left or right of centre; the space bar is wide and central.
        let pan = kind == .space ? 0 : random.next(in: -0.25...0.25)
        let angle = (pan + 1) * .pi / 4
        let leftGain = Float(cos(angle) * 2.squareRoot())
        let rightGain = Float(sin(angle) * 2.squareRoot())
        return Hit(left: mono.map { $0 * leftGain }, right: mono.map { $0 * rightGain })
    }

    /// Resamples to the output rate at `pitch`; linear interpolation is plenty
    /// for clicks this short.
    private static func resampled(_ source: [Float], pitch: Double) -> [Float] {
        let step = TypingSoundSamples.sampleRate / sampleRate * pitch
        let length = Int(Double(source.count - 1) / step)
        guard length > 0 else { return [] }
        var output = [Float](repeating: 0, count: length)
        for i in 0..<length {
            let position = Double(i) * step
            let lower = Int(position)
            let fraction = Float(position - Double(lower))
            let next = min(lower + 1, source.count - 1)
            output[i] = source[lower] + (source[next] - source[lower]) * fraction
        }
        return output
    }
}

/// SplitMix64: tiny, deterministic, good enough for audio jitter.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        let unit = Double(nextUInt64() >> 11) / Double(UInt64(1) << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}

// MARK: - Playback

/// Plays the agent's keystrokes live. Callers are off the main actor and must
/// never be slowed down, so everything happens on a private serial queue and
/// settings are read straight from UserDefaults (`enabledKey`, `volumeKey` —
/// `NaviSettings` writes them). The audio engine starts on the first key and
/// stops after a few quiet seconds, so Navi holds no audio hardware while idle;
/// a device change that stops it is picked up by the next key.
final class TypingSoundPlayer: @unchecked Sendable {
    static let shared = TypingSoundPlayer()

    static let enabledKey = "agentTypingSounds"
    static let volumeKey = "agentTypingSoundsVolume"
    static let defaultVolume = 0.5

    /// Enough voices that a hit's release tail is never cut off by the next key.
    private static let voiceCount = 4
    private static let idleSeconds = 3.0

    private let queue = DispatchQueue(label: "com.liamcarlin.navi.typing-sounds", qos: .userInitiated)
    // Everything below is confined to `queue`.
    private var engine: AVAudioEngine?
    private var voices: [AVAudioPlayerNode] = []
    private var nextVoice = 0
    private var buffers: [TypingKeyKind: [AVAudioPCMBuffer]] = [:]
    private var lastVariant: [TypingKeyKind: Int] = [:]
    private var random = SeededRandom(seed: 0x5EED_0F7E_C11C)
    private var pacer = TypingSoundPacer()
    private var idleStop: DispatchWorkItem?

    var isEnabled: Bool { UserDefaults.navi.object(forKey: Self.enabledKey) as? Bool ?? false }

    private var volume: Float {
        let v = UserDefaults.navi.object(forKey: Self.volumeKey) as? Double ?? Self.defaultVolume
        return Float(v.isFinite ? min(max(v, 0), 1) : Self.defaultVolume)
    }

    /// One synthesized key-down (`InputController`); paced by `TypingSoundPacer`.
    func keyDown(_ kind: TypingKeyKind) {
        guard isEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            guard pacer.shouldVoice(kind, at: now) else { return }
            play(kind)
        }
    }

    /// Text that went in all at once (an AXValue set, a browser fill).
    func burst(_ text: String) {
        guard isEnabled else { return }
        schedule(text)
    }

    /// Settings → Agent → Preview: plays even while typing sounds are off.
    func preview() {
        schedule("Hello, Navi\n")
    }

    private func schedule(_ text: String) {
        queue.async { [self] in
            let start = DispatchTime.now()
            for event in TypingSoundPacer.burst(for: text, seed: random.nextUInt64()) {
                queue.asyncAfter(deadline: start + event.offset) { [self] in play(event.kind) }
            }
        }
    }

    // MARK: Engine (on `queue`)

    private func play(_ kind: TypingKeyKind) {
        guard startEngineIfNeeded(), !voices.isEmpty,
              let variants = buffers[kind] ?? buffers[.key], !variants.isEmpty else { return }
        // Never the same variant twice in a row for a kind.
        var variant = Int(random.nextUInt64() % UInt64(variants.count))
        if variants.count > 1, variant == lastVariant[kind] { variant = (variant + 1) % variants.count }
        lastVariant[kind] = variant

        let voice = voices[nextVoice]
        nextVoice = (nextVoice + 1) % voices.count
        voice.volume = volume
        voice.scheduleBuffer(variants[variant], completionHandler: nil)

        idleStop?.cancel()
        let stop = DispatchWorkItem { [weak self] in self?.stopEngine() }
        idleStop = stop
        queue.asyncAfter(deadline: .now() + Self.idleSeconds, execute: stop)
    }

    private func startEngineIfNeeded() -> Bool {
        if let engine, engine.isRunning { return true }
        if engine == nil {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: TypingSoundSynthesizer.sampleRate, channels: 2) else { return false }
            let e = AVAudioEngine()
            let nodes = (0..<Self.voiceCount).map { _ in AVAudioPlayerNode() }
            for node in nodes {
                e.attach(node)
                e.connect(node, to: e.mainMixerNode, format: format)
            }
            buffers = Self.buffers(format: format)
            engine = e
            voices = nodes
        }
        guard let engine else { return false }
        voices.forEach { $0.stop() }   // a device change stops the engine under playing nodes
        do {
            try engine.start()
        } catch {
            Log.agent.debug("Typing sounds: audio engine did not start: \(error.localizedDescription, privacy: .public)")
            return false
        }
        voices.forEach { $0.play() }
        return true
    }

    private func stopEngine() {
        voices.forEach { $0.stop() }
        engine?.stop()
    }

    private static func buffers(format: AVAudioFormat) -> [TypingKeyKind: [AVAudioPCMBuffer]] {
        TypingSoundSynthesizer.bank().mapValues { hits in
            hits.compactMap { hit in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(hit.frameCount)),
                      let channels = buffer.floatChannelData else { return nil }
                buffer.frameLength = AVAudioFrameCount(hit.frameCount)
                for i in 0..<hit.frameCount {
                    channels[0][i] = hit.left[i]
                    channels[1][i] = hit.right[i]
                }
                return buffer
            }
        }
    }
}
