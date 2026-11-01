import Foundation
import OSLog

struct CodexTimingEvent: Codable, Equatable, Sendable {
    let requestID: String
    let operation: CodexTiming.Operation
    let stage: CodexTiming.Stage
    let outcome: CodexTiming.Outcome
    let elapsedMilliseconds: Double
}

// Fixed fields only: no RPC parameters, model/account identifiers, paths,
// response content, raw errors or stderr can enter this diagnostic channel.
struct CodexTiming: Sendable {
    enum Operation: String, Codable, Sendable { case catalog, respond }
    enum Stage: String, Codable, Sendable {
        case launch, initialize
        case accountRead = "account/read", modelList = "model/list"
        case threadStart = "thread/start", turnStart = "turn/start"
        case answer = "answer/wait", total, clientTotal
    }
    enum Outcome: String, Codable, Sendable {
        case started, success, timeout, cancelled, failure
        static func failure(_ error: Error, cancelled: Bool) -> Self {
            if cancelled || error is CancellationError { return .cancelled }
            if error as? CodexConnectionError == .timeout { return .timeout }
            return .failure
        }
    }
    struct Span: Sendable {
        private let timing: CodexTiming
        private let stage: Stage
        private let started: ContinuousClock.Instant
        fileprivate init(timing: CodexTiming, stage: Stage) {
            self.timing = timing; self.stage = stage; started = .now
        }
        func finish(outcome: Outcome) {
            let elapsed = started.duration(to: .now).components
            timing.record(stage, outcome: outcome, milliseconds: Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1_000_000_000_000_000)
        }
    }
    private let requestID: String
    private let operation: Operation
    private let sink: @Sendable (CodexTimingEvent) -> Void
    private static let logger = Logger(subsystem: "local.ledge.desktop", category: "CodexTiming")

    init(requestID: String, operation: Operation, sink: @escaping @Sendable (CodexTimingEvent) -> Void = CodexTiming.log) {
        // XPC validates IDs before Worker runs. Keep the diagnostic boundary
        // safe even when reused by an in-process caller with an invalid ID.
        self.requestID = UUID(uuidString: requestID)?.uuidString ?? "invalid"
        self.operation = operation; self.sink = sink
    }
    func begin(_ stage: Stage) -> Span {
        let span = Span(timing: self, stage: stage)
        record(stage, outcome: .started, milliseconds: 0)
        return span
    }
    private func record(_ stage: Stage, outcome: Outcome, milliseconds: Double) {
        sink(CodexTimingEvent(requestID: requestID, operation: operation, stage: stage, outcome: outcome, elapsedMilliseconds: milliseconds))
    }
    private static func log(_ event: CodexTimingEvent) {
        do {
            let message = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
            logger.notice("\(message, privacy: .public)")
        } catch { logger.error("Codex timing event could not be encoded") }
    }
}
