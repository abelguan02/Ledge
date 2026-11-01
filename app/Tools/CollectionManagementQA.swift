import Foundation

@main struct CollectionManagementQA {
    static func main() async throws {
        let args = CommandLine.arguments, fm = FileManager.default
        let root = URL(fileURLWithPath: args[2], isDirectory: true)
        let marker = root.appendingPathComponent("collection-qa-fixture")
        if args[1] == "inspect" {
            guard fm.fileExists(atPath: marker.path) else { throw LibraryError.invalid("Not a synthetic collection QA library") }
            let index = try JSONDecoder().decode(LibraryIndex.self, from: Data(contentsOf: root.appendingPathComponent("library.json")))
            print("current=\(index.currentCollection) collections=\(index.collections.count) items=\(index.items.count) undo=\(index.undo?.collections?.count ?? 0)")
            for group in index.collections {
                let items = index.items.filter { $0.collectionID == group.id }
                print("\(group.id) \(group.name) count=\(items.count) cached=\(items.filter { $0.linkPreview?.filename != nil }.count) stacked=\(items.filter { $0.stackID != nil }.count)")
            }
            return
        }
        guard args[1] == "seed", !fm.fileExists(atPath: root.path) else { throw LibraryError.invalid("Seed requires a new synthetic directory") }
        let library = try Library(root: root, makeBookmark: { _ in Data() })
        let first = await library.index.currentCollection
        try await library.renameCollection(first, name: "QA 当前素材")
        let text = try await library.importText("QA 本地文字：管理与批量删除", collection: first)
        let link = try await library.importText("https://example.com/reference?token=synthetic", collection: first)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
        _ = try await library.saveLinkPreview(link.id, png: png, title: "QA 本地预览", siteName: "合成站点")
        _ = try await library.createStack([text.id, link.id])
        for (n, name) in ["QA 同名", "QA 同名", "QA 空区", "QA 名字很长的收集区用于核对省略号和完整名称提示", "QA 素材六", "QA 空区七", "QA 素材八"].enumerated() {
            let group = try await library.createCollection(name)
            if !name.contains("空区") {
                _ = try await library.importText("QA export \(n)", collection: group.id)
            }
        }
        try await library.selectCollection(first)
        try "Synthetic only".write(to: marker, atomically: true, encoding: .utf8)
        print("PREPARED synthetic library: 8 collections, duplicate names, empty groups, long name, stack and local screenshot")
    }
}
