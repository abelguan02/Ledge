import AppKit
import Carbon
@preconcurrency import ApplicationServices

@MainActor protocol ShortcutRecordingAccess {
    var authorized: Bool { get }
    func requestPermission()
    func suspendSystemShortcuts() -> Bool
    func restoreSystemShortcuts()
}

@MainActor final class NativeShortcutRecordingAccess: ShortcutRecordingAccess {
    private var mode: UnsafeMutableRawPointer?
    var authorized: Bool { AXIsProcessTrusted() }
    func requestPermission() {
        let alert = NSAlert()
        alert.messageText = "录制快捷键需要辅助功能权限"
        alert.informativeText = "请在系统设置中允许\(AppIdentity.name)，然后回到此处重新开始录制。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if !NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) {
            let failure = NSAlert(); failure.messageText = "无法打开系统设置"
            failure.informativeText = "请手动打开系统设置中的隐私与安全性。"
            failure.runModal()
        }
    }
    func suspendSystemShortcuts() -> Bool {
        mode = PushSymbolicHotKeyMode(OptionBits(kHIHotKeyModeAllDisabled))
        return mode != nil
    }
    func restoreSystemShortcuts() {
        if let mode { PopSymbolicHotKeyMode(mode); self.mode = nil }
    }
}

// Only a user-initiated recording session may request access or suspend hotkeys.
// The view ends the session on cancellation, focus loss, closure or removal.
@MainActor final class ShortcutRecording {
    private let access: any ShortcutRecordingAccess
    private(set) var isRecording = false
    private(set) var error = ""
    init(access: any ShortcutRecordingAccess = NativeShortcutRecordingAccess()) { self.access = access }
    func begin() {
        guard !isRecording else { return }
        guard access.authorized else {
            error = "需要辅助功能权限"
            access.requestPermission()
            return
        }
        guard access.suspendSystemShortcuts() else { error = "无法开始录制快捷键"; return }
        error = ""; isRecording = true
    }
    func canRecordKey() -> Bool {
        guard isRecording else { return false }
        guard access.authorized else { stop(); error = "需要辅助功能权限"; return false }
        return true
    }
    func stop() {
        guard isRecording else { return }
        isRecording = false
        access.restoreSystemShortcuts()
    }
}
