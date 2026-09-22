import AppKit
import Carbon.HIToolbox

/// Global hotkey via Carbon `RegisterEventHotKey`. Works without Accessibility
/// permission. ⌘Space is also Spotlight's shortcut: the user must disable it in
/// System Settings → Keyboard → Keyboard Shortcuts → Spotlight (Settings has a
/// button that opens that pane and a one-click `defaults` fix).
@MainActor
final class HotKeyManager {
    var onActivate: (() -> Void)?
    /// The voice shortcut (⌥Space by default): start / stop listening from anywhere.
    var onVoice: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var voiceHotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var settingsObserver: NSObjectProtocol?
    private static let signature: OSType = 0x4E415649 // 'NAVI'
    private static let panelID: UInt32 = 1
    private static let voiceID: UInt32 = 2

    func register(settings: NaviSettings) {
        unregister()
        let keyCode = settings.hotKeyCode
        let mods = settings.hotKeyModifiers
        let voiceOn = settings.voiceHotKeyEnabled
        let voiceCode = settings.voiceHotKeyCode
        let voiceMods = settings.voiceHotKeyModifiers

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData else { return noErr }
            let me = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if hkID.signature == HotKeyManager.signature {
                let isVoice = hkID.id == HotKeyManager.voiceID
                DispatchQueue.main.async { MainActor.assumeIsolated { isVoice ? me.onVoice?() : me.onActivate?() } }
            }
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)

        let id = EventHotKeyID(signature: Self.signature, id: Self.panelID)
        let status = RegisterEventHotKey(keyCode, mods, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            Log.app.error("RegisterEventHotKey failed: \(status)")
        } else {
            Log.app.info("Hotkey registered: code=\(keyCode) mods=\(mods)")
        }
        if voiceOn, !(voiceCode == keyCode && voiceMods == mods) {
            let vid = EventHotKeyID(signature: Self.signature, id: Self.voiceID)
            let vs = RegisterEventHotKey(voiceCode, voiceMods, vid, GetApplicationEventTarget(), 0, &voiceHotKeyRef)
            if vs != noErr { Log.app.error("Voice hotkey registration failed: \(vs)") } else { Log.app.info("Voice hotkey registered: code=\(voiceCode) mods=\(voiceMods)") }
        }

        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        settingsObserver = NotificationCenter.default.addObserver(forName: .naviSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                let s = NaviSettings.shared
                if s.hotKeyCode != keyCode || s.hotKeyModifiers != mods
                    || s.voiceHotKeyEnabled != voiceOn || s.voiceHotKeyCode != voiceCode || s.voiceHotKeyModifiers != voiceMods {
                    self.register(settings: s)
                }
            }
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        if let voiceHotKeyRef { UnregisterEventHotKey(voiceHotKeyRef); self.voiceHotKeyRef = nil }
        if let handlerRef { RemoveEventHandler(handlerRef); self.handlerRef = nil }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let voiceHotKeyRef { UnregisterEventHotKey(voiceHotKeyRef) }
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
