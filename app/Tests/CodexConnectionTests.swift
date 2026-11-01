import Foundation

final class TimingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CodexTimingEvent] = []
    func record(_ event: CodexTimingEvent) { lock.withLock { recorded.append(event) } }
    var events: [CodexTimingEvent] { lock.withLock { recorded } }
}

@main struct CodexConnectionTests {
    static func backpressureTests(script: URL, directory: URL) async throws {
        for mode in ["timeout", "cancel", "stop", "drain"] {
            let records = TimingRecorder()
            let client = CodexConnection(timeout: mode == "timeout" ? .milliseconds(350) : .seconds(5),
                timing: CodexTiming(requestID: UUID().uuidString, operation: .respond, sink: { records.record($0) }))
            try await client.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, "backpressure-\(mode)"], directory: directory, environment: [:])
            let began = ContinuousClock.now
            let request = Task { try await client.respond(input: String(repeating: "x", count: 128 * 1024), instructions: "Synthetic", model: "synthetic-model", directory: directory) }
            if mode == "cancel" || mode == "stop" {
                for _ in 0..<200 where !records.events.contains(where: { $0.stage == .turnStart && $0.outcome == .started }) {
                    try await Task.sleep(for: .milliseconds(10))
                }
                precondition(records.events.contains { $0.stage == .turnStart && $0.outcome == .started })
                try await Task.sleep(for: .milliseconds(80))
                if mode == "cancel" { request.cancel() } else { await client.stop() }
            }
            do {
                let answer = try await request.value
                precondition(mode == "drain" && answer == "synthetic answer", "partial writes preserve the entire JSON request")
            } catch let error as CodexConnectionError {
                precondition(mode == "timeout" ? error == .timeout : (mode == "cancel" || mode == "stop") && error == .closed)
            } catch is CancellationError { precondition(mode == "cancel") }
            precondition(began.duration(to: .now) < .seconds(2), "backpressure must not wait for the peer's three-second stall")
            await client.stop()
            try await client.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, "response"], directory: directory, environment: [:])
            let recovered = try await client.respond(input: "synthetic input", instructions: "Synthetic", model: "synthetic-model", directory: directory)
            precondition(recovered == "synthetic answer", "no stale queued bytes reach a replacement child")
            await client.stop()
        }
        print("PASS 128 KiB pipe backpressure: deadline, cancellation, explicit stop, partial-write completion and connection reuse")
    }
    static func timingTests(script: URL, directory: URL) async throws {
        let totals = TimingRecorder()
        let totalTiming = CodexTiming(requestID: "must-not-log-this-secret", operation: .catalog, sink: { totals.record($0) })
        let total = totalTiming.begin(.total)
        try await Task.sleep(for: .milliseconds(20))
        total.finish(outcome: .success)
        precondition(totals.events.count == 2 && totals.events[1].elapsedMilliseconds >= 10, "total span measures elapsed monotonic time")
        precondition(totals.events.allSatisfy { $0.requestID == "invalid" }, "an invalid ID cannot inject private text into diagnostics")
        let requestID = UUID().uuidString
        let recorder = TimingRecorder()
        let timing = CodexTiming(requestID: requestID, operation: .respond, sink: { recorder.record($0) })
        let client = CodexConnection(timeout: .seconds(5), timing: timing)
        try await client.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, "response"], directory: directory, environment: [:])
        let catalog = try await client.catalog()
        _ = try await client.respond(input: "synthetic input", instructions: "Secret instruction", model: catalog.preferred, directory: directory)
        await client.stop()
        let expected: [CodexTiming.Stage] = [.launch, .initialize, .accountRead, .modelList, .accountRead, .threadStart, .turnStart, .answer]
        precondition(recorder.events.filter { $0.outcome == .started }.map(\.stage) == expected, "each actual phase has a start event")
        precondition(recorder.events.filter { $0.outcome == .success }.map(\.stage) == expected, "each successful phase ends once")
        precondition(recorder.events.allSatisfy { $0.requestID == requestID && $0.operation == .respond && $0.elapsedMilliseconds >= 0 }, "one request ID and monotonic durations span all phases")
        let encoded = String(decoding: try JSONEncoder().encode(recorder.events), as: UTF8.self)
        for secret in ["synthetic input", "Secret instruction", "synthetic-model", script.path, directory.path, "secret@example.invalid"] {
            precondition(!encoded.contains(secret), "timings never contain input, instructions, model, account or paths")
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dump-timing-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stalled = root.appendingPathComponent("stalled.py")
        try """
        import json, sys, time
        mode = sys.argv[1]
        for line in sys.stdin:
            value = json.loads(line)
            method = value['method']
            if method == 'initialized': continue
            if method == mode: time.sleep(10); continue
            if method == 'account/read': result = {'account': {'type': 'chatgpt', 'email': 'secret@example.invalid'}}
            elif method == 'model/list': result = {'data': [{'model': 'synthetic-model', 'displayName': 'Synthetic', 'isDefault': True}], 'nextCursor': None}
            elif method == 'thread/start': result = {'thread': {'id': 'private-thread'}}
            elif method == 'turn/start': result = {'turn': {'id': 'private-turn'}}
            else: result = {}
            print(json.dumps({'id': value['id'], 'result': result}), flush=True)
            if method == 'turn/start' and mode != 'answer/wait':
                print(json.dumps({'method': 'turn/completed', 'params': {'threadId': 'private-thread', 'turn': {'status': 'completed', 'items': [{'type': 'agentMessage', 'id': 'private-message', 'text': 'private-answer'}]}}}), flush=True)
        """.write(to: stalled, atomically: true, encoding: .utf8)

        for stage: CodexTiming.Stage in [.initialize, .accountRead, .modelList, .threadStart, .turnStart, .answer] {
            let records = TimingRecorder()
            let timing = CodexTiming(requestID: UUID().uuidString, operation: .respond, sink: { records.record($0) })
            let client = CodexConnection(timeout: .milliseconds(350), answerTimeout: .milliseconds(350), timing: timing)
            do {
                try await client.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [stalled.path, stage.rawValue], directory: root, environment: [:])
                if stage == .modelList { _ = try await client.catalog() }
                else { _ = try await client.respond(input: "private-input", instructions: "private-instruction", model: "private-model", directory: root) }
                preconditionFailure("synthetic stall must time out at \(stage.rawValue)")
            } catch let error as CodexConnectionError { precondition(error == .timeout) }
            await client.stop()
            let timeouts = records.events.filter { $0.outcome == .timeout }
            precondition(timeouts.count == 1 && timeouts[0].stage == stage, "timing localizes the actual stalled phase")
            precondition(timeouts[0].elapsedMilliseconds >= 300, "timeout records elapsed monotonic time")
            precondition(records.events.filter { $0.outcome == .started }.count == records.events.filter { $0.outcome != .started }.count, "all started phases have one terminal event")
        }

        let cancelled = TimingRecorder()
        let cancellationClient = CodexConnection(timeout: .seconds(5), timing: CodexTiming(requestID: UUID().uuidString, operation: .respond, sink: { cancelled.record($0) }))
        try await cancellationClient.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [stalled.path, "answer/wait"], directory: root, environment: [:])
        let task = Task { try await cancellationClient.respond(input: "private-input", instructions: "private-instruction", model: "private-model", directory: root) }
        for _ in 0..<200 where !cancelled.events.contains(where: { $0.stage == .answer && $0.outcome == .started }) { try await Task.sleep(for: .milliseconds(10)) }
        precondition(cancelled.events.contains { $0.stage == .answer && $0.outcome == .started }, "cancellation happens during actual answer wait")
        task.cancel()
        do { _ = try await task.value; preconditionFailure("cancelled answer must fail") } catch { }
        await cancellationClient.stop()
        precondition(cancelled.events.contains { $0.stage == .answer && $0.outcome == .cancelled }, "cancellation is not mislabeled as connection failure")
        precondition(!cancelled.events.contains { $0.outcome == .timeout || $0.outcome == .failure })

        let failed = TimingRecorder()
        let failureClient = CodexConnection(timeout: .seconds(5), timing: CodexTiming(requestID: UUID().uuidString, operation: .catalog, sink: { failed.record($0) }))
        try await failureClient.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, "rpc"], directory: directory, environment: [:])
        do { _ = try await failureClient.account(); preconditionFailure("synthetic RPC failure must fail") }
        catch let error as CodexConnectionError { precondition(error == .rpc(-32001)) }
        await failureClient.stop()
        precondition(failed.events.contains { $0.stage == .accountRead && $0.outcome == .failure }, "RPC failure is distinct from cancellation and timeout")
        let launchFailure = TimingRecorder()
        let unavailable = CodexConnection(timing: CodexTiming(requestID: UUID().uuidString, operation: .catalog, sink: { launchFailure.record($0) }))
        do {
            try await unavailable.start(executable: root.appendingPathComponent("missing-executable"), arguments: [], directory: root, environment: [:])
            preconditionFailure("missing executable must fail")
        } catch let error as CodexConnectionError { precondition(error == .unavailable) }
        precondition(launchFailure.events.map(\.stage) == [.launch, .launch] && launchFailure.events.map(\.outcome) == [.started, .failure], "launch failure ends its own phase without starting initialize")
        print("PASS timing: correlated private-safe stages; six isolated timeout locations; cancellation and RPC failure")
    }

    static func main() async throws {
        let script = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let dir = script.deletingLastPathComponent()
        var count = 0
        let filtered = CodexConnection.environment(["HOME": "/synthetic", "CODEX_HOME": "/synthetic-config", "CODEX_SESSION_ID": "removed", "OPENAI_API_KEY": "removed", "PATH": "/usr/bin"])
        precondition(filtered == ["HOME": "/synthetic", "CODEX_HOME": "/synthetic-config", "PATH": "/usr/bin"]); count += 1
        for mode in ["ok", "signedout", "api", "rpc", "missing", "closed", "hang", "malformed", "oversized", "brokenpipe"] {
            let client = CodexConnection(timeout: .seconds(mode == "hang" ? 1 : 5))
            do {
                try await client.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, mode], directory: dir, environment: [:])
                let state = try await client.account()
                if mode == "ok" { precondition(state == .chatGPT) }
                else if mode == "signedout" { precondition(state == .signedOut) }
                else { fatalError("Expected error: \(mode)") }
            } catch let error as CodexConnectionError {
                let expected: [String: CodexConnectionError] = ["api": .unsupportedAccount, "rpc": .rpc(-32001), "missing": .malformed, "closed": .closed, "hang": .timeout, "malformed": .malformed, "oversized": .oversized, "brokenpipe": .closed]
                precondition(error == expected[mode], "\(mode): \(error)")
            }
            await client.stop(); count += 1
        }
        let client = CodexConnection(timeout: .seconds(5))
        let pending = Task { try await client.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, "hang"], directory: dir, environment: [:]) }
        try await Task.sleep(for: .milliseconds(100)); pending.cancel()
        do { try await pending.value; fatalError("Cancellation should fail") } catch {}
        await client.stop(); count += 1
        // Reuse after cancellation: stale termination must not close a new child.
        try await client.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, "ok"], directory: dir, environment: [:])
        let resumed = try await client.account(); precondition(resumed == .chatGPT)
        await client.stop(); count += 1
        for mode in ["response", "longresponse", "fragmented", "answerlimit", "turnfail", "turnhang"] {
            let client = CodexConnection(timeout: .seconds(5))
            try await client.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, mode], directory: dir, environment: [:])
            let catalog = try await client.catalog()
            precondition(catalog.models.count == 1 && catalog.preferred == "synthetic-model")
            let task = Task { try await client.respond(input: "synthetic input", instructions: "Synthetic", model: catalog.preferred, directory: dir) }
            if mode == "turnhang" { try await Task.sleep(for: .milliseconds(150)); task.cancel() }
            do {
                let text = try await task.value
                precondition(text == (mode == "longresponse" ? String(repeating: "x", count: 900 * 1024) : "synthetic answer"))
                precondition(["response", "longresponse", "fragmented"].contains(mode))
            } catch let error as CodexConnectionError {
                precondition((mode == "turnfail" && error == .incomplete) || (mode == "turnhang" && error == .closed) || (mode == "answerlimit" && error == .oversized), "\(mode): \(error)")
            } catch is CancellationError { precondition(mode == "turnhang") }
            await client.stop(); count += 1
        }
        let promptClient = CodexConnection(timeout: .seconds(5))
        try await promptClient.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, "response"], directory: dir, environment: [:])
        for size in [9000, MingTextLimits.maximumInstructionBytes] {
            let response = try await promptClient.respond(input: "synthetic input", instructions: String(repeating: "x", count: size), model: "synthetic-model", directory: dir)
            precondition(response == "synthetic answer", "long saved prompt reaches the synthetic RPC peer")
            count += 1
        }
        do {
            _ = try await promptClient.respond(input: "synthetic input", instructions: String(repeating: "x", count: MingTextLimits.maximumInstructionBytes + 1), model: "synthetic-model", directory: dir)
            fatalError("oversized prompt should fail before a turn")
        } catch { precondition(error.localizedDescription == MingTextLimits.instructionTooLongMessage); count += 1 }
        await promptClient.stop()
        try await backpressureTests(script: script, directory: dir)
        try await timingTests(script: script, directory: dir)
        print("PASS \(count) offline connection scenarios; no real Codex, account or model")
    }
}
