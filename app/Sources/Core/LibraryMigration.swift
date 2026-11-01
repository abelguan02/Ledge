import Foundation
import CryptoKit

enum LibraryMigration {
    static func importPreferences(_ values: [String: Any], into defaults: UserDefaults, domain: String) {
        // Directory authorization creates navigation defaults before migration.
        // Imported values must win while new-only keys remain intact.
        var merged = defaults.persistentDomain(forName: domain) ?? [:]
        merged.merge(values, uniquingKeysWith: { _, imported in imported })
        merged["ledge.preferencesMigrated"] = true
        defaults.setPersistentDomain(merged, forName: domain)
    }
    struct Report: Codable {
        let collections: Int
        let materials: Int
        let files: Int
        let indexSHA256: String
    }
    // Do not initialize Library on the source: its recovery pass may write.
    static func snapshot(_ root: URL) throws -> [String: String] {
        let fm = FileManager.default
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw LibraryError.invalid("迁移目录不能是符号链接。")
        }
        var result: [String: String] = [:]
        func walk(_ directory: URL, prefix: String = "") throws {
            for url in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]) {
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
                let relative = prefix + url.lastPathComponent
                guard values.isSymbolicLink != true else { throw LibraryError.invalid("旧库含符号链接，迁移已停止：\(relative)") }
                if values.isDirectory == true { result[relative] = "directory"; try walk(url, prefix: relative + "/") }
                else if values.isRegularFile == true {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    var hash = SHA256()
                    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
                    result[relative] = hash.finalize().map { String(format: "%02x", $0) }.joined()
                } else { throw LibraryError.invalid("旧库含不支持的文件类型：\(relative)") }
            }
        }
        try walk(root)
        return result
    }
    static func copy(source: URL, destination: URL, preferences: [String: Any], beforeCommit: () throws -> Void = {}) throws -> Report {
        let fm = FileManager.default
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        let destination = destination.standardizedFileURL
        guard destination.path != source.path, !destination.path.hasPrefix(source.path + "/"),
              !fm.fileExists(atPath: destination.path) else { throw LibraryError.invalid("新目录已存在或与旧库重叠；未覆盖任何数据。") }
        let before = try snapshot(source)
        let indexData = try Data(contentsOf: source.appendingPathComponent("library.json"))
        let index = try JSONDecoder().decode(LibraryIndex.self, from: indexData)
        guard index.schema == 1, !index.collections.isEmpty else { throw LibraryError.invalid("旧库索引无效。") }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".ledge-migration-\(UUID())")
        do {
            try fm.copyItem(at: source, to: staging)
            let copied = try snapshot(staging)
            guard copied == before else { throw LibraryError.invalid("迁移副本哈希核对失败。") }
            // Validate using the existing library rules on a disposable copy only.
            let validation = staging.deletingLastPathComponent().appendingPathComponent(".ledge-validation-\(UUID())")
            do {
                try fm.copyItem(at: staging, to: validation)
                _ = try Library(root: validation)
                try fm.removeItem(at: validation)
            } catch {
                if fm.fileExists(atPath: validation.path) { try fm.removeItem(at: validation) }
                throw error
            }
            try beforeCommit()
            guard try snapshot(source) == before else { throw LibraryError.invalid("旧库在迁移期间发生变化，未启用副本。请退出旧版后重试。") }
            let report = Report(collections: index.collections.count, materials: index.items.count, files: before.values.filter { $0 != "directory" }.count, indexSHA256: before["library.json"]!)
            guard before["migration-preferences.plist"] == nil, before["migration-report.json"] == nil else { throw LibraryError.invalid("旧库含同名迁移记录，未覆盖。") }
            try PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0).write(to: staging.appendingPathComponent("migration-preferences.plist"), options: .atomic)
            try JSONEncoder().encode(report).write(to: staging.appendingPathComponent("migration-report.json"), options: .atomic)
            try fm.moveItem(at: staging, to: destination)
            return report
        } catch {
            if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
            throw error
        }
    }
}
