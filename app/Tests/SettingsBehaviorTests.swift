import AppKit

@MainActor final class SettingsBackend: TextBackend {
    var calls = 0
    var unavailable = false
    var pause = false
    var waiting: CheckedContinuation<String, Never>?
    func catalog() async throws -> CodexCatalog {
        if unavailable { throw AIError.problem("synthetic unavailable") }
        return CodexCatalog(models: [], preferred: "synthetic")
    }
    func respond(input: String, instructions: String, model: String) async throws -> String {
        calls += 1
        if pause { return await withCheckedContinuation { waiting = $0 } }
        return "synthetic reply"
    }
    func stop() {}
}
@MainActor final class TestShortcutRegistry: ShortcutRegistry {
    var registrations: [UInt32: AppShortcut] = [:]
    var reject = false
    func register(_ shortcut: AppShortcut, id: UInt32) throws {
        if reject { throw LibraryError.invalid("这个组合无法使用") }
        registrations[id] = shortcut
    }
    func unregister(id: UInt32) throws { registrations[id] = nil }
}
@main @MainActor struct SettingsBehaviorTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ledge-settings-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let domain = "local.ledge.test.\(UUID())", defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let prefs = AppPreferences(defaults: defaults), backend = SettingsBackend()
        precondition(prefs.skin == .classic)
        prefs.skin = .unit01
        precondition(AppPreferences(defaults: defaults).skin == .unit01)
        defaults.set("unknown", forKey: "skin")
        precondition(AppPreferences(defaults: defaults).skin == .classic)
        prefs.skin = .classic
        precondition(SkinChoice.unit01.title(language: "zh-Hans") == "初号机")
        precondition(SkinChoice.unit01.title(language: "zh-Hant") == "初號機")
        precondition(SkinChoice.unit01.title(language: "en") == "Unit-01")
        let library = try Library(root: root)
        let item = try await library.importText("synthetic", collection: await library.index.currentCollection)
        let model = WorkbenchModel(library: library, bridge: backend, preferences: prefs)
        await model.refresh()
        prefs.aiEnabled = false
        model.runText(item, action: .explain)
        precondition(model.busy.isEmpty && backend.calls == 0 && model.aiHelp == "AI 已关闭")
        precondition(!AppPreferences(defaults: defaults).aiEnabled)
        prefs.aiEnabled = true
        await model.checkCodex()
        precondition(model.canUseAI && model.aiStatus == "已连接 Codex")
        backend.unavailable = true
        await model.checkCodex()
        precondition(!model.canUseAI && model.aiHelp == "未找到 Codex")
        model.runText(item, action: .explain)
        precondition(backend.calls == 0)
        backend.unavailable = false
        await model.checkCodex()
        model.runText(item, action: .explain)
        while !model.busy.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        precondition(backend.calls == 1)
        let queued = try await library.importText("synthetic queued", collection: item.collectionID)
        await model.refresh(); backend.pause = true
        model.runText(item, action: .explain)
        while backend.waiting == nil { try await Task.sleep(for: .milliseconds(10)) }
        model.runText(queued, action: .explain)
        let inFlightItems = model.items, inFlightBusy = model.busy
        for skin in [SkinChoice.unit01, .classic, .unit01] { prefs.skin = skin }
        precondition(model.items == inFlightItems && model.busy == inFlightBusy && backend.calls == 2)
        prefs.aiEnabled = false
        backend.waiting?.resume(returning: "in-flight reply completed"); backend.waiting = nil
        while !model.busy.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        precondition(backend.calls == 2 && model.drafts[item.id]?.answer == "in-flight reply completed")
        precondition(model.drafts[queued.id]?.answer.isEmpty == true)
        print("PASS disabling AI allows in-flight reply to finish and stops the next queued request")
        let registry = TestShortcutRegistry()
        let recording = GlobalShortcut(preferences: prefs, registry: registry)
        recording.start()
        let previous = prefs.shortcut
        precondition(AppShortcut.initial.menuKey == "d")
        precondition(AppShortcut(keyCode: 49, modifiers: AppShortcut.command, key: "空格").keyCaps == ["⌘", "空格"])
        precondition(AppShortcut(keyCode: 122, modifiers: AppShortcut.control, key: "F1").menuKey == "\u{F704}")
        registry.reject = true
        recording.set(AppShortcut(keyCode: 40, modifiers: AppShortcut.command, key: "K"))
        precondition(prefs.shortcut == previous && registry.registrations.count == 1 && !recording.error.isEmpty)
        registry.reject = false
        recording.set(AppShortcut(keyCode: 40, modifiers: AppShortcut.command, key: "K"))
        precondition(prefs.shortcut?.display == "⌘K" && registry.registrations.count == 1)
        recording.set(nil)
        precondition(registry.registrations.isEmpty && AppPreferences(defaults: defaults).shortcut == nil)
        ShortcutRecordingTests.run(preferences: prefs)
        await library.updateLimits(CapacityLimits(collection: 2, item: 2, freeDisk: 0))
        do { _ = try await library.importText("too large", collection: item.collectionID); fatalError("New limit not applied") } catch {}
        let preserved = await library.index
        precondition(preserved.items.contains { $0.id == item.id })
        precondition(model.undoTitle == nil)
        model.askRemoval(ids: [queued.id]); await model.waitForWrites()
        model.confirmRemoval(); await model.waitForWrites()
        precondition(model.undoTitle == "撤销删除 1 样材料")
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let undo = try encoder.encode(model.index.undo), current = model.index.currentCollection
        prefs.skin = .classic; prefs.skin = .unit01
        let switchedUndo = try encoder.encode(model.index.undo)
        precondition(switchedUndo == undo && model.index.currentCollection == current)
        model.undo(); await model.waitForWrites(); precondition(model.undoTitle == nil)
        model.askRemoval(ids: Set(model.items.map(\.id))); await model.waitForWrites()
        model.confirmRemoval(); await model.waitForWrites()
        precondition(model.undoTitle == "撤销清空「\(model.collectionName)」")
        model.undo(); await model.waitForWrites()
        precondition(model.undoTitle == nil && model.items.count == preserved.items.count)
        print("PASS skin default, persistence, unknown-value fallback, labels, switching during processing and undo preservation")
        print("PASS conditional menu undo labels and shared material/clear undo")
        print("PASS shortcut registration conflict preserves old binding, replacement, clearing persistence; live capacity reduction preserves old materials")
        print("PASS AI toggle persistence, disabled gating, unavailable state and recheck; synthetic backend only")
    }
}
