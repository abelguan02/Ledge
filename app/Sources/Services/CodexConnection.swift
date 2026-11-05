import Foundation

// Typed RPC boundary. No login, arbitrary command or file RPC is exposed.
// A turn is started only by the explicit respond path, never by account checks.
enum CodexConnectionError: Error, LocalizedError, Equatable {
    case unavailable, launch, closed, timeout, malformed, oversized, rpc(Int), unsupportedAccount, incomplete, busy, backendExit(Int32, String)
    var errorDescription: String? { copy.rendered(.simplified) }
    var copy: InterfaceText {
        switch self {
        case .unavailable: return "未找到已有 Codex；未打开登录页面。"
        case .launch: return "Codex 后台进程未能启动；这不是账号登录失败。"
        case .closed: return "Codex 后台连接已结束；未要求重新登录。"
        case .timeout: return "Codex 后台连接超时；未重复发送请求。"
        case .malformed: return "Codex 返回的连接数据格式异常。"
        case .oversized: return "Codex 返回的连接数据超过本地限制。"
        case .rpc(let code): return "Codex 连接请求失败（\(code)）；未自动重新登录。"
        case .unsupportedAccount: return "Codex 尚未确认可复用的 ChatGPT 登录；未切换到 API 计费。"
        case .incomplete: return "Codex 未完成文字回复；未自动重试或重新登录。"
        case .busy: return "当前后台连接已有请求进行中。"
        case .backendExit(let code, let category): return "Codex 后台退出（\(code)，\(InterfaceText(key: category))）；未启动登录。"
        }
    }
}

enum CodexAccountState: Equatable, Sendable { case chatGPT, signedOut }

