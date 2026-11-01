import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct ImageSettings: Codable, Equatable, Sendable {
    var resize = false
    var width = 1600
    var percent = 75
    var resizeMode = "width"
    var format = "original"
    var compress = true
    var quality = 0.82
    var maxMB = 0.0
    func validate() throws {
        guard (1...20000).contains(width), (1...100).contains(percent), (0.2...1).contains(quality),
              maxMB.isFinite, (0...1000).contains(maxMB), ["width", "percent"].contains(resizeMode),
              ["original", "jpeg", "png"].contains(format) else { throw LibraryError.invalid("图片设置超出范围。") }
    }
    var summary: String {
        let size = resize ? (resizeMode == "width" ? "宽度 ≤\(width)px" : "缩小到 \(percent)%") : "原尺寸"
        let output = format == "original" ? "原格式" : format.uppercased()
        return "\(size) · \(output) · \(maxMB > 0 ? "每张 ≤\(maxMB) MB" : (compress ? "清晰优先压缩" : "不主动降质"))"
    }
}
struct ImageOutput: Sendable { let url: URL; let note: String; var changed = true }
enum ImageTool {
    static func process(_ input: URL, outputDirectory: URL, settings s: ImageSettings) throws -> ImageOutput {
        try s.validate()
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?, [UTType.jpeg.identifier, UTType.png.identifier].contains(type),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, Int64(w) * Int64(h) <= 100_000_000 else {
            throw LibraryError.invalid("首版图片处理支持单帧 PNG/JPG（不超过 1 亿像素）；输入未处理。")
        }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let displayW = (5...8).contains(orientation) ? h : w
        let displayH = (5...8).contains(orientation) ? w : h
        let scale = !s.resize ? 1.0 : (s.resizeMode == "width" ? min(1, Double(s.width) / Double(displayW)) : Double(s.percent) / 100)
        let maxPixel = max(1, Int((Double(max(displayW, displayH)) * scale).rounded()))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw LibraryError.invalid("图片解码失败。") }
        let outputType = s.format == "original" ? type : (s.format == "jpeg" ? UTType.jpeg.identifier : UTType.png.identifier)
        var rendered = image
        if outputType == UTType.jpeg.identifier {
            guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw LibraryError.invalid("图片转换内存不足。") }
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.interpolationQuality = .high; context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let flattened = context.makeImage() else { throw LibraryError.invalid("图片合成失败。") }
            rendered = flattened
        }
        func encode(_ quality: Double) throws -> Data {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, outputType as CFString, 1, nil) else { throw LibraryError.invalid("编码器不可用。") }
            CGImageDestinationAddImage(destination, rendered, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw LibraryError.invalid("图片编码失败。") }
            return data as Data
        }
        var data = try encode(s.compress ? s.quality : 1)
        let target = Int(s.maxMB * 1_000_000)
        if target > 0, data.count > target, outputType == UTType.jpeg.identifier, s.compress {
            var quality = s.quality
            while data.count > target && quality > 0.50 {
                quality = max(0.5, quality - 0.08)
                data = try encode(quality)
            }
        }
        if scale == 1 && outputType == type {
            let original = try Data(contentsOf: input)
            if original.count <= data.count, target == 0 || original.count <= target {
                return ImageOutput(url: input, note: "没有进一步减小图片，已保留原图，未生成重复副本。可尝试缩小尺寸或转换为 JPEG。", changed: false)
            }
        }
        // Never silently report success when the explicit size target is unmet.
        guard target == 0 || data.count <= target else { throw LibraryError.invalid("在当前尺寸、格式和清晰度下无法达到 \(s.maxMB) MB；请缩小尺寸或调整格式。原图保留。") }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let ext = outputType == UTType.jpeg.identifier ? "jpg" : "png"
        let output = outputDirectory.appendingPathComponent(input.deletingPathExtension().lastPathComponent + "-处理." + ext)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw LibraryError.invalid("结果路径已存在，未覆盖。") }
        try data.write(to: output, options: .atomic)
        return ImageOutput(url: output, note: "\(rendered.width) × \(rendered.height) · \(data.count) 字节" + (outputType == UTType.jpeg.identifier ? " · 透明区域填白" : ""))
    }
}
