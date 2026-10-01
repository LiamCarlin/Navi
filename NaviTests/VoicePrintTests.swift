import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import Navi

/// "Only my voice": features, the bundled speaker model, the voiceprint math, word times
/// and the gate's rules. The fixture (`Fixtures/voice_fixture.json`, made by
/// `scripts/voiceprint/fixture.py`) holds a few seconds of two synthetic voices plus
/// torchaudio's fbank and PyTorch's embedding for one of them.
@Suite struct VoicePrintTests {
    private final class Marker {}

    struct Fixture: Decodable {
        var pcm16: String
        var frames: Int
        var raw_rows: [[Float]]
        var cmn_frame_sums: [Float]
        var embedding: [Float]
        var clips: [String: String]
    }

    static let fixture: Fixture = {
        let bundle = Bundle(for: Marker.self)
        let url = bundle.url(forResource: "voice_fixture", withExtension: "json")!
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    static func samples(_ b64: String) -> [Float] {
        let d = Data(base64Encoded: b64)!
        return d.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 } }
    }

    // MARK: Features and model

    @Test func fbankMatchesTorchaudio() {
        let s = Self.samples(Self.fixture.pcm16)
        #expect(VoiceFbank.frameCount(s.count) == Self.fixture.frames)
        let raw = VoiceFbank.logMel(s)
        for (row, frame) in zip(Self.fixture.raw_rows, [0, 1, 70, 147]) {
            let mine = Array(raw[(frame * 80)..<((frame + 1) * 80)])
            let worst = zip(mine, row).map { abs($0 - $1) }.max() ?? 1
            #expect(worst < 0.02, "frame \(frame) differs by \(worst)")
        }
        let (cmn, frames) = VoiceFbank.features(s)
        let sums = (0..<frames).map { f in cmn[(f * 80)..<((f + 1) * 80)].reduce(0, +) }
        let worst = zip(sums, Self.fixture.cmn_frame_sums).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 0.5)
    }

    @Test func bundledModelMatchesPyTorch() throws {
        let e = try #require(SpeakerModel.shared.embedding(Self.samples(Self.fixture.pcm16)))
        #expect(e.count == VoicePrint.dimension)
        #expect(VoicePrint.cosine(e, Self.fixture.embedding) > 0.995)
    }

    @Test func tellsTwoVoicesApart() throws {
        func emb(_ n: String) throws -> [Float] { try #require(SpeakerModel.shared.embedding(Self.samples(Self.fixture.clips[n]!))) }
        let s1 = try emb("Samantha_1"), s2 = try emb("Samantha_2"), d1 = try emb("Daniel_1"), d2 = try emb("Daniel_2")
        let same = min(VoicePrint.cosine(s1, s2), VoicePrint.cosine(d1, d2))
        let other = max(VoicePrint.cosine(s1, d1), VoicePrint.cosine(s2, d2), VoicePrint.cosine(s1, d2))
        #expect(same > 0.5 && other < 0.4 && same - other > 0.3)
        // Enrolled on one voice: the same voice passes, the other is turned away.
        let print = try #require(VoicePrint.enroll(prompts: [[s1], [s2], [s1, s2]]))
        #expect(print.verdict(d1, seconds: 2) == .other(VoicePrint.cosine(d1, print.centroid)))
        if case .user = print.verdict(s2, seconds: 2) {} else { Issue.record("the enrolled voice should pass") }
    }

    // MARK: Voiceprint math

    /// A unit vector: random for `seed`, or `around` a unit vector with noise of about `noise` (relative).
    static func unit(_ seed: Int, noise: Float = 0.3, around base: [Float]? = nil) -> [Float] {
        var x = UInt64(truncatingIfNeeded: seed &* 2654435761 &+ 1)
        func rnd() -> Float { x = x &* 6364136223846793005 &+ 1442695040888963407; return Float((x >> 33) % 2000) / 1000 - 1 }
        guard let base else { return VoicePrint.normalized((0..<VoicePrint.dimension).map { _ in rnd() }) }
        let scale = noise * Float(3).squareRoot() / Float(VoicePrint.dimension).squareRoot()
        return VoicePrint.normalized(base.map { $0 + scale * rnd() })
    }

    @Test func enrollmentSetsABarFromTheUsersOwnSpread() throws {
        let voice = Self.unit(1, noise: 0)
        let prompts = (0..<6).map { p in (0..<4).map { w in Self.unit(100 + p * 10 + w, noise: 0.6, around: voice) } }
        let print = try #require(VoicePrint.enroll(prompts: prompts))
        #expect(print.threshold >= VoicePrint.minThreshold && print.threshold <= VoicePrint.maxThreshold)
        #expect(print.selfMean > print.threshold)
        #expect(print.count == 24)
        #expect(VoicePrint.enroll(prompts: [prompts[0]]) == nil)                   // one line is not a voiceprint
        // A line read by someone else stands out.
        var lines = prompts.map { $0[0] }
        lines[2] = Self.unit(999, noise: 0)
        #expect(VoicePrint.outliers(prompts: lines) == [2])
    }

    @Test func shortClipsGetALowerBarAndOnlyConfidentLongOnesAdapt() {
        var print = VoicePrint(centroid: Self.unit(1, noise: 0), threshold: 0.45, selfMean: 0.7, selfSpread: 0.08,
                               count: 20, created: .distantPast, updated: .distantPast)
        // 0.42 of the voice and 0.9 of a direction orthogonal to it: cosine 0.42/√(0.42²+0.9²) ≈ 0.42.
        let r = Self.unit(7)
        let along = VoicePrint.cosine(r, print.centroid)
        let ortho = VoicePrint.normalized(zip(r, print.centroid).map { $0 - along * $1 })
        let near = VoicePrint.normalized(zip(print.centroid, ortho).map { 0.42 * $0 + 0.9 * $1 })
        let s = VoicePrint.cosine(near, print.centroid)
        #expect(s < 0.45 && s >= 0.37)
        if case .other = print.verdict(near, seconds: 2) {} else { Issue.record("below the bar on a long clip") }
        if case .user = print.verdict(near, seconds: 0.8) {} else { Issue.record("a short clip gets the margin") }
        let before = print.centroid
        let unsure = print.adapt(near, score: s, seconds: 3)                      // not confident: no drift
        let short = print.adapt(print.centroid, score: 0.9, seconds: 1)           // too short to trust
        let clear = print.adapt(Self.unit(3, noise: 0.2, around: before), score: 0.8, seconds: 3)
        #expect(!unsure && !short && clear)
        #expect(print.centroid != before && VoicePrint.cosine(print.centroid, before) > 0.99)
        #expect(print.count == 21)
    }

    @Test func voiceprintsSurviveAReloadAndForgetting() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vp-\(UUID().uuidString).json")
        let print = VoicePrint(centroid: Self.unit(2, noise: 0), threshold: 0.4, selfMean: 0.7, selfSpread: 0.1,
                               count: 24, created: Date(timeIntervalSince1970: 1_000), updated: Date(timeIntervalSince1970: 2_000))
        try VoicePrintStore.save(print, to: url)
        #expect(VoicePrintStore.load(from: url) == print)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        VoicePrintStore.delete(at: url)
        #expect(VoicePrintStore.load(from: url) == nil)
    }

    // MARK: Word times and audio

    static func words(_ s: String, step: Double = 0.4) -> [TimedWord] {
        s.split(separator: " ").enumerated().map { TimedWord(word: String($1), start: Double($0) * step, end: Double($0) * step + step * 0.9) }
    }

    @Test func clausesAreFoundInTheTimedTranscript() throws {
        let w = Self.words("open chrome and search for cats then open chrome again")
        let last = try #require(TimedWord.span(of: "open chrome", in: w))
        #expect(abs(last.start - 2.8) < 1e-9)                                          // the latest occurrence
        let s = try #require(TimedWord.span(of: "Search for cats,", in: w))
        #expect(abs(s.start - 1.2) < 1e-9 && abs(s.end - 2.36) < 1e-9)
        // The recognizer revised a word since: first and last word still place it.
        let revised = Self.words("search four cats please")
        #expect(TimedWord.span(of: "search for cats", in: revised)?.start == 0)
        #expect(TimedWord.span(of: "play music", in: w) == nil)
    }

    @Test func recognizerRunsBecomeTimedWords() {
        var text = AttributedString("open chrome, please")
        let words = [("open", 0.2, 0.5), (" chrome,", 0.5, 1.0), (" please", 1.1, 1.5)]
        var pos = text.startIndex
        for (w, a, b) in words {
            let end = text.index(pos, offsetByCharacters: w.count)
            text[pos..<end].audioTimeRange = CMTimeRange(start: CMTime(seconds: a, preferredTimescale: 1000),
                                                         end: CMTime(seconds: b, preferredTimescale: 1000))
            pos = end
        }
        let timed = SpeechListener.timedWords(text)
        #expect(timed.map(\.word) == ["open", "chrome,", "please"])
        #expect(timed[1].start == 0.5 && timed[2].end == 1.5)
    }

    @Test func theRingKeepsTheRecognizersClock() throws {
        let ring = VoiceAudioRing(seconds: 2)
        let format = VoiceAudioRing.format
        for chunk in 0..<30 {    // 3 s of 100 ms chunks, each filled with its index
            let b = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
            b.frameLength = 1600
            for i in 0..<1600 { b.floatChannelData![0][i] = Float(chunk) }
            ring.append(b)
        }
        #expect(abs(ring.seconds - 3) < 1e-9)
        #expect(ring.samples(from: 2.5, to: 2.6)?.allSatisfy { $0 == 25 } == true)
        #expect(ring.samples(from: 0.2, to: 0.4) == nil)                              // older than the ring holds
        #expect(ring.samples(from: 2.9, to: 4)?.count == 1600)                        // clipped to what was heard
    }

    // MARK: End to end

    /// 16 kHz mono samples of `text` in macOS voice `voice` (nil when that voice is missing).
    static func spoken(_ text: String, voice: String) -> [Float]? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("say-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "-o", url.path, "--data-format=LEF32@16000", text]
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0, let f = try? AVAudioFile(forReading: url),
              let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: b)) != nil, let d = b.floatChannelData, f.processingFormat.sampleRate == 16_000 else { return nil }
        return Array(UnsafeBufferPointer(start: d[0], count: Int(b.frameLength)))
    }

    /// The real recognizer on a file where one voice speaks, then another: each clause's
    /// words map to its own audio (the recognizer's clock = the ring's), and the voiceprint
    /// of the first voice accepts its clause and turns the other one away.
    @MainActor @Test func liveClausesAreJudgedByTheirOwnAudio() async throws {
        let locale = await SpeechListener.resolveLocale(preferred: "en_US")
        // Needs the on-device speech model and the Samantha and Daniel voices (standard on macOS).
        guard await SpeechListener.modelStatus(for: locale) == .installed else { return }
        guard let user1 = Self.spoken("Open the calendar and show me what is happening next week.", voice: "Samantha"),
              let user2 = Self.spoken("Remind me to buy groceries after work on Friday afternoon.", voice: "Samantha"),
              let mine = Self.spoken("Search for cheap flights to Denver in November.", voice: "Samantha"),
              let theirs = Self.spoken("Send a message to the whole team about lunch tomorrow.", voice: "Daniel") else {
            Issue.record("could not synthesize the test voices"); return
        }
        let enrolled = [user1, user2].map { SpeakerModel.shared.embeddings($0) }
        let print = try #require(VoicePrint.enroll(prompts: enrolled))

        // One file: the user's sentence, a pause, the other person's sentence.
        let pause = [Float](repeating: 0, count: 12_000)
        let all = mine + pause + theirs + pause
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mix-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = VoiceAudioRing.format
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let b = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(all.count)))
            b.frameLength = AVAudioFrameCount(all.count)
            all.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: all.count) }
            try file.write(from: b)
        }

        let listener = SpeechListener()
        listener.recordsVoice = true
        try await listener.start(locale: locale, audioFile: url)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, !listener.timedWords().map({ TimedWord.key($0.word) }).contains("lunch") {
            try await Task.sleep(for: .milliseconds(200))
        }
        let a = try #require(listener.voiceAudio(for: "flights to Denver in November"))
        let b = try #require(listener.voiceAudio(for: "message to the whole team"))
        await listener.stop()
        let ea = try #require(SpeakerModel.shared.embedding(a.samples)), eb = try #require(SpeakerModel.shared.embedding(b.samples))
        if case .user = print.verdict(ea, seconds: a.seconds) {} else { Issue.record("the enrolled voice's clause was turned away: \(print.verdict(ea, seconds: a.seconds))") }
        if case .other = print.verdict(eb, seconds: b.seconds) {} else { Issue.record("another voice's clause got through: \(print.verdict(eb, seconds: b.seconds))") }
    }

    // MARK: Gate rules

    @Test func stoppingIsAlwaysHeard() {
        #expect(SpeakerGate.alwaysHeard("stop"))
        #expect(SpeakerGate.alwaysHeard("Stop it"))
        #expect(SpeakerGate.alwaysHeard("never mind"))
        #expect(!SpeakerGate.alwaysHeard("stop the music and open spotify"))
        #expect(!SpeakerGate.alwaysHeard("open chrome"))
    }

    @MainActor @Test func noVoiceprintMeansNoGate() async {
        let gate = SpeakerGate()
        #expect(!gate.isActive)
        #expect(await gate.check(head: "open chrome", audio: ([Float](repeating: 0.1, count: 32_000), 2)) == .unsure)
    }

    @Test func enrollmentHearsMostOfTheLine() {
        let line = "Text my mom that I'm running about ten minutes late, and open my calendar."
        #expect(VoiceEnrollmentModel.coverage(of: line, heard: ["text", "my", "mom", "that", "I'm", "running"]) > 0.4)
        #expect(VoiceEnrollmentModel.coverage(of: line, heard: line.split(separator: " ").map(String.init)) == 1)
        #expect(VoiceEnrollmentModel.coverage(of: line, heard: ["hello"]) == 0)
    }
}
