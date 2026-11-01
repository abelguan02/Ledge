import AppKit

@MainActor final class TestRecordingAccess: ShortcutRecordingAccess {
    var authorized = false
    var requests = 0
    var suspensions = 0
    var restorations = 0
    var acceptsSuspension = true
    func requestPermission() { requests += 1 }
    func suspendSystemShortcuts() -> Bool { suspensions += 1; return acceptsSuspension }
    func restoreSystemShortcuts() { restorations += 1 }
}

@MainActor enum ShortcutRecordingTests {
    static func run(preferences: AppPreferences) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let access = TestRecordingAccess(), registry = TestShortcutRegistry()
        let recording = ShortcutRecording(access: access)
        let shortcut = GlobalShortcut(preferences: preferences, registry: registry)
        shortcut.set(.initial)
        let field = ShortcutField(session: recording)
        var changes = 0
        field.changed = {
            precondition(!recording.isRecording)
            changes += 1; shortcut.set($0)
        }
        field.recordingFeedback = { shortcut.error = $0 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = field
        defer { window.contentView = nil; window.close() }
        func key(_ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            field.keyDown(with: event)
        }
        func begin() { precondition(field.accessibilityPerformPress()); precondition(recording.isRecording) }

        precondition(access.requests == 0 && access.suspensions == 0)
        _ = field.accessibilityPerformPress()
        precondition(access.requests == 1 && access.suspensions == 0 && !recording.isRecording)
        precondition(preferences.shortcut == .initial && shortcut.error == "需要辅助功能权限")
        key(51, "")
        precondition(preferences.shortcut == nil && access.requests == 1)
        shortcut.set(.initial)
        access.authorized = true
        begin(); key(38, "j")
        precondition(recording.isRecording)
        key(53, "")
        precondition(!recording.isRecording && access.restorations == 1 && preferences.shortcut == .initial)

        registry.reject = true
        begin(); key(49, " ", .command)
        precondition(!recording.isRecording && access.restorations == 2)
        precondition(preferences.shortcut == .initial && shortcut.error == "这个组合无法使用")
        registry.reject = false
        begin(); key(40, "k", .command)
        precondition(preferences.shortcut?.display == "⌘K" && access.restorations == 3 && shortcut.error.isEmpty)
        begin(); precondition(field.acceptCurrentShortcut())
        precondition(!recording.isRecording && access.restorations == 4)
        precondition(!field.acceptCurrentShortcut())

        begin(); access.authorized = false
        let beforeRevocation = changes
        key(37, "l", .command)
        precondition(changes == beforeRevocation && preferences.shortcut?.display == "⌘K")
        precondition(!recording.isRecording && access.restorations == 5 && shortcut.error == "需要辅助功能权限")
        precondition(access.requests == 1)
        access.authorized = true
        for (name, object) in [(NSWindow.didResignKeyNotification, window as AnyObject), (NSWindow.willCloseNotification, window as AnyObject), (NSApplication.didResignActiveNotification, app as AnyObject)] {
            begin(); let restores = access.restorations
            NotificationCenter.default.post(name: name, object: object)
            precondition(!recording.isRecording && access.restorations == restores + 1)
            field.stopRecording()
            precondition(access.restorations == restores + 1)
        }
        begin(); let restores = access.restorations
        field.removeFromSuperview()
        precondition(!recording.isRecording && access.restorations == restores + 1)
        access.acceptsSuspension = false
        recording.begin()
        precondition(!recording.isRecording && recording.error == "无法开始录制快捷键")
        precondition(!window.isVisible && !app.isActive)
        print("PASS hidden shortcut field: explicit permission request, denial preserves binding, clearing without access, conflict/success, Esc, current shortcut, revocation, focus/window/app/view cleanup; no real permission or keyboard events")
    }
}
