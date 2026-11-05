import Foundation
import Darwin

// Copied from Ming then adapted: retain copy-only imports, controlled paths and
// atomic manifest commits. Dump adds canvas placement and one durable undo slot.
private struct StoragePaths: Sendable {
    let root: URL
    var manifest: URL { root.appendingPathComponent("library.json") }
    func requireSafe(_ url: URL) throws {
        do {
            if try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeSymbolicLink {
                throw LibraryError.invalid("存储路径包含符号链接，操作已停止。")
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { }
    }
    func directory(_ id: UUID, trash: Bool = false) throws -> URL {
        let base = root.appendingPathComponent(trash ? "trash" : "objects")
        let dir = base.appendingPathComponent(id.uuidString)
        for path in [root, base, dir] { try requireSafe(path) }
        return dir
    }
    func payload(_ item: Material, trash: Bool = false) throws -> URL {
        guard !item.filename.isEmpty, ![".", ".."].contains(item.filename), !item.filename.contains("/"), !item.filename.contains("\0") else { throw LibraryError.invalid("材料路径无效。") }
        let url = try directory(item.id, trash: trash).appendingPathComponent(item.filename)
        try requireSafe(url); return url
    }
    func preview(_ item: Material, trash: Bool = false) throws -> URL? {
        guard let name = item.linkPreview?.filename else { return nil }
        guard item.kind == .link, name.hasPrefix("web-preview-"), name.hasSuffix(".png"),
              UUID(uuidString: String(name.dropFirst(12).dropLast(4))) != nil else { throw LibraryError.invalid("网页预览路径无效。") }
        let url = try directory(item.id, trash: trash).appendingPathComponent(name)
        try requireSafe(url); return url
    }
    func reconcile(_ index: LibraryIndex) throws {
        // Manifest commits precede moves. Reopening finishes an interrupted
        // clear or undo in the direction recorded by that atomic commit.
        for (items, trashed) in [(index.items, false), (index.undo?.items ?? [], true)] {
            for item in items {
                let pairs = [(try payload(item, trash: trashed), try payload(item, trash: !trashed))] +
                    (try preview(item, trash: trashed).map { [( $0, try preview(item, trash: !trashed)! )] } ?? [])
                for (target, source) in pairs where !FileManager.default.fileExists(atPath: target.path) {
                    // A missing copy is a recoverable material state, not a
                    // corrupt library. Retain its record, including undo data.
                    guard FileManager.default.fileExists(atPath: source.path) else { continue }
                    let destination = target.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: source, to: target)
                    let sourceDirectory = source.deletingLastPathComponent()
                    if try FileManager.default.contentsOfDirectory(atPath: sourceDirectory.path).isEmpty {
                        try FileManager.default.removeItem(at: sourceDirectory)
                    }
                }
            }
        }
        for id in index.garbage {
            for trash in [false, true] {
                let dir = try directory(id, trash: trash)
                if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
            }
        }
    }
}

enum RemovalResult<Snapshot: Sendable>: Sendable {
    case changed(Snapshot)
    case removed(cleanupWarning: InterfaceText?)
}

actor Library {
    let root: URL
    private let paths: StoragePaths
    private var limits: CapacityLimits
    func updateLimits(_ value: CapacityLimits) { limits = value }
    private let makeBookmark: @Sendable (URL) throws -> Data
    private let copyPayload: @Sendable (URL, URL) throws -> Void
    private(set) var index: LibraryIndex
    init(root: URL, limits: CapacityLimits = CapacityLimits(), makeBookmark: @escaping @Sendable (URL) throws -> Data = {
        try $0.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }, copyPayload: @escaping @Sendable (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }) throws {
        self.root = root.standardizedFileURL
        paths = StoragePaths(root: root.standardizedFileURL); self.limits = limits; self.makeBookmark = makeBookmark; self.copyPayload = copyPayload
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try paths.requireSafe(root)
        for name in ["objects", "trash"] {
            let dir = root.appendingPathComponent(name)
            try paths.requireSafe(dir); try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try paths.requireSafe(paths.manifest)
        if fm.fileExists(atPath: paths.manifest.path) {
            var loaded = try JSONDecoder().decode(LibraryIndex.self, from: Data(contentsOf: paths.manifest))
            // Preserve phase-four layouts; only newly collected links use 216×192.
            for n in loaded.items.indices where loaded.items[n].kind == .link && loaded.items[n].linkPreview == nil {
                if loaded.items[n].displaySize == nil { loaded.items[n].displaySize = CanvasSize(width: 216, height: 96) }
                loaded.items[n].linkPreview = LinkPreview(state: .failed)
            }
            if var undo = loaded.undo {
                for n in undo.items.indices where undo.items[n].kind == .link && undo.items[n].linkPreview == nil {
                    if undo.items[n].displaySize == nil { undo.items[n].displaySize = CanvasSize(width: 216, height: 96) }
                    undo.items[n].linkPreview = LinkPreview(state: .failed)
                }
                loaded.undo = undo
            }
            let ids = loaded.items.map(\.id) + (loaded.undo?.items.map(\.id) ?? []) + loaded.garbage
            var totalBytes: Int64 = 0
            for item in loaded.items + (loaded.undo?.items ?? []) {
                let cacheBytes = item.linkPreview?.byteCount ?? 0
                guard item.byteCount >= 0, cacheBytes >= 0, item.byteCount <= Int64.max - cacheBytes,
                      totalBytes <= Int64.max - item.byteCount - cacheBytes,
                      item.linkPreview == nil || item.kind == .link else { throw LibraryError.invalid("材料或预览容量记录无效。") }
                totalBytes += item.byteCount + cacheBytes
            }
            guard loaded.schema == 1, !loaded.collections.isEmpty, Set(ids).count == ids.count,
                  Set(loaded.collections.map(\.id)).count == loaded.collections.count,
                  loaded.collections.contains(where: { $0.id == loaded.currentCollection }),
                  loaded.items.allSatisfy({ item in loaded.collections.contains { $0.id == item.collectionID } && item.position.x.isFinite && item.position.y.isFinite && item.byteCount >= 0 && (item.displaySize.map { CardResize.valid($0, kind: item.kind) } ?? true) }) else { throw LibraryError.invalid("索引无法安全读取，原内容保留。") }
            guard CardStacks.valid(loaded.items) else { throw LibraryError.invalid("堆叠关系无法安全读取，原内容保留。") }
            index = loaded; try paths.reconcile(index)
        } else {
            index = LibraryIndex(); try JSONEncoder().encode(index).write(to: paths.manifest, options: .atomic)
        }
    }
    private func save(_ next: LibraryIndex) throws {
        try paths.requireSafe(paths.manifest)
        try JSONEncoder().encode(next).write(to: paths.manifest, options: .atomic)
        index = next
    }
    func url(for item: Material) throws -> URL {
        let url = try paths.payload(item)
        guard FileManager.default.fileExists(atPath: url.path) else { throw LibraryError.invalid("副本已丢失。可以移除这条记录，其他材料不受影响。") }
        return url
    }
    func missingCopies() throws -> Set<UUID> {
        try Set(index.items.filter { !FileManager.default.fileExists(atPath: try paths.payload($0).path) }.map(\.id))
    }
    // File promises can be the only copy of generated content. Failed or
    // cancelled imports must outlive the temporary directory and app process.
    func retainPromisedFiles(from directory: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        try paths.requireSafe(directory)
        guard try !FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else {
            try FileManager.default.removeItem(at: directory); return nil
        }
        let recovery = root.appendingPathComponent("recovered-promises")
        try paths.requireSafe(recovery)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        let target = recovery.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: directory, to: target)
        return target
    }
    func promisedRecoveries() throws -> [URL] {
        let directory = root.appendingPathComponent("recovered-promises")
        try paths.requireSafe(directory)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter {
            try paths.requireSafe($0)
            return try !FileManager.default.contentsOfDirectory(atPath: $0.path).isEmpty
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    func used(in collection: UUID) -> Int64 { index.items.filter { $0.collectionID == collection }.reduce(0) { $0 + $1.byteCount + ($1.linkPreview?.byteCount ?? 0) } }
    private func capacity(_ count: Int64, collection: UUID, hasCopiedPayload: Bool = false, replacing: Int64 = 0) throws {
        guard index.collections.contains(where: { $0.id == collection }) else { throw LibraryError.invalid("收集区已不存在。") }
        let values = try FileManager.default.attributesOfFileSystem(forPath: root.path)
        guard let available = (values[.systemFreeSize] as? NSNumber)?.int64Value else { throw LibraryError.invalid("无法读取磁盘剩余空间。") }
        try limits.validate(incoming: count, used: used(in: collection) - replacing, available: available, hasCopiedPayload: hasCopiedPayload)
    }
    private func positioned(_ item: Material, preferred: CanvasPoint?) -> Material {
        var item = item
        item.position = Placement.locate(size: item.size, occupied: CardStacks.visible(index.items.filter { $0.collectionID == item.collectionID }).map(\.rect), preferred: preferred)
        return item
    }
    private func validName(_ name: String) throws -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 80 else { throw LibraryError.invalid("请输入 1–80 个字的名称。") }
        return value
    }
    @discardableResult func createCollection(_ name: String) throws -> Collection {
        let collection = Collection(name: try validName(name))
        var next = index; next.collections.append(collection); next.currentCollection = collection.id
        try save(next); return collection
    }
    func renameCollection(_ id: UUID, name: String) throws {
        var next = index
        guard let n = next.collections.firstIndex(where: { $0.id == id }) else { throw LibraryError.invalid("收集区已不存在。") }
        next.collections[n].name = try validName(name)
        if next.undo?.collections != nil, next.undo?.replacementCollection == id { next.undo?.replacementRenamed = true }
        try save(next)
    }
    func selectCollection(_ id: UUID) throws {
        guard index.collections.contains(where: { $0.id == id }) else { throw LibraryError.invalid("收集区已不存在。") }
        var next = index; next.currentCollection = id; try save(next)
    }
    @discardableResult func importFile(_ source: URL, collection: UUID, kind: MaterialKind = .file, origin: MaterialOrigin = .importedFile,
                                      derivedFrom: UUID? = nil, preferred: CanvasPoint? = nil, metadata: MaterialSource = MaterialSource()) async throws -> Material {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let sourcePath = source.standardizedFileURL.resolvingSymlinksInPath().path
        guard root.path != sourcePath, !root.path.hasPrefix(sourcePath + "/") else { throw LibraryError.invalid("不能收纳包含 \(AppIdentity.name) 数据目录的文件夹。") }
        let measuredLimit = limits.item
        let original = try await Task.detached(priority: .utility) { try self.measurePayload(source, itemLimit: measuredLimit) }.value
        try capacity(original.bytes, collection: collection)
        var item = Material(collectionID: collection, name: source.lastPathComponent, filename: source.lastPathComponent,
                            kind: original.folder ? .folder : kind, origin: derivedFrom == nil ? origin : .result, derivedFrom: derivedFrom)
        item.sourceTitle = metadata.title; item.sourceURL = metadata.url
        if item.origin == .importedFile {
            var relationship = FileManager.URLRelationship.other
            try FileManager.default.getRelationship(&relationship, ofDirectoryAt: root, toItemAt: URL(fileURLWithPath: sourcePath))
            if relationship != .other { item.origin = .unsourced }
        }
        if item.origin == .importedFile {
            item.sourcePath = source.path
            item.sourceBookmark = try makeBookmark(source)
            item.sourceFileID = try Self.fileIdentity(source.path)
        }
        let target = try paths.payload(item)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: false)
        do {
            let copyPayload = self.copyPayload
            let actual = try await Task.detached(priority: .utility) {
                try copyPayload(source, target)
                return try self.measurePayload(target, itemLimit: measuredLimit)
            }.value
            guard actual.entries == original.entries else { throw LibraryError.invalid("复制期间内容发生变化，原件保留，请重新收纳。") }
            item.byteCount = actual.bytes
            try capacity(item.byteCount, collection: collection, hasCopiedPayload: true)
            item = positioned(item, preferred: preferred)
            var next = index; next.items.append(item); try save(next); return item
        } catch {
            do { try FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
            catch let cleanup { throw LibraryError.invalid("导入失败，临时副本清理失败：\(InterfaceText(error: cleanup))") }
            throw error
        }
    }
    private nonisolated func measurePayload(_ url: URL, itemLimit: Int64) throws -> (folder: Bool, bytes: Int64, entries: [String: Int64]) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        let top = try url.resourceValues(forKeys: keys)
        var bytes: Int64 = 0, entries: [String: Int64] = [:]
        func record(_ child: URL, relative: String) throws {
            let values = try child.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else {
                throw LibraryError.invalid("文件夹只能包含普通文件和子文件夹；符号链接或特殊文件未收纳。")
            }
            if values.isDirectory == true { entries[relative] = -1; return }
            entries[relative] = Int64(values.fileSize ?? 0)
            let charge = Int64(max(values.fileSize ?? 0, values.totalFileAllocatedSize ?? 0))
            guard charge <= itemLimit - bytes else { throw LibraryError.invalid("单个材料超过 \(bytes: itemLimit) 上限。") }
            bytes += charge
        }
        try record(url, relative: ".")
        if top.isDirectory == true {
            var failure: Error?
            guard let iterator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in failure = error; return false }) else {
                throw LibraryError.invalid("文件夹内容无法读取。")
            }
            for case let child as URL in iterator {
                try record(child, relative: String(child.path.dropFirst(url.path.count + 1)))
            }
            if let failure { throw failure }
        }
        return (top.isDirectory == true, bytes, entries)
    }
    @discardableResult func importText(_ text: String, collection: UUID, derivedFrom: UUID? = nil,
                                      origin: MaterialOrigin = .pastedText, preferred: CanvasPoint? = nil, metadata: MaterialSource = MaterialSource(),
                                      recognizeLink: Bool = true) throws -> Material {
        guard !text.isEmpty else { throw LibraryError.invalid("文字为空。") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = recognizeLink && derivedFrom == nil && Self.webURL(trimmed) != nil
        let bytes = link ? try PropertyListSerialization.data(fromPropertyList: ["URL": trimmed], format: .xml, options: 0) : Data(text.utf8)
        try capacity(Int64(bytes.count), collection: collection)
        var item = Material(collectionID: collection, name: String(trimmed.prefix(40)), filename: link ? "链接.webloc" : "文字.txt",
                            kind: link ? .link : .text, origin: derivedFrom != nil ? .result : (link ? .link : origin), derivedFrom: derivedFrom)
        item.sourceTitle = metadata.title; item.sourceURL = metadata.url
        if link, let title = metadata.title { item.name = title }
        if link, let url = Self.webURL(trimmed) { item.linkPreview = LinkPreviewPolicy.initial(url) }
        item = positioned(item, preferred: preferred)
        let target = try paths.payload(item)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: false)
        do {
            try bytes.write(to: target, options: .atomic)
            item.byteCount = Int64(max(bytes.count, try target.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0))
            try capacity(item.byteCount, collection: collection, hasCopiedPayload: true)
            var next = index; next.items.append(item); try save(next); return item
        } catch {
            do { try FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
            catch let cleanup { throw LibraryError.invalid("文字保存失败，临时副本清理失败：\(InterfaceText(error: cleanup))") }
            throw error
        }
    }
    nonisolated static func webURL(_ text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace), let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
    func text(for item: Material) throws -> String {
        let file = try url(for: item)
        if item.kind == .link {
            guard let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: String], let url = value["URL"] else { throw LibraryError.invalid("链接内容无法读取。") }
            return url
        }
        return try String(contentsOf: file, encoding: .utf8)
    }
    func previewURL(for item: Material) throws -> URL? {
        guard let url = try paths.preview(item), FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return url
    }
    // A new image is written before the manifest changes. A failed refresh
    // cannot overwrite the last good image or its metadata.
    func saveLinkPreview(_ id: UUID, png: Data, title: String?, siteName: String?) throws -> InterfaceText? {
        guard let n = index.items.firstIndex(where: { $0.id == id && $0.kind == .link }) else { return nil }
        let old = index.items[n], oldURL = try paths.preview(old)
        var next = index
        next.items[n].linkPreview = LinkPreview(state: .ready, filename: "web-preview-\(UUID()).png", title: title, siteName: siteName, capturedAt: Date())
        let target = try paths.preview(next.items[n])!
        do {
            try png.write(to: target, options: .atomic)
            let charge = Int64(max(png.count, try target.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0))
            try capacity(old.byteCount + charge, collection: old.collectionID, hasCopiedPayload: true, replacing: old.byteCount + (old.linkPreview?.byteCount ?? 0))
            next.items[n].linkPreview?.byteCount = charge
            try save(next)
        } catch {
            if FileManager.default.fileExists(atPath: target.path) {
                do { try FileManager.default.removeItem(at: target) }
                catch let cleanup { throw LibraryError.invalid("预览未更新，临时截图清理失败：\(InterfaceText(error: cleanup))") }
            }
            throw error
        }
        if let oldURL, FileManager.default.fileExists(atPath: oldURL.path) {
            do { try FileManager.default.removeItem(at: oldURL) }
            catch { return "预览已更新，旧缓存清理失败：\(InterfaceText(error: error))" }
        }
        return nil
    }
    func failLinkPreview(_ id: UUID, state: LinkPreviewState) throws {
        guard let n = index.items.firstIndex(where: { $0.id == id && $0.kind == .link }), index.items[n].linkPreview?.filename == nil else { return }
        var next = index
        next.items[n].linkPreview = LinkPreview(state: state)
        try save(next)
    }
    func move(_ id: UUID, to point: CanvasPoint) throws {
        try move([id], anchor: id, to: point)
    }
    func resize(_ id: UUID, to size: CanvasSize?) throws {
        guard let offset = index.items.firstIndex(where: { $0.id == id }), index.items[offset].kind.resizable,
              size.map({ CardResize.valid($0, kind: index.items[offset].kind) }) ?? true else {
            throw LibraryError.invalid("卡片尺寸无效。")
        }
        var next = index
        var item = next.items.remove(at: offset)
        item.displaySize = size == item.kind.size ? nil : size
        next.items.append(item)
        try save(next)
    }
    func move(_ ids: Set<UUID>, anchor id: UUID, to point: CanvasPoint) throws {
        guard point.x.isFinite, point.y.isFinite else { throw LibraryError.invalid("无效画布位置。") }
        let members = index.items.filter { ids.contains($0.id) }
        guard members.count == ids.count, let anchor = members.first(where: { $0.id == id }),
              members.allSatisfy({ $0.collectionID == anchor.collectionID }) else {
            throw LibraryError.invalid("选中的材料已变化，请重新选择后移动。")
        }
        let visible = CardStacks.visible(members)
        let visibleAnchor = visible.first { $0.id == id || (anchor.stackID != nil && $0.stackID == anchor.stackID) }!
        let positions = Placement.locateGroup(visible, anchor: visibleAnchor,
            occupied: CardStacks.visible(index.items.filter { $0.collectionID == anchor.collectionID && !ids.contains($0.id) }).map(\.rect), preferred: point)
        var next = index
        for n in next.items.indices {
            if ids.contains(next.items[n].id), let representative = visible.first(where: { $0.id == next.items[n].id || (next.items[n].stackID != nil && $0.stackID == next.items[n].stackID) }), let position = positions[representative.id] { next.items[n].position = position }
        }
        guard CardStacks.valid(next.items) else { throw LibraryError.invalid("请整摞移动，或从托盘拖出成员。") }
        next.dissolved = nil
        try save(next)
    }
    func createStack(_ ids: Set<UUID>) throws -> UUID {
        let members = index.items.filter { ids.contains($0.id) }
        guard members.count == ids.count, members.count >= 2, members.allSatisfy({ $0.stackID == nil && $0.collectionID == members[0].collectionID }) else {
            throw LibraryError.invalid("请选择同一区内至少两份未成摞的材料。")
        }
        let stack = UUID(), position = members.last!.position
        var next = index
        for (order, member) in members.enumerated() {
            let n = next.items.firstIndex { $0.id == member.id }!
            next.items[n].stackID = stack; next.items[n].stackOrder = order; next.items[n].position = position
        }
        next.dissolved = nil; try save(next); return stack
    }
    func joinStack(_ id: UUID, stack: UUID) throws {
        guard let n = index.items.firstIndex(where: { $0.id == id }), index.items[n].stackID == nil,
              let top = CardStacks.visible(index.items).first(where: { $0.stackID == stack }), top.collectionID == index.items[n].collectionID else {
            throw LibraryError.invalid("只能把单份材料加入同一区的现有堆叠。")
        }
        var next = index
        next.items[n].stackID = stack; next.items[n].stackOrder = top.stackOrder! + 1; next.items[n].position = top.position
        next.dissolved = nil; try save(next)
    }
    func detachFromStack(_ ids: Set<UUID>, to point: CanvasPoint) throws {
        let members = index.items.filter { ids.contains($0.id) }
        guard point.x.isFinite, point.y.isFinite, !members.isEmpty, members.count == ids.count,
              let stack = members[0].stackID, members.allSatisfy({ $0.stackID == stack }) else { throw LibraryError.invalid("堆叠成员已变化。") }
        var next = index
        var occupied = CardStacks.visible(next.items.filter { $0.collectionID == members[0].collectionID && !ids.contains($0.id) }).map(\.rect)
        for member in members {
            let n = next.items.firstIndex { $0.id == member.id }!
            next.items[n].stackID = nil; next.items[n].stackOrder = nil
            next.items[n].position = Placement.locate(size: member.size, occupied: occupied, preferred: point)
            occupied.append(next.items[n].rect)
        }
        CardStacks.dissolveSingletons(&next.items)
        next.dissolved = nil; try save(next)
    }
    func dissolveStack(_ id: UUID) throws {
        let members = index.items.filter { $0.stackID == id }.sorted { $0.stackOrder! < $1.stackOrder! }
        guard members.count >= 2 else { throw LibraryError.invalid("这一摞已不存在。") }
        var next = index
        var occupied = CardStacks.visible(next.items.filter { $0.collectionID == members[0].collectionID && $0.stackID != id }).map(\.rect)
        for member in members {
            let n = next.items.firstIndex { $0.id == member.id }!
            next.items[n].stackID = nil; next.items[n].stackOrder = nil
            next.items[n].position = Placement.locate(size: member.size, occupied: occupied, preferred: member.position)
            occupied.append(next.items[n].rect)
        }
        next.dissolved = UndoDissolve(collectionID: members[0].collectionID, members: members.map(StackLayout.init))
        try save(next)
    }
    func undoDissolve() throws {
        guard let undo = index.dissolved else { return }
        var next = index
        for state in undo.members {
            guard let n = next.items.firstIndex(where: { $0.id == state.id }), next.items[n].stackID == nil else { throw LibraryError.invalid("材料已变化，无法撤销解除堆叠。") }
            next.items[n].stackID = state.stackID; next.items[n].stackOrder = state.stackOrder; next.items[n].position = state.position
        }
        next.currentCollection = undo.collectionID; next.dissolved = nil; try save(next)
    }
    func clearSummary(ids: Set<UUID>) throws -> ClearSummary {
        var summary = ClearSummary()
        for item in index.items where ids.contains(item.id) {
            let category: ClearCategory
            switch item.origin {
            case .importedFile:
                if hasMatchingExternalOriginal(item) { summary.backedUp += 1; continue }; category = .missingOriginal
            case .pastedText: category = .pastedText
            case .link: category = .link
            case .result: category = .result
            case .unsourced: category = .unsourced
            }
            summary.unique[category, default: []].append(item.id)
        }
        return summary
    }
    private func hasMatchingExternalOriginal(_ item: Material) -> Bool {
        guard let path = item.sourcePath else { return false }
        var scopedURL: URL?
        if let bookmark = item.sourceBookmark {
            var stale = false
            scopedURL = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        let acquired = scopedURL?.startAccessingSecurityScopedResource() ?? false
        defer { if acquired { scopedURL?.stopAccessingSecurityScopedResource() } }
        guard let expected = item.sourceFileID, (try? Self.fileIdentity(path)) == expected,
              let payload = try? url(for: item) else { return false }
        let original = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        var relationship = FileManager.URLRelationship.other
        do { try FileManager.default.getRelationship(&relationship, ofDirectoryAt: root, toItemAt: original) }
        catch { return false }
        // An editor can change either copy in place, including files inside a folder.
        return relationship == .other && (try? Self.samePayload(original, payload)) == true
    }
    private static func samePayload(_ a: URL, _ b: URL) throws -> Bool {
        let fm = FileManager.default
        let type = try fm.attributesOfItem(atPath: a.path)[.type] as? FileAttributeType
        guard type == (try fm.attributesOfItem(atPath: b.path)[.type] as? FileAttributeType) else { return false }
        switch type {
        case .typeDirectory:
            let names = try fm.contentsOfDirectory(atPath: a.path)
            guard Set(names) == Set(try fm.contentsOfDirectory(atPath: b.path)) else { return false }
            for name in names {
                guard try samePayload(a.appendingPathComponent(name), b.appendingPathComponent(name)) else { return false }
            }
            return true
        case .typeRegular:
            guard fm.contentsEqual(atPath: a.path, andPath: b.path) else { return false }
            // contentsEqual compares only the data fork. Mac files can also store content in the resource fork.
            func forkSize(_ path: String) -> Int? {
                let size = getxattr(path, "com.apple.ResourceFork", nil, 0, 0, XATTR_NOFOLLOW)
                return size >= 0 ? size : (errno == ENOATTR ? 0 : nil)
            }
            guard let size = forkSize(a.path), size == forkSize(b.path) else { return false }
            return size == 0 || fm.contentsEqual(atPath: a.path + "/..namedfork/rsrc", andPath: b.path + "/..namedfork/rsrc")
        default: return false
        }
    }
    private static func fileIdentity(_ path: String) throws -> String {
        let values = try FileManager.default.attributesOfItem(atPath: path)
        guard [.typeRegular, .typeDirectory].contains(values[.type] as? FileAttributeType ?? .typeUnknown),
              let device = values[.systemNumber] as? NSNumber, let inode = values[.systemFileNumber] as? NSNumber else { throw LibraryError.invalid("原件身份无法读取。") }
        return "\(device.uint64Value):\(inode.uint64Value)"
    }
    @discardableResult func remove(ids: Set<UUID>, collection: UUID? = nil, actionTitle: String? = nil,
                                   expected: ClearSummary? = nil) throws -> RemovalResult<ClearSummary> {
        guard ids.isSubset(of: Set(index.items.map(\.id))) else { throw LibraryError.invalid("材料已变化，请重新确认。") }
        if let expected {
            let current = try clearSummary(ids: ids)
            guard current == expected else { return .changed(current) }
        }
        var next = index
        if let old = next.undo { next.garbage += old.items.map(\.id) }
        let oldCollection = collection.flatMap { id in next.collections.first { $0.id == id } }
        let oldCollectionIndex = collection.flatMap { id in next.collections.firstIndex { $0.id == id } }
        var replacement: UUID?
        if let collection {
            guard oldCollection != nil, !next.items.contains(where: { $0.collectionID == collection && !ids.contains($0.id) }) else { throw LibraryError.invalid("收集区内容已变化，请重新确认。") }
            next.collections.removeAll { $0.id == collection }
            if next.collections.isEmpty { next.collections = [Collection(name: "收集区")]; replacement = next.collections[0].id }
            if next.currentCollection == collection { next.currentCollection = next.collections[0].id }
        }
        next.undo = UndoRemoval(items: index.items.filter { ids.contains($0.id) }, collection: oldCollection, drafts: next.drafts.filter { ids.contains($0.sourceID) },
                               previousCurrentCollection: index.currentCollection, replacementCollection: replacement, collectionIndex: oldCollectionIndex, itemOrder: index.items.map(\.id))
        let affectedStacks = Set(index.items.filter { ids.contains($0.id) }.compactMap(\.stackID))
        next.undo?.actionTitle = actionTitle
        next.undo?.stackLayout = index.items.filter { !ids.contains($0.id) && $0.stackID.map(affectedStacks.contains) == true }.map(StackLayout.init)
        next.items.removeAll { ids.contains($0.id) }; next.drafts.removeAll { ids.contains($0.sourceID) }
        CardStacks.dissolveSingletons(&next.items); next.dissolved = nil
        try save(next)
        do { try reconcileAfterCommit(); return .removed(cleanupWarning: nil) }
        catch { return .removed(cleanupWarning: "材料已删除，但文件清理未完成：\(InterfaceText(error: error))") }
    }
    private func reconcileAfterCommit() throws {
        try paths.reconcile(index)
        if !index.garbage.isEmpty { var cleaned = index; cleaned.garbage = []; try save(cleaned) }
    }
    @discardableResult func undoRemoval() throws -> InterfaceText? {
        guard let undo = index.undo else { return nil }
        var next = index
        if let restored = undo.collections {
            if let replacement = undo.replacementCollection, undo.replacementRenamed != true, !next.items.contains(where: { $0.collectionID == replacement }), next.collections.first(where: { $0.id == replacement })?.name == "收集区" {
                next.collections.removeAll { $0.id == replacement }
            }
            let rank = Dictionary(uniqueKeysWithValues: (undo.collectionOrder ?? []).enumerated().map { ($0.element, $0.offset) })
            next.collections = (next.collections + restored).enumerated().sorted {
                (rank[$0.element.id] ?? (rank.count + $0.offset)) < (rank[$1.element.id] ?? (rank.count + $1.offset))
            }.map(\.element)
        } else if let group = undo.collection {
            if let replacement = undo.replacementCollection, !next.items.contains(where: { $0.collectionID == replacement }), next.collections.first(where: { $0.id == replacement })?.name == "收集区" {
                next.collections.removeAll { $0.id == replacement }
            }
            next.collections.insert(group, at: min(undo.collectionIndex ?? next.collections.count, next.collections.count))
        }
        if next.collections.contains(where: { $0.id == undo.previousCurrentCollection }) { next.currentCollection = undo.previousCurrentCollection }
        let rank = Dictionary(uniqueKeysWithValues: undo.itemOrder.enumerated().map { ($0.element, $0.offset) })
        next.items = (next.items + undo.items).enumerated().sorted {
            (rank[$0.element.id] ?? (rank.count + $0.offset)) < (rank[$1.element.id] ?? (rank.count + $1.offset))
        }.map(\.element)
        for state in undo.stackLayout ?? [] {
            if let n = next.items.firstIndex(where: { $0.id == state.id }), next.items[n].stackID == nil {
                next.items[n].stackID = state.stackID; next.items[n].stackOrder = state.stackOrder; next.items[n].position = state.position
            }
        }
        // Restored members follow a surviving stack if it moved after deletion.
        for item in undo.items {
            if let stack = item.stackID, let survivor = next.items.first(where: { $0.stackID == stack && !undo.items.map(\.id).contains($0.id) }) {
                for n in next.items.indices where next.items[n].stackID == stack { next.items[n].position = survivor.position }
            }
        }
        let groups = Dictionary(grouping: next.items.filter { $0.stackID != nil }, by: { $0.stackID! })
        for members in groups.values {
            for (order, member) in members.sorted(by: { $0.stackOrder! < $1.stackOrder! }).enumerated() {
                let n = next.items.firstIndex { $0.id == member.id }!
                next.items[n].stackOrder = order
            }
        }
        CardStacks.dissolveSingletons(&next.items); next.dissolved = nil
        next.drafts += undo.drafts; next.undo = nil
        try save(next)
        do { try reconcileAfterCommit(); return nil }
        catch { return "撤销已生效，但文件恢复未完成：\(InterfaceText(error: error))" }
    }
    func finishSession() throws {
        var next = index; next.garbage += next.undo?.items.map(\.id) ?? []; next.undo = nil
        try save(next); try paths.reconcile(index)
        next.garbage = []; try save(next)
    }
    func collectionRemovalSnapshot(_ ids: Set<UUID>) throws -> CollectionRemovalSnapshot {
        let groups = index.collections.filter { ids.contains($0.id) }
        let members = Dictionary(uniqueKeysWithValues: groups.map { group in
            (group.id, Set(index.items.filter { $0.collectionID == group.id }.map(\.id)))
        })
        return CollectionRemovalSnapshot(collections: groups, allCollectionIDs: Set(index.collections.map(\.id)), members: members,
            summary: try clearSummary(ids: Set(members.values.flatMap { $0 })))
    }
    // Revalidation and the single atomic manifest commit share this actor turn.
    // Report post-commit cleanup separately: a cleanup error cannot turn an
    // already committed deletion into "nothing was deleted" in the interface.
    func removeCollections(_ expected: CollectionRemovalSnapshot) throws -> RemovalResult<CollectionRemovalSnapshot> {
        let current = try collectionRemovalSnapshot(expected.ids)
        guard current == expected else { return .changed(current) }
        guard !current.collections.isEmpty else { throw LibraryError.invalid("所选收集区已不存在，请返回列表。") }
        var next = index
        if let old = next.undo { next.garbage += old.items.map(\.id) }
        next.collections.removeAll { current.ids.contains($0.id) }
        var replacement: UUID?
        if next.collections.isEmpty {
            let group = Collection(name: "收集区"); next.collections = [group]; replacement = group.id
        }
        if current.ids.contains(next.currentCollection) { next.currentCollection = next.collections[0].id }
        next.undo = UndoRemoval(items: index.items.filter { current.itemIDs.contains($0.id) },
            drafts: index.drafts.filter { current.itemIDs.contains($0.sourceID) }, previousCurrentCollection: index.currentCollection,
            replacementCollection: replacement, itemOrder: index.items.map(\.id), collections: current.collections,
            collectionOrder: index.collections.map(\.id))
        next.items.removeAll { current.itemIDs.contains($0.id) }
        next.drafts.removeAll { current.itemIDs.contains($0.sourceID) }
        next.dissolved = nil
        try save(next)
        do {
            try reconcileAfterCommit()
            return .removed(cleanupWarning: nil)
        } catch {
            return .removed(cleanupWarning: "收集区已删除，但文件清理未完成：\(InterfaceText(error: error))")
        }
    }
    func saveDraft(_ draft: AnswerDraft) throws {
        try saveDrafts([draft])
    }
    func saveDrafts(_ drafts: [AnswerDraft]) throws {
        guard drafts.allSatisfy({ draft in index.items.contains { $0.id == draft.sourceID } }) else { throw LibraryError.invalid("原材料已不存在。") }
        var next = index
        for draft in drafts {
            if let position = next.drafts.firstIndex(where: { $0.sourceID == draft.sourceID }) { next.drafts[position] = draft }
            else { next.drafts.append(draft) }
        }
        if next.drafts != index.drafts { try save(next) }
    }
    func discardDraft(_ id: UUID) throws { var next = index; next.drafts.removeAll { $0.sourceID == id }; try save(next) }
    func export(ids: Set<UUID>, to directory: URL) throws {
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        let destination = directory.resolvingSymlinksInPath().path, own = root.resolvingSymlinksInPath().path
        guard destination != own, !destination.hasPrefix(own + "/") else { throw LibraryError.invalid("不能导出到 \(AppIdentity.name) 内部数据目录。") }
        for item in index.items where ids.contains(item.id) {
            let source = try url(for: item)
            let ext = (item.filename as NSString).pathExtension, base = (item.filename as NSString).deletingPathExtension
            var target = directory.appendingPathComponent(item.filename), n = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = directory.appendingPathComponent("\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")); n += 1
            }
            try FileManager.default.copyItem(at: source, to: target)
        }
    }
}
