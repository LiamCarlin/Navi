import AppKit
import CoreGraphics
import Vision

/// Pure image/OS helpers used by `CaptureScheduler`: perceptual hashing,
/// thumbnails, on-device OCR and the "should we even look?" environment probes.
enum FrameCapture {

    // MARK: dHash

    /// 64-bit difference hash: downscale to 9×8 grayscale and compare each
    /// pixel with its right neighbour. Two frames of the same screen differ by
    /// only a few bits; a different window flips dozens.
    static func dHash(_ image: CGImage) -> UInt64 {
        // Two-step downscale so CG actually averages the source rather than
        // point-sampling a handful of pixels out of a 5K frame.
        let (small, _) = ScreenCapture.downscale(image, maxLongEdge: 256)
        let w = 9, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        let ok: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(small, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return 0 }
        var hash: UInt64 = 0
        for y in 0..<h {
            for x in 0..<(w - 1) {
                hash <<= 1
                if pixels[y * w + x] < pixels[y * w + x + 1] { hash |= 1 }
            }
        }
        return hash
    }

    static func hamming(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    // MARK: Thumbnail

    /// JPEG thumbnail, long edge ≤ 1024 px, quality 0.6 (~60–120 KB per frame).
    static func thumbnailJPEG(_ image: CGImage, maxLongEdge: Int = 1024, quality: CGFloat = 0.6) -> Data? {
        let (small, _) = ScreenCapture.downscale(image, maxLongEdge: maxLongEdge)
        return ScreenCapture.jpegData(small, quality: quality)
    }

    /// `frames/YYYY/MM/DD/<unix-ts>.jpg` under the store's frames directory.
    static func thumbnailURL(in framesDirectory: URL, at date: Date, calendar: Calendar = .current) -> URL {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let dir = framesDirectory
            .appendingPathComponent(String(format: "%04d", c.year ?? 0), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", c.month ?? 0), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", c.day ?? 0), isDirectory: true)
        return dir.appendingPathComponent("\(Int(date.timeIntervalSince1970)).jpg")
    }

    // MARK: OCR

    static let ocrQueue = DispatchQueue(label: "com.liamcarlin.navi.memory.ocr", qos: .utility)
    static let maxOCRChars = 6000

    /// On-device text recognition (Vision, accurate, language-corrected).
    /// Lines are emitted top-to-bottom, left-to-right, one per visual line.
    static func recognizeText(in image: CGImage, maxChars: Int = maxOCRChars) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            ocrQueue.async {
                do {
                    // Vision copes fine with ~2.5K wide input; anything beyond is wasted work.
                    let (img, _) = ScreenCapture.downscale(image, maxLongEdge: 2560)
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    let handler = VNImageRequestHandler(cgImage: img, options: [:])
                    try handler.perform([request])
                    let observations = request.results ?? []
                    cont.resume(returning: joinLines(observations, maxChars: maxChars))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Orders observations into reading order and merges boxes that share a
    /// baseline into a single line.
    static func joinLines(_ observations: [VNRecognizedTextObservation], maxChars: Int) -> String {
        struct Box { var text: String; var midY: CGFloat; var minX: CGFloat; var height: CGFloat }
        let boxes: [Box] = observations.compactMap { o in
            guard let t = o.topCandidates(1).first?.string, !t.isEmpty else { return nil }
            return Box(text: t, midY: o.boundingBox.midY, minX: o.boundingBox.minX, height: o.boundingBox.height)
        }
        return joinBoxes(boxes.map { ($0.text, $0.midY, $0.minX, $0.height) }, maxChars: maxChars)
    }

    /// Testable core of `joinLines`: tuples are (text, midY, minX, height) in
    /// Vision's normalised bottom-left coordinate space.
    static func joinBoxes(_ boxes: [(String, CGFloat, CGFloat, CGFloat)], maxChars: Int) -> String {
        // Top of screen = high Y in Vision space.
        let sorted = boxes.sorted { $0.1 > $1.1 }
        var lines: [[(String, CGFloat, CGFloat, CGFloat)]] = []
        for b in sorted {
            if let last = lines.last, let ref = last.first {
                let tolerance = max(0.006, min(ref.3, b.3) * 0.6)
                if abs(ref.1 - b.1) <= tolerance {
                    lines[lines.count - 1].append(b)
                    continue
                }
            }
            lines.append([b])
        }
        var out = ""
        for line in lines {
            let text = line.sorted { $0.2 < $1.2 }.map(\.0).joined(separator: "  ")
            if out.count + text.count + 1 > maxChars {
                out += String(text.prefix(max(0, maxChars - out.count)))
                break
            }
            out += (out.isEmpty ? "" : "\n") + text
        }
        return out
    }

    // MARK: Environment probes

    static var isScreenLocked: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let v = dict["CGSSessionScreenIsLocked"] as? Bool { return v }
        if let n = dict["CGSSessionScreenIsLocked"] as? NSNumber { return n.boolValue }
        return false
    }

    static var isScreensaverRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.ScreenSaver.Engine" || $0.bundleIdentifier == "com.apple.ScreenSaver.Engine.legacyScreenSaver"
        }
    }

    static var isDisplayAsleep: Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }

    /// Seconds since the user last touched the keyboard/mouse/trackpad.
    static var secondsSinceUserInput: TimeInterval {
        // kCGAnyInputEventType: any HID input.
        let anyInput = CGEventType(rawValue: ~0) ?? .null
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    // MARK: Automation preflight (browser URLs)

    /// Whether Navi may send Apple Events to `bundleID` (needed to read the
    /// front browser tab URL). `ask` shows the one-time system consent prompt —
    /// only call with `ask: true` off the main thread.
    static func automationPermitted(bundleID: String, ask: Bool) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return false }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask)
        return status == noErr
    }

    static let browserBundleIDs: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
    ]
}
