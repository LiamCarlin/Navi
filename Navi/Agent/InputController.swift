import AppKit
import ApplicationServices
import Carbon.HIToolbox

// MARK: - Key combos

/// A parsed xdotool-style key combination ("cmd+shift+s", "Return", "ctrl+alt+Delete").
struct KeyCombo: Equatable, Sendable {
    var keyCode: CGKeyCode
    var flags: CGEventFlags
    /// Canonical lower-case key name ("s", "return", "delete").
    var keyName: String

    static let modifierFlags: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "super": .maskCommand, "meta": .maskCommand, "win": .maskCommand,
        "super_l": .maskCommand, "super_r": .maskCommand,
        "ctrl": .maskControl, "control": .maskControl, "ctrl_l": .maskControl, "ctrl_r": .maskControl,
        "alt": .maskAlternate, "option": .maskAlternate, "opt": .maskAlternate, "alt_l": .maskAlternate, "alt_r": .maskAlternate,
        "shift": .maskShift, "shift_l": .maskShift, "shift_r": .maskShift,
        "fn": .maskSecondaryFn, "function": .maskSecondaryFn,
    ]

    /// Virtual key codes for the modifier keys themselves (used by hold_key / bare "cmd").
    static let modifierKeyCodes: [String: CGKeyCode] = [
        "cmd": 55, "command": 55, "super": 55, "meta": 55, "win": 55, "super_l": 55, "super_r": 54,
        "ctrl": 59, "control": 59, "ctrl_l": 59, "ctrl_r": 62,
        "alt": 58, "option": 58, "opt": 58, "alt_l": 58, "alt_r": 61,
        "shift": 56, "shift_l": 56, "shift_r": 60,
        "fn": 63, "function": 63,
    ]

    /// US-ANSI virtual key codes keyed by lower-case xdotool/keysym-ish names.
    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "=": 24, "equal": 24, "-": 27, "minus": 27, "]": 30, "bracketright": 30, "[": 33, "bracketleft": 33,
        "'": 39, "apostrophe": 39, "quote": 39, ";": 41, "semicolon": 41, "\\": 42, "backslash": 42,
        ",": 43, "comma": 43, "/": 44, "slash": 44, ".": 47, "period": 47, "`": 50, "grave": 50,
        "return": 36, "enter": 36, "kp_enter": 76, "tab": 48, "space": 49, " ": 49,
        "backspace": 51, "delete": 117, "escape": 53, "esc": 53,
        "caps_lock": 57, "capslock": 57,
        "home": 115, "end": 119, "page_up": 116, "pageup": 116, "prior": 116, "page_down": 121, "pagedown": 121, "next": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "help": 114, "insert": 114, "clear": 71,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101,
        "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79, "f19": 80,
        "kp_0": 82, "kp_1": 83, "kp_2": 84, "kp_3": 85, "kp_4": 86, "kp_5": 87, "kp_6": 88, "kp_7": 89, "kp_8": 91, "kp_9": 92,
        "kp_decimal": 65, "kp_multiply": 67, "kp_add": 69, "kp_divide": 75, "kp_subtract": 78, "kp_equal": 81,
        "volumeup": 72, "volumedown": 73, "mute": 74,
    ]

    /// Characters that need Shift on a US layout → base key name.
    static let shifted: [String: String] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "minus", "+": "equal", "plus": "equal", "{": "bracketleft", "}": "bracketright", "|": "backslash",
        ":": "semicolon", "\"": "quote", "<": "comma", ">": "period", "?": "slash", "~": "grave",
        "exclam": "1", "at": "2", "numbersign": "3", "dollar": "4", "percent": "5", "asciicircum": "6",
        "ampersand": "7", "asterisk": "8", "parenleft": "9", "parenright": "0", "underscore": "minus",
        "braceleft": "bracketleft", "braceright": "bracketright", "bar": "backslash", "colon": "semicolon",
        "quotedbl": "quote", "less": "comma", "greater": "period", "question": "slash", "asciitilde": "grave",
    ]

    static func parse(_ text: String) throws -> KeyCombo {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw NaviError.other("Empty key combination") }

        var parts: [String]
        if s == "+" {
            parts = ["+"]
        } else if s.hasSuffix("++") {
            // "cmd++" → modifiers "cmd", key "+"
            parts = String(s.dropLast(2)).split(separator: "+").map(String.init) + ["+"]
        } else {
            parts = s.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        guard let last = parts.last, !last.isEmpty else { throw NaviError.other("Malformed key combination: \(text)") }

        var flags: CGEventFlags = []
        for mod in parts.dropLast() {
            guard let f = modifierFlags[mod.lowercased()] else { throw NaviError.other("Unknown modifier: \(mod)") }
            flags.insert(f)
        }

        let lower = last.lowercased()
        if let code = modifierKeyCodes[lower] {
            return KeyCombo(keyCode: code, flags: flags, keyName: lower)
        }
        if let base = shifted[last] ?? shifted[lower], let code = keyCodes[base] {
            flags.insert(.maskShift)
            return KeyCombo(keyCode: code, flags: flags, keyName: base)
        }
        if last.count == 1, let ch = last.first, ch.isUppercase, let code = keyCodes[lower] {
            flags.insert(.maskShift)
            return KeyCombo(keyCode: code, flags: flags, keyName: lower)
        }
        if let code = keyCodes[lower] {
            return KeyCombo(keyCode: code, flags: flags, keyName: lower)
        }
        throw NaviError.other("Unknown key: \(last)")
    }

    /// "⌘⇧S"-style label for the UI.
    var displayLabel: String {
        var out = ""
        if flags.contains(.maskControl) { out += "⌃" }
        if flags.contains(.maskAlternate) { out += "⌥" }
        if flags.contains(.maskShift) { out += "⇧" }
        if flags.contains(.maskCommand) { out += "⌘" }
        let name: String
        switch keyName {
        case "return", "enter": name = "Return"
        case "backspace": name = "⌫"
        case "delete": name = "⌦"
        case "escape": name = "Esc"
        case "space": name = "Space"
        case "tab": name = "Tab"
        case "up": name = "↑"
        case "down": name = "↓"
        case "left": name = "←"
        case "right": name = "→"
        default: name = keyName.count == 1 ? keyName.uppercased() : keyName.capitalized
        }
        return out + name
    }
}

