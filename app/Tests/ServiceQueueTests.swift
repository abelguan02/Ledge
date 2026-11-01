import Foundation

actor Registry {
    var active: Set<Int> = []
    var order: [Int] = []
    func register(_ n: Int) async { await Task.yield(); active.insert(n); order.append(n) }
    func cancel(_ n: Int) { active.remove(n) }
    func stop() { active = [] }
}
@main struct ServiceQueueTests {
    static func main() async {
        let queue = ServiceQueue(), registry = Registry()
        for n in 0..<50 {
            queue.enqueue { await registry.register(n) }
            queue.enqueue { await registry.cancel(n) }
        }
        queue.enqueue { await registry.stop() }
        await queue.drain()
        let order = await registry.order, active = await registry.active
        precondition(order == Array(0..<50) && active.isEmpty)
        print("PASS XPC registration/cancel/stop arrival order; no service or model launched")
    }
}
