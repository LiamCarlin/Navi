import AppKit
import Carbon.HIToolbox

/// Global hotkey via Carbon `RegisterEventHotKey`. Works without Accessibility
/// permission. ⌘Space is also Spotlight's shortcut: the user must disable it in
/// System Settings → Keyboard → Keyboard Shortcuts → Spotlight (Settings has a
/// button that opens that pane and a one-click `defaults` fix).
@MainActor
final class HotKeyManager {
    var onActivate: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x4E415649 // 'NAVI'

    func register(settings: NaviSettings) {
        unregister()
        let keyCode = settings.hotKeyCode
        let mods = settings.hotKeyModifiers

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData else { return noErr }
            let me = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if hkID.signature == HotKeyManager.signature {
                DispatchQueue.main.async { MainActor.assumeIsolated { me.onActivate?() } }
            }
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)

        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(keyCode, mods, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            Log.app.error("RegisterEventHotKey failed: \(status)")
        } else {
            Log.app.info("Hotkey registered: code=\(keyCode) mods=\(mods)")
        }

        NotificationCenter.default.addObserver(forName: .naviSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                if NaviSettings.shared.hotKeyCode != keyCode || NaviSettings.shared.hotKeyModifiers != mods {
                    self.register(settings: NaviSettings.shared)
                }
            }
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        if let handlerRef { RemoveEventHandler(handlerRef); self.handlerRef = nil }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Human-readable description like "⌘Space".
    static func describe(keyCode: UInt32, modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        s += keyName(keyCode)
        return s
    }

    static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        default:
            let src = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
            guard let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
            let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
            return data.withUnsafeBytes { raw -> String in
                guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return "?" }
                var dead: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var len = 0
                UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                               UInt32(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
                return String(utf16CodeUnits: chars, count: len).uppercased()
            }
        }
    }
}
