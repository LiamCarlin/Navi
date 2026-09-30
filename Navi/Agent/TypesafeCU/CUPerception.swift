import AppKit
import CoreGraphics
import Foundation
import Vision

// Port of typesafe_computer_use/perception.py: everything worth clicking on this screen
// as one numbered list, each item carrying where it came from.
//
// "Read structure before pixels" (VISION.md): the accessibility tree comes first — its
// controls and its static text are exact — and OCR is the fallback for what the tree does
// not carry (canvas apps, CEF shells like Spotify, text baked into images). Navi reads the
// tree every step and OCRs only when the tree is thin, or when Jev stopped on a screen the
// tree alone could not explain (see `CUOCRPolicy`).

/// The screen as Jev sees it for one step.
struct CUScreen: @unchecked Sendable {
    var snapshot: AXSnapshot
    var items: [CUItem]
    /// Item index → the AX element behind it, when it came from the tree.
    var elementForItem: [Int: String]
    var field: CUField?
    var usedOCR: Bool

    var app: String { snapshot.appName ?? snapshot.bundleID ?? "unknown" }
    var url: String? { snapshot.url }
    /// What regions are measured against: the window, else everything on screen.
    var frame: CGRect {
        if let w = snapshot.windowFrame, w.width > 0 { return w }
        return items.reduce(CGRect.null) { $0.union($1.box) }.standardized
    }
    var offscreen: [AXElement] { snapshot.offscreen }
    var signature: CUSignature { .of(app: app, url: url ?? snapshot.windowTitle, field: field, items: items) }

    func element(forItem index: Int) -> AXElement? { elementForItem[index].flatMap(snapshot.element) }
    /// Text inputs Jev may type into, as items (secure fields never).
    var editableItems: [CUItem] {
        items.filter { it in element(forItem: it.index).map { $0.isTextInput && !$0.isSecure } ?? false }
    }
    /// Pop-ups whose options the tree enumerates.
    var selectableItems: [CUItem] {
        items.filter { it in element(forItem: it.index).map { $0.isPopUp && !$0.options.isEmpty } ?? false }
    }
}

/// One OCR line (or merged block): text, Vision's confidence, box in screen points.
struct CUOCRLine: Equatable, Sendable {
    var text: String
    var confidence: Double
    var box: CGRect
}

enum CUPerception {
    static let maxOptions = 255            // TypeSafe Choice ceiling
    static let minOCRConfidence = 0.3
    static let minBoxOverlap: CGFloat = 0.5
    static let minTokenOverlap = 0.5
    static let iconHosts: Set<String> = ["button", "link"]

    /// Builds the item list from the walk (and OCR lines when there are any).
    static func perceive(_ snapshot: AXSnapshot, ocr: [CUOCRLine]?, goal: String, budget: Int = maxOptions) -> CUScreen {
        let field = focusedField(snapshot)
        let echoes = CUFacts.goalEchoes(goal)
        // Controls: every element the walk kept. An unlabelled field still gets a name.
        let controls: [(CUItem, String)] = snapshot.elements.compactMap { e in
            let text = e.label.isEmpty ? (e.isTextInput ? "text field" : "") : e.label
            guard !text.isEmpty else { return nil }
            return (CUItem(index: 0, text: text, confidence: 1, box: e.frame, role: CURoles.word(e.role), source: .ax), e.id)
        }
        // Plain text: the tree's static text lines, then OCR blocks the tree did not already carry.
        var plain: [CUItem] = snapshot.texts.filter { !CUFacts.isEcho($0.text, echoes: echoes) }.map {
            CUItem(index: 0, text: $0.text, confidence: 1, box: $0.frame, source: .text)
        }
        if let ocr {
            let blocks = mergeBlocks(ocr.filter { $0.confidence >= minOCRConfidence })
                .filter { !CUFacts.isEcho($0.text, echoes: echoes) && !inField($0.box, field: field) }
            let known = plain
            for b in blocks {
                let item = CUItem(index: 0, text: b.text, confidence: b.confidence, box: b.box, source: .ocr)
                if known.contains(where: { boxOverlap($0.box, item.box) >= minBoxOverlap && textsMatch($0.text, item.text) }) { continue }
                plain.append(item)
            }
        }
        plain = plain.filter { !inField($0.box, field: field) }
        let merged = mergeWithOrigins(plain: plain, controls: controls, budget: budget)
        var map: [Int: String] = [:]
        for (it, id) in merged { if let id { map[it.index] = id } }
        return CUScreen(snapshot: snapshot, items: merged.map(\.0), elementForItem: map, field: field, usedOCR: ocr != nil)
    }

    static func focusedField(_ snapshot: AXSnapshot) -> CUField? {
        guard let f = snapshot.focusedElement, f.isTextInput, !f.isSecure else { return nil }
        return CUField(role: f.role, label: f.label, placeholder: "", value: f.value ?? "", frame: f.frame, elementID: f.id)
    }

