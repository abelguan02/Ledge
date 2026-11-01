import AppKit
import SwiftUI

@main @MainActor struct MaterialTransferTests {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dump-handoff-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let library = try Library(root: root, makeBookmark: { _ in Data() })
        let collection = await library.index.currentCollection
        let fullText = "QA-FIRST\n" + String(repeating: "完整文字🙂 ", count: 800) + "\nEND-FIRST"
        let first = try await library.importText(fullText, collection: collection)
        let second = try await library.importText("QA-SECOND\nEND-SECOND", collection: collection)
        let address = "https://example.com/reference?one=1&two=%E4%B8%AD#complete"
        let link = try await library.importText(address, collection: collection, metadata: MaterialSource(title: "参考标题", url: "https://example.com/source"))
        let raw = root.appendingPathComponent("sample.csv")
        let csv = Data("name,value\nsynthetic,42\n".utf8); try csv.write(to: raw)
        let file = try await library.importFile(raw, collection: collection)
        let imageURL = root.appendingPathComponent("sample.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = bitmap.representation(using: .png, properties: [:])!; try png.write(to: imageURL)
        let picture = try await library.importFile(imageURL, collection: collection, kind: .image)
        let directory = root.appendingPathComponent("folder")
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        try csv.write(to: directory.appendingPathComponent("nested.csv"))
        let folder = try await library.importFile(directory, collection: collection, kind: .folder)
        let model = WorkbenchModel(library: library); await model.refresh()
        precondition(model.textPreviews[first.id]!.count < fullText.count)
        model.selected = Set([first, second, link, file, picture, folder].map(\.id))
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        model.copySelected(to: board)
        let rows = board.pasteboardItems!
        precondition(rows.count == 6, "one item per real member, no extra text item")
        precondition(rows[0].string(forType: .string) == fullText, "must not copy the 2048-byte preview")
        precondition(rows[1].string(forType: .string) == "QA-SECOND\nEND-SECOND")
        precondition(rows[2].string(forType: .URL) == address && rows[2].string(forType: .materialTitle) == "参考标题")
        precondition(rows[2].string(forType: .dumpSourceURL) == "https://example.com/source")
        let joined = fullText + "\nQA-SECOND\nEND-SECOND\n" + address
        precondition(board.string(forType: .string) == joined, "system must provide all selected text and full URL in order")
        let editor = NSTextView(frame: .zero)
        precondition(editor.readSelection(from: board, type: .string) && editor.string == joined, "native text receiver gets complete concatenated content")
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as! [URL]
        precondition(urls == model.selectedItems.map { model.payloadURLs[$0.id]! }, "files remain available including text, URL and folder")
        let copiedCSV = try Data(contentsOf: urls[3]); let nestedCSV = try Data(contentsOf: urls[5].appendingPathComponent("nested.csv"))
        precondition(copiedCSV == csv && nestedCSV == csv && rows[4].data(forType: .png) == png)
        let source = MaterialDragView(model: model, item: first)
        let dragged = try source.makeDraggingItems().map { $0.item as! NSPasteboardItem }
        precondition(dragged.count == rows.count)
        for (drag, copy) in zip(dragged, rows) {
            precondition(Set(drag.types) == Set(copy.types))
            for type in drag.types { precondition(drag.data(forType: type) == copy.data(forType: type)) }
        }
        print("PASS per-member drag/copy parity, full long Unicode text, multi-text native paste, complete URL/title, original image/file/folder bytes")

        model.selected = [first.id, second.id, link.id]; model.createStack(); await model.waitForWrites()
        let top = model.canvasItems.first { $0.stackID != nil }!
        model.select(top.id)
        model.copySelected(to: board)
        precondition(board.pasteboardItems!.count == 3 && board.string(forType: .string) == joined)
        model.openStack(top.stackID!); model.select(first.id)
        model.copySelected(to: board)
        precondition(board.pasteboardItems!.count == 1 && board.string(forType: .string) == fullText)
        precondition(model.stackMembers(top.stackID!).count == 3, "copy from tray never detaches")
        model.closeStack(); model.selected = []
        let count = board.changeCount; model.copySelected(to: board); precondition(board.changeCount == count)
        model.selected = [first.id, file.id]
        try fm.removeItem(at: model.payloadURLs[file.id]!)
        model.copySelected(to: board)
        precondition(board.changeCount == count && !model.message.isEmpty, "missing member rejects all before touching clipboard")
        do { _ = try source.makeDraggingItems(); preconditionFailure("missing copy must reject drag") } catch { }
        print("PASS stack expansion, tray single-member copy, unchanged membership, empty selection and missing-copy clipboard protection")

        let input = NSPasteboard.withUniqueName(); defer { input.releaseGlobally() }
        let incomingFile = NSPasteboardItem(); incomingFile.setString(raw.absoluteString, forType: .fileURL)
        incomingFile.setString("文件来源标题", forType: .materialTitle); incomingFile.setString("https://example.com/file-source", forType: .URL)
        let incomingText = NSPasteboardItem(); incomingText.setString("incoming full text", forType: .string)
        incomingText.setString("https://example.com/text-source", forType: .dumpSourceURL)
        let incomingLink = NSPasteboardItem(); incomingLink.setString(address, forType: .URL)
        incomingLink.setString("随拖入提供的标题", forType: .materialTitle); incomingLink.setString("ignored alternate", forType: .string)
        let incomingImage = NSPasteboardItem(); incomingImage.setData(png, forType: .png)
        incomingImage.setString("https://example.com/image-source", forType: .URL)
        incomingImage.setString("来源图片", forType: .materialTitle)
        precondition(input.writeObjects([incomingFile, incomingText, incomingLink, incomingImage]))
        let surface = DropSurface(model: model)
        precondition(surface.describe(input) && model.dropCount == 4 && model.dropKind == .file, "mixed feedback counts every item and offers no single-type processing")
        let payload = DropSurface.payload(input)!
        let before = model.items.count
        model.importPayload(payload); await model.waitForWrites()
        let imported = Array(model.items.dropFirst(before))
        precondition(imported.count == 4 && imported.map(\.kind) == [.file, .text, .link, .image], "mixed clipboard must not drop non-file items or duplicate representations")
        precondition(imported.map(\.sourceURL) == ["https://example.com/file-source", "https://example.com/text-source", address, "https://example.com/image-source"])
        precondition(imported[2].sourceTitle == "随拖入提供的标题" && imported[2].name == "随拖入提供的标题")
        precondition(imported[3].sourceTitle == "来源图片")
        let savedText = try await library.text(for: imported[1]); let savedLink = try await library.text(for: imported[2])
        precondition(savedText == "incoming full text" && savedLink == address)
        let restored = try Library(root: root, makeBookmark: { _ in Data() })
        let reopened = await restored.index.items
        precondition(Array(reopened.suffix(4)) == imported, "optional source metadata survives restart")
        let old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as! [String: Any]
        precondition(old["sourceTitle"] == nil && old["sourceURL"] == nil)
        let oldDecoded = try JSONDecoder().decode(Material.self, from: JSONSerialization.data(withJSONObject: old))
        precondition(oldDecoded.sourceTitle == nil && oldDecoded.sourceURL == nil)

        input.clearContents()
        let titled = NSPasteboardItem(); titled.setPropertyList([[address, "https://example.com/second"], ["第一链接", "第二链接"]], forType: .webURLsWithTitles)
        precondition(input.writeObjects([titled]))
        let batch = MaterialTransfer.received(input)
        precondition(batch.count == 2)
        if case .text(let url, let metadata) = batch[1] { precondition(url == "https://example.com/second" && metadata.title == "第二链接") }
        else { preconditionFailure("expected titled link") }
        input.declareTypes([NSPasteboard.PasteboardType("WebURLsWithTitlesPboardType")], owner: nil)
        precondition(input.setPropertyList([[address], ["legacy browser title"]], forType: .init("WebURLsWithTitlesPboardType")))
        if case .text(let url, let metadata) = MaterialTransfer.received(input)[0] {
            precondition(url == address && metadata.title == "legacy browser title", "legacy board name must map to the item's dynamic UTI")
        } else { preconditionFailure("expected legacy browser link") }
        input.clearContents()
        let invalid = NSPasteboardItem(); invalid.setString("safe plain text", forType: .string)
        invalid.setString("javascript:alert(1)", forType: .dumpSourceURL)
        invalid.setPropertyList([["invalid"]], forType: .webURLsWithTitles)
        precondition(input.writeObjects([invalid]))
        if case .text(_, let metadata) = MaterialTransfer.received(input)[0] { precondition(metadata.url == nil && metadata.title == nil) }
        else { preconditionFailure("expected plain text") }
        print("PASS mixed import, provided title/source only, persistence/old schema, titled URL arrays and invalid metadata; no network")
        let beforePromises = model.items.count
        model.receivePromiseSources([{ directory, callback in
            let promised = directory.appendingPathComponent("promised.csv")
            do { try csv.write(to: promised); callback(promised, nil) } catch { callback(promised, error) }
            return 1
        }], point: nil, action: nil, metadata: [MaterialSource(title: "承诺文件来源", url: "https://example.com/promised")],
        additional: [.text("Alongside a promised file", MaterialSource(title: "混合文字", url: "https://example.com/mixed"))])
        await model.waitForWrites()
        let promised = Array(model.items.dropFirst(beforePromises))
        precondition(promised.count == 2 && promised[0].sourceTitle == "承诺文件来源" && promised[0].sourceURL == "https://example.com/promised")
        precondition(promised[1].kind == .text && promised[1].sourceURL == "https://example.com/mixed")
        print("PASS promised-file metadata and mixed non-promised members preserved together")
        try await model.shutdown()
    }
}
