import AVFoundation
import CoreMedia
import ScreenCaptureKit
import Speech

/// What the Mac is playing — every app's audio except Navi's own — as a
/// stream for the speech analyzer (the second echo layer, see `EchoFilter`).
///
/// ScreenCaptureKit with `capturesAudio` (Navi already holds Screen Recording
/// for the agent); the video half is 2×2 px at 2 fps and thrown away. Silence
/// is not fed to the analyzer, so the second recognizer costs nothing while
/// nothing plays. Buffers arrive on a private queue, never the main actor.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Called when the stream stops on its own (display change, permission revoked).
    var onStop: (@Sendable (String) -> Void)?

    private let analyzerFormat: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let onLevel: @Sendable (Float) -> Void
    private let queue = DispatchQueue(label: "com.liamcarlin.navi.voice.system-audio", qos: .userInitiated)
    private var stream: SCStream?
    // Queue-confined.
    private var pipe: AudioPipe?
    private var pipeFormat: AVAudioFormat?
    private var feedUntil: TimeInterval = 0

    /// Below this RMS (dBFS) the Mac counts as silent.
    static let silenceDB: Float = -55
    /// Keep feeding this long after the last sound, so word endings aren't cut.
    static let hangoverSeconds: TimeInterval = 1.5

    init(analyzerFormat: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
         onLevel: @escaping @Sendable (Float) -> Void) {
        self.analyzerFormat = analyzerFormat
        self.continuation = continuation
        self.onLevel = onLevel
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw NaviError.other("No display to capture audio from") }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true   // Navi's own cues and typing sounds
        config.sampleRate = 48_000
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        config.queueDepth = 3
        config.showsCursor = false
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        // Frames nobody reads still need an output, or ScreenCaptureKit logs every one it drops.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let buffer = Self.pcmBuffer(sampleBuffer) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if Self.rmsDB(buffer) > Self.silenceDB { feedUntil = now + Self.hangoverSeconds }
        guard now <= feedUntil else { return }
        if pipe == nil || pipeFormat != buffer.format {
            pipe = AudioPipe(input: buffer.format, output: analyzerFormat, continuation: continuation, onLevel: onLevel)
            pipeFormat = buffer.format
        }
        pipe?.ingest(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.voice.error("system audio capture stopped: \(error.localizedDescription, privacy: .public)")
        onStop?(error.localizedDescription)
    }

    // MARK: Buffers

    /// A copy of the sample buffer's audio (the buffer's memory is not ours to keep).
    static func pcmBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = sampleBuffer.formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: desc)
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                                  into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }

    static func rmsDB(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return -120 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[0][i] * data[0][i] }
        return 20 * log10(max((sum / Float(n)).squareRoot(), 1e-7))
    }
}
