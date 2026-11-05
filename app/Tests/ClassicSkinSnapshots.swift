import AppKit
import SwiftUI
import CryptoKit

@MainActor final class SnapshotBackend: TextBackend {
    func catalog() async throws -> CodexCatalog { fatalError("Snapshots must not contact AI") }
    func respond(input: String, instructions: String, model: String) async throws -> String { fatalError("Snapshots must not contact AI") }
    func stop() { }
}
@MainActor final class SnapshotShortcuts: ShortcutRegistry {
    func register(_ shortcut: AppShortcut, id: UInt32) throws { fatalError("Snapshots must not register shortcuts") }
    func unregister(id: UInt32) throws { fatalError("Snapshots must not register shortcuts") }
}

// Render production components without opening windows, reading the clipboard,
// connecting to accounts or importing personal files. ImageRenderer does not
// reproduce window-server glass or native editors: those need separate UI QA.
@main @MainActor struct ClassicSkinSnapshots {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixture = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // URL.standardizedFileURL can resolve /private/tmp differently before
        // the directory exists. Both versions must display the same path.
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let library = try Library(root: fixture, makeBookmark: { _ in Data() })
        let preferences = AppPreferences()
        #if UNIT_SKIN
        preferences.skin = .unit01
        #endif
        preferences.automaticWebPreviews = false
        let model = WorkbenchModel(library: library, bridge: SnapshotBackend(), preferences: preferences)
        model.index.collections[0].name = "灵感 · Classic"
        let group = model.index.currentCollection
        let text = Material(collectionID: group, name: "合成便签", filename: "note.txt", kind: .text, origin: .pastedText)
        let link = Material(collectionID: group, name: "Example reference", filename: "link.txt", kind: .link, origin: .link)
        var photo = Material(collectionID: group, name: "合成图片.png", filename: "photo.png", kind: .image, origin: .importedFile)
        photo.position = CanvasPoint(x: 240, y: 24)
        var video = photo; video.id = UUID(); video.kind = .video; video.name = "合成视频.mov"
        let audio = Material(collectionID: group, name: "合成音频.wav", filename: "sound.wav", kind: .audio, origin: .importedFile)
        let file = Material(collectionID: group, name: "合成文件.pdf", filename: "file.pdf", kind: .file, origin: .importedFile)
        model.index.items = [text, photo, link, video, audio, file]
        model.textPreviews[text.id] = "看中的东西，先搁这儿。\nClassic skin regression\n" + String(repeating: "文字裁切与行距检查。", count: 30)
        model.textPreviews[link.id] = "https://example.invalid/reference"
        let picture = ImageRenderer(content: LinearGradient(colors: [.red, .blue], startPoint: .topLeading, endPoint: .bottomTrailing).frame(width: 144, height: 120)).nsImage!
        model.thumbnails[photo.id] = picture; model.thumbnails[video.id] = picture
        model.durations[video.id] = "1:23"; model.durations[audio.id] = "3:21"
        model.drafts[text.id] = AnswerDraft(sourceID: text.id, answer: "这是隔离的合成回答。")
        var manifest: [String: String] = [:]
        for scheme in [ColorScheme.light, .dark] {
            NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            for scale: CGFloat in [1, 2] {
                preferences.aiEnabled = true
                func save<V: View>(_ name: String, _ view: V, _ width: CGFloat, _ height: CGFloat) throws {
                    #if UNIT_SKIN
                    let presented = AnyView(SkinRoot(preferences: preferences, scanlines: !(view is DropView)) { view }.environment(\.skinMotionOverride, true))
                    #else
                    let presented = AnyView(view)
                    #endif
                    let renderer = ImageRenderer(content: presented.frame(width: width, height: height)
                        .environment(\.colorScheme, scheme).environment(\.displayScale, scale)
                        .transaction { $0.animation = nil })
                    renderer.scale = scale
                    guard let image = renderer.cgImage else { throw NSError(domain: "Snapshot", code: 1) }
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    guard let png = bitmap.representation(using: .png, properties: [:]), let bytes = image.dataProvider?.data else { throw NSError(domain: "Snapshot", code: 2) }
                    let key = "\(scheme)-\(Int(scale))x-\(name)"
                    try png.write(to: output.appendingPathComponent(key + ".png"))
                    manifest[key] = "\(image.width)x\(image.height):" + SHA256.hash(data: bytes as Data).map { String(format: "%02x", $0) }.joined()
                }
                for edge in DockEdge.allCases {
                    for (name, state) in [("quiet", EdgeState.quiet), ("processing", .processing), ("attention", .attention), ("failed", .failed)] {
                        for reduced in [false, true] {
                            #if UNIT_SKIN
                            try save("tab-\(edge)-\(name)-\(reduced)", EdgeLineIndicator(state: state, time: 0.6, reduceMotion: reduced, hovering: true, edge: edge), 160, 160)
                            #else
                            try save("tab-\(edge)-\(name)-\(reduced)", EdgeLineIndicator(state: state, time: 0.6, reduceMotion: reduced, hovering: true, edge: edge), 100, 100)
                            #endif
                        }
                    }
                    preferences.dockEdge = edge
                    try save("panel-\(edge)", PanelShell(width: 300, height: 420, edge: edge) { Text("Classic") }, 360, 480)
                    for kind in [DropKind.file, .image, .text] {
                        model.dropKind = kind; model.dropCount = 3; model.dropZone = 1
                        try save("drop-\(edge)-\(kind)", DropView(model: model), 360, 480)
                    }
                }
                for item in [text, photo, video, audio, file] {
                    for selected in [false, true] {
                        model.selected = selected ? [item.id] : []
                        try save("material-\(item.kind)-\(selected)", MaterialView(model: model, item: item), 340, 260)
                    }
                }
                model.selected = []
                model.missingCopies = [text.id]
                try save("missing-copy", MaterialView(model: model, item: text), 260, 210)
                model.missingCopies = []
                for state in [LinkPreviewState.pending, .ready, .failed, .needsLogin, .blocked] {
                    var item = link
                    item.linkPreview = LinkPreview(state: state)
                    if state == .ready { model.webImages[link.id] = picture } else { model.webImages = [:] }
                    if state == .pending { model.webProgress[link.id] = 0.4 } else { model.webProgress = [:] }
                    try save("link-\(state)", MaterialView(model: model, item: item), 320, 280)
                }
                for enabled in [true, false] {
                    preferences.aiEnabled = enabled
                    try save("answer-\(enabled)", AnswerCard(model: model, item: text), 340, 500)
                }
                for summary in [ClearSummary(backedUp: 3), ClearSummary(backedUp: 2, unique: [.pastedText: [text.id], .link: [link.id]])] {
                    let request = RemovalRequest(ids: [text.id, link.id], title: "清空‘灵感’？", summary: summary)
                    try save("clear-\(summary.uniqueIDs.count)", ClearConfirmation(model: model, request: request), 520, 720)
                }
                for page in [CollectionPage.switcher, .manager, .confirmation] {
                    model.collectionPage = page
                    model.collectionSelection = [group]
                    model.collectionConfirmation = CollectionRemovalSnapshot(collections: model.index.collections, allCollectionIDs: [group], members: [group: [text.id, link.id]], summary: ClearSummary(unique: [.pastedText: [text.id], .link: [link.id]]))
                    try save("collections-\(page)", CollectionMenuView(model: model), 340, 480)
                }
                model.collectionPage = .closed
                for tab in 0..<4 { try save("settings-\(tab)", skinSnapshotSettings(model: model, tab: tab), 520, 400) }
                for coffee in [false, true] { try save("about-\(coffee)", skinSnapshotAbout(coffee: coffee), 340, 470) }
                for step in 0..<6 { try save("guide-\(step)", skinSnapshotGuide(preferences: preferences, step: step), 1100, 750) }
                let stack = UUID()
                var first = text; first.stackID = stack; first.stackOrder = 0
                var second = photo; second.stackID = stack; second.stackOrder = 1; second.position = first.position
                model.index.items = [first, second]; model.openStackID = stack
                model.visibleCanvasRect = CGRect(x: 0, y: 0, width: 520, height: 668)
                try save("stack-tray", StackTrayOverlay(model: model, stack: stack), 520, 668)
                model.openStackID = nil; model.stackHoverID = stack; model.stackDropReady = true
                try save("stack-canvas", CanvasContent(model: model, size: CGSize(width: 520, height: 668)), 520, 668)
                model.index.items = [text, photo, link, video, audio, file]; model.stackHoverID = nil
            }
        }
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("manifest.json"))
        precondition(NSApp.windows.allSatisfy { !$0.isVisible }, "Snapshot run must not show windows")
        print("PASS \(manifest.count) production component renders; light/dark, 1x/2x; no visible windows or network")
    }
}
