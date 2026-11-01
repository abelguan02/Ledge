import Foundation

enum PromisedFilesError: LocalizedError {
    case timedOut, empty
    var errorDescription: String? {
        switch self {
        case .timedOut: "等待来源交付文件超时，已结束本次收纳。已收到的材料保留，可以重新拖入。"
        case .empty: "拖入来源没有提供文件名。"
        }
    }
}

// NSFilePromiseReceiver may call back before fileNames is available. Buffer
// those deliveries, but put a deadline on the whole batch and reject late ones.
// All mutable state is protected by lock; stream continuations are Sendable.
final class PromisedFiles: @unchecked Sendable {
    let stream: AsyncThrowingStream<Result<URL, Error>, Error>
    private let continuation: AsyncThrowingStream<Result<URL, Error>, Error>.Continuation
    private let lock = NSLock()
    private var expected: Int?
    private var received = 0
    private var ended = false
    private var timer: Task<Void, Never>?

    init(timeout: Duration = .seconds(120)) {
        (stream, continuation) = AsyncThrowingStream.makeStream()
        continuation.onTermination = { [weak self] _ in self?.consumerEnded() }
        let timer = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.finish(throwing: PromisedFilesError.timedOut)
        }
        let alreadyEnded = lock.withLock {
            if ended { return true }
            self.timer = timer; return false
        }
        if alreadyEnded { timer.cancel() }
    }

    @discardableResult func yield(_ result: Result<URL, Error>) -> Bool {
        let state = lock.withLock { () -> (accepted: Bool, complete: Bool, timer: Task<Void, Never>?) in
            guard !ended else { return (false, false, nil) }
            // Yield under the lock so a concurrent final delivery cannot finish
            // the stream before an earlier accepted result reaches its buffer.
            if case .terminated = continuation.yield(result) {
                ended = true
                let timer = self.timer; self.timer = nil
                return (false, false, timer)
            }
            received += 1
            guard let expected, received >= expected else { return (true, false, nil) }
            ended = true
            let timer = self.timer; self.timer = nil
            return (true, true, timer)
        }
        state.timer?.cancel()
        if state.complete { continuation.finish() }
        return state.accepted
    }

    func expect(_ count: Int) {
        guard count > 0 else { finish(throwing: PromisedFilesError.empty); return }
        let state = lock.withLock { () -> (complete: Bool, timer: Task<Void, Never>?) in
            guard !ended else { return (false, nil) }
            expected = count
            guard received >= count else { return (false, nil) }
            ended = true
            let timer = self.timer; self.timer = nil
            return (true, timer)
        }
        state.timer?.cancel()
        if state.complete { continuation.finish() }
    }

    func cancel() { finish(throwing: CancellationError()) }

    private func finish(throwing error: Error) {
        let state = lock.withLock { () -> (finish: Bool, timer: Task<Void, Never>?) in
            guard !ended else { return (false, nil) }
            ended = true
            let timer = self.timer; self.timer = nil
            return (true, timer)
        }
        state.timer?.cancel()
        if state.finish { continuation.finish(throwing: error) }
    }

    private func consumerEnded() {
        let timer = lock.withLock {
            ended = true
            let timer = self.timer; self.timer = nil
            return timer
        }
        timer?.cancel()
    }

    deinit {
        timer?.cancel()
        continuation.finish(throwing: CancellationError())
    }
}
