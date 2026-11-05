import AppKit

// Access is granted by the user through system panels; no sandbox exception.
@MainActor enum LibraryLocation {
    static func requireOldAppStopped() throws {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "local.dump.desktop").isEmpty else {
            throw LibraryError.invalid("请先退出旧版 Dump，再打开\(InterfaceText(key: "搁这儿"))。旧库尚未迁移。")
        }
    }
    static func choose(_ message: String) throws -> URL {
        let panel = NSOpenPanel()
        panel.message = message; panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { throw LibraryError.invalid("已取消目录授权；未打开收集区。") }
        return url
    }
    static func open(expectedParent: URL? = nil, language: AppLanguage = .simplified) throws -> URL {
        try requireOldAppStopped()
        let defaults = UserDefaults.standard
        if let bookmark = defaults.data(forKey: "ledge.libraryLocation") {
            do {
                var stale = false
                let root = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
                guard root.startAccessingSecurityScopedResource() else { throw LibraryError.invalid("无法访问已授权的数据目录。") }
                if stale { defaults.set(try root.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil), forKey: "ledge.libraryLocation") }
                return root
            } catch {
                let alert = NSAlert(); alert.messageText = language.label("需要重新授权数据目录")
                alert.informativeText = InterfaceText(error: error).rendered(language)
                alert.addButton(withTitle: language.label("重新选择目录")); alert.addButton(withTitle: language.label("取消"))
                guard alert.runModal() == .alertFirstButtonReturn else { throw error }
                defaults.removeObject(forKey: "ledge.libraryLocation")
            }
        }
        let parent = try choose(language.label("请选择用户目录中的 Library/Application Support，用于保存 Ledge。"))
        let accessing = parent.startAccessingSecurityScopedResource()
        defer { if accessing { parent.stopAccessingSecurityScopedResource() } }
        // The selected parent remains authoritative; enforce the requested location.
        let userHome = FileManager.default.homeDirectoryForCurrentUser
        // In a sandbox homeDirectoryForCurrentUser may name its container. getpwuid
        // supplies the user's real home without inspecting their files.
        let home = getpwuid(getuid()).map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir)) } ?? userHome
        let expected = (expectedParent ?? home.appendingPathComponent("Library/Application Support")).resolvingSymlinksInPath()
        guard parent.resolvingSymlinksInPath().path == expected.path else { throw LibraryError.invalid("请选择 ~/Library/Application Support；未在其他位置创建数据。") }
        let root = parent.appendingPathComponent("Ledge")
        var created = false
        if !FileManager.default.fileExists(atPath: root.path) {
            let alert = NSAlert()
            alert.messageText = language.label("迁移旧版 Dump 的收集区？")
            alert.informativeText = language.label("将复制并核对旧库，原目录保留。请选择旧库所在的 Library 文件夹；迁移完成前请保持旧版退出。")
            alert.addButton(withTitle: language.label("选择旧库并迁移")); alert.addButton(withTitle: language.label("取消")); alert.addButton(withTitle: language.label("我没有旧库，创建空库"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                let oldData = try choose(language.label("请选择旧库所在的 Library 文件夹：通常是 ~/Library/Containers/local.dump.desktop/Data/Library；非沙盒旧库则选 ~/Library。只读取 Dump 收集区及旧偏好设置。"))
                let oldAccess = oldData.startAccessingSecurityScopedResource()
                defer { if oldAccess { oldData.stopAccessingSecurityScopedResource() } }
                let source = oldData.appendingPathComponent("Application Support/Dump")
                let preferenceFile = oldData.appendingPathComponent("Preferences/local.dump.desktop.plist")
                var preferences: [String: Any] = [:]
                do {
                    let data = try Data(contentsOf: preferenceFile)
                    guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw LibraryError.invalid("旧偏好设置格式无效。") }
                    preferences = values
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile { }
                _ = try LibraryMigration.copy(source: source, destination: root, preferences: preferences, beforeCommit: requireOldAppStopped)
            case .alertThirdButtonReturn:
                _ = try Library(root: root)
                created = true
            default: throw LibraryError.invalid("已取消迁移，旧库未改变。")
            }
        }
        // Retry can adopt a fully committed copy after interruption, never overwrite it.
        let saved = root.appendingPathComponent("migration-preferences.plist")
        if FileManager.default.fileExists(atPath: saved.path), defaults.bool(forKey: "ledge.preferencesMigrated") == false {
            guard let values = try PropertyListSerialization.propertyList(from: Data(contentsOf: saved), format: nil) as? [String: Any] else { throw LibraryError.invalid("迁移偏好设置无法读取。") }
            LibraryMigration.importPreferences(values, into: defaults, domain: AppIdentity.identifier)
        }
        let bookmark = try root.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        var stale = false
        let authorized = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard authorized.startAccessingSecurityScopedResource() else { throw LibraryError.invalid("新库已完整保存，但目录授权无法保留；请重新打开后授权。") }
        defaults.set(bookmark, forKey: "ledge.libraryLocation")
        if created { defaults.set(true, forKey: "ledge.onboardingEligible") }
        return authorized
    }
}
