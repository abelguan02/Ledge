import Foundation

private enum ProbeError: Error { case sourceFailed, watchdog }
private struct PromiseTestFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
private func expect(_ value: Bool, _ message: String) throws {
    if !value { throw PromiseTestFailure(message: message) }
}
private struct Received: Sendable {
    var urls: [URL] = []
    var failures = 0
    var terminalError: Error?
}

@main struct PromiseTests {
    // A watchdog makes regressions fail instead of hanging the test process.
    private static func collect(_ batch: PromisedFiles) async throws -> Received {
        try await withThrowingTaskGroup(of: Received.self) { group in
            group.addTask {
                var received = Received()
                do {
                    for try await outcome in batch.stream {
                        switch outcome {
                        case .success(let url): received.urls.append(url)
                        case .failure: received.failures += 1
                        }
                    }
                } catch { received.terminalError = error }
                return received
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw ProbeError.watchdog
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    static func main() async {
        do {
            let file = URL(fileURLWithPath: "/synthetic/promised.txt")
            let timeout = PromisedFiles(timeout: .milliseconds(30))
            timeout.expect(1)
            let started = ContinuousClock.now
            let expired = try await collect(timeout)
            try expect(expired.terminalError is PromisedFilesError, "silent source must report a timeout")
            try expect(ContinuousClock.now - started < .seconds(1), "silent source must release the wait promptly")
            try expect(!timeout.yield(.success(file)), "late delivery after timeout must be rejected")
            print("PASS promises: silent source expires and rejects late delivery")

            let complete = PromisedFiles(timeout: .seconds(1))
            complete.expect(3)
            try expect(complete.yield(.success(file)), "first result accepted")
            try expect(complete.yield(.failure(ProbeError.sourceFailed)), "source failure counts as one delivered result")
            let second = URL(fileURLWithPath: "/synthetic/second.txt")
            try expect(complete.yield(.success(second)), "remaining successful result accepted")
            try expect(!complete.yield(.success(file)), "extra callback after expected count rejected")
            let finished = try await collect(complete)
            try expect(finished.urls == [file, second] && finished.failures == 1 && finished.terminalError == nil,
                       "partial source failure must preserve both successful deliveries and finish")
            print("PASS promises: multiple files, partial failure, completion, extra callback")

            let early = PromisedFiles(timeout: .seconds(1))
            try expect(early.yield(.success(file)), "callback before expected count accepted")
            early.expect(1)
            let earlyResult = try await collect(early)
            try expect(earlyResult.urls == [file] && earlyResult.terminalError == nil, "early callback must not leave the batch waiting")
            print("PASS promises: callback before fileNames becomes available")

            let partial = PromisedFiles(timeout: .milliseconds(30))
            partial.expect(2)
            _ = partial.yield(.success(file))
            let partialResult = try await collect(partial)
            try expect(partialResult.urls == [file] && partialResult.terminalError is PromisedFilesError,
                       "timeout preserves already delivered files")
            print("PASS promises: partial delivery survives timeout")

            let cancelled = PromisedFiles(timeout: .seconds(60))
            cancelled.expect(1)
            let waiting = Task {
                var result = Received()
                do { for try await _ in cancelled.stream { result.failures += 1 } }
                catch { result.terminalError = error }
                return result
            }
            waiting.cancel()
            _ = await waiting.value
            try expect(!cancelled.yield(.success(file)), "consumer cancellation rejects late callback")
            let explicitlyCancelled = PromisedFiles(timeout: .seconds(60))
            explicitlyCancelled.expect(1)
            explicitlyCancelled.cancel()
            let cancelledResult = try await collect(explicitlyCancelled)
            try expect(cancelledResult.terminalError is CancellationError, "explicit cancellation ends with cancellation")
            try expect(!explicitlyCancelled.yield(.success(file)), "explicit cancellation rejects late callback")
            print("PASS promises: consumer and explicit cancellation release wait")

            let empty = PromisedFiles(timeout: .seconds(60))
            empty.expect(0)
            let emptyResult = try await collect(empty)
            try expect(emptyResult.terminalError is PromisedFilesError, "empty source fails immediately")
            print("PASS promises: source without file names fails immediately")

            let concurrent = PromisedFiles(timeout: .seconds(1))
            concurrent.expect(64)
            await withTaskGroup(of: Void.self) { group in
                for number in 0..<64 {
                    group.addTask {
                        _ = concurrent.yield(.success(URL(fileURLWithPath: "/synthetic/\(number).txt")))
                    }
                }
            }
            let concurrentResult = try await collect(concurrent)
            try expect(Set(concurrentResult.urls).count == 64 && concurrentResult.terminalError == nil,
                       "concurrent final callbacks must not end stream before earlier accepted files are buffered")
            try expect(!concurrent.yield(.success(file)), "concurrent completion rejects late delivery")
            print("PASS promises: concurrent delivery preserves every accepted file")

            let orphanedStream = PromisedFiles(timeout: .seconds(60)).stream
            var orphanedCancelled = false
            do { for try await _ in orphanedStream { } }
            catch is CancellationError { orphanedCancelled = true }
            try expect(orphanedCancelled, "releasing the receiver must not leave an orphan stream waiting")
            print("PASS promises: released receiver ends its remaining stream")
        } catch {
            FileHandle.standardError.write(Data("FAIL promises: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
