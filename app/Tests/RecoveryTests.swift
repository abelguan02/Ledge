import Foundation

struct RecoveryTestFailure: LocalizedError {
    let description: String
    var errorDescription: String? { description }
}

func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw RecoveryTestFailure(description: message) }
}

@main struct RecoveryTests {
    static func library(_ root: URL) throws -> Library {
        try Library(root: root, limits: CapacityLimits(freeDisk: 0), makeBookmark: { _ in Data() })
    }

    static func missingActiveCopy(root: URL, removeDirectory: Bool) async throws {
        let store = try library(root)
        let collection = await store.index.currentCollection
        let missing = try await store.importText("Missing copy", collection: collection)
        let healthy = try await store.importText("Healthy copy remains readable", collection: collection)
        let draft = AnswerDraft(sourceID: missing.id, answer: "Saved answer", followUp: "Unsent follow-up", manuallyEdited: true)
        try await store.saveDraft(draft)
        let before = await store.index.items
        let payload = try await store.url(for: missing)
        try FileManager.default.removeItem(at: removeDirectory ? payload.deletingLastPathComponent() : payload)

        let recovered = try library(root)
        try expect(await recovered.index.items == before, "opening preserves healthy and missing records")
        try expect(try await recovered.text(for: healthy) == "Healthy copy remains readable", "healthy payload remains readable")
        try await recovered.remove(ids: [missing.id])
        try expect(await recovered.index.items == [healthy], "missing record can be removed")
        try expect(await recovered.index.undo?.items == [missing], "missing record is retained for undo")
        let afterRemoval = try library(root)
        try await afterRemoval.undoRemoval()
        try expect(await afterRemoval.index.items == before, "undo restores missing record with exact metadata and order")
        try expect(await afterRemoval.index.drafts == [draft], "undo restores missing record's saved draft")
        try expect(try await afterRemoval.text(for: healthy) == "Healthy copy remains readable", "removing and undoing missing record preserves healthy bytes")
        let afterUndo = try library(root)
        try expect(await afterUndo.index.items == before, "restored missing record survives another opening")
    }

    static func missingUndoCopy(root: URL, removeDirectory: Bool) async throws {
        let store = try library(root)
        let collection = await store.index.currentCollection
        let missing = try await store.importText("Deleted copy", collection: collection)
        let healthy = try await store.importText("Live payload", collection: collection)
        let before = await store.index.items
        try await store.remove(ids: [missing.id])
        let trashDirectory = root.appendingPathComponent("trash/\(missing.id)")
        let payload = trashDirectory.appendingPathComponent(missing.filename)
        try FileManager.default.removeItem(at: removeDirectory ? trashDirectory : payload)

        let recovered = try library(root)
        try expect(await recovered.index.items == [healthy], "missing undo copy does not change live records")
        try expect(await recovered.index.undo?.items == [missing], "opening keeps undo metadata despite missing payload")
        try expect(try await recovered.text(for: healthy) == "Live payload", "missing undo copy does not block healthy content")
        try await recovered.undoRemoval()
        try expect(await recovered.index.items == before, "undo restores missing record from persisted undo slot")
        try expect(await recovered.index.undo == nil, "successful undo consumes the undo slot")
        let afterUndo = try library(root)
        try expect(await afterUndo.index.items == before, "restored missing undo record survives opening")
    }

    static func interruptedMoves(root: URL) async throws {
        let fm = FileManager.default
        let store = try library(root)
        let collection = await store.index.currentCollection
        let item = try await store.importText("Recover these bytes", collection: collection)
        let healthy = try await store.importText("Unaffected bytes", collection: collection)
        let before = await store.index.items
        let objects = root.appendingPathComponent("objects/\(item.id)")
        let trash = root.appendingPathComponent("trash/\(item.id)")

        try await store.remove(ids: [item.id])
        // The manifest committed removal, but the payload move did not finish.
        try fm.moveItem(at: trash, to: objects)
        let afterClear = try library(root)
        try expect(await afterClear.index.items == [healthy], "interrupted clear preserves committed live records")
        try expect(fm.fileExists(atPath: trash.appendingPathComponent(item.filename).path), "opening completes interrupted clear")
        try expect(!fm.fileExists(atPath: objects.path), "clear finishes in the committed direction")
        try await afterClear.undoRemoval()
        try expect(await afterClear.index.items == before, "recovered clear can restore exact records")
        try expect(try await afterClear.text(for: item) == "Recover these bytes", "recovered clear can restore payload")

        // The manifest committed undo, but its reverse payload move did not finish.
        try fm.moveItem(at: objects, to: trash)
        let afterUndo = try library(root)
        try expect(await afterUndo.index.items == before, "interrupted undo preserves committed records")
        try expect(!fm.fileExists(atPath: trash.path), "opening completes interrupted undo")
        try expect(try await afterUndo.text(for: item) == "Recover these bytes", "interrupted undo restores payload to active storage")
        try expect(try await afterUndo.text(for: healthy) == "Unaffected bytes", "recovery leaves unrelated bytes intact")
    }