// MARK: - Input controller

/// CGEvent-based mouse and keyboard synthesis. All coordinates are global
/// screen *points* (CGEvent space: origin top-left of the main display).
/// Requires the Accessibility permission.
final class InputController: @unchecked Sendable {
    enum MouseButton { case left, right, middle }
    enum ScrollDirection: String { case up, down, left, right }

    private let source = CGEventSource(stateID: .hidSystemState)
    private let tap = CGEventTapLocation.cghidEventTap

    // MARK: Permissions

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Prompts the system Accessibility dialog if not yet trusted.
    @discardableResult
    static func requestTrust() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// True when the focused AX element is a secure (password) text field.
    static func focusedElementIsSecureField() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return false }
        let element = focused as! AXUIElement
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success else { return false }
        if (role as? String) == "AXSecureTextField" { return true }
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           (subrole as? String) == "AXSecureTextField" { return true }
        return false
    }

    // MARK: Mouse

    var cursorPosition: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    func move(to p: CGPoint) async {
        post(mouse(.mouseMoved, at: p, button: .left))
        await sleep(ms: 20)
    }

    func click(at p: CGPoint?, button: MouseButton = .left, count: Int = 1, flags: CGEventFlags = []) async {
        let point = p ?? cursorPosition
        if p != nil { await move(to: point) }
        let (down, up, cgButton) = types(for: button)
        for n in 1...max(1, count) {
            let d = mouse(down, at: point, button: cgButton)
            let u = mouse(up, at: point, button: cgButton)
            d?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            u?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            if !flags.isEmpty { d?.flags = flags; u?.flags = flags }
            post(d); await sleep(ms: 30); post(u)
            if n < count { await sleep(ms: 60) }
        }
        await sleep(ms: 40)
    }

    func mouseDown(at p: CGPoint?) async {
        let point = p ?? cursorPosition
        if p != nil { await move(to: point) }
        post(mouse(.leftMouseDown, at: point, button: .left))
        await sleep(ms: 30)
    }

    func mouseUp(at p: CGPoint?) async {
        let point = p ?? cursorPosition
        post(mouse(.leftMouseUp, at: point, button: .left))
        await sleep(ms: 30)
    }

    func drag(from a: CGPoint, to b: CGPoint) async {
        await move(to: a)
        post(mouse(.leftMouseDown, at: a, button: .left))
        await sleep(ms: 60)
        let steps = 12
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            post(mouse(.leftMouseDragged, at: p, button: .left))
            await sleep(ms: 16)
        }
        await sleep(ms: 60)
        post(mouse(.leftMouseUp, at: b, button: .left))
        await sleep(ms: 40)
    }

    /// Wheel events: positive wheel1 scrolls content up, positive wheel2 scrolls left,
    /// so "down"/"right" are negated.
    func scroll(_ direction: ScrollDirection, amount: Int, at p: CGPoint?) async {
        if let p { await move(to: p) }
        var v: Int32 = 0, h: Int32 = 0
        switch direction {
        case .up: v = 1
        case .down: v = -1
        case .left: h = 1
        case .right: h = -1
        }
        for _ in 0..<max(1, amount) {
            let ev = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                             wheel1: v, wheel2: h, wheel3: 0)
            post(ev)
            await sleep(ms: 12)
        }
    }

    // MARK: Keyboard

    /// Types text as unicode key events, 8 ms apart. Newlines/tabs become Return/Tab.
    func type(_ text: String) async {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in lines.enumerated() {
            if i > 0 { await press(KeyCombo(keyCode: 36, flags: [], keyName: "return")) }
            for ch in line {
                if ch == "\t" { await press(KeyCombo(keyCode: 48, flags: [], keyName: "tab")); continue }
                var units = Array(String(ch).utf16)
                let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
                let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
                down?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                up?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                down?.flags = []; up?.flags = []
                post(down); post(up)
                await sleep(ms: 8)
            }
        }
    }

    func press(_ combo: KeyCombo, repeat count: Int = 1) async {
        for i in 0..<max(1, count) {
            let down = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: false)
            down?.flags = combo.flags
            up?.flags = combo.flags
            post(down); await sleep(ms: 20); post(up)
            if i + 1 < count { await sleep(ms: 40) }
        }
        await sleep(ms: 30)
    }

    func hold(_ combo: KeyCombo, seconds: Double) async {
        let down = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: true)
        down?.flags = combo.flags
        post(down)
        try? await Task.sleep(for: .milliseconds(Int(max(0, min(seconds, 30)) * 1000)))
        let up = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: false)
        up?.flags = combo.flags
        post(up)
        await sleep(ms: 30)
    }

    // MARK: Internals

    private func types(for b: MouseButton) -> (CGEventType, CGEventType, CGMouseButton) {
        switch b {
        case .left: return (.leftMouseDown, .leftMouseUp, .left)
        case .right: return (.rightMouseDown, .rightMouseUp, .right)
        case .middle: return (.otherMouseDown, .otherMouseUp, .center)
        }
    }

    private func mouse(_ type: CGEventType, at p: CGPoint, button: CGMouseButton) -> CGEvent? {
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
    }

    private func post(_ e: CGEvent?) { e?.post(tap: tap) }

    private func sleep(ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
}
