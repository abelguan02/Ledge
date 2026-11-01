import Foundation

private struct StorageTestFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw StorageTestFailure(message: message) }
}

// The copy cannot finish until the test opens the gate. This proves that a
// draft commits during the copy rather than merely winning a timing race.
private final class CopyGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var arrived = 0
    private var released = false
    func copy(_ source: URL, _ target: URL) throws {
        condition.lock()
        arrived += 1
        let deadline = Date().addingTimeInterval(8)
        while !released {
            if !condition.wait(until: deadline) {
                condition.unlock()
                throw StorageTestFailure(message: "test copy gate was not released")
            }
        }
        condition.unlock()
        try FileManager.default.copyItem(at: source, to: target)
    }
    func entered(_ count: Int) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return arrived >= count
    }
    func open() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
}

private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func finish() { lock.withLock { done = true } }
    func isFinished() -> Bool { lock.withLock { done } }
}

@main struct StorageConcurrencyTests {
    private static func waitUntil(_ condition: @Sendable () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }
    private static func load(_ root: URL) throws -> LibraryIndex {
        try JSONDecoder().decode(LibraryIndex.self, from: Data(contentsOf: root.appendingPathComponent("library.json")))
    }
    private static func importTask(_ source: URL, store: Library, collection: UUID) -> Task<Result<Material, Error>, Never> {
        Task {
            do { return .success(try await store.importFile(source, collection: collection, preferred: CanvasPoint(x: 24, y: 24))) }
            catch { return .failure(error) }
        }
    }

    private static func draftDuringCopy(_ root: URL, source: URL) async throws {
        let gate = CopyGate()
        defer { gate.open() }
        let store = try Library(root: root, limits: CapacityLimits(freeDisk: 0), makeBookmark: { _ in Data() }, copyPayload: gate.copy)
        let group = await store.index.currentCollection
        let first = try await store.importText("first source", collection: group)
        let second = try await store.importText("second source", collection: group)
        let task = importTask(source, store: store, collection: group)
        let copying = try await waitUntil { gate.entered(1) }
        let drafts = [AnswerDraft(sourceID: first.id, answer: "answer one", followUp: "unsent one"),
                      AnswerDraft(sourceID: second.id, answer: "answer two", followUp: "unsent two")]
        let saved = CompletionFlag()
        let saveTask = Task {
            do { try await store.saveDrafts(drafts); saved.finish(); return Result<Void, Error>.success(()) }
            catch { saved.finish(); return .failure(error) }
        }
        let responsive = try await waitUntil { saved.isFinished() }
        // Capture the on-disk state before releasing copy, including on a
        // regression. Always release/drain before throwing a test failure.
        let duringCopy = try load(root)
        gate.open()
        let imported = try await task.value.get()
        try await saveTask.value.get()
        try expect(copying && responsive, "draft save must complete while the payload copy remains blocked")
        try expect(duringCopy.drafts == drafts && !duringCopy.items.contains { $0.id == imported.id },
                   "entire draft batch must be on disk before copy commits")
        let complete = try load(root)
        try expect(complete.drafts == drafts && Set(complete.items.map(\.id)) == [first.id, second.id, imported.id],
                   "later import commit must retain concurrent draft updates and existing materials")
        try expect(try Data(contentsOf: await store.url(for: imported)) == Data(contentsOf: source), "concurrent draft save preserves copied bytes")

        let manifest = root.appendingPathComponent("library.json")
        let before = try FileManager.default.attributesOfItem(atPath: manifest.path)
        try await store.saveDrafts(drafts.reversed())
        let after = try FileManager.default.attributesOfItem(atPath: manifest.path)
        try expect(before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber &&
                   before[.modificationDate] as? Date == after[.modificationDate] as? Date,
                   "re-saving identical drafts in any order must not rewrite the manifest")

        let previousBytes = try Data(contentsOf: manifest)
        var changed = drafts[0]; changed.followUp = "must not partly commit"
        var rejected = false
        do { try await store.saveDrafts([changed, AnswerDraft(sourceID: UUID(), answer: "missing source")]) }
        catch is LibraryError { rejected = true }
        try expect(rejected && Data(contentsOf: manifest) == previousBytes,
                   "invalid batch must fail atomically without saving its valid prefix")
        let reopened = try Library(root: root, limits: CapacityLimits(freeDisk: 0))
        try expect(await reopened.index.drafts == drafts, "completed batch survives reopening")
        print("PASS storage: drafts persist during blocked copy; batch atomicity, no-op save, reopen")
    }

