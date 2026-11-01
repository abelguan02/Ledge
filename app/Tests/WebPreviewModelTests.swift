import AppKit

@MainActor private final class CaptureHarness {
    var calls: [(url: URL, manual: Bool)] = []
    var waiting: CheckedContinuation<WebSnapshot, Error>?
    func capture(_ url: URL, manual: Bool, progress: @escaping @MainActor (Double) -> Void) async throws -> WebSnapshot {
        precondition(waiting == nil, "capture queue must be serial")
        calls.append((url, manual)); progress(0.5)
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }
    func complete(_ result: Result<WebSnapshot, Error>) {
        let current = waiting!; waiting = nil; current.resume(with: result)
    }
}

@main @MainActor struct WebPreviewModelTests {
    static func check(_ condition: Bool, file: StaticString = #file, line: UInt = #line) { precondition(condition, file: file, line: line) }
    static func until(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        preconditionFailure("model operation did not reach expected state")
    }
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("dump-web-model-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let image = NSImage(size: CGSize(width: 1280, height: 800), flipped: false) { rect in NSColor.gray.setFill(); NSBezierPath(rect: rect).fill(); return true }
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let result = WebSnapshot(png: png, title: "页面标题", siteName: "测试站点")
        let harness = CaptureHarness()
        let library = try Library(root: root, makeBookmark: { _ in Data() })
        let model = WorkbenchModel(library: library, webSnapshot: { url, manual, progress in try await harness.capture(url, manual: manual, progress: progress) })
        await model.refresh()
        let aURL = "https://example.com/first?whole=yes#anchor", bURL = "https://example.com/second", onceURL = "https://example.com/item?token=one"
        model.importPayload(.materials([
            .text(aURL, MaterialSource(title: "自带标题", url: "https://origin.example/source")),
            .text(onceURL, MaterialSource()), .text(bURL, MaterialSource())
        ]))
        await model.waitForWrites(); try await until { harness.calls.count == 1 }
        precondition(model.items.count == 3 && !model.locked && harness.calls[0].url.absoluteString == aURL && !harness.calls[0].manual)
        let a = model.items[0], once = model.items[1], b = model.items[2]
        precondition(model.linkPreviewState(a) == .pending && model.linkPreviewState(once) == .blocked)
        precondition(model.openURL(for: a)?.absoluteString == aURL, "open original target, not provenance URL")
        var previews: [SystemPreviewItem] = []
        model.presentPreview = { previews = $0 }
        model.selected = [a.id, once.id]
        model.previewSelected()
        let localDescriptions = previews.compactMap(\.previewItemURL)
        precondition(localDescriptions.count == 2 && localDescriptions.allSatisfy { $0.isFileURL && $0.pathExtension == "txt" })
        for item in [a, once] {
            let file = previews.first { $0.materialID == item.id }!.previewItemURL!
            let text = try String(contentsOf: file, encoding: .utf8)
            precondition(text.contains(model.openURL(for: item)!.absoluteString) && text.contains(model.linkTitle(item)) && text.contains(model.linkSiteName(item)))
            precondition(file != model.payloadURLs[item.id] && !file.path.hasPrefix(root.path))
        }
        precondition(harness.calls.count == 1, "preview must not schedule any webpage capture")
        harness.complete(.success(result)); try await until { harness.calls.count == 2 }
        precondition(harness.calls[1].url.absoluteString == bURL)
        harness.complete(.failure(WebSnapshotError.failed)); await model.waitForWebPreviews()
        let ready = model.items.first { $0.id == a.id }!, failed = model.items.first { $0.id == b.id }!
        precondition(model.linkPreviewState(ready) == .ready && model.linkPreviewState(failed) == .failed && model.payloadURLs[b.id] != nil)
        precondition(model.linkTitle(ready) == "自带标题" && model.linkSiteName(ready) == "测试站点")
        let cachedURL = model.webImageURLs[a.id]!
        check(try Data(contentsOf: cachedURL) == png)
        let stack = try await library.createStack([a.id, b.id]); await model.refresh()
        model.select(model.canvasItems.first { $0.stackID == stack }!.id)
        model.previewSelected()
        precondition(Set(previews.map(\.materialID)) == [a.id, b.id])
        precondition(previews.first { $0.materialID == a.id }?.previewItemURL == cachedURL)
        precondition(previews.first { $0.materialID == a.id }?.previewItemTitle == "自带标题 — 测试站点")
        let failedDescription = previews.first { $0.materialID == b.id }!.previewItemURL!
        precondition(failedDescription.pathExtension == "txt" && failedDescription != model.payloadURLs[b.id])
        check(try String(contentsOf: failedDescription, encoding: .utf8).contains(bURL))
        try await library.failLinkPreview(b.id, state: .needsLogin); await model.refresh()
        model.previewSelected()
        let loginDescription = previews.first { $0.materialID == b.id }!.previewItemURL!
        precondition(loginDescription.pathExtension == "txt")
        check(try String(contentsOf: loginDescription, encoding: .utf8).contains(bURL))
        let writers = try MaterialTransfer.writers(model.selectedItems, urls: model.payloadURLs)
        precondition(writers.count == 2 && writers.allSatisfy { !$0.types.contains(.png) })
        precondition(writers[0].string(forType: .fileURL) == model.payloadURLs[a.id]!.absoluteString && writers[0].string(forType: .string) == aURL)

        model.generateWebPreview(once); try await until { harness.calls.count == 3 }
        precondition(harness.calls[2].manual)
        harness.complete(.success(result)); await model.waitForWebPreviews()
        let titledOnce = model.items.first { $0.id == once.id }!
        let titledWriter = try MaterialTransfer.writers([titledOnce], urls: model.payloadURLs)[0]
        precondition(titledWriter.string(forType: .materialTitle) == "页面标题" && titledWriter.string(forType: .URL) == onceURL && !titledWriter.types.contains(.png))
        model.generateWebPreview(ready); try await until { harness.calls.count == 4 }
        harness.complete(.failure(WebSnapshotError.failed)); await model.waitForWebPreviews()
        precondition(model.webImageURLs[a.id] == cachedURL && model.webFeedback[a.id] != nil)
        precondition(model.items.first { $0.id == a.id }!.linkPreview == ready.linkPreview)

        model.generateWebPreview(ready); try await until { harness.calls.count == 5 }
        model.askRemoval(ids: Set(model.items.map(\.id))); await model.waitForWrites()
        model.confirmRemoval(); await model.waitForWrites()
        precondition(model.items.isEmpty)
        harness.complete(.success(WebSnapshot(png: png, title: "删除后不得写回", siteName: nil)))
        await model.waitForWebPreviews(); precondition(model.items.isEmpty)
        model.undo(); await model.waitForWrites()
        precondition(model.items.count == 3 && model.webImageURLs[a.id] == cachedURL)
        check(try Data(contentsOf: cachedURL) == png)
        let restart = WorkbenchModel(library: try Library(root: root), webSnapshot: { _, _, _ in preconditionFailure("restart must not revisit websites") })
        await restart.refresh()
        precondition(restart.webImageURLs[a.id] == cachedURL && restart.items.first { $0.id == a.id }!.linkPreview == ready.linkPreview)
        model.preferences.automaticWebPreviews = false
        model.importPayload(.text("https://example.com/disabled")); await model.waitForWrites(); await model.waitForWebPreviews()
        let disabled = model.items.first { model.openURL(for: $0)?.path == "/disabled" }!
        precondition(model.linkPreviewState(disabled) == .blocked && harness.calls.count == 5)
        precondition(model.webImageURLs[a.id] == cachedURL)
        model.generateWebPreview(disabled); try await until { harness.calls.count == 6 }
        precondition(harness.calls.last!.manual)
        harness.complete(.success(result)); await model.waitForWebPreviews()
        precondition(model.webImageURLs[disabled.id] != nil)
        model.preferences.automaticWebPreviews = true
        model.importPayload(.materials([.text("https://example.com/queued-one", MaterialSource()), .text("https://example.com/queued-two", MaterialSource())]))
        await model.waitForWrites(); try await until { harness.calls.count == 7 }
        model.preferences.automaticWebPreviews = false
        harness.complete(.success(result)); await model.waitForWebPreviews()
        let queued = model.items.first { model.openURL(for: $0)?.path == "/queued-two" }!
        precondition(model.linkPreviewState(queued) == .blocked && harness.calls.count == 7)
        print("PASS webpage setting: disabled import makes zero captures, manual override works, cache retained, queued automatic work stops after toggle")
        try await model.shutdown()
        precondition((localDescriptions + [failedDescription, loginDescription]).allSatisfy { !fm.fileExists(atPath: $0.path) }, "temporary descriptions must be removed at shutdown")
        precondition(NSApp.windows.allSatisfy { !$0.isVisible })
        print("PASS immediate collection, serial background captures, one-time consent, local-only pending/blocked/failed/needs-login link previews and cleanup, source-title priority, full target URL, system-preview member expansion, transfer formats, failed refresh retention, in-flight deletion cancellation, clear/undo and offline restart cache")
    }
}
