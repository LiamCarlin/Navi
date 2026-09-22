import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Click, press a combo, done. Captures the next key-down through a local
/// `NSEvent` monitor and writes Carbon key code + Carbon modifier mask to
/// `NaviSettings`. While recording, the live global hotkey is unregistered so
/// the current combo (e.g. ⌘Space) can be re-captured instead of toggling the panel.
struct HotKeyRecorderView: View {
    /// Which shortcut this recorder edits: the panel's (⌘Space) or voice control's (⌥Space).
    enum Kind { case panel, voice }
    var kind: Kind = .panel

    @EnvironmentObject private var settings: NaviSettings
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    private var code: UInt32 { kind == .panel ? settings.hotKeyCode : settings.voiceHotKeyCode }
    private var mods: UInt32 { kind == .panel ? settings.hotKeyModifiers : settings.voiceHotKeyModifiers }
    private var defaultCode: UInt32 { 49 }
    private var defaultMods: UInt32 { kind == .panel ? UInt32(cmdKey) : UInt32(optionKey) }
    private func set(code: UInt32, mods: UInt32) {
        if kind == .panel { settings.hotKeyModifiers = mods; settings.hotKeyCode = code }
        else { settings.voiceHotKeyModifiers = mods; settings.voiceHotKeyCode = code }
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                recording ? stop() : start()
            } label: {
                HStack(spacing: 6) {
                    if recording {
                        Image(systemName: "record.circle").foregroundStyle(.red).symbolEffect(.pulse)
                        Text("Press a shortcut…")
                    } else {
                        Text(HotKeyManager.describe(keyCode: code, modifiers: mods))
                            .font(.system(.body, design: .rounded).weight(.medium))
                            .monospacedDigit()
                    }
                }
                .frame(minWidth: 130)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            if recording {
                Button("Cancel") { stop() }.buttonStyle(.borderless).controlSize(.small)
            } else if code != defaultCode || mods != defaultMods {
                Button("Reset to \(HotKeyManager.describe(keyCode: defaultCode, modifiers: defaultMods))") {
                    set(code: defaultCode, mods: defaultMods)
                }
                .buttonStyle(.borderless).controlSize(.small)
            }
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear { if recording { stop() } }
    }

    private func start() {
        recording = true
        hint = "Use at least one modifier. ⎋ cancels."
        AppDelegate.shared?.hotKey.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { ev in
            if ev.keyCode == UInt16(kVK_Escape) {
                MainActor.assumeIsolated { stop() }
                return nil
            }
            let carbon = Self.carbonModifiers(from: ev.modifierFlags)
            let isFunctionKey = (ev.keyCode >= 96 && ev.keyCode <= 111) || ev.keyCode == 122 || ev.keyCode == 120 || ev.keyCode == 99 || ev.keyCode == 118
            guard carbon != 0 || isFunctionKey else {
                MainActor.assumeIsolated { hint = "Add ⌘, ⌥, ⌃ or ⇧ — a bare key would swallow typing." }
                return nil
            }
            let code = UInt32(ev.keyCode)
            MainActor.assumeIsolated {
                set(code: code, mods: carbon)   // posts .naviSettingsChanged → HotKeyManager re-registers
                hint = nil
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        recording = false
        AppDelegate.shared?.hotKey.register(settings: settings)
    }

    /// Cocoa flags → Carbon mask (cmdKey=256, shiftKey=512, optionKey=2048, controlKey=4096).
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }
}