    /// Whether a block sits inside the focused one-line field: its value or placeholder read
    /// again as something to click. A text area keeps its lines.
    static func inField(_ box: CGRect, field: CUField?) -> Bool {
        guard let field, field.isText, field.role != "AXTextArea", field.frame.width > 0 else { return false }
        return field.frame.contains(CGPoint(x: box.midX, y: box.midY))
    }

    // MARK: Merge (perception.py `merge_with_origins`)

    /// One item per thing. A control that sits on the text naming it replaces both; a button or
    /// link stands for the symbol OCR read off its icon. Each item keeps the element id it came
    /// from, which survives the budget cut and the renumbering.
    static func mergeWithOrigins(plain: [CUItem], controls: [(CUItem, String)], budget: Int = maxOptions) -> [(CUItem, String?)] {
        var taken = Set<Int>()
        var merged: [(CUItem, String?)] = []
        for (control, id) in controls {
            var best: Int?, bestOverlap = minBoxOverlap
            for (i, block) in plain.enumerated() where !taken.contains(i) {
                let overlap = boxOverlap(control.box, block.box)
                if overlap >= bestOverlap, textsMatch(control.text, block.text) { best = i; bestOverlap = overlap }
            }
            guard let best else { merged.append((control, id)); continue }
            taken.insert(best)
            let block = plain[best]
            // The text's box (what is drawn), the control's role, the longer of the two labels.
            var item = control
            item.box = block.box
            item.text = control.text.count >= block.text.count ? control.text : block.text
            if block.source == .ocr { item.source = .axOCR }
            merged.append((item, id))
        }
        let controlItems = controls.map(\.0)
        for (i, block) in plain.enumerated() where !taken.contains(i) && !isIcon(block, controls: controlItems) {
            merged.append((block, nil))
        }
        let kept = keptByBudget(merged.map(\.0), budget: budget).map { merged[$0] }
        return readingOrder(kept.map(\.0)).enumerated().map { i, j in
            var it = kept[j].0; it.index = i; return (it, kept[j].1)
        }
    }

    /// A block with no letter or digit, centred on a button or link: its icon read as a stray
    /// symbol ('←' on Back). The control already offers that click; a second option splits the vote.
    static func isIcon(_ block: CUItem, controls: [CUItem]) -> Bool {
        guard !block.text.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
        return controls.contains { iconHosts.contains($0.role) && $0.box.contains(block.center) }
    }

    /// Intersection over the smaller box, so a tight control inside a wide text line still counts.
    static func boxOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 ? i.width * i.height / smaller : 0
    }

    /// One label contains the other, or they share half their words.
    static func textsMatch(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let y = b.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x.contains(y) || y.contains(x) { return true }
        let wx = Set(x.split(separator: " ")), wy = Set(y.split(separator: " "))
        return Double(wx.intersection(wy).count) / Double(min(wx.count, wy.count)) >= minTokenOverlap
    }

    /// Which items survive the Choice ceiling: the faintest plain text goes first, and a control
    /// is never dropped for text. Their positions, in the order given.
    static func keptByBudget(_ items: [CUItem], budget: Int) -> [Int] {
        guard items.count > budget else { return Array(items.indices) }
        let ranked = items.indices.sorted { a, b in
            let ka = (items[a].fromAX ? 1 : 0, items[a].confidence), kb = (items[b].fromAX ? 1 : 0, items[b].confidence)
            return ka < kb
        }
        let dropped = Set(ranked.prefix(items.count - budget))
        return items.indices.filter { !dropped.contains($0) }
    }

    /// Positions in reading order: rows by the median item height, then left to right.
    static func readingOrder(_ items: [CUItem]) -> [Int] {
        let heights = items.map(\.box.height).sorted()
        let rowH = max(1, heights.isEmpty ? 1 : heights[heights.count / 2])
        return items.indices.sorted { a, b in
            let ra = Int((items[a].box.midY / rowH).rounded()), rb = Int((items[b].box.midY / rowH).rounded())
            return ra != rb ? ra < rb : items[a].box.minX < items[b].box.minX
        }
    }

    /// Joins lines that continue a block above them: aligned left edge, small gap, similar height.
    static func mergeBlocks(_ lines: [CUOCRLine]) -> [CUOCRLine] {
        var blocks: [(line: CUOCRLine, lastHeight: CGFloat)] = []
        for l in lines.sorted(by: { ($0.box.minY, $0.box.minX) < ($1.box.minY, $1.box.minX) }) {
            let h = l.box.height
            var best: (gap: CGFloat, index: Int)?
            for (i, b) in blocks.enumerated() {
                let bh = b.lastHeight, gap = l.box.minY - b.line.box.maxY
                let continues = abs(l.box.minX - b.line.box.minX) < 0.6 * bh && gap > -0.2 * bh && gap < 0.8 * bh
                    && h / max(bh, 1) > 0.7 && h / max(bh, 1) < 1.4
                if continues, best == nil || gap < best!.gap { best = (gap, i) }
            }
            guard let best else { blocks.append((l, h)); continue }
            var b = blocks[best.index]
            b.line.text += " " + l.text
            b.line.confidence = min(b.line.confidence, l.confidence)
            b.line.box = b.line.box.union(l.box)
            b.lastHeight = h
            blocks[best.index] = b
        }
        return blocks.map(\.line)
    }
}

