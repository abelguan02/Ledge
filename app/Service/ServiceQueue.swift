import Foundation

// NSXPC callbacks are synchronous; preserve their arrival order when crossing
// into Worker. In particular, cancel/stop must not overtake run registration.
final class ServiceQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock(); defer { lock.unlock() }
        let previous = tail
        tail = Task { await previous?.value; await operation() }
    }
    func drain() async {
        let last = lock.withLock { tail }
        await last?.value
    }
}
