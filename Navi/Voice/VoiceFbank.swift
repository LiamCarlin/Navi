import Accelerate
import Foundation

/// Log-mel filterbank features exactly as the speaker model was trained on them:
/// Kaldi's `fbank` (torchaudio.compliance.kaldi) at 16 kHz — 25 ms Hamming frames every
/// 10 ms, DC removed, pre-emphasis 0.97, 512-point power spectrum, 80 mel bins from
/// 20 Hz to 8 kHz, log — then each bin's mean over the clip subtracted (CMN).
/// Samples are floats in −1…1 (scaled to 16-bit range inside, as Kaldi expects).
///
/// Pure and deterministic; `VoiceFbankTests` checks it against torchaudio's output.
enum VoiceFbank {
    static let sampleRate = 16_000
    static let frameLength = 400        // 25 ms
    static let frameShift = 160         // 10 ms
    static let fftSize = 512
    static let melBins = 80
    static let lowHz: Float = 20
    static let preemphasis: Float = 0.97

    /// Frames in `count` samples (Kaldi `snip_edges`: only whole frames).
    static func frameCount(_ count: Int) -> Int {
        count < frameLength ? 0 : 1 + (count - frameLength) / frameShift
    }

    /// Raw log-mel energies, `frames × melBins`, row-major (no mean normalization).
    static func logMel(_ samples: [Float]) -> [Float] {
        let n = frameCount(samples.count)
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n * melBins)
        var frame = [Float](repeating: 0, count: fftSize)
        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)
        var power = [Float](repeating: 0, count: fftSize / 2 + 1)
        let banks = melBanks
        let window = hamming
        guard let setup = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        for f in 0..<n {
            let start = f * frameShift
            // Scaled to 16-bit range, DC removed.
            var mean: Float = 0
            for i in 0..<frameLength { frame[i] = samples[start + i] * 32768; mean += frame[i] }
            mean /= Float(frameLength)
            for i in 0..<frameLength { frame[i] -= mean }
            // Pre-emphasis, the first sample against itself (Kaldi's replicate padding).
            for i in stride(from: frameLength - 1, to: 0, by: -1) { frame[i] -= preemphasis * frame[i - 1] }
            frame[0] -= preemphasis * frame[0]
            for i in 0..<frameLength { frame[i] *= window[i] }
            for i in frameLength..<fftSize { frame[i] = 0 }
            // Power spectrum. vDSP's packed real FFT scales by 2 and puts Nyquist in imag[0].
            real.withUnsafeMutableBufferPointer { re in
                imag.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    frame.withUnsafeBufferPointer { src in
                        src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, 9, FFTDirection(FFT_FORWARD))
                }
            }
            power[0] = (real[0] / 2) * (real[0] / 2)
            power[fftSize / 2] = (imag[0] / 2) * (imag[0] / 2)
            for k in 1..<(fftSize / 2) { power[k] = (real[k] * real[k] + imag[k] * imag[k]) / 4 }
            // Mel energies, floored at float epsilon, logged.
            for m in 0..<melBins {
                var e: Float = 0
                let row = m * (fftSize / 2)
                for k in 0..<(fftSize / 2) where banks[row + k] != 0 { e += banks[row + k] * power[k] }
                out[f * melBins + m] = log(max(e, Float.ulpOfOne))
            }
        }
        return out
    }

    /// `logMel` with each bin's mean over the clip subtracted — the model's input.
    static func features(_ samples: [Float]) -> (values: [Float], frames: Int) {
        var v = logMel(samples)
        let n = v.count / melBins
        guard n > 0 else { return ([], 0) }
        for m in 0..<melBins {
            var mean: Float = 0
            for f in 0..<n { mean += v[f * melBins + m] }
            mean /= Float(n)
            for f in 0..<n { v[f * melBins + m] -= mean }
        }
        return (v, n)
    }

    // MARK: Tables

    /// Symmetric Hamming window over one frame (torch `hamming_window(periodic: false)`).
    static let hamming: [Float] = (0..<frameLength).map { i in
        0.54 - 0.46 * cos(2 * Float.pi * Float(i) / Float(frameLength - 1))
    }

    /// Kaldi's triangular mel filters, `melBins × fftSize/2` (the Nyquist bin gets no weight).
    static let melBanks: [Float] = {
        func mel(_ hz: Float) -> Float { 1127 * log(1 + hz / 700) }
        let bins = fftSize / 2
        let binHz = Float(sampleRate) / Float(fftSize)
        let lo = mel(lowHz), hi = mel(Float(sampleRate) / 2)
        let delta = (hi - lo) / Float(melBins + 1)
        var w = [Float](repeating: 0, count: melBins * bins)
        for m in 0..<melBins {
            let left = lo + Float(m) * delta, center = left + delta, right = center + delta
            for k in 0..<bins {
                let x = mel(binHz * Float(k))
                let up = (x - left) / (center - left), down = (right - x) / (right - center)
                w[m * bins + k] = max(0, min(up, down))
            }
        }
        return w
    }()
}