actor CodexConnection {
    private var process: Process?
    private var input: FileHandle?
    private var outbound = Data()
    private var outboundOffset = 0
    private var writeRetry: Task<Void, Never>?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var buffer = Data()
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var nextID = 0
    private var outputReader: Task<Void, Never>?
    private var outputContinuation: AsyncStream<Data>.Continuation?
    private var outputFinished = false
    private var generation = 0
    private var ready = false
    private var diagnosticCategory = "进程结束"
    private var activeThread: String?
    private var answer: CheckedContinuation<String, Error>?
    private var completedAnswer: Result<String, Error>?
    private var messages: [String: String] = [:]
    private var messageOrder: [String] = []
    private var answerBytes = 0
    private let timeout: Duration
    private let answerTimeout: Duration
    private let timing: CodexTiming?
    private let byteLimit = 2 * 1024 * 1024

    init(timeout: Duration = .seconds(15), answerTimeout: Duration = .seconds(150), timing: CodexTiming? = nil) {
        self.timeout = timeout; self.answerTimeout = answerTimeout; self.timing = timing
    }

    static func environment(_ original: [String: String]) -> [String: String] {
        let names: Set<String> = ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "CODEX_HOME", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy"]
        return original.filter { names.contains($0.key) }
    }

    func start(executable: URL, arguments: [String], directory: URL,
               environment: [String: String]) async throws {
        let launch = timing?.begin(.launch)
        var launched = false
        defer { if !launched { launch?.finish(outcome: Task.isCancelled ? .cancelled : .failure) } }
        guard process == nil else { throw CodexConnectionError.launch }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw CodexConnectionError.unavailable }
        generation += 1
        let current = generation
        buffer.removeAll(); outputFinished = false; ready = false; diagnosticCategory = "进程结束"
        let child = Process(), incoming = Pipe(), outgoing = Pipe(), diagnostic = Pipe()
        child.executableURL = executable; child.arguments = arguments
        child.currentDirectoryURL = directory; child.environment = Self.environment(environment)
        child.standardInput = incoming; child.standardOutput = outgoing; child.standardError = diagnostic
        process = child; input = incoming.fileHandleForWriting
        output = outgoing.fileHandleForReading; errors = diagnostic.fileHandleForReading
        // macOS supports suppressing SIGPIPE per descriptor. Do not change the
        // entire application's signal disposition when a backend disconnects.
        let inputFD = incoming.fileHandleForWriting.fileDescriptor
        let flags = fcntl(inputFD, F_GETFL)
        guard flags != -1, fcntl(inputFD, F_SETNOSIGPIPE, 1) != -1,
              fcntl(inputFD, F_SETFL, flags | O_NONBLOCK) != -1 else {
            stop(reason: .launch); throw CodexConnectionError.launch
        }
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        outputContinuation = continuation
        outputReader = Task { [weak self] in
            for await bytes in stream {
                guard !Task.isCancelled else { break }
                await self?.receive(bytes, generation: current)
            }
        }
        // Yield synchronously from the serial FileHandle callback. Only one
        // consumer crosses into the actor, preserving chunk and EOF order.
        outgoing.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            continuation.yield(bytes)
            if bytes.isEmpty { handle.readabilityHandler = nil; continuation.finish() }
        }
        // Drain stderr without retaining it: it may contain account details.
        diagnostic.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil }
            else { Task { await self?.diagnostic(bytes, generation: current) } }
        }
        child.terminationHandler = { [weak self] _ in
            Task {
                // Let stderr category delivery catch up before closing pipes.
                try? await Task.sleep(for: .milliseconds(80))
                await self?.ended(generation: current)
            }
        }
        do { try child.run() } catch { stop(reason: .launch); throw CodexConnectionError.launch }
        launch?.finish(outcome: .success); launched = true
        do {
            _ = try await request(method: "initialize", params: ["clientInfo": ["name": "dump", "version": "1"], "capabilities": ["experimentalApi": false]])
            try write(["method": "initialized"])
            ready = true
        } catch { stop(); throw error }
    }

    func account() async throws -> CodexAccountState {
        guard ready else { throw CodexConnectionError.closed }
        let data = try await request(method: "account/read", params: ["refreshToken": false])
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              result.keys.contains("account") else { throw CodexConnectionError.malformed }
        if result["account"] is NSNull { return .signedOut }
        guard let account = result["account"] as? [String: Any],
              let type = account["type"] as? String else { throw CodexConnectionError.malformed }
        guard type == "chatgpt" else { throw CodexConnectionError.unsupportedAccount }
        return .chatGPT
    }

    func catalog() async throws -> CodexCatalog {
        guard try await account() == .chatGPT else { throw CodexConnectionError.unsupportedAccount }
        var cursor: String?, models: [AccountModel] = [], preferred = ""
        for _ in 0..<8 {
            var params: [String: Any] = ["limit": 100, "includeHidden": false]
            if let cursor { params["cursor"] = cursor }
            let data = try await request(method: "model/list", params: params)
            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = result["data"] as? [[String: Any]] else { throw CodexConnectionError.malformed }
            for row in rows where row["hidden"] as? Bool != true {
                guard let slug = row["model"] as? String, let name = row["displayName"] as? String else { continue }
                if !models.contains(where: { $0.slug == slug }) { models.append(AccountModel(slug: slug, display_name: name, visibility: "list")) }
                if row["isDefault"] as? Bool == true { preferred = slug }
            }
            cursor = result["nextCursor"] as? String
            if cursor == nil { break }
        }
        guard !models.isEmpty else { throw CodexConnectionError.unsupportedAccount }
        return CodexCatalog(models: models, preferred: preferred.isEmpty ? models[0].slug : preferred)
    }

    func respond(input: String, instructions: String, model: String, directory: URL) async throws -> String {
        guard activeThread == nil else { throw CodexConnectionError.busy }
        guard instructions.utf8.count <= MingTextLimits.maximumInstructionBytes else { throw AIError.problem(MingTextLimits.instructionTooLongMessage) }
        guard input.utf8.count <= MingTextLimits.maximumInputBytes, !model.isEmpty else { throw CodexConnectionError.oversized }
        guard try await account() == .chatGPT else { throw CodexConnectionError.unsupportedAccount }
        let created = try await request(method: "thread/start", params: [
            "model": model, "modelProvider": "openai", "cwd": directory.path,
            "ephemeral": true, "sandbox": "read-only", "approvalPolicy": "never",
            "baseInstructions": "You are a text-only reading assistant. Answer only the supplied text. Do not use tools, access files, browse, or execute commands.",
            "developerInstructions": instructions])
        guard let result = try JSONSerialization.jsonObject(with: created) as? [String: Any],
              let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else { throw CodexConnectionError.malformed }
        activeThread = id; completedAnswer = nil; messages = [:]; messageOrder = []; answerBytes = 0
        defer { activeThread = nil; completedAnswer = nil; messages = [:]; messageOrder = []; answerBytes = 0 }
        return try await withTaskCancellationHandler {
            _ = try await request(method: "turn/start", params: ["threadId": id, "input": [["type": "text", "text": input, "text_elements": []]]])
            return try await waitForAnswer()
        } onCancel: { Task { await self.stop() } }
    }

    private func waitForAnswer() async throws -> String {
        let span = timing?.begin(.answer)
        var outcome: CodexTiming.Outcome = .success
        defer { span?.finish(outcome: outcome) }
        do {
            try Task.checkCancellation()
            if let completedAnswer { return try completedAnswer.get() }
            guard ready, process?.isRunning == true else { throw CodexConnectionError.closed }
            return try await withCheckedThrowingContinuation { continuation in
                answer = continuation
                timeouts[-1] = Task { [weak self, answerTimeout] in
                    do { try await Task.sleep(for: answerTimeout) } catch { return }
                    await self?.stop(reason: .timeout)
                }
            }
        } catch {
            outcome = .failure(error, cancelled: Task.isCancelled)
            throw error
        }
    }

    private func notification(_ method: String, _ params: [String: Any]) {
        guard let activeThread, params["threadId"] as? String == activeThread else { return }
        if method == "item/completed", let item = params["item"] as? [String: Any],
           item["type"] as? String == "agentMessage", let text = item["text"] as? String,
           let id = item["id"] as? String, item["phase"] as? String != "commentary" {
            guard storeMessage(text, id: id) else { return }
        }
        if method == "turn/completed", let turn = params["turn"] as? [String: Any] {
            if let items = turn["items"] as? [[String: Any]] {
                for item in items where item["type"] as? String == "agentMessage" && item["phase"] as? String != "commentary" {
                    if let id = item["id"] as? String, let text = item["text"] as? String {
                        guard storeMessage(text, id: id) else { return }
                    }
                }
            }
            let text = messageOrder.compactMap { messages[$0] }.joined(separator: "\n\n")
            let result: Result<String, Error> = turn["status"] as? String == "completed" && !text.isEmpty ? .success(text) : .failure(CodexConnectionError.incomplete)
            completedAnswer = result; timeouts.removeValue(forKey: -1)?.cancel()
            answer?.resume(with: result); answer = nil
        }
    }

    private func storeMessage(_ text: String, id: String) -> Bool {
        let size = answerBytes - (messages[id]?.utf8.count ?? 0) + text.utf8.count
            + (messages[id] == nil && !messageOrder.isEmpty ? 2 : 0)
        guard size <= byteLimit else { stop(reason: .oversized); return false }
        if messages[id] == nil { messageOrder.append(id) }
        messages[id] = text; answerBytes = size
        return true
    }

    private func request(method: String, params: [String: Any]) async throws -> Data {
        guard ["initialize", "account/read", "model/list", "thread/start", "turn/start"].contains(method),
              let stage = CodexTiming.Stage(rawValue: method) else { throw CodexConnectionError.closed }
        // This interval ends at the RPC response; answer/wait measures any
        // remaining time after turn/start acknowledges the request.
        let span = timing?.begin(stage)
        var outcome: CodexTiming.Outcome = .success
        defer { span?.finish(outcome: outcome) }
        do {
            guard process?.isRunning == true else { throw CodexConnectionError.closed }
            try Task.checkCancellation()
            nextID += 1; let id = nextID
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    pending[id] = continuation
                    timeouts[id] = Task { [weak self, timeout] in
                        do { try await Task.sleep(for: timeout) } catch { return }
                        await self?.expire(id)
                    }
                    do { try write(["id": id, "method": method, "params": params]) }
                    catch { stop(); return }
                }
            } onCancel: { Task { await self.cancel(id) } }
        } catch {
            outcome = .failure(error, cancelled: Task.isCancelled)
            throw error
        }
    }

    private func write(_ message: [String: Any]) throws {
        guard input != nil else { throw CodexConnectionError.closed }
        var data = try JSONSerialization.data(withJSONObject: message); data.append(10)
        outbound.append(data)
        try drainInput()
        if !outbound.isEmpty, writeRetry == nil {
            let current = generation
            writeRetry = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                    guard let self, await self.retryInput(generation: current) else { return }
                }
            }
        }
    }

    // Preserve complete JSON frames and partial-write offsets. A full pipe must
    // yield the actor so timeout, cancellation and stop can close the connection.
    private func drainInput() throws {
        guard let input else { throw CodexConnectionError.closed }
        while outboundOffset < outbound.count {
            let written = outbound.withUnsafeBytes { bytes in
                Darwin.write(input.fileDescriptor, bytes.baseAddress!.advanced(by: outboundOffset), bytes.count - outboundOffset)
            }
            if written > 0 { outboundOffset += written }
            else if written == -1 && errno == EINTR { continue }
            else if written == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            else { throw CodexConnectionError.closed }
        }
        outbound.removeAll(keepingCapacity: true); outboundOffset = 0
    }

    private func retryInput(generation current: Int) -> Bool {
        guard current == generation else { return false }
        do { try drainInput() }
        catch { stop(); return false }
        if outbound.isEmpty { writeRetry = nil; return false }
        return true
    }

    private func receive(_ bytes: Data, generation current: Int) {
        guard current == generation, process != nil else { return }
        guard !bytes.isEmpty else {
            outputFinished = true
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                await self?.eof(generation: current)
            }
            return
        }
        buffer.append(bytes)
        while let newline = buffer.firstIndex(of: 10) {
            guard buffer.distance(from: buffer.startIndex, to: newline) <= byteLimit else { stop(reason: .oversized); return }
            let line = buffer[..<newline]; buffer.removeSubrange(...newline)
            if line.isEmpty { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { stop(reason: .malformed); return }
            // A backend request cannot activate a tool or permission flow.
            if let method = object["method"] as? String {
                if let id = object["id"] {
                    do { try write(["id": id, "error": ["code": -32601, "message": "HUD read-only connection does not support server requests"]]) }
                    catch { stop(); return }
                } else if let params = object["params"] as? [String: Any] {
                    notification(method, params)
                    guard current == generation else { return }
                }
                continue
            }
            guard let id = object["id"] as? Int, pending[id] != nil else { continue }
            if let error = object["error"] as? [String: Any], let code = error["code"] as? Int {
                finish(id, result: .failure(CodexConnectionError.rpc(code)))
            } else if let result = object["result"], JSONSerialization.isValidJSONObject(result),
                      let data = try? JSONSerialization.data(withJSONObject: result) {
                finish(id, result: .success(data))
            } else { stop(reason: .malformed); return }
        }
        guard buffer.count <= byteLimit else { stop(reason: .oversized); return }
    }

    private func diagnostic(_ bytes: Data, generation current: Int) {
        guard current == generation else { return }
        let text = String(decoding: bytes, as: UTF8.self).lowercased()
        // Emit only predefined categories, never raw configuration or stderr.
        if text.contains("error loading") || text.contains("invalid type") || text.contains("unknown configuration") || text.contains("failed to parse") || text.contains("escape") { diagnosticCategory = "配置不兼容" }
        else if text.contains("operation not permitted") || text.contains("permission denied") { diagnosticCategory = "系统访问被拒绝" }
        else if text.contains("no such file") { diagnosticCategory = "依赖路径不存在" }
    }

    private func finish(_ id: Int, result: Result<Data, Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }
    private func expire(_ id: Int) { if pending[id] != nil { stop(reason: .timeout) } }
    private func cancel(_ id: Int) { if pending[id] != nil { stop() } }
    private func ended(generation current: Int) {
        if current == generation, outputFinished {
            let status = process?.terminationStatus ?? 0
            stop(reason: status == 0 ? .closed : .backendExit(status, diagnosticCategory))
        }
    }
    private func eof(generation current: Int) {
        guard current == generation else { return }
        if process?.isRunning == false { ended(generation: current) }
        else { stop() }
    }

    func stop(reason: CodexConnectionError = .closed) {
        generation += 1; ready = false
        writeRetry?.cancel(); writeRetry = nil
        outbound.removeAll(); outboundOffset = 0
        answer?.resume(throwing: reason); answer = nil
        timeouts.removeValue(forKey: -1)?.cancel()
        output?.readabilityHandler = nil; errors?.readabilityHandler = nil
        outputContinuation?.finish(); outputContinuation = nil
        outputReader?.cancel(); outputReader = nil
        try? input?.close(); try? output?.close(); try? errors?.close()
        input = nil; output = nil; errors = nil; buffer.removeAll()
        let child = process; process = nil
        child?.terminationHandler = nil
        if let child, child.isRunning {
            child.terminate()
            // Only this owned child is targeted; never a user's Codex process.
            Task.detached {
                try? await Task.sleep(for: .seconds(1))
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        for id in Array(pending.keys) { finish(id, result: .failure(reason)) }
    }
}
