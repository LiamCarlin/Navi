import CoreGraphics
import Foundation

// Port of typesafe_computer_use/models.py (vendor/typesafe-computer-use, see docs/TYPESAFE_CU.md).
//
// The idea that runs through the whole port: the classifier (Jev) picks, code decides
// facts, and the writer (Claude) only writes free text. Everything here is a fact code
// computed about the screen, handed to Jev as state.

/// One thing on screen Jev can point at: a control the app declared, a line of text
/// the accessibility tree carries, or a block OCR read off the pixels.
struct CUItem: Equatable, Sendable {
    enum Source: String, Sendable {
        case ax        // a control from the accessibility tree
        case text      // an AXStaticText line (no action of its own; clicked by position)
        case ocr       // a text block Vision read off the capture
        case axOCR = "ax+ocr"   // a control and the OCR block naming it, merged
    }

    var index: Int
    var text: String
    /// 1 for anything the accessibility tree reported; Vision's confidence for OCR.
    var confidence: Double
    /// Global screen points, top-left origin.
    var box: CGRect
    /// A short human word (button, link, field…) for controls; empty for plain text.
    var role: String = ""
    var source: Source = .ocr

    var center: CGPoint { CGPoint(x: box.midX, y: box.midY) }
    /// Declared by the app: a real control, not a line of text.
    var fromAX: Bool { source == .ax || source == .axOCR }
}

/// Accessibility roles as one human word (models.py `ROLE_WORDS`, plus the few Navi's walk adds).
enum CURoles {
    static let words: [String: String] = [
        "AXButton": "button", "AXCell": "cell", "AXCheckBox": "checkbox", "AXComboBox": "field",
        "AXDockItem": "dock item", "AXImage": "image", "AXLink": "link", "AXMenuBarItem": "menu",
        "AXMenuButton": "button", "AXPopUpButton": "popup", "AXRadioButton": "radio", "AXRow": "cell",
        "AXSearchField": "field", "AXSlider": "slider", "AXTab": "tab", "AXTextArea": "field",
        "AXTextField": "field", "AXDisclosureTriangle": "button", "AXMenuItem": "menu item",
        "AXIncrementor": "stepper", "AXStaticText": "text", "AXHeading": "heading",
    ]
    static func word(_ role: String) -> String { words[role] ?? "other" }
}

/// The focused text field (models.py `Field`), with the element id it came from.
struct CUField: Equatable, Sendable {
    var role: String
    var label: String
    var placeholder: String
    var value: String
    var frame: CGRect
    var elementID: String?

    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]
    var isText: Bool { Self.textRoles.contains(role) }

    func summary() -> [String: Any] {
        ["role": role, "label": label, "placeholder": placeholder, "current_value": String(value.prefix(200))]
    }
}

/// What the run has learned about its goal since it began (models.py `Guidance`).
///
/// The goal is one sentence and never changes. `focus` is the sub-goal the writer sent
/// Jev back to work on the last time Jev stopped; `exchanges` are questions the user
/// answered. Every model call reads both.
struct CUGuidance: Equatable, Sendable {
    struct Exchange: Equatable, Sendable { var question: String; var reply: String }
    var focus: String?
    var exchanges: [Exchange] = []

    func focused(_ f: String) -> CUGuidance { var g = self; g.focus = f; return g }

    /// The keys a model packet carries, and only the ones that hold something.
    func state() -> [String: Any] {
        var s: [String: Any] = [:]
        if let focus, !focus.isEmpty { s["current_focus"] = focus }
        if !exchanges.isEmpty { s["user_said"] = exchanges.map { ["asked": $0.question, "replied": $0.reply] } }
        return s
    }
}

// MARK: - Screen identity (models.py `signature` / `same_screen`)

/// What identifies a screen from one step to the next: the app, the page, which field has
/// the focus, and each line of text with the row it sits in.
///
/// A click that only moves the focus changes no text, but it changes what the next action
/// can do, so it counts. A scroll keeps most of the text and moves all of it, so the row
/// counts too: the same line lower down is a different line.
struct CUSignature: Equatable, Sendable {
    struct Line: Hashable, Sendable { var text: String; var row: Int }
    var app: String
    var url: String?
    var focused: String?
    var lines: [Line]

    /// Pages identify "somewhere new" for the stall count: app + URL (or window title).
    var page: String { "\(app)|\(url ?? "")" }

    static let rowPt: CGFloat = 20
    /// A screen is the same when at most one line differs, and that line is one in ten or fewer.
    static let linesPerDifference = 10
    static let maxDifferingLines = 1
    /// Chromium names a tab "Settings - Memory usage - 56.0 MB" while the hover card shows memory.
    /// The figure drifts between two captures of one screen, so it is left out.
    static let tabMemory = try! NSRegularExpression(pattern: #" - (?:high )?memory usage - [\d.,]+ ?[kmgt]?b$"#, options: [.caseInsensitive])

    static func of(app: String, url: String?, field: CUField?, items: [CUItem]) -> CUSignature {
        let focused = field.map { "\($0.role):\($0.label)" }
        let lines = items.map { it -> Line in
            let ns = it.text as NSString
            let text = tabMemory.stringByReplacingMatches(in: it.text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            return Line(text: text, row: Int((it.center.y / rowPt).rounded()))
        }
        return CUSignature(app: app, url: url, focused: focused, lines: lines)
    }

    /// Whether two captures show the same screen, allowing for a clock, a ticker, or an OCR slip.
    /// Measured as lines that appeared or vanished, whichever is more.
    func same(as other: CUSignature) -> Bool {
        guard app == other.app, url == other.url, focused == other.focused else { return false }
        let a = Set(lines), b = Set(other.lines)
        let differing = max(a.subtracting(b).count, b.subtracting(a).count)
        return differing <= Self.maxDifferingLines && differing * Self.linesPerDifference <= max(a.count, b.count)
    }
}
