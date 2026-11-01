import Foundation

@objc protocol HUDCodexService {
    func connect(_ requestID: String, reply: @escaping @Sendable (Data?, String?) -> Void)
    func respond(_ input: String, instructions: String, model: String, requestID: String,
                 reply: @escaping @Sendable (Data?, String?) -> Void)
    func cancel(_ requestID: String)
    func stop()
}
struct AccountModel: Identifiable, Codable, Sendable {
    var slug: String
    var display_name: String
    var visibility: String
    var id: String { slug }
}
struct CodexCatalog: Codable, Sendable { var models: [AccountModel]; var preferred: String }

// The HUD keeps its existing sandbox and container. Only the bundled service
// manages the ordinary desktop Codex process; no credentials cross this link.
@MainActor protocol TextBackend {
    func catalog() async throws -> CodexCatalog
    func respond(input: String, instructions: String, model: String) async throws -> String
    func stop()
}

@MainActor final class CodexBridge: TextBackend {
    private var connection: NSXPCConnection?
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    private var spans: [String: CodexTiming.Span] = [:]
    private var generation = 0
    private let makeConnection: () -> NSXPCConnection
    init(makeConnection: @escaping () -> NSXPCConnection = { NSXPCConnection(serviceName: "local.ledge.desktop.CodexService") }) {
        self.makeConnection = makeConnection
    }
    private func remote() throws -> HUDCodexService {
        if connection == nil {
            generation += 1; let current = generation
            let link = makeConnection()
            let service = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/CodexService.xpc")
            link.setCodeSigningRequirement(try PeerSignature.requirement(at: service, identifier: "local.ledge.desktop.CodexService"))
            link.remoteObjectInterface = NSXPCInterface(with: HUDCodexService.self)
            link.invalidationHandler = { @Sendable [weak self] in Task { @MainActor in if self?.generation == current { self?.failed() } } }
            link.interruptionHandler = { @Sendable [weak self] in Task { @MainActor in if self?.generation == current { self?.failed() } } }
            connection = link; link.resume()
        }
        let current = generation
        // XPC invokes this on its own queue, before the explicit MainActor hop.
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ @Sendable [weak self] _ in
            Task { @MainActor in if self?.generation == current { self?.failed() } }
        }) as? HUDCodexService else { throw AIError.problem("HUD 后台连接不可用；未要求重新登录。") }
        return proxy
    }
    func catalog() async throws -> CodexCatalog {
        let data = try await call(input: nil, instructions: "", model: "")
        return try JSONDecoder().decode(CodexCatalog.self, from: data)
    }
    func respond(input: String, instructions: String, model: String) async throws -> String {
        let data = try await call(input: input, instructions: instructions, model: model)
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { throw AIError.problem("模型没有返回完整文字。") }
        return text
    }
    private func call(input: String?, instructions: String, model: String) async throws -> Data {
        try Task.checkCancellation()
        let id = UUID().uuidString
        let span = CodexTiming(requestID: id, operation: input == nil ? .catalog : .respond).begin(.clientTotal)
        let proxy: HUDCodexService
        do { proxy = try remote() }
        catch { span.finish(outcome: .failure(error, cancelled: Task.isCancelled)); throw error }
        spans[id] = span
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                timers[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(input == nil ? 60 : 180)) } catch { return }
                    self?.cancel(id, error: AIError.problem("后台请求超时；未自动重试或重新登录。"), outcome: .timeout)
                }
                let reply: @Sendable (Data?, String?) -> Void = { [weak self] data, error in
                    Task { @MainActor in
                        if let error { self?.finish(id, .failure(AIError.problem(error))) }
                        else if let data, data.count <= 2 * 1024 * 1024 { self?.finish(id, .success(data)) }
                        else { self?.finish(id, .failure(AIError.problem("后台响应格式异常。"))) }
                    }
                }
                if let input { proxy.respond(input, instructions: instructions, model: model, requestID: id, reply: reply) }
                else { proxy.connect(id, reply: reply) }
            }
        } onCancel: { Task { @MainActor in self.cancel(id, error: CancellationError()) } }
    }
    private func finish(_ id: String, _ result: Result<Data, Error>, outcome: CodexTiming.Outcome? = nil) {
        if let span = spans.removeValue(forKey: id) {
            switch result {
            case .success: span.finish(outcome: outcome ?? .success)
            case .failure(let error): span.finish(outcome: outcome ?? .failure(error, cancelled: false))
            }
        }
        timers.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }
    private func cancel(_ id: String, error: Error, outcome: CodexTiming.Outcome? = nil) {
        guard pending[id] != nil else { return }
        (connection?.remoteObjectProxy as? HUDCodexService)?.cancel(id)
        finish(id, .failure(error), outcome: outcome)
    }
    private func failed() {
        generation += 1
        connection?.invalidationHandler = nil; connection?.interruptionHandler = nil
        connection?.invalidate(); connection = nil
        for id in Array(pending.keys) { finish(id, .failure(AIError.problem("Codex 后台连接中断；可恢复连接，无需重复授权。"))) }
    }
    func stop() {
        (connection?.remoteObjectProxy as? HUDCodexService)?.stop()
        failed()
    }
}
