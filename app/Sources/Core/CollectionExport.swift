import Foundation

struct CollectionExportProgress: Sendable {
    var directory: URL
    var completed: Int
    var total: Int
}

extension Library {
    func exportCollections(_ snapshot: CollectionRemovalSnapshot, to directory: URL,
                           progress: @Sendable (CollectionExportProgress) async -> Void) async throws -> URL {
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        let destination = directory.resolvingSymlinksInPath().path, own = root.resolvingSymlinksInPath().path
        guard destination != own, !destination.hasPrefix(own + "/") else { throw LibraryError.invalid("不能导出到 \(AppIdentity.name) 内部数据目录。") }
        let items = index.items.filter { snapshot.summary.uniqueIDs.contains($0.id) }
        guard Set(items.map(\.id)) == snapshot.summary.uniqueIDs else { throw LibraryError.invalid("材料有变化，请返回后重新确认。") }
        let files = try items.map { ($0, try url(for: $0)) }
        let fm = FileManager.default
        func unused(_ parent: URL, _ name: String) -> URL {
            var target = parent.appendingPathComponent(name), n = 2
            while fm.fileExists(atPath: target.path) { target = parent.appendingPathComponent("\(name) (\(n))"); n += 1 }
            return target
        }
        try Task.checkCancellation()
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let output = unused(directory, "\(AppIdentity.name)导出 " + formatter.string(from: Date()))
        try fm.createDirectory(at: output, withIntermediateDirectories: false)
        var folders: [UUID: URL] = [:]
        for group in snapshot.collections where items.contains(where: { $0.collectionID == group.id }) {
            var name = group.name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "\0", with: "_")
            if name == "." || name == ".." { name = "收集区" }
            let folder = unused(output, name)
            try fm.createDirectory(at: folder, withIntermediateDirectories: false); folders[group.id] = folder
        }
        await progress(CollectionExportProgress(directory: output, completed: 0, total: files.count))
        for (n, entry) in files.enumerated() {
            try Task.checkCancellation()
            let (item, source) = entry
            guard let folder = folders[item.collectionID] else { throw LibraryError.invalid("材料所属收集区已变化。") }
            let ext = (item.filename as NSString).pathExtension, base = (item.filename as NSString).deletingPathExtension
            var target = folder.appendingPathComponent(item.filename), suffix = 2
            while fm.fileExists(atPath: target.path) {
                target = folder.appendingPathComponent("\(base) (\(suffix))" + (ext.isEmpty ? "" : ".\(ext)")); suffix += 1
            }
            try fm.copyItem(at: source, to: target)
            await progress(CollectionExportProgress(directory: output, completed: n + 1, total: files.count))
        }
        try Task.checkCancellation()
        return output
    }
}