    private static func concurrentPlacement(_ root: URL, sources: [URL]) async throws {
        let gate = CopyGate()
        defer { gate.open() }
        let store = try Library(root: root, limits: CapacityLimits(freeDisk: 0), makeBookmark: { _ in Data() }, copyPayload: gate.copy)
        let group = await store.index.currentCollection
        let tasks = sources.map { importTask($0, store: store, collection: group) }
        let simultaneous = try await waitUntil { gate.entered(2) }
        gate.open()
        var items: [Material] = []
        for task in tasks { items.append(try await task.value.get()) }
        try expect(simultaneous, "both imports should reach copy before either commits")
        try expect(!items[0].rect.intersects(items[1].rect), "concurrent imports targeting the same position must not overlap")
        let saved = try load(root)
        try expect(Set(saved.items.map(\.id)) == Set(items.map(\.id)), "both concurrent imports must remain in the index")
        for item in items {
            let source = sources.first { $0.lastPathComponent == item.filename }!
            try expect(try Data(contentsOf: await store.url(for: item)) == Data(contentsOf: source), "each import must retain its own bytes")
        }
        print("PASS storage: concurrent imports retain both payloads and choose separate positions")
    }

    private static func concurrentCapacity(_ root: URL, sources: [URL]) async throws {
        let gate = CopyGate()
        defer { gate.open() }
        let store = try Library(root: root, limits: CapacityLimits(collection: 98_304, item: 131_072, freeDisk: 0),
                                makeBookmark: { _ in Data() }, copyPayload: gate.copy)
        let group = await store.index.currentCollection
        let tasks = sources.map { importTask($0, store: store, collection: group) }
        let simultaneous = try await waitUntil { gate.entered(2) }
        gate.open()
        var success: [Material] = [], failures: [Error] = []
        for task in tasks {
            switch await task.value {
            case .success(let item): success.append(item)
            case .failure(let error): failures.append(error)
            }
        }
        try expect(simultaneous && success.count == 1 && failures.count == 1, "capacity must allow exactly one concurrent 64 KiB payload")
        try expect(failures[0].localizedDescription.contains("上限"), "second commit must fail because of collection capacity")
        let saved = try load(root)
        let objectIDs = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("objects").path)
        try expect(saved.items == success && objectIDs == [success[0].id.uuidString], "rejected import must remove its uncommitted staging directory")
        print("PASS storage: concurrent imports recheck capacity and clean the rejected payload")
    }

    private static func removedCollection(_ root: URL, source: URL) async throws {
        let gate = CopyGate()
        defer { gate.open() }
        let store = try Library(root: root, limits: CapacityLimits(freeDisk: 0), makeBookmark: { _ in Data() }, copyPayload: gate.copy)
        let group = await store.index.currentCollection
        let task = importTask(source, store: store, collection: group)
        let copying = try await waitUntil { gate.entered(1) }
        try await store.remove(ids: [], collection: group)
        gate.open()
        let result = await task.value
        try expect(copying, "copy must be in progress before collection removal")
        switch result {
        case .success: throw StorageTestFailure(message: "import must not commit into a deleted collection")
        case .failure(let error): try expect(error.localizedDescription.contains("收集区已不存在"), "deleted collection must produce a clear rejection")
        }
        let saved = try load(root)
        try expect(saved.items.isEmpty && !saved.collections.contains { $0.id == group }, "removed collection must remain removed with no dangling material")
        try expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("objects").path).isEmpty,
                   "import rejected after deletion must clean its uncommitted directory")
        print("PASS storage: deleting a collection during copy rejects commit and cleans staging")
    }

    static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dump-storage-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let sources = [root.appendingPathComponent("one.bin"), root.appendingPathComponent("two.bin")]
            try Data(repeating: 0x31, count: 65_536).write(to: sources[0])
            try Data(repeating: 0x72, count: 65_536).write(to: sources[1])
            try await draftDuringCopy(root.appendingPathComponent("drafts"), source: sources[0])
            try await concurrentPlacement(root.appendingPathComponent("positions"), sources: sources)
            try await concurrentCapacity(root.appendingPathComponent("capacity"), sources: sources)
            try await removedCollection(root.appendingPathComponent("removed"), source: sources[0])
        } catch {
            FileHandle.standardError.write(Data("FAIL storage: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
