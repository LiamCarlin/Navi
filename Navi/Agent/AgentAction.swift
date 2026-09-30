import Foundation

/// A fully resolved action `ActionExecutor` carries out. `typeText`'s text is resolved by the
/// loop (the writer, `CUWriter`) before execution.
enum AgentAction: Equatable, Sendable {
    case click(elementID: String)
    /// A line of text with no element of its own (an AXStaticText line or an OCR block):
    /// a click at its centre, in screen points.
    case clickPoint(x: Double, y: Double, label: String)
    /// `AXPress` on a control the app exposes but does not show (`AXSnapshot.offscreen`).
    case press(elementID: String)
    case typeText(elementID: String)
    case select(elementID: String, option: String)
    case scroll(up: Bool)
    case wait
    case key(String)
    case openApp(String)
    case openURL(String)

    /// Actions that only observe: never need approval.
    var isReadOnly: Bool {
        switch self {
        case .wait, .scroll: return true
        default: return false
        }
    }

    var kind: String {
        switch self {
        case .click, .clickPoint: return "click"
        case .press: return "press"
        case .typeText: return "type_text"
        case .select: return "select"
        case .scroll: return "scroll"
        case .wait: return "wait"
        case .key: return "key"
        case .openApp: return "open_app"
        case .openURL: return "open_url"
        }
    }

    /// Upper bound on the post-action settle. `AXSnapshotter.settle` returns as soon as the AX
    /// fingerprint changes, so this is only reached when nothing reacts.
    var settleMs: Int {
        switch self {
        case .openApp, .openURL: return 800
        case .key(let k) where k.lowercased().contains("return") || k.lowercased().contains("enter"): return 500
        case .wait: return 600
        default: return 250
        }
    }

    var elementID: String? {
        switch self {
        case .click(let id), .press(let id), .typeText(let id), .select(let id, _): return id
        default: return nil
        }
    }

    static func short(_ s: String, _ n: Int = 48) -> String {
        let one = s.replacingOccurrences(of: "\n", with: "⏎")
        return one.count > n ? String(one.prefix(n)) + "…" : one
    }

    /// "Click ‘Sign in’", "Type ‘jev’ into ‘Search’", "Press ⌘L" — for the panel timeline.
    func human(in snapshot: AXSnapshot, text: String? = nil) -> String {
        func name(_ id: String) -> String { snapshot.element(id)?.displayName ?? id }
        switch self {
        case .click(let id): return "Click \(name(id))"
        case .clickPoint(_, _, let label): return "Click ‘\(Self.short(label))’"
        case .press(let id): return "Press \(name(id)) (off screen)"
        case .typeText(let id): return "Type ‘\(Self.short(text ?? "…"))’ into \(name(id))"
        case .select(let id, let opt): return "Select ‘\(Self.short(opt))’ in \(name(id))"
        case .scroll(let up): return up ? "Scroll up" : "Scroll down"
        case .wait: return "Wait for the screen"
        case .key(let k): return "Press \((try? KeyCombo.parse(k).displayLabel) ?? k)"
        case .openApp(let a): return "Open \(a)"
        case .openURL(let u): return "Open URL \(Self.short(u, 60))"
        }
    }
}
