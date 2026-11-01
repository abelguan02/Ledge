import AppKit

private struct PromiseShutdownFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw PromiseShutdownFailure(message: message) }
}

@MainActor private final class ShutdownBackend: TextBackend {
    var stopped = false
    func catalog() async throws -> CodexCatalog { throw PromiseShutdownFailure(message: "test must not request AI catalog") }
    func respond(input: String, instructions: String, model: String) async throws -> String {
        throw PromiseShutdownFailure(message: "test must not request AI response")
    }
    func stop() { stopped = true }
}

private final class FirstCopyGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    func copy(_ source: URL, _ target: URL) throws {
        condition.lock()
        if !entered {
            entered = true
            let deadline = Date().addingTimeInterval(8)
            while !released {
                if !condition.wait(until: deadline) {
                    condition.unlock()
                    throw PromiseShutdownFailure(message: "first copy was not released by test")
                }
            }
        }
        condition.unlock()
        try FileManager.default.copyItem(at: source, to: target)
    }
    func hasEntered() -> Bool {
        condition.lock(); defer { condition.unlock() }
        return entered
    }
    func open() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
}

@main @MainActor struct PromiseShutdownTests {
    private static func waitUntil(_ condition: @MainActor () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    private static func drainsBufferedFiles(_ root: URL) async throws {
        let gate = FirstCopyGate()
        defer { gate.open() }
        let store = try Library(root: root, limits: CapacityLimits(freeDisk: 0), copyPayload: gate.copy)
        let backend = ShutdownBackend()
        let model = WorkbenchModel(library: store, bridge: backend)
        await model.refresh()
        let payloads = ["first.txt": Data("first accepted file".utf8), "second.txt": Data("second buffered file".utf8)]
        var receivingDirectory: URL?
        var sourceError: Error?
        defer { if let receivingDirectory { try? FileManager.default.removeItem(at: receivingDirectory) } }
        model.receivePromiseSources([{ directory, callback in
            receivingDirectory = directory
            for name in ["first.txt", "second.txt"] {
                let file = directory.appendingPathComponent(name)
                do { try payloads[name]!.write(to: file); callback(file, nil) }
                catch { sourceError = error; callback(file, error) }
            }
            return 3 // The third promised file never arrives.
        }], point: nil, action: nil)
        try expect(try await waitUntil { gate.hasEntered() }, "first accepted file must be copying before quit")
        try expect(sourceError == nil, "synthetic source must deliver both files")
        var shutdownResult: Result<Void, Error>?
        let began = ContinuousClock.now
        let shutdown = Task {
            do { try await model.shutdown(); shutdownResult = .success(()) }
            catch { shutdownResult = .failure(error) }
        }
        try expect(try await waitUntil { backend.stopped }, "quit must enter shutdown while the first copy is blocked")
        try expect(shutdownResult == nil, "quit must wait for already accepted copy to finish")
        gate.open()
        // Bounded observation catches an accidental 120-second promise wait.
        try expect(try await waitUntil { shutdownResult != nil }, "quit must stop waiting for the undelivered third file")
        await shutdown.value
        try shutdownResult!.get()
        try expect(began.duration(to: .now) < .seconds(3) && !model.locked,
                   "quit must drain accepted files and release all write/import locks promptly")
        let reopenedStore = try Library(root: root, limits: CapacityLimits(freeDisk: 0))
        let saved = await reopenedStore.index
        try expect(saved.items.count == 2 && Set(saved.items.map(\.filename)) == Set(payloads.keys),
                   "both delivered files must be indexed after quitting during the first copy")
        for item in saved.items {
            try expect(try Data(contentsOf: await reopenedStore.url(for: item)) == payloads[item.filename],
                       "quit must preserve the complete bytes of each accepted file")
        }
        let recovered = try await reopenedStore.promisedRecoveries()
        try expect(model.recoveryPaths.isEmpty && recovered.isEmpty,
                   "successful buffered imports must not produce unnecessary recovery duplicates")
        try expect(receivingDirectory.map { !FileManager.default.fileExists(atPath: $0.path) } == true,
                   "successfully drained temporary receiving directory must be cleaned")
        print("PASS promise shutdown: two buffered files persist while undelivered third file does not block exit")
    }

    private static func retainsCapacityFailures(_ root: URL) async throws {
        let store = try Library(root: root, limits: CapacityLimits(collection: 1, item: 1, freeDisk: 0))
        let model = WorkbenchModel(library: store, bridge: ShutdownBackend())
        await model.refresh()
        let payloads = ["first.txt": Data("only copy one".utf8), "second.txt": Data("only copy two".utf8)]
        var sourceDelivered = false
        var receivingDirectory: URL?
        var sourceError: Error?
        defer { if let receivingDirectory { try? FileManager.default.removeItem(at: receivingDirectory) } }
        model.receivePromiseSources([{ directory, callback in
            receivingDirectory = directory
            for name in ["first.txt", "second.txt"] {
                let file = directory.appendingPathComponent(name)
                do { try payloads[name]!.write(to: file); callback(file, nil) }
                catch { sourceError = error; callback(file, error) }
            }
            sourceDelivered = true
            return 3
        }], point: nil, action: nil)
        try expect(try await waitUntil { sourceDelivered }, "capacity test source must have delivered both files")
        try expect(sourceError == nil, "capacity test fixtures must be written successfully")
        var shutdownResult: Result<Void, Error>?
        let shutdown = Task {
            do { try await model.shutdown(); shutdownResult = .success(()) }
            catch { shutdownResult = .failure(error) }
        }
        try expect(try await waitUntil { shutdownResult != nil }, "capacity failure must not leave quit waiting for further promises")
        await shutdown.value
        try shutdownResult!.get()
        try expect(model.items.isEmpty && !model.locked, "failed imports must not create incomplete indexed materials")
        let reopened = WorkbenchModel(library: try Library(root: root), bridge: ShutdownBackend())
        await reopened.refresh()
        try expect(reopened.recoveryPaths.count == 1 && reopened.recoveryPaths == model.recoveryPaths,
                   "recovery location must remain discoverable after app restart")
        let recovery = reopened.recoveryPaths[0]
        try expect(recovery.deletingLastPathComponent().standardizedFileURL.path == root.appendingPathComponent("recovered-promises").standardizedFileURL.path,
                   "failed unsourced copies must move under durable library storage")
        for (name, bytes) in payloads {
            try expect(try Data(contentsOf: recovery.appendingPathComponent(name)) == bytes,
                       "every failed delivered file must remain intact in recovery storage")
        }
        try expect(receivingDirectory.map { !FileManager.default.fileExists(atPath: $0.path) } == true,
                   "recovery files must no longer depend on the temporary receiving directory")
        try expect(reopened.edgeState == .attention, "reopening must draw attention to recoverable files")
        print("PASS promise shutdown: capacity failures survive restart in discoverable durable recovery storage")
    }

    static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dump-promise-shutdown-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try await drainsBufferedFiles(root.appendingPathComponent("buffered"))
            try await retainsCapacityFailures(root.appendingPathComponent("capacity"))
        } catch {
            FileHandle.standardError.write(Data("FAIL promise shutdown: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
