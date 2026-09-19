import AppKit
import Carbon.HIToolbox

/// Detects and (optionally) disables Spotlight's ⌘Space so Navi's global
/// hotkey can own it.
///
/// Spotlight's shortcuts live in `com.apple.symbolichotkeys` →
/// `AppleSymbolicHotKeys`: key `64` = "Show Spotlight search", `65` =
/// "Show Finder search window". An entry is enabled unless `enabled = 0`; a
/// missing entry means the default (enabled, ⌘Space).
enum SpotlightShortcutFix {
    struct Status: Equatable {
        /// Spotlight's "Show Spotlight search" (key 64) is enabled.
        var spotlightSearchEnabled: Bool = true
        /// Its current key combo, if we could parse it (Cocoa flags + key code).
        var spotlightKeyCode: Int? = 49
        var spotlightCocoaFlags: Int? = 1 << 20
        /// "Show Finder search window" (key 65) is enabled.
        var finderSearchEnabled: Bool = true
        /// Navi's hotkey collides with Spotlight's enabled shortcut.
        var conflict: Bool = false
        var error: String? = nil

        var summary: String {
            if let error { return "Could not read Spotlight shortcuts: \(error)" }
            if !spotlightSearchEnabled { return "Spotlight's ⌘Space shortcut is disabled — Navi owns it." }
            if conflict { return "Spotlight still owns ⌘Space. Navi's hotkey will not fire until it is disabled." }
            return "Spotlight is bound to a different shortcut — no conflict."
        }

        var level: StatusLevel {
            if error != nil { return .warn }
            return conflict ? .bad : .ok
        }
    }

    static let domain = "com.apple.symbolichotkeys"
    static let hotKeysKey = "AppleSymbolicHotKeys"

    /// Reads the current state via `defaults export` (typed XML plist) and
    /// compares Spotlight's combo with Navi's configured hotkey.
    static func detect(naviKeyCode: UInt32, naviCarbonModifiers: UInt32) async -> Status {
        var st = Status()
        let r = await Shell.run("/usr/bin/defaults", ["export", domain, "-"])
        guard r.status == 0, let data = r.stdout.data(using: .utf8) else {
            // A missing domain just means factory defaults (Spotlight on ⌘Space).
            if r.stderr.contains("does not exist") {
                st.conflict = matchesNavi(keyCode: 49, cocoaFlags: 1 << 20, naviKeyCode: naviKeyCode, naviCarbonModifiers: naviCarbonModifiers)
                return st
            }
            st.error = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return st
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let hotkeys = plist[hotKeysKey] as? [String: Any] else {
            st.conflict = matchesNavi(keyCode: 49, cocoaFlags: 1 << 20, naviKeyCode: naviKeyCode, naviCarbonModifiers: naviCarbonModifiers)
            return st
        }
        if let e64 = hotkeys["64"] as? [String: Any] {
            st.spotlightSearchEnabled = isEnabled(e64)
            if let params = ((e64["value"] as? [String: Any])?["parameters"] as? [Any]), params.count >= 3 {
                st.spotlightKeyCode = (params[1] as? NSNumber)?.intValue
                st.spotlightCocoaFlags = (params[2] as? NSNumber)?.intValue
            }
        }
        if let e65 = hotkeys["65"] as? [String: Any] { st.finderSearchEnabled = isEnabled(e65) }
        st.conflict = st.spotlightSearchEnabled && matchesNavi(keyCode: st.spotlightKeyCode, cocoaFlags: st.spotlightCocoaFlags,
                                                                naviKeyCode: naviKeyCode, naviCarbonModifiers: naviCarbonModifiers)
        return st
    }

    private static func isEnabled(_ entry: [String: Any]) -> Bool {
        if let n = entry["enabled"] as? NSNumber { return n.boolValue }
        if let s = entry["enabled"] as? String { return s != "0" && s.lowercased() != "false" }
        return true
    }

    private static func matchesNavi(keyCode: Int?, cocoaFlags: Int?, naviKeyCode: UInt32, naviCarbonModifiers: UInt32) -> Bool {
        guard let keyCode, let cocoaFlags else { return false }
        return keyCode == Int(naviKeyCode) && (cocoaFlags & 0x1F0000) == carbonToCocoa(naviCarbonModifiers)
    }

    /// Carbon modifier mask → Cocoa `NSEvent.ModifierFlags` raw bits used by symbolichotkeys.
    static func carbonToCocoa(_ carbon: UInt32) -> Int {
        var f = 0
        if carbon & UInt32(cmdKey) != 0 { f |= 1 << 20 }
        if carbon & UInt32(shiftKey) != 0 { f |= 1 << 17 }
        if carbon & UInt32(optionKey) != 0 { f |= 1 << 19 }
        if carbon & UInt32(controlKey) != 0 { f |= 1 << 18 }
        return f
    }

    static func openKeyboardShortcuts() { Permissions.openSettings(.keyboardShortcuts) }

    /// Disables "Show Spotlight search" (key 64), flushes the preference
    /// daemon, and re-registers Navi's hotkey. A logout may still be required
    /// for Spotlight itself to release the key.
    @MainActor
    static func disableSpotlightCmdSpace() async throws {
        let entry = "<dict><key>enabled</key><false/><key>value</key><dict><key>parameters</key><array><integer>32</integer><integer>49</integer><integer>1048576</integer></array><key>type</key><string>standard</string></dict></dict>"
        let w = await Shell.run("/usr/bin/defaults", ["write", domain, hotKeysKey, "-dict-add", "64", entry])
        guard w.status == 0 else { throw NaviError.other("defaults write failed: \(w.stderr)") }
        let a = await Shell.run("/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings", ["-u"])
        if a.status != 0 { Log.settings.warning("activateSettings -u exited \(a.status): \(a.stderr)") }
        AppDelegate.shared?.hotKey.register(settings: NaviSettings.shared)
        Log.settings.info("Spotlight ⌘Space disabled via symbolichotkeys; hotkey re-registered")
    }
}
