import Foundation

// Explicit, bounded diagnostics. Never starts a thread/turn or prints account data.
@main struct ConnectionProbe {
    static func main() async {
        let client = CodexConnection(timeout: .seconds(20))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dump-connection-probe-\(UUID())")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let launch = try CodexLaunch.make(directory: directory)
            print("STEP initialize")
            try await client.start(executable: launch.executable, arguments: launch.arguments, directory: directory, environment: launch.environment)
            print("PASS initialize; STEP account")
            _ = try await client.account()
            print("PASS account; STEP model catalog")
            let catalog = try await client.catalog()
            print("PASS catalog: \(catalog.models.count) models; no model request sent")
        } catch { print("FAIL \(error.localizedDescription)") }
        await client.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}
