import AppKit
import SwiftUI

// Foreground QA only, after the user's current idle-time confirmation.
// Uses the real controllers with a temporary library and a synthetic backend.
@MainActor private final class SkinReviewBackend: TextBackend {
    func catalog() async throws -> CodexCatalog { CodexCatalog(models: [], preferred: "synthetic") }
    func respond(input: String, instructions: String, model: String) async throws -> String { "这是隔离验收的合成回答，不会连接账号或网络。" }
    func stop() { }
}
@MainActor private final class SkinReviewShortcuts: ShortcutRegistry {
    func register(_ shortcut: AppShortcut, id: UInt32) throws { }
    func unregister(id: UInt32) throws { }
}

@MainActor private final class SkinReviewSession: NSObject, NSApplicationDelegate {
    private var model: WorkbenchModel!
    private var panel: PanelController!
    private var settings: SettingsController!
    private var about: AboutController!
    private var guide: OnboardingController!
    private var root: URL!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await prepare() }
            catch { FileHandle.standardError.write(Data("Skin review failed: \(error)\n".utf8)); NSApp.terminate(nil) }
        }
    }
    private func prepare() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ledge-skin-review-\(UUID())")
        let library = try Library(root: root.appendingPathComponent("library"), makeBookmark: { _ in Data() })
        let group = await library.index.currentCollection
        _ = try await library.importText("看中的东西，先搁这儿。\n\n这是一张合成便签。\nClassic appearance review", collection: group)
        _ = try await library.importText("https://example.invalid/skin-review", collection: group)
        let renderer = ImageRenderer(content: LinearGradient(colors: [.blue, .orange], startPoint: .topLeading, endPoint: .bottomTrailing).frame(width: 320, height: 240))
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        let picture = root.appendingPathComponent("synthetic.png")
        try data.write(to: picture)
        _ = try await library.importFile(picture, collection: group, kind: .image)
        _ = try await library.createCollection("合成收集区")
        let preferences = AppPreferences()
        preferences.automaticWebPreviews = false
        model = WorkbenchModel(library: library, bridge: SkinReviewBackend(), preferences: preferences)
        await model.refresh()
        model.selectCollection(group)
        await model.waitForWrites()
        model.codexAvailable = true
        panel = PanelController(model: model)
        settings = SettingsController(model: model, shortcut: GlobalShortcut(preferences: preferences, registry: SkinReviewShortcuts()), login: LoginPreference())
        guide = OnboardingController(preferences: preferences) { [weak self] in self?.panel.resume(.canvas) }
        about = AboutController(preferences: preferences) { [weak self] in self?.showGuide() }
        model.requestSettings = { [weak self] in self?.settings.present() }
        let menu = NSMenu()
        let item = NSMenuItem(title: "经典验收", action: nil, keyEquivalent: "")
        let commands = NSMenu()
        for title in ["画布", "投放面板", "小舌片", "清空确认", "设置", "关于", "新手引导", "右侧", "左侧", "上方", "浅色", "深色", "退出验收"] {
            let entry = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: title == "退出验收" ? "q" : "")
            entry.target = self; commands.addItem(entry)
        }
        item.submenu = commands; menu.addItem(item); NSApp.mainMenu = menu
        panel.show(.canvas)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func choose(_ sender: NSMenuItem) {
        switch sender.title {
        case "画布": panel.show(.canvas)
        case "投放面板": model.dropKind = .image; model.dropCount = 3; panel.show(.drop)
        case "小舌片": panel.show(.line)
        case "清空确认": panel.show(.canvas); model.askRemoval(ids: Set(model.items.map(\.id)))
        case "设置": settings.present()
        case "关于": about.present()
        case "新手引导": showGuide()
        case "右侧", "左侧", "上方":
            let edge: DockEdge = sender.title == "右侧" ? .right : sender.title == "左侧" ? .left : .top
            model.preferences.dockEdge = edge; panel.setEdge(edge)
        case "浅色", "深色": NSApp.appearance = NSAppearance(named: sender.title == "深色" ? .darkAqua : .aqua)
        case "退出验收": NSApp.terminate(nil)
        default: break
        }
    }
    private func showGuide() { panel.suspend(); guide.present() }
    func applicationWillTerminate(_ notification: Notification) {
        panel?.suspend()
        // Retain only this disposable fixture directory for inspection. It is
        // under the OS temporary directory and never becomes the user's library.
    }
}

@main @MainActor struct SkinReview {
    static func main() {
        guard CommandLine.arguments.contains("--show") else {
            print("Foreground review requires --show and the user's current idle-time confirmation.")
            return
        }
        NSApplication.shared.setActivationPolicy(.regular)
        let session = SkinReviewSession()
        NSApp.delegate = session
        withExtendedLifetime(session) { NSApp.run() }
    }
}
