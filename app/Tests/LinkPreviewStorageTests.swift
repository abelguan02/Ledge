import Foundation

@main struct LinkPreviewStorageTests {
    static func check(_ condition: Bool, file: StaticString = #file, line: UInt = #line) { precondition(condition, file: file, line: line) }
    static func main() async throws {
        let fm = FileManager.default, root = FileManager.default.temporaryDirectory.appendingPathComponent("dump-link-preview-\(UUID())")
        let exported = fm.temporaryDirectory.appendingPathComponent("dump-link-export-\(UUID())")
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: exported) }
        for term in LinkPreviewPolicy.oneTimeTerms {
            precondition(LinkPreviewPolicy.requiresConsent(URL(string: "https://example.com/\(term.uppercased())/next")!))
            precondition(LinkPreviewPolicy.requiresConsent(URL(string: "https://example.com/page?my_\(term)=value")!))
        }
        precondition(LinkPreviewPolicy.requiresConsent(URL(string: "https://example.com/%74oken/next")!))
        precondition(LinkPreviewPolicy.requiresConsent(URL(string: "https://example.com/page?%63ode=1")!))
        precondition(!LinkPreviewPolicy.requiresConsent(URL(string: "https://example.com/page?reference=token#login")!))
        let library = try Library(root: root, makeBookmark: { _ in Data() })
        let group = await library.index.currentCollection
        let link = try await library.importText("https://example.com/page?ref=whole#anchor", collection: group, metadata: MaterialSource(title: "自带标题"))
        let blocked = try await library.importText("https://example.com/page?TOKEN=once", collection: group)
        precondition(link.size == CanvasSize(width: 216, height: 192) && link.linkPreview?.state == .pending && blocked.linkPreview?.state == .blocked)
        let payload = try await library.url(for: link), original = try Data(contentsOf: payload)
        let first = Data("first synthetic screenshot bytes".utf8), second = Data("replacement screenshot bytes".utf8)
        _ = try await library.saveLinkPreview(link.id, png: first, title: "网页标题", siteName: "站点")
        let ready = await library.index.items.first { $0.id == link.id }!
        let firstURL = try await library.previewURL(for: ready)!
        precondition(ready.sourceTitle == "自带标题" && ready.linkPreview?.title == "网页标题" && ready.linkPreview?.state == .ready)
        check(try Data(contentsOf: payload) == original)
        try await library.failLinkPreview(link.id, state: .failed)
        check(await library.index.items.first { $0.id == link.id } == ready)

        // Force a manifest failure after the staged screenshot was written.
        let manifest = root.appendingPathComponent("library.json"), savedManifest = try Data(contentsOf: manifest)
        try fm.removeItem(at: manifest); try fm.createDirectory(at: manifest, withIntermediateDirectories: false)
        do { _ = try await library.saveLinkPreview(link.id, png: second, title: "不能提交", siteName: nil); preconditionFailure("manifest failure was swallowed") }
        catch { check(try Data(contentsOf: firstURL) == first) }
        check(await library.index.items.first { $0.id == link.id } == ready)
        check(try fm.contentsOfDirectory(atPath: payload.deletingLastPathComponent().path).count == 2)
        try fm.removeItem(at: manifest); try savedManifest.write(to: manifest)

        _ = try await library.saveLinkPreview(link.id, png: second, title: "新版标题", siteName: "新版站点")
        let updated = await library.index.items.first { $0.id == link.id }!
        let secondURL = try await library.previewURL(for: updated)!
        precondition(!fm.fileExists(atPath: firstURL.path))
        check(try Data(contentsOf: secondURL) == second)
        try fm.createDirectory(at: exported, withIntermediateDirectories: false)
        try await library.export(ids: [link.id], to: exported)
        check(try fm.contentsOfDirectory(atPath: exported.path) == [link.filename])
        check(try Data(contentsOf: exported.appendingPathComponent(link.filename)) == original)
        try await library.remove(ids: [link.id, blocked.id])
        precondition(!fm.fileExists(atPath: secondURL.path))
        let trashPNG = root.appendingPathComponent("trash/\(link.id)/\(updated.linkPreview!.filename!)")
        check(try Data(contentsOf: trashPNG) == second)
        let reopened = try Library(root: root)
        try await reopened.undoRemoval()
        check(try Data(contentsOf: secondURL) == second)
        check(await reopened.index.items.first { $0.id == link.id } == updated)
        try await reopened.remove(ids: [link.id]); try await reopened.finishSession()
        precondition(!fm.fileExists(atPath: trashPNG.path))

        // Existing phase-four cards keep their old size without changing positions.
        var legacy = await reopened.index
        var old = blocked; old.linkPreview = nil; old.displaySize = nil
        old.position = CanvasPoint(x: 600, y: 312); legacy.items = [old]
        try JSONEncoder().encode(legacy).write(to: manifest, options: .atomic)
        let migrated = try Library(root: root)
        let preserved = await migrated.index.items[0]
        precondition(preserved.position == old.position && preserved.size == CanvasSize(width: 216, height: 96))
        try await migrated.resize(preserved.id, to: nil)
        check(await migrated.index.items[0].size == CanvasSize(width: 216, height: 192))
        let resetRestart = try Library(root: root)
        check(await resetRestart.index.items[0].size == CanvasSize(width: 216, height: 192))
        print("PASS one-time URL policy, new size/legacy layout, title precedence, durable screenshots, transactional refresh failure, export exclusion, clear/restart/undo and final cleanup")
    }
}
