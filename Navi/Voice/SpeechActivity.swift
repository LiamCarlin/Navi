import Foundation

/// Is the user speaking right now? Decided from the microphone level alone,
/// against a noise floor that follows the room.
///
/// The floor is a low percentile of the last few seconds of level: speech
/// keeps dipping between words, so the floor stays near the quiet between
/// them, while a steady sound — a fan, music, a video Navi just opened —
/// becomes the floor within a few seconds and stops counting as speech. (The
/// old floor rose ~0.01 per second: 30–50 s of music read as nonstop talking,
/// so no pause was ever seen, the recognizer was never flushed and boundary-less
/// instructions waited for good.)
///
/// Pure value type; `VoiceSession` feeds it ~25 levels a second.
struct SpeechActivity: Equatable {
    /// Seconds of level history the floor is taken from.
    static let windowSeconds: TimeInterval = 4
    static let floorPercentile = 0.1
    /// Level above the floor that counts as speech.
    static let aboveFloor: Float = 0.16
    static let initialFloor: Float = 0.06
    static let minFloor: Float = 0.02
    /// Never so high that ordinary speech can't clear it.
    static let maxFloor: Float = 0.55
    /// Samples needed before the percentile replaces the initial floor (~0.5 s).
    static let minSamples = 12

    private var samples: [(t: TimeInterval, level: Float)] = []
    private(set) var floor: Float = SpeechActivity.initialFloor

    static func == (a: SpeechActivity, b: SpeechActivity) -> Bool { a.floor == b.floor && a.samples.count == b.samples.count }

    /// Records a level at time `t` (seconds, any monotonic origin); true when it is speech.
    mutating func isSpeech(_ level: Float, at t: TimeInterval) -> Bool {
        samples.append((t, level))
        if let first = samples.first, t - first.t > Self.windowSeconds {
            samples.removeFirst(samples.firstIndex { t - $0.t <= Self.windowSeconds } ?? 0)
        }
        if samples.count >= Self.minSamples {
            let sorted = samples.map(\.level).sorted()
            let p = sorted[min(sorted.count - 1, Int(Double(sorted.count) * Self.floorPercentile))]
            floor = min(Self.maxFloor, max(Self.minFloor, p))
        } else {
            floor = min(floor, max(Self.minFloor, level))
        }
        return level >= floor + Self.aboveFloor
    }

    mutating func reset() { samples = []; floor = Self.initialFloor }
}