// MARK: - When to OCR

/// Navi's policy for the OCR fallback. Upstream reads every step on the Mac; Navi's tree is
/// usually rich enough (Finder 100 % of controls labelled, Chrome 88 %, Slack 85 %) and OCR
/// costs 300–700 ms, so it runs where the tree is thin, and once more on any screen Jev
/// stopped on before the writer is asked (perception escalates before a model does).
enum CUOCRPolicy {
    /// Apps whose tree carries (almost) nothing: CEF/game/canvas shells.
    static let thinTreeBundles: Set<String> = ["com.spotify.client", "com.apple.Terminal", "com.googlecode.iterm2",
                                               "dev.warp.Warp-Stable", "com.figma.Desktop", "com.microsoft.rdc.macos"]
    static let minLabelledControls = 8
    static let minTextLines = 3

    static func wantsOCR(_ snapshot: AXSnapshot) -> Bool {
        if let b = snapshot.bundleID, thinTreeBundles.contains(b) { return true }
        let labelled = snapshot.elements.filter { !$0.label.isEmpty }.count
        return labelled < minLabelledControls && snapshot.texts.count < minTextLines
    }
}

// MARK: - OCR reader

/// Vision OCR of one window, with upstream's reuse rule simplified: the capture is compared
/// with the previous one at 1/8 scale in 256 px tiles, and when no tile changed the previous
/// lines are reused (a wait, a refused action, a scroll at the bottom of the page).
final class CUOCRReader: @unchecked Sendable {
    private let lock = NSLock()
    private var last: (window: CGWindowID, thumb: [UInt8], w: Int, h: Int, lines: [CUOCRLine])?

    static let thumbDivisor = 8
    static let tilePx = 256
    static let tileDiff = 6.0

    /// The window to read: the pinned target's, else the frontmost app's window the walk read.
    static func windowID(for snapshot: AXSnapshot, target: AgentTarget?) async -> CGWindowID? {
        if let target, let w = target.window(for: snapshot) { return w.id }
        guard snapshot.pid > 0 else { return nil }
        return AgentTarget.matchWindow(AgentTarget.windowList(pid: snapshot.pid), frame: snapshot.windowFrame, title: snapshot.windowTitle)?.id
    }

    func read(windowID: CGWindowID) async -> [CUOCRLine]? {
        guard ScreenCapture.hasPermission, let frame = try? await ScreenCapture.captureWindow(id: windowID) else { return nil }
        let (thumb, w, h) = Self.thumbnail(frame.image)
        lock.lock()
        if let last, last.window == windowID, last.w == w, last.h == h, !Self.changed(last.thumb, thumb, w: w, h: h) {
            let lines = last.lines
            lock.unlock()
            return lines
        }
        lock.unlock()
        let lines = await Self.recognize(frame.image, bounds: frame.bounds)
        lock.lock(); last = (windowID, thumb, w, h, lines); lock.unlock()
        return lines
    }

    static func recognize(_ image: CGImage, bounds: CGRect) async -> [CUOCRLine] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                let lines: [CUOCRLine] = (request.results ?? []).compactMap { o in
                    guard let c = o.topCandidates(1).first, !c.string.isEmpty else { return nil }
                    let bb = o.boundingBox   // normalised, bottom-left origin
                    let box = CGRect(x: bounds.minX + bb.minX * bounds.width, y: bounds.minY + (1 - bb.maxY) * bounds.height,
                                     width: bb.width * bounds.width, height: bb.height * bounds.height)
                    return CUOCRLine(text: c.string, confidence: Double(c.confidence), box: box)
                }
                cont.resume(returning: lines)
            }
        }
    }

    static func thumbnail(_ image: CGImage) -> ([UInt8], Int, Int) {
        let w = max(1, image.width / thumbDivisor), h = max(1, image.height / thumbDivisor)
        var px = [UInt8](repeating: 0, count: w * h)
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (px, w, h)
    }

    /// Any tile whose mean absolute difference exceeds `tileDiff`.
    static func changed(_ a: [UInt8], _ b: [UInt8], w: Int, h: Int) -> Bool {
        guard a.count == b.count, a.count == w * h else { return true }
        let t = tilePx / thumbDivisor
        var ty = 0
        while ty < h {
            var tx = 0
            while tx < w {
                var sum = 0, n = 0
                for y in ty..<min(h, ty + t) {
                    for x in tx..<min(w, tx + t) { sum += abs(Int(a[y * w + x]) - Int(b[y * w + x])); n += 1 }
                }
                if n > 0, Double(sum) / Double(n) > tileDiff { return true }
                tx += t
            }
            ty += t
        }
        return false
    }
}
