import Foundation
import QuickLookUI

// Stable per-opening snapshot: Quick Look owns navigation and playback.
final class SystemPreviewItem: NSObject, QLPreviewItem {
    let materialID: UUID
    let previewItemURL: URL?
    let previewItemTitle: String?
    init(id: UUID, url: URL, title: String) {
        materialID = id; previewItemURL = url; previewItemTitle = title
    }
}

// Quick Look may load a .webloc remotely. Unsnapshotted links therefore use
// plain local text, kept outside the library and all export representations.
@MainActor final class LinkPreviewDocuments {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dump-link-preview-\(UUID())", isDirectory: true)
    private var created = false

    func make(title: String, siteName: String, url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        created = true
        let file = directory.appendingPathComponent("\(UUID()).txt")
        let text = "\(title)\n\(siteName)\n\n\(url.absoluteString)\n\n尚无网页截图。这是本地网址说明，预览不会打开网页。\n要打开网页，请返回 \(AppIdentity.name) 双击链接卡片。\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func removeAll() throws {
        guard created else { return }
        try FileManager.default.removeItem(at: directory)
        created = false
    }
}
