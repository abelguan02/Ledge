import Foundation

@main struct MigrationTests {
    static func main() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("ledge-migration-test-\(UUID())")
        defer { try? fm.removeItem(at: base) }
        let old = base.appendingPathComponent("Dump"), new = base.appendingPathComponent("Ledge")
        let library = try Library(root: old)
        _ = try await library.importText("Synthetic material", collection: await library.index.currentCollection)
        let second = try await library.createCollection("Second synthetic collection")
        _ = try await library.importText("第二个合成材料", collection: second.id)
        let nested = old.appendingPathComponent("synthetic-folder/empty")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([0, 255, 127, 1]).write(to: nested.deletingLastPathComponent().appendingPathComponent("binary.dat"))
        let before = try LibraryMigration.snapshot(old)
        let preferences: [String: Any] = ["syntheticShortcut": "cmd-shift-L", "syntheticAIEnabled": false]
        let report = try LibraryMigration.copy(source: old, destination: new, preferences: preferences)
        precondition(report.collections == 2 && report.materials == 2)
        let after = try LibraryMigration.snapshot(old)
        precondition(after == before)
        let oldIndex = try Data(contentsOf: old.appendingPathComponent("library.json"))
        let newIndex = try Data(contentsOf: new.appendingPathComponent("library.json"))
        precondition(oldIndex == newIndex)
        let migrated = try NSDictionary(contentsOf: new.appendingPathComponent("migration-preferences.plist"), error: ())
        precondition(migrated["syntheticShortcut"] as? String == "cmd-shift-L")
        let domain = "local.ledge.preference-migration-test.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let bookmark = Data([1, 2, 3])
        defaults.setPersistentDomain(["NSOSPLastRootDirectory": "new authorization location", "ledge.libraryLocation": bookmark], forName: domain)
        LibraryMigration.importPreferences(["NSOSPLastRootDirectory": "old location", "aiEnabled": false, "dockEdge": "left"], into: defaults, domain: domain)
        let reloaded = UserDefaults(suiteName: domain)!
        precondition(reloaded.string(forKey: "NSOSPLastRootDirectory") == "old location")
        precondition(reloaded.object(forKey: "aiEnabled") as? Bool == false)
        precondition(reloaded.string(forKey: "dockEdge") == "left")
        precondition(reloaded.data(forKey: "ledge.libraryLocation") == bookmark)
        precondition(reloaded.bool(forKey: "ledge.preferencesMigrated"))
        print("PASS preference import replaces authorization defaults, preserves new directory bookmark, persists legacy settings")
        do { _ = try LibraryMigration.copy(source: old, destination: new, preferences: [:]); fatalError("Overwrite accepted") } catch {}
        let failed = base.appendingPathComponent("Failed")
        do {
            _ = try LibraryMigration.copy(source: old, destination: failed, preferences: [:], beforeCommit: { throw LibraryError.invalid("Injected failure") })
            fatalError("Failure ignored")
        } catch {}
        precondition(!fm.fileExists(atPath: failed.path))
        let afterFailure = try LibraryMigration.snapshot(old)
        precondition(afterFailure == before)
        let changed = base.appendingPathComponent("Changed")
        do {
            _ = try LibraryMigration.copy(source: old, destination: changed, preferences: [:], beforeCommit: {
                try Data("changed".utf8).write(to: old.appendingPathComponent("mutation"))
            })
            fatalError("Source mutation ignored")
        } catch {}
        precondition(!fm.fileExists(atPath: changed.path))
        let link = old.appendingPathComponent("external-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: base)
        do { _ = try LibraryMigration.copy(source: old, destination: changed, preferences: [:]); fatalError("Symlink accepted") } catch {}
        try fm.removeItem(at: link)
        try Data("invalid index".utf8).write(to: old.appendingPathComponent("library.json"))
        do { _ = try LibraryMigration.copy(source: old, destination: changed, preferences: [:]); fatalError("Invalid index accepted") } catch {}
        precondition(!fm.fileExists(atPath: changed.path))
        precondition(AppIdentity.displayName(languages: ["zh-Hant"]) == "搁这儿")
        precondition(AppIdentity.displayName(languages: ["en", "zh-Hans"]) == "Ledge")
        print("PASS copy-only migration, index/count/hash verification, preferences, collision, rollback, source mutation, localization")
    }
}
