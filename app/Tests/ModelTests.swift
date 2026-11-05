import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor final class FakeTextBackend: TextBackend {
    var catalogCalls = 0, active = 0, maximumActive = 0
    var inputs: [String] = []
    func catalog() async throws -> CodexCatalog { catalogCalls += 1; return CodexCatalog(models: [], preferred: "offline-test") }
    func respond(input: String, instructions: String, model: String) async throws -> String {
        active += 1; maximumActive = max(maximumActive, active); inputs.append(input)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(20))
        if input == "batch 2" { throw AIError.problem("synthetic failure") }
        return "answer: \(input)"
    }
    func stop() { }
}

final class CleanupFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [URL] = []
    func fail(_ url: URL) throws {
        lock.withLock { paths.append(url) }
        throw CocoaError(.fileWriteNoPermission)
    }
    func clean() { for url in lock.withLock({ paths }) { try? FileManager.default.removeItem(at: url) } }
}

@main @MainActor struct ModelTests {
    static func checkCommittedCleanup(root: URL) async throws {
        let fm = FileManager.default
        let library = try Library(root: root)
        let item = try await library.importText("synthetic bytes", collection: library.index.currentCollection)
        let model = WorkbenchModel(library: library)
        await model.refresh()
        let trash = root.appendingPathComponent("trash/\(item.id)")
        try Data().write(to: trash)
        model.askRemoval(ids: [item.id]); await model.waitForWrites()
        model.confirmRemoval(); await model.waitForWrites()
        precondition(model.items.isEmpty && model.removal == nil && model.index.undo != nil && !model.message.isEmpty)
        try fm.removeItem(at: trash)
        _ = try Library(root: root) // Finish the interrupted move before testing the reverse direction.
        let active = root.appendingPathComponent("objects/\(item.id)")
        try Data().write(to: active)
        model.message = ""
        model.undo(); await model.waitForWrites()
        precondition(model.items.map(\.id) == [item.id] && model.index.undo == nil && !model.message.isEmpty)
        try fm.removeItem(at: active)
        let reopened = try Library(root: root)
        let bytes = try await reopened.text(for: item)
        precondition(bytes == "synthetic bytes")
    }
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dump-model-tests-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let library = try Library(root: root, makeBookmark: { _ in Data() })
        try await checkCommittedCleanup(root: root.appendingPathComponent("cleanup"))
        let model = WorkbenchModel(library: library)
        await model.refresh()
        model.importPayload(.text("synthetic draft source"))
        await model.waitForWrites()
        let item = model.items[0]
        model.busy.insert(item.id); precondition(model.edgeState == .processing)
        model.unseenResults.insert(item.id); precondition(model.edgeState == .attention)
        model.errors[item.id] = "synthetic failure"; precondition(model.edgeState == .failed)
        model.errors = [:]; model.busy = []; model.markViewed(); precondition(model.edgeState == .quiet)
        model.drafts[item.id] = AnswerDraft(sourceID: item.id, answer: "answer")
        model.editDraft(item.id, followUp: "new unsent question")
        model.removal = RemovalRequest(ids: [item.id], title: "test", summary: try await library.clearSummary(ids: [item.id]))
        model.confirmRemoval()
        await model.waitForWrites()
        model.undo()
        await model.waitForWrites()
        precondition(model.drafts[item.id]?.followUp == "new unsent question", "immediate deletion must preserve latest input for undo")
        model.importPayload(.text("accepted just before quit"))
        try await model.shutdown()
        let reopened = try Library(root: root)
        let saved = await reopened.index
        precondition(saved.items.count == 2, "quit must drain accepted import")
        precondition(saved.drafts.first?.followUp == "new unsent question", "quit preserves unsent input")
        let promiseModel = WorkbenchModel(library: reopened)
        await promiseModel.refresh()
        var delayed: (@Sendable (URL, Error?) -> Void)?
        var temporary: URL?
        promiseModel.receivePromiseSources([{ directory, callback in
            delayed = callback; temporary = directory
            let delivered = directory.appendingPathComponent("first.txt")
            try! Data("delivered before timeout".utf8).write(to: delivered)
            callback(delivered, nil)
            return 2
        }, { _, _ in preconditionFailure("timeout must stop receiving remaining sources") }], point: nil, action: nil, timeout: .milliseconds(40))
        for _ in 0..<200 {
            if !promiseModel.locked { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(!promiseModel.locked && !promiseModel.message.isEmpty, "promise timeout must release the import/write locks and report failure")
        precondition(promiseModel.items.count == 3, "delivered files survive a partial timeout")
        try fm.createDirectory(at: temporary!, withIntermediateDirectories: true)
        let late = temporary!.appendingPathComponent("late.txt")
        try Data("late file".utf8).write(to: late); delayed?(late, nil)
        try await Task.sleep(for: .milliseconds(40))
        precondition(promiseModel.items.count == 3 && promiseModel.recoveryPaths.count == 1 && fm.fileExists(atPath: promiseModel.recoveryPaths[0].appendingPathComponent("late.txt").path), "late unsourced files must be retained with a recovery location, never silently discarded")
        promiseModel.importPayload(.text("accepted after promise timeout")); await promiseModel.waitForWrites()
        precondition(promiseModel.items.count == 4)
        promiseModel.receivePromiseSources([{ _, _ in 1 }], point: nil, action: nil)
        let quitStart = ContinuousClock.now
        try await promiseModel.shutdown()
        precondition(quitStart.duration(to: .now) < .seconds(2) && !promiseModel.locked, "quit cancels an undelivered promise without waiting for its deadline")
        let fullLibrary = try Library(root: root.appendingPathComponent("full"), limits: CapacityLimits(collection: 1, item: 1, freeDisk: 0))
        let fullModel = WorkbenchModel(library: fullLibrary); await fullModel.refresh()
        var failedDelivery: URL?
        fullModel.receivePromiseSources([{ directory, callback in
            let file = directory.appendingPathComponent("unsourced.txt"); failedDelivery = file
            try! Data("only copy".utf8).write(to: file); callback(file, nil); return 1
        }], point: nil, action: nil)
        await fullModel.waitForWrites()
        precondition(fullModel.items.isEmpty && fullModel.recoveryPaths.count == 1 && fm.fileExists(atPath: fullModel.recoveryPaths[0].appendingPathComponent("unsourced.txt").path), "failed import preserves the only delivered copy and reports its location")
        precondition(!fm.fileExists(atPath: failedDelivery!.path))
        try await fullModel.shutdown()
        let reopenedFull = WorkbenchModel(library: try Library(root: fullLibrary.root)); await reopenedFull.refresh()
        precondition(reopenedFull.recoveryPaths == fullModel.recoveryPaths, "recovery locations survive app restart")
        print("PASS partial promise timeout, retained late/failed deliveries, subsequent import and quit cancellation")
        let backend = FakeTextBackend()
        let batchLibrary = try Library(root: root.appendingPathComponent("batch"))
        let batch = WorkbenchModel(library: batchLibrary, bridge: backend)
        let collection = await batchLibrary.index.currentCollection
        for n in 0..<6 { _ = try await batchLibrary.importText("batch \(n)", collection: collection) }
        await batch.refresh()
        let sources = batch.items
        batch.process(sources, action: "解释")
        for _ in 0..<500 { if batch.busy.isEmpty { break }; try await Task.sleep(for: .milliseconds(10)) }
        precondition(batch.busy.isEmpty && backend.inputs.count == 6 && backend.maximumActive == 1 && backend.catalogCalls == 1)
        precondition(batch.activeAnswer == sources[0].id, "batch opens first answer, not the final queued card")
        for (n, item) in sources.enumerated() {
            batch.select(item.id)
            precondition(batch.activeAnswer == item.id)
            if n == 2 { precondition(batch.errors[item.id] != nil) }
            else { precondition(batch.drafts[item.id]?.answer == "answer: batch \(n)") }
        }
        let urlItem = try await batchLibrary.importText("https://example.com/test", collection: collection)
        await batch.refresh(); batch.process([urlItem], action: "翻译")
        precondition(batch.notice.contains("链接") && backend.inputs.count == 6 && batch.drafts[urlItem.id] == nil)
        try await batch.shutdown()
        print("PASS six-text serial batch, independent answers, middle failure recovery and link feedback; fake AI only")

        let cleanup = CleanupFailure(); defer { cleanup.clean() }
        let imageLibrary = try Library(root: root.appendingPathComponent("images"))
        let images = WorkbenchModel(library: imageLibrary, cleanTemporary: { try cleanup.fail($0) })
        await images.refresh()
        let bitmap = CGContext(data: nil, width: 100, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
        let png = NSMutableData()
        let pngEncoder = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(pngEncoder, bitmap.makeImage()!, nil); precondition(CGImageDestinationFinalize(pngEncoder))
        images.importPayload(.image(png as Data)); await images.waitForWrites()
        precondition(images.items.count == 1 && images.message.isEmpty && images.notice.contains("已保存"), "cleanup failure must not hide successful paste")
        let picture = images.items[0]
        images.notice = ""; images.process([picture], action: "压缩")
        for _ in 0..<500 { if images.busy.isEmpty { break }; try await Task.sleep(for: .milliseconds(10)) }
        precondition(images.items.count == 1 && images.notice.contains("未生成重复副本") && images.errors.isEmpty)
        var jpeg = ImageSettings(); jpeg.format = "jpeg"
        images.process([picture], action: "转换格式", settings: jpeg)
        for _ in 0..<500 { if images.busy.isEmpty { break }; try await Task.sleep(for: .milliseconds(10)) }
        precondition(images.items.count == 2 && images.notice.contains("已保存") && images.errors.isEmpty, "cleanup failure must not report an imported result as unsaved")
        try await images.shutdown()
        print("PASS PNG no-op skips duplicate, paste/image cleanup failures preserve visible saved results")
        print("PASS edit/delete/undo and accepted-import/quit; no window, account or clipboard access")
    }
}
