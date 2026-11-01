import AppKit
import CoreText

@main @MainActor struct Phase5QA {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let args = CommandLine.arguments, fm = FileManager.default
        let command = args[1]
        if command == "fixtures" {
            let directory = URL(fileURLWithPath: args[2], isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let image = NSImage(size: CGSize(width: 640, height: 400), flipped: false) { rect in
                NSColor.darkGray.setFill(); NSBezierPath(rect: rect).fill()
                ("Dump QA 图片" as NSString).draw(at: CGPoint(x: 80, y: 180), withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.white])
                return true
            }
            try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("QA-image.png"))
            var page = CGRect(x: 0, y: 0, width: 600, height: 800)
            let pdf = CGContext(directory.appendingPathComponent("QA-document.pdf") as CFURL, mediaBox: &page, nil)!
            pdf.beginPDFPage(nil); pdf.setFillColor(NSColor.white.cgColor); pdf.fill(page)
            pdf.textPosition = CGPoint(x: 60, y: 650)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Dump Phase5 PDF QA", attributes: [.font: NSFont.systemFont(ofSize: 28)])), pdf)
            pdf.endPDFPage(); pdf.closePDF()
            let folder = directory.appendingPathComponent("QA-folder/nested", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try "QA nested file — export must remain intact".write(to: folder.appendingPathComponent("QA-note.txt"), atomically: true, encoding: .utf8)
            print("PASS synthetic image, PDF and nested folder prepared"); return
        }
        if command == "clipboard" {
            let board = NSPasteboard.general, base = args[2]
            let saved = (board.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
            defer {
                let restored = saved.map { entries in let item = NSPasteboardItem(); for (type, data) in entries { item.setData(data, forType: type) }; return item }
                board.clearContents(); if !restored.isEmpty { board.writeObjects(restored) }
                print("RESTORED clipboard item count=\(restored.count)")
            }
            print("READY clipboard backup held only in memory")
            while let command = readLine() {
                if command == "restore" { return }
                if command == "inspect" {
                    let items = board.pasteboardItems ?? []
                    print("items=\(items.count) types=\(items.map { $0.types.map(\.rawValue) })")
                    print("textCount=\(board.string(forType: .string)?.count ?? 0) hasEnd=\(board.string(forType: .string)?.contains("END-PHASE5") ?? false)")
                    let text = board.string(forType: .string) ?? ""
                    print("hasCompleteReadyURL=\(text.contains(base + "/page?sample=ready#complete")) hasCompleteTitledURL=\(text.contains(base + "/page?sample=titled#complete")) hasLocalText=\(text.contains("QA-PHASE5-LOCAL"))")
                    continue
                }
                let item = NSPasteboardItem()
                if command == "edit" {
                    item.setString("QA", forType: .string)
                } else if command == "text" {
                    item.setString("QA-PHASE5-TEXT\n" + String(repeating: "完整文字预览与复制测试🙂\n", count: 250) + "END-PHASE5", forType: .string)
                } else if command == "artstation" {
                    let url = "https://www.artstation.com/?sort_by=community&dimension=all"
                    item.setString(url, forType: .URL); item.setString(url, forType: .string)
                } else {
                    let paths = ["ready": "/page?sample=ready#complete", "titled": "/page?sample=titled#complete", "blocked": "/token/consume?sample=once", "login": "/restricted", "failure": "/download", "isolated": "/isolated-denied", "slow": "/hang"]
                    guard let path = paths[command] else { print("UNKNOWN command"); continue }
                    let url = base + path
                    item.setString(url, forType: .URL); item.setString(url, forType: .string)
                    if command == "titled" { item.setString("QA 自带标题", forType: .init("public.url-name")) }
                }
                board.clearContents(); board.writeObjects([item]); print("SEEDED \(command)")
            }
            return
        }
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/local.dump.desktop/Data/Library/Application Support/Dump")
        if command == "inspect" {
            let index = try JSONDecoder().decode(LibraryIndex.self, from: Data(contentsOf: root.appendingPathComponent("library.json")))
            guard let group = index.collections.first(where: { $0.name == "第五阶段预览验收" }) else { print("NO QA collection"); return }
            print("currentID=\(index.currentCollection) qaID=\(group.id)")
            for item in index.items where item.collectionID == group.id {
                print("QA id=\(item.id) kind=\(item.kind) name=\(item.name.replacingOccurrences(of: "\n", with: " ")) x=\(item.position.x) y=\(item.position.y) size=\(item.size.width)x\(item.size.height) state=\(item.linkPreview?.state.rawValue ?? "none") stack=\(item.stackID?.uuidString ?? "none") image=\(item.linkPreview?.filename ?? "none")")
            }
            return
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "local.dump.desktop").isEmpty else {
            throw LibraryError.invalid("Quit Dump before changing the QA collection.")
        }
        let library = try Library(root: root)
        if command == "restore" {
            try await library.selectCollection(UUID(uuidString: args[2])!); print("RESTORED original collection"); return
        }
        if command == "resume" {
            let index = await library.index
            guard let group = index.collections.first(where: { $0.name == "第五阶段预览验收" }) else { throw LibraryError.invalid("QA collection does not exist") }
            try await library.selectCollection(group.id)
            print("ORIGINAL_COLLECTION=\(index.currentCollection) QA_COLLECTION=\(group.id)")
            return
        }
        guard command == "prepare" else { throw LibraryError.invalid("Unknown QA command") }
        let original = await library.index.currentCollection
        guard await library.index.collections.allSatisfy({ $0.name != "第五阶段预览验收" }) else { throw LibraryError.invalid("QA collection already exists; inspect before reuse.") }
        let group = try await library.createCollection("第五阶段预览验收")
        let directory = URL(fileURLWithPath: args[2], isDirectory: true)
        for (name, kind, x, y) in [("QA-image.png", MaterialKind.image, 48.0, 72.0), ("QA-motion-30s.mp4", .video, 240, 72), ("QA-audio.wav", .audio, 48, 240), ("QA-document.pdf", .file, 336, 240), ("QA-folder", .folder, 600, 72)] {
            _ = try await library.importFile(directory.appendingPathComponent(name), collection: group.id, kind: kind, preferred: .init(x: x, y: y))
        }
        _ = try await library.importText("QA-PHASE5-LOCAL\n完整文字预览。\nEND-PHASE5", collection: group.id, preferred: .init(x: 48, y: 432))
        print("ORIGINAL_COLLECTION=\(original) QA_COLLECTION=\(group.id)")
    }
}