    static func recoverIntoExistingDirectory(root: URL) async throws {
        let fm = FileManager.default
        let store = try library(root)
        let collection = await store.index.currentCollection
        let item = try await store.importText("Payload in trash", collection: collection)
        let healthy = try await store.importText("Healthy bytes", collection: collection)
        let before = await store.index.items
        let activePayload = try await store.url(for: item)
        let activeSidecar = activePayload.deletingLastPathComponent().appendingPathComponent("active-sidecar")
        let trashDirectory = root.appendingPathComponent("trash/\(item.id)")
        let trashSidecar = trashDirectory.appendingPathComponent("trash-sidecar")
        try fm.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        try Data("Keep active sidecar".utf8).write(to: activeSidecar)
        try Data("Keep trash sidecar".utf8).write(to: trashSidecar)
        try fm.moveItem(at: activePayload, to: trashDirectory.appendingPathComponent(item.filename))

        let recovered = try library(root)
        try expect(await recovered.index.items == before, "recovery into existing directory keeps all records")
        try expect(try await recovered.text(for: item) == "Payload in trash", "payload is recovered despite existing target directory")
        try expect(try await recovered.text(for: healthy) == "Healthy bytes", "existing-directory recovery leaves other material intact")
        try expect(try String(contentsOf: activeSidecar, encoding: .utf8) == "Keep active sidecar", "recovery preserves existing target directory contents")
        try expect(try String(contentsOf: trashSidecar, encoding: .utf8) == "Keep trash sidecar", "recovery preserves remaining source directory contents")
        try expect(!fm.fileExists(atPath: trashDirectory.appendingPathComponent(item.filename).path), "recovered payload no longer remains in trash")
    }

    static func rejectSymbolicLink(root: URL, directory: Bool, dangling: Bool) async throws {
        let fm = FileManager.default
        let storageRoot = root.appendingPathComponent("library")
        let store = try library(storageRoot)
        let collection = await store.index.currentCollection
        let item = try await store.importText("Stored bytes", collection: collection)
        let payload = try await store.url(for: item)
        let manifest = storageRoot.appendingPathComponent("library.json")
        let before = try Data(contentsOf: manifest)
        let linkedPath = directory ? payload.deletingLastPathComponent() : payload
        let outside = root.appendingPathComponent(directory ? "outside-directory" : "outside-file")
        if !dangling {
            if directory { try fm.createDirectory(at: outside, withIntermediateDirectories: true) }
            try Data("Unrelated content".utf8).write(to: directory ? outside.appendingPathComponent(item.filename) : outside)
        }
        try fm.removeItem(at: linkedPath)
        try fm.createSymbolicLink(at: linkedPath, withDestinationURL: outside)

        do {
            _ = try library(storageRoot)
            throw RecoveryTestFailure(description: "\(dangling ? "dangling" : "existing") \(directory ? "directory" : "payload") symlink must not be treated as a missing copy")
        } catch let error as LibraryError {
            try expect(error.localizedDescription.contains("符号链接"), "symlink failure identifies unsafe storage path")
        }
        do {
            _ = try await store.url(for: item)
            throw RecoveryTestFailure(description: "an existing actor must reject a replaced payload path")
        } catch let error as LibraryError {
            try expect(error.localizedDescription.contains("符号链接"), "URL lookup reports unsafe path")
        }
        do {
            _ = try await store.text(for: item)
            throw RecoveryTestFailure(description: "text reads must not follow replaced symbolic links")
        } catch let error as LibraryError {
            try expect(error.localizedDescription.contains("符号链接"), "text read reports unsafe path")
        }
        let exportDirectory = root.appendingPathComponent("export")
        try fm.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        do {
            try await store.export(ids: [item.id], to: exportDirectory)
            throw RecoveryTestFailure(description: "export must not copy replaced symbolic links")
        } catch let error as LibraryError {
            try expect(error.localizedDescription.contains("符号链接"), "export reports unsafe path")
        }
        try expect(try fm.contentsOfDirectory(atPath: exportDirectory.path).isEmpty, "unsafe export creates no output")
        try expect(try Data(contentsOf: manifest) == before, "rejected symlink leaves manifest unchanged")
        try expect(try fm.destinationOfSymbolicLink(atPath: linkedPath.path) == outside.path, "rejected symlink is not removed or followed")
        if !dangling {
            let outsidePayload = directory ? outside.appendingPathComponent(item.filename) : outside
            try expect(try String(contentsOf: outsidePayload, encoding: .utf8) == "Unrelated content", "symlink target remains untouched")
        }
    }

    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dump-recovery-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await interruptedMoves(root: root.appendingPathComponent("interrupted-moves"))
        print("PASS recovery: interrupted clear and undo still finish payload moves and preserve bytes")
        try await missingActiveCopy(root: root.appendingPathComponent("missing-payload"), removeDirectory: false)
        try await missingActiveCopy(root: root.appendingPathComponent("missing-directory"), removeDirectory: true)
        print("PASS recovery: missing live payload and directory preserve records, healthy bytes, removal and undo")
        try await missingUndoCopy(root: root.appendingPathComponent("missing-undo-payload"), removeDirectory: false)
        try await missingUndoCopy(root: root.appendingPathComponent("missing-undo-directory"), removeDirectory: true)
        print("PASS recovery: missing undo payload and directory preserve startup, undo records and healthy content")
        try await recoverIntoExistingDirectory(root: root.appendingPathComponent("existing-target-directory"))
        print("PASS recovery: payload restores from trash into existing object directory without losing sidecars")
        for directory in [false, true] {
            for dangling in [false, true] {
                try await rejectSymbolicLink(root: root.appendingPathComponent("symlink-\(directory)-\(dangling)"), directory: directory, dangling: dangling)
            }
        }
        print("PASS recovery: existing and dangling symlinks are rejected for payloads and object directories")
    }

    static func main() async {
        do { try await run() }
        catch {
            print("FAIL recovery: \(error.localizedDescription)")
            exit(1)
        }
    }
}
