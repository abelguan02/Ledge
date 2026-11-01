import AppKit

// Explicit QA opt-in. Only window/responder metadata and command key codes;
// never clipboard values, ordinary typed text, material names or contents.
@MainActor enum UIFocusTrace {
    static let enabled = ProcessInfo.processInfo.environment["LEDGE_TRACE_FOCUS"] == "1"
    private static var monitor: Any?
    private static var timer: Timer?
    private static var previous = ""
    static func snapshot(_ event: String) {
        guard enabled else { return }
        let key = NSApp.keyWindow
        let state = "active=\(NSApp.isActive) key=\(key?.windowNumber ?? -1) responder=\(key?.firstResponder.map { String(describing: type(of: $0)) } ?? "none")"
        FileHandle.standardError.write(Data("UIFocus \(event) \(state)\n".utf8))
    }
    static func start() {
        guard enabled else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                let command = !event.modifierFlags.intersection([.command, .option, .control]).isEmpty || event.keyCode == 53
                snapshot(command ? "key=\(event.keyCode) flags=\(event.modifierFlags.rawValue)" : "plain-key")
            }
            return event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            MainActor.assumeIsolated {
                let value = "\(NSApp.isActive)-\(NSApp.keyWindow?.windowNumber ?? -1)-\(String(describing: NSApp.keyWindow?.firstResponder))"
                if value != previous { previous = value; snapshot("focus-change") }
            }
        }
    }
}
