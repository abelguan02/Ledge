import AppKit
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    static let dumpMaterial = Self("local.dump.material")
    static let dumpSourceURL = Self("local.dump.source-url")
    static let materialTitle = Self("public.url-name")
    // NSPasteboardItem takes UTIs, while browsers also expose this legacy
    // pasteboard name. Resolve its system UTI rather than inventing an alias.
    static let webURLsWithTitles = Self(UTType(tag: "WebURLsWithTitlesPboardType",
        tagClass: UTTagClass(rawValue: "com.apple.nspboard-type"), conformingTo: .data)!.identifier)
}

enum ReceivedMaterial: Sendable {
    case file(URL, MaterialSource)
    case text(String, MaterialSource)
    case image(Data, MaterialSource)
}

// The same representations are offered to every destination, for drag and copy.
// Each writer represents exactly one material; file URLs always remain available.
@MainActor enum MaterialTransfer {
    static func writers(_ materials: [Material], urls: [UUID: URL]) throws -> [NSPasteboardItem] {
        try materials.map { material in
            guard let url = urls[material.id], FileManager.default.isReadableFile(atPath: url.path) else {
                throw LibraryError.invalid("选中材料中有副本已丢失或无法读取，未开始传输。请取消选择该材料后重试。")
            }
            let writer = NSPasteboardItem()
            writer.setString(material.id.uuidString, forType: .dumpMaterial)
            writer.setString(url.absoluteString, forType: .fileURL)
            if let source = material.sourceURL { writer.setString(source, forType: .dumpSourceURL) }
            let title = material.sourceTitle ?? (material.kind == .link ? material.linkPreview?.title : nil)
            if let title { writer.setString(title, forType: .materialTitle) }
            if material.kind == .text {
                writer.setString(try String(contentsOf: url, encoding: .utf8), forType: .string)
            } else if material.kind == .link {
                guard let contents = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String],
                      let text = contents["URL"], Library.webURL(text) != nil else { throw LibraryError.invalid("链接内容无法读取，未开始传输。") }
                writer.setString(text, forType: .URL)
                writer.setString(text, forType: .string)
                if let title { writer.setPropertyList([[text], [title]], forType: .webURLsWithTitles) }
            } else if material.kind == .image, let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
                // Original encoded image bytes, never the downsampled card thumbnail.
                writer.setData(try Data(contentsOf: url, options: .mappedIfSafe), forType: .init(type.identifier))
            }
            return writer
        }
    }

    static func received(_ board: NSPasteboard) -> [ReceivedMaterial] {
        received(board.pasteboardItems ?? [])
    }

    static func source(_ item: NSPasteboardItem) -> MaterialSource {
        let titledURLs = item.propertyList(forType: .webURLsWithTitles) as? [[String]]
        let pair = titledURLs.flatMap { $0.count == 2 && $0[0].count == $0[1].count ? $0 : nil }
        return MaterialSource(title: item.string(forType: .materialTitle) ?? pair?.last?.first,
                              url: item.string(forType: .dumpSourceURL) ?? item.string(forType: .URL) ?? pair?.first?.first)
    }

    static func received(_ items: [NSPasteboardItem]) -> [ReceivedMaterial] {
        items.flatMap { item -> [ReceivedMaterial] in
            let titledURLs = item.propertyList(forType: .webURLsWithTitles) as? [[String]]
            let webURL = item.string(forType: .URL).flatMap { Library.webURL($0)?.absoluteString }
            let source = source(item)
            if let value = item.string(forType: .fileURL), let url = URL(string: value), url.isFileURL {
                return [.file(url, source)]
            }
            if let data = item.data(forType: .png) { return [.image(data, source)] }
            if let data = item.data(forType: .tiff), let bitmap = NSBitmapImageRep(data: data),
               let png = bitmap.representation(using: .png, properties: [:]) { return [.image(png, source)] }
            if let webURL { return [.text(webURL, source)] }
            if let titledURLs, titledURLs.count == 2, titledURLs[0].count == titledURLs[1].count {
                return zip(titledURLs[0], titledURLs[1]).compactMap { url, title in
                    guard Library.webURL(url) != nil else { return nil }
                    return .text(url, MaterialSource(title: title, url: url))
                }
            }
            if let text = item.string(forType: .string), !text.isEmpty { return [.text(text, source)] }
            return []
        }
    }
}
