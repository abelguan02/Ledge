import Foundation
import Security

actor Worker {
    private var tasks: [String: Task<Void, Never>] = [:]
    private func report(_ text: InterfaceText, to reply: @Sendable (Data?, Data?) -> Void) {
        // A malformed response is already handled by the client.
        reply(nil, try? JSONEncoder().encode(text))
    }
    func run(id: String, input: String?, instructions: String = "", model: String = "",
             reply: @escaping @Sendable (Data?, Data?) -> Void) {
        guard tasks[id] == nil, tasks.count < 4 else { report("已有请求进行中，请稍后再试。", to: reply); return }
        tasks[id] = Task {
            let timing = CodexTiming(requestID: id, operation: input == nil ? .catalog : .respond)
            let total = timing.begin(.total)
            var outcome: CodexTiming.Outcome = .success
            defer { total.finish(outcome: outcome) }
            let client = CodexConnection(timeout: .seconds(45), timing: timing)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dump-codex-\(UUID().uuidString)")
            var stage: InterfaceText = "初始化 Codex"
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let launch = try CodexLaunch.make(directory: directory)
                try await client.start(executable: launch.executable, arguments: launch.arguments, directory: directory, environment: launch.environment)
                let data: Data
                if let input {
                    stage = "处理文字"
                    data = Data(try await client.respond(input: input, instructions: instructions, model: model, directory: directory).utf8)
                } else {
                    stage = "读取模型列表"
                    data = try JSONEncoder().encode(await client.catalog())
                }
                try Task.checkCancellation()
                reply(data, nil)
            } catch {
                outcome = .failure(error, cancelled: Task.isCancelled)
                let detail: InterfaceText
                if let connection = error as? CodexConnectionError { detail = connection.copy }
                else if error is AIError { detail = InterfaceText(key: error.localizedDescription) }
                else { detail = "后台连接未完成；没有启动登录或重复发送。" }
                report("\(stage)：\(detail)", to: reply)
            }
            await client.stop()
            try? FileManager.default.removeItem(at: directory)
            tasks[id] = nil
        }
    }
    func cancel(_ id: String) { tasks[id]?.cancel() }
    func stop() { tasks.values.forEach { $0.cancel() } }
}

final class Service: NSObject, HUDCodexService, @unchecked Sendable {
    let worker = Worker()
    private let queue = ServiceQueue()
    func connect(_ requestID: String, reply: @escaping @Sendable (Data?, Data?) -> Void) {
        guard UUID(uuidString: requestID) != nil else { reply(nil, try? JSONEncoder().encode(InterfaceText(key: "无效请求。"))); return }
        queue.enqueue { [worker] in await worker.run(id: requestID, input: nil, reply: reply) }
    }
    func respond(_ input: String, instructions: String, model: String, requestID: String, reply: @escaping @Sendable (Data?, Data?) -> Void) {
        guard UUID(uuidString: requestID) != nil else { reply(nil, try? JSONEncoder().encode(InterfaceText(key: "无效请求。"))); return }
        queue.enqueue { [worker] in await worker.run(id: requestID, input: input, instructions: instructions, model: model, reply: reply) }
    }
    func cancel(_ requestID: String) { queue.enqueue { [worker] in await worker.cancel(requestID) } }
    func stop() { queue.enqueue { [worker] in await worker.stop() } }
}

final class Listener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let host = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let rule = try? PeerSignature.requirement(at: host, identifier: "local.ledge.desktop") else { return false }
        connection.setCodeSigningRequirement(rule)
        let service = Service()
        connection.exportedInterface = NSXPCInterface(with: HUDCodexService.self)
        connection.exportedObject = service
        connection.invalidationHandler = { service.stop() }
        connection.interruptionHandler = { service.stop() }
        connection.resume()
        return true
    }
}
let delegate = Listener()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
