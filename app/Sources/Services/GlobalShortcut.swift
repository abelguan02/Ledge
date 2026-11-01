import AppKit
import Carbon

@MainActor protocol ShortcutRegistry {
    func register(_ shortcut: AppShortcut, id: UInt32) throws
    func unregister(id: UInt32) throws
}

@MainActor final class NativeShortcutRegistry: ShortcutRegistry {
    var pressed: ((UInt32) -> Void)?
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private func install() throws {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard result == noErr else { return result }
            MainActor.assumeIsolated { Unmanaged<NativeShortcutRegistry>.fromOpaque(data).takeUnretainedValue().pressed?(key.id) }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw LibraryError.invalid("全局快捷键监听无法建立。") }
    }
    func register(_ shortcut: AppShortcut, id: UInt32) throws {
        try install()
        var flags: UInt32 = 0
        for (mask, carbon) in [(AppShortcut.control, controlKey), (AppShortcut.option, optionKey), (AppShortcut.command, cmdKey), (AppShortcut.shift, shiftKey)] where shortcut.modifiers & mask != 0 { flags |= UInt32(carbon) }
        var systemKeys: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&systemKeys) == noErr, let systemKeys else { throw LibraryError.invalid("无法检查系统快捷键。") }
        let reserved = systemKeys.takeRetainedValue() as NSArray
        for case let entry as NSDictionary in reserved {
            if (entry[kHISymbolicHotKeyEnabled] as? NSNumber)?.boolValue == true,
               (entry[kHISymbolicHotKeyCode] as? NSNumber)?.uint32Value == shortcut.keyCode,
               (entry[kHISymbolicHotKeyModifiers] as? NSNumber)?.uint32Value == flags {
                throw LibraryError.invalid("这个组合无法使用")
            }
        }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, flags, EventHotKeyID(signature: 0x4C444745, id: id), GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { throw LibraryError.invalid("这个组合无法使用") }
        references[id] = ref
    }
    func unregister(id: UInt32) throws {
        guard let ref = references[id] else { return }
        guard UnregisterEventHotKey(ref) == noErr else { throw LibraryError.invalid("无法释放原快捷键。") }
        references[id] = nil
    }
    func stop() {
        for ref in references.values { UnregisterEventHotKey(ref) }
        references = [:]
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
}

@MainActor final class GlobalShortcut: ObservableObject {
    @Published var error = ""
    private let preferences: AppPreferences
    private let registry: any ShortcutRegistry
    private(set) var activeID: UInt32?
    private var nextID: UInt32 = 0
    init(preferences: AppPreferences, registry: any ShortcutRegistry) { self.preferences = preferences; self.registry = registry }
    func start() { if let shortcut = preferences.shortcut { set(shortcut, initial: true) } }
    func set(_ shortcut: AppShortcut?, initial: Bool = false) {
        guard initial || shortcut != preferences.shortcut else { error = ""; return }
        guard shortcut?.valid != false else { error = "这个组合无法使用"; return }
        let oldID = activeID
        nextID += 1
        do {
            if let shortcut { try registry.register(shortcut, id: nextID) }
            do { if let oldID { try registry.unregister(id: oldID) } }
            catch { if shortcut != nil { try registry.unregister(id: nextID) }; throw error }
            activeID = shortcut == nil ? nil : nextID
            preferences.shortcut = shortcut; error = ""
        } catch { self.error = error.localizedDescription }
    }
}
