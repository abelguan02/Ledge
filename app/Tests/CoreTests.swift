import Foundation
import CoreGraphics

func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw TestFailure(message: message) }
}
struct TestFailure: Error { let message: String }

@main struct CoreTests {
    static func main() async throws {
        let size = CanvasSize(width: 144, height: 120)
        let first = Placement.locate(size: size, occupied: [], preferred: nil)
        try expect(first == CanvasPoint(x: 24, y: 24), "first item starts on grid")
        let occupied = [CanvasRect(origin: first, size: size)]
        let second = Placement.locate(size: size, occupied: occupied, preferred: nil)
        try expect(second == CanvasPoint(x: 192, y: 24), "row-major placement leaves a grid gap")
        let collision = Placement.locate(size: size, occupied: occupied, preferred: first)
        try expect(!CanvasRect(origin: collision, size: size).intersects(occupied[0]), "large overlap moves to free space")
        var rectangles: [CanvasRect] = []
        for _ in 0..<45 {
            let point = Placement.locate(size: size, occupied: rectangles, preferred: nil)
            let rect = CanvasRect(origin: point, size: size)
            try expect(!rectangles.contains(where: { $0.intersects(rect) }), "auto placement never overlaps")
            rectangles.append(rect)
        }
        try expect(rectangles.last!.origin.y > 720, "canvas grows vertically")
        try expect(rectangles.allSatisfy { $0.origin.x >= 0 && $0.maxX <= 520 }, "fixed canvas width")
        print("PASS placement: grid, overlap recovery, row order, vertical growth")
        for visible in [CGRect(x: 0, y: 80, width: 1440, height: 820), CGRect(x: -1920, y: 35, width: 1920, height: 1045), CGRect(x: 0, y: 40, width: 900, height: 620)] {
            for edge: DockEdge in [.left, .right, .top] {
                for size in [CGSize(width: 48, height: 160), CGSize(width: 320, height: 468), CGSize(width: 540, height: 768)] {
                    try expect(visible.contains(PanelPlacement.frame(size: size, visible: visible, edge: edge)), "panel fits after monitor or resolution changes")
                }
            }
        }
        try expect(PanelPlacement.screenID(current: 2, available: [1, 2], main: 1) == 2, "keep connected display")
        try expect(PanelPlacement.screenID(current: 2, available: [1], main: 1) == 1, "unplugged display falls back to main")
        try expect(PanelPlacement.screenID(current: 2, available: [], main: nil) == nil, "no stale display while disconnected")
        let dragSession = EdgeDragSession(origin: .zero, pasteboardRevision: 8)
        try expect(!dragSession.isExternalDrag(at: CGPoint(x: 50, y: 0), revision: 8, supported: true), "ordinary drag cannot reuse stale pasteboard")
        try expect(!dragSession.isExternalDrag(at: CGPoint(x: 50, y: 0), revision: 9, supported: false), "unsupported drag stays collapsed")
        try expect(dragSession.isExternalDrag(at: CGPoint(x: 50, y: 0), revision: 9, supported: true), "fresh supported drag can expand")
        print("PASS display removal, changed resolution and fresh-drag gating")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dump-tests-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let original = root.appendingPathComponent("sample.bin")
        let bytes = Data([0, 1, 2, 3, 255])
        try bytes.write(to: original)
        // OS bookmark creation needs the app's sandbox identity; test its
        // file-system contract separately using a synthetic bookmark here.
        let store = try Library(root: root.appendingPathComponent("library"), makeBookmark: { _ in Data() })
        let group = await store.index.currentCollection
        let imported = try await store.importFile(original, collection: group)
        try expect(try Data(contentsOf: original) == bytes, "import preserves original")
        let copy = try await store.url(for: imported)
        try expect(try Data(contentsOf: copy) == bytes && copy != original, "independent copy")
        let note = try await store.importText("唯一文字", collection: group)
        let link = try await store.importText("https://example.com/path", collection: group)
        let result = try await store.importText("处理结果", collection: group, derivedFrom: imported.id)
        var summary = try await store.clearSummary(ids: Set([imported.id, note.id, link.id, result.id]))
        try expect(summary.backedUp == 1 && summary.uniqueIDs.count == 3, "clear distinguishes origins")
        try fm.moveItem(at: original, to: root.appendingPathComponent("moved.bin"))
        summary = try await store.clearSummary(ids: [imported.id])
        try expect(summary.unique[.missingOriginal] == [imported.id], "moved original becomes unique")
        try Data("replacement".utf8).write(to: original)
        summary = try await store.clearSummary(ids: [imported.id])
        try expect(summary.unique[.missingOriginal] == [imported.id], "unrelated file at the old path is not the original")
        let before = await store.index.items
        try await store.remove(ids: Set(before.map(\.id)))
        try expect(await store.index.items.isEmpty, "clear removes active materials")
        try expect(fm.fileExists(atPath: root.appendingPathComponent("library/trash/\(imported.id)/\(imported.filename)").path), "payload staged in trash")
        try await store.undoRemoval()
        try expect(await store.index.items == before, "undo restores all metadata")
        try expect(try Data(contentsOf: copy) == bytes, "undo restores payload")
        try await store.remove(ids: [imported.id])
        // Simulate interruption after manifest commit but before the payload move.
        let staged = root.appendingPathComponent("library/trash/\(imported.id)")
        let active = root.appendingPathComponent("library/objects/\(imported.id)")
        try fm.moveItem(at: staged, to: active)
        let recovered = try Library(root: root.appendingPathComponent("library"))
        try expect(fm.fileExists(atPath: staged.path), "reopen completes interrupted clear")
        try await recovered.undoRemoval()
        try expect(try Data(contentsOf: copy) == bytes, "recovered clear still undoes")
        // Continue with the actor holding the latest committed state.
        try await store.undoRemoval()
        let secondGroup = try await store.createCollection("另一区")
        try await store.renameCollection(secondGroup.id, name: "重命名")
        try await store.selectCollection(group)
        try expect(await store.index.currentCollection == group, "switch persists")
        try await store.remove(ids: [], collection: secondGroup.id)
        try await store.undoRemoval()
        try expect(await store.index.collections.contains { $0.id == secondGroup.id && $0.name == "重命名" }, "deleted collection can be restored")
        let reopened = try Library(root: root.appendingPathComponent("library"))
        try expect(await reopened.index.items == before, "reopen restores positions and materials")
        let single = try Library(root: root.appendingPathComponent("single"))
        let singleBefore = await single.index
        try await single.remove(ids: [], collection: singleBefore.currentCollection)
        try await single.undoRemoval()
        try expect(await single.index.collections == singleBefore.collections, "undo sole collection removal leaves no extra collection")
        let out = root.appendingPathComponent("export")
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        try await store.export(ids: [note.id, link.id], to: out)
        try expect(try fm.contentsOfDirectory(atPath: out.path).contains(where: { $0.hasSuffix(".webloc") }), "links export as webloc")
        for values: (Int64, Int64, Int64) in [(101, 0, 1000), (50, 180, 1000), (1, 0, 9)] {
            do {
                try CapacityLimits(collection: 200, item: 100, freeDisk: 10).validate(incoming: values.0, used: values.1, available: values.2)
                throw TestFailure(message: "capacity should reject \(values)")
            } catch is LibraryError { }
        }
        try CapacityLimits(collection: 200, item: 100, freeDisk: 100).validate(incoming: 100, used: 0, available: 150, hasCopiedPayload: true)
        let manifest = root.appendingPathComponent("library/library.json")
        let savedManifest = try Data(contentsOf: manifest)
        try fm.removeItem(at: manifest)
        try fm.createDirectory(at: manifest, withIntermediateDirectories: false)
        do {
            try await store.remove(ids: [imported.id])
            throw TestFailure(message: "failed manifest write must throw")
        } catch is CocoaError { }
        try expect(await store.index.items == before, "failed clear leaves index intact")
        try expect(try Data(contentsOf: copy) == bytes, "failed clear leaves bytes intact")
        try fm.removeItem(at: manifest)
        try savedManifest.write(to: manifest)
        let emptyLimits = CapacityLimits(collection: 4, item: 100, freeDisk: 0)
        let limited = try Library(root: root.appendingPathComponent("limited"), limits: emptyLimits, makeBookmark: { _ in Data() })
        let limitedGroup = await limited.index.currentCollection
        do { _ = try await limited.importText("capacity test", collection: limitedGroup); throw TestFailure(message: "storage must apply collection capacity") }
        catch is LibraryError { }
        try expect(await limited.index.items.isEmpty, "rejected input never reaches manifest")
        print("PASS storage: copies, source classification, undo, collections, export, persistence, capacity, atomic failure")
        let folders = try Library(root: root.appendingPathComponent("folder-library"), makeBookmark: { _ in Data() })
        let folderGroup = await folders.index.currentCollection
        let directory = root.appendingPathComponent("Folder")
        try fm.createDirectory(at: directory.appendingPathComponent("nested/empty"), withIntermediateDirectories: true)
        try bytes.write(to: directory.appendingPathComponent("nested/file.bin"))
        let folder = try await folders.importFile(directory, collection: folderGroup)
        let folderCopy = try await folders.url(for: folder)
        try expect(folder.kind == .folder && folder.byteCount >= bytes.count, "folder is one material with recursive capacity")
        try expect(try Data(contentsOf: folderCopy.appendingPathComponent("nested/file.bin")) == bytes, "nested file copied")
        try expect(fm.fileExists(atPath: folderCopy.appendingPathComponent("nested/empty").path), "empty subfolder preserved")
        try Data("changed".utf8).write(to: directory.appendingPathComponent("nested/file.bin"))
        try expect(try Data(contentsOf: folderCopy.appendingPathComponent("nested/file.bin")) == bytes, "folder copy independent")
        try expect(try await folders.clearSummary(ids: [folder.id]).backedUp == 1, "folder original classified")
        try await folders.remove(ids: [folder.id]); try await folders.undoRemoval()
        try expect(try Data(contentsOf: folderCopy.appendingPathComponent("nested/file.bin")) == bytes, "folder undo restores descendants")
        try await folders.export(ids: [folder.id], to: out)
        try expect(try Data(contentsOf: out.appendingPathComponent("Folder/nested/file.bin")) == bytes, "folder export preserves tree")
        try fm.createSymbolicLink(at: directory.appendingPathComponent("link"), withDestinationURL: original)
        do { _ = try await folders.importFile(directory, collection: folderGroup); throw TestFailure(message: "linked folder input must reject") }
        catch is LibraryError { }
        try fm.removeItem(at: directory.appendingPathComponent("link"))
        try fm.moveItem(at: directory, to: root.appendingPathComponent("MovedFolder"))
        try expect(try await folders.clearSummary(ids: [folder.id]).uniqueIDs == [folder.id], "moved folder becomes unique")
        do { _ = try await folders.importFile(root, collection: folderGroup); throw TestFailure(message: "recursive self-copy must reject") }
        catch is LibraryError { }
        let tiny = try Library(root: root.appendingPathComponent("tiny-folder-library"), limits: CapacityLimits(collection: 500, item: 1, freeDisk: 0), makeBookmark: { _ in Data() })
        do { _ = try await tiny.importFile(folderCopy, collection: await tiny.index.currentCollection); throw TestFailure(message: "folder aggregate capacity must reject") }
        catch is LibraryError { }
        print("PASS folders: recursive copy, empty directories, independence, origin, undo, export, symlink rejection and aggregate capacity")
    }
}
