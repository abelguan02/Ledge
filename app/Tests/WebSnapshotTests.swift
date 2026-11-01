import AppKit

@main @MainActor struct WebSnapshotTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print("FAIL WebSnapshot: \(error)"); exit(1) }
        }
        RunLoop.main.run()
    }
    static func run() async throws {
        let base = URL(string: "http://localhost:\(CommandLine.arguments[1])")!
        func url(_ path: String) -> URL { base.appendingPathComponent(path) }
        for _ in 0..<2 {
            let value = try await WebSnapshotCapture().capture(url("page"))
            precondition(value.title == "1280x800:fresh" && value.siteName == "合成站点", "fresh cookie jar and delayed metadata")
            let bitmap = NSBitmapImageRep(data: value.png)!
            precondition(bitmap.pixelsWide == 1280 && bitmap.pixelsHigh == 800)
            let top = bitmap.colorAt(x: 100, y: 100)!.usingColorSpace(.deviceRGB)!
            let bottom = bitmap.colorAt(x: 100, y: 700)!.usingColorSpace(.deviceRGB)!
            precondition(top.redComponent > 0.9 && top.blueComponent < 0.1 && bottom.blueComponent > 0.9 && bottom.redComponent < 0.1)
        }
        for (path, expected) in [("isolated-denied", WebSnapshotError.failed), ("token/consume", .needsConsent), ("redirect", .needsConsent), ("restricted", .needsLogin), ("gate", .needsLogin), ("download", .failed)] {
            do { _ = try await WebSnapshotCapture().capture(url(path)); preconditionFailure("unexpected capture: \(path)") }
            catch let error as WebSnapshotError { precondition(error == expected, "wrong classification for \(path): \(error)") }
        }
        let requestsBefore = try await URLSession.shared.data(from: url("requests")).0
        let pathsBefore = try JSONDecoder().decode([String].self, from: requestsBefore)
        precondition(!pathsBefore.contains("/token/consume"), "automatic capture must not consume a one-time redirect")
        _ = try await WebSnapshotCapture().capture(url("token/consume"), permitsOneTime: true)
        _ = try await WebSnapshotCapture().capture(url("popup"))
        let requestsAfter = try await URLSession.shared.data(from: url("requests")).0
        let pathsAfter = try JSONDecoder().decode([String].self, from: requestsAfter)
        precondition(pathsAfter.filter { $0 == "/token/consume" }.count == 1 && !pathsAfter.contains("/popup-target"))
        let cancel = Task { try await WebSnapshotCapture().capture(url("cancel")) }
        try await Task.sleep(for: .milliseconds(300)); cancel.cancel()
        do { _ = try await cancel.value; preconditionFailure("capture ignored cancellation") } catch is CancellationError { }
        let started = Date()
        do { _ = try await WebSnapshotCapture().capture(url("hang")); preconditionFailure("capture ignored timeout") }
        catch WebSnapshotError.timedOut { precondition(Date().timeIntervalSince(started) >= 19 && Date().timeIntervalSince(started) < 23) }
        precondition(NSApp.windows.allSatisfy { !$0.isVisible }, "capture must never present a window")
        print("PASS 1280×800 rendered pixels, delayed metadata, per-capture cookies, one-time input/redirect guard, manual consent, login gates, no downloads/popups/dialogs, cancellation, 20s deadline and no visible windows")
    }
}
