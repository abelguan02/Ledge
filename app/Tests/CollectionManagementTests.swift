import Foundation

@main struct CollectionManagementTests {
    static func check(_ value: Bool, file: StaticString = #file, line: UInt = #line) { precondition(value, file: file, line: line) }
    static func removed(_ result: RemovalResult<CollectionRemovalSnapshot>) -> Bool {
        if case .removed(cleanupWarning: nil) = result { return true }
        return false
    }
    static func cleanupTests(root: URL) async throws {
        let fm = FileManager.default
        for failCleanup in [false, true] {
            let directory = root.appendingPathComponent(failCleanup ? "cleanup-failure" : "cleanup-success")
            let store = try Library(root: directory, limits: CapacityLimits(freeDisk: 0))
            let first = await store.index.currentCollection
            let a = try await store.importText("first deleted payload", collection: first)
            let second = try await store.createCollection("second")
            let b = try await store.importText("second deleted payload", collection: second.id)
            check(removed(try await store.removeCollections(store.collectionRemovalSnapshot([first]))))
            let oldDirectory = directory.appendingPathComponent("trash/\(a.id)")
            let held = directory.appendingPathComponent("held")
            if failCleanup {
                try fm.moveItem(at: oldDirectory, to: held)
                try fm.createSymbolicLink(at: oldDirectory, withDestinationURL: held)
            }
            let result = try await store.removeCollections(store.collectionRemovalSnapshot([second.id]))
            guard case .removed(let warning) = result else { preconditionFailure("second deletion must commit") }
            check((warning != nil) == failCleanup)
            check(await store.index.items.isEmpty)
            check(await store.index.undo?.items.map(\.id) == [b.id])
            if failCleanup {
                check(await store.index.garbage == [a.id])
                check(fm.fileExists(atPath: held.appendingPathComponent(a.filename).path))
                // Retained recovery metadata must survive a cleanup failure.
                try fm.removeItem(at: oldDirectory); try fm.moveItem(at: held, to: oldDirectory)
            } else {
                check(await store.index.garbage.isEmpty)
                for base in ["objects", "trash"] { check(!fm.fileExists(atPath: directory.appendingPathComponent("\(base)/\(a.id)").path)) }
            }
            let reopened = try Library(root: directory)
            check(!fm.fileExists(atPath: oldDirectory.path))
            try await reopened.undoRemoval()
            check(try await reopened.text(for: b) == "second deleted payload")
            check(await reopened.index.items.map(\.id) == [b.id])
        }
        print("PASS successive collection deletion reclaims superseded undo files; post-commit cleanup failure is reported, recoverable and preserves current undo")
    }
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dump-collections-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let store = try Library(root: root, makeBookmark: { _ in Data() })
        let first = await store.index.collections[0]
        let second = try await store.createCollection("收集区")
        let third = try await store.createCollection("空区")
        let a = try await store.importText("first", collection: first.id)
        let b = try await store.importText("second", collection: second.id)
        let initial = await store.index
        let stale = try await store.collectionRemovalSnapshot([first.id, second.id])
        try await store.renameCollection(first.id, name: "新名字")
        guard case .changed = try await store.removeCollections(stale) else { preconditionFailure("stale snapshot must require confirmation") }
        check(await store.index.items.count == 2)
        let batch = try await store.collectionRemovalSnapshot([first.id, second.id])
        check(removed(try await store.removeCollections(batch)))
        check(await store.index.collections.map(\.id) == [third.id])
        // Reopen between delete and undo checks durable undo payloads.
        let reopened = try Library(root: root, makeBookmark: { _ in Data() })
        try await reopened.undoRemoval()
        check(await reopened.index.collections.map(\.id) == initial.collections.map(\.id))
        check(await reopened.index.items == initial.items)
        check(try await reopened.text(for: a) == "first")
        check(try await reopened.text(for: b) == "second")
        let all = try await reopened.collectionRemovalSnapshot(Set(initial.collections.map(\.id)))
        check(removed(try await reopened.removeCollections(all)))
        let replacement = await reopened.index.currentCollection
        _ = try await reopened.importText("keep replacement", collection: replacement)
        try await reopened.undoRemoval()
        check(await reopened.index.collections.count == 4)
        check(await reopened.index.collections.filter { $0.name == "收集区" }.count == 2)
        check(await reopened.index.currentCollection == third.id)

        let stable = try await reopened.collectionRemovalSnapshot([first.id, second.id])
        let manifest = root.appendingPathComponent("library.json")
        let backup = root.appendingPathComponent("saved.json")
        try fm.moveItem(at: manifest, to: backup)
        try fm.createSymbolicLink(at: manifest, withDestinationURL: backup)
        do { _ = try await reopened.removeCollections(stable); preconditionFailure("write should fail") }
        catch LibraryError.invalid { }
        check(await reopened.index.collections.count == 4)
        try fm.removeItem(at: manifest); try fm.moveItem(at: backup, to: manifest)
        let afterFailure = try Library(root: root)
        check(await afterFailure.index.collections.count == 4)
        try await afterFailure.renameCollection(first.id, name: "收集区")
        let exportRoot = root.appendingPathExtension("exports")
        try fm.createDirectory(at: exportRoot, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: exportRoot) }
        let exportSnapshot = try await afterFailure.collectionRemovalSnapshot([first.id, second.id])
        let output = try await afterFailure.exportCollections(exportSnapshot, to: exportRoot) { _ in }
        let folders = try fm.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
        check(Set(folders.map(\.lastPathComponent)) == ["收集区", "收集区 (2)"])
        for folder in folders { check(try fm.contentsOfDirectory(atPath: folder.path).count == 1) }
        let cancelled = Task {
            try await afterFailure.exportCollections(exportSnapshot, to: exportRoot) { progress in
                if progress.completed == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await cancelled.value; preconditionFailure("export ignored cancel") } catch is CancellationError { }
        let outputs = try fm.contentsOfDirectory(at: exportRoot, includingPropertiesForKeys: nil)
        check(outputs.count == 2)
        let partial = outputs.first { $0.resolvingSymlinksInPath().path != output.resolvingSymlinksInPath().path }!
        let partialFolders = try fm.contentsOfDirectory(at: partial, includingPropertiesForKeys: nil)
        let exportedCount = try partialFolders.reduce(0) { try $0 + fm.contentsOfDirectory(atPath: $1.path).count }
        check(exportedCount == 1)
        check(await afterFailure.index.collections.count == 4)
        print("PASS batch atomic commit failure, stale names, whole-batch undo/order/payloads, reopen, all-delete and used same-name replacement")
        print("PASS grouped export, duplicate collection names, unique dated destination, cancellation keeps completed files and all materials")
        try await cleanupTests(root: root)
    }
}
