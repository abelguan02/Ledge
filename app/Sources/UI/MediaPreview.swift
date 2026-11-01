import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

struct MediaPreview: @unchecked Sendable {
    var image: CGImage?
    var duration: String?
    static func kind(_ url: URL) -> MaterialKind {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return .folder }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return .file }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return .file
    }
    static func load(url: URL, kind: MaterialKind) async -> MediaPreview {
        await Task.detached(priority: .utility) {
            if kind == .image {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return MediaPreview() }
                return MediaPreview(image: CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 400] as CFDictionary))
            }
            let asset = AVURLAsset(url: url)
            do {
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration >= 0, duration < Double(Int.max) else { return MediaPreview() }
                let text = "\(Int(duration) / 60):" + String(format: "%02d", Int(duration) % 60)
                if kind == .video {
                    let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 400, height: 300)
                    let frame = try await generator.image(at: .zero)
                    return MediaPreview(image: frame.image, duration: text)
                }
                return MediaPreview(duration: text)
            } catch { return MediaPreview() } // Unsupported media uses the specified generic file icon.
        }.value
    }
}
