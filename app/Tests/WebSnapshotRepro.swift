import AppKit

// Explicit URL only; isolated from Dump's library and clipboard. No visible UI.
@main @MainActor struct WebSnapshotRepro {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let url = URL(string: CommandLine.arguments[1])!
            for attempt in 1...3 {
                print("capture \(attempt) started")
                do {
                    let snapshot = try await WebSnapshotCapture().capture(url)
                    print("capture \(attempt) produced \(snapshot.png.count) bytes")
                } catch {
                    print("capture \(attempt) ended: \(error)")
                }
                try? await Task.sleep(for: .seconds(1))
            }
            precondition(NSApp.windows.allSatisfy { !$0.isVisible })
            print("completed without process crash")
            exit(0)
        }
        RunLoop.main.run()
    }
}
