import AppKit

// Frontend-only probe. Build with a distinct sandbox identity and synthetic data.
@main @MainActor struct MigrationAuthorizationProbe {
    static func main() {
        guard CommandLine.arguments.count == 2 else { fatalError("Expected synthetic Application Support parent") }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        app.activate(ignoringOtherApps: true)
        do {
            let root = try LibraryLocation.open(expectedParent: URL(fileURLWithPath: CommandLine.arguments[1]))
            _ = try Library(root: root)
            print("PASS authorized synthetic migration and library open")
        } catch {
            let alert = NSAlert(); alert.messageText = "Synthetic migration probe"; alert.informativeText = error.localizedDescription
            alert.runModal(); exit(1)
        }
    }
}
