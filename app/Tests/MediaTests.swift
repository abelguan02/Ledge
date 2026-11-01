import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

@main struct MediaTests {
    static func main() async throws {
        let fm = FileManager.default, root = FileManager.default.temporaryDirectory.appendingPathComponent("dump-media-tests-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let context = CGContext(data: nil, width: 1000, height: 600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 600))
        let font = CTFontCreateWithName("Helvetica" as CFString, 64, nil)
        let text = NSAttributedString(string: "DUMP SAMPLE 2026", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
        context.textPosition = CGPoint(x: 80, y: 300)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        let input = root.appendingPathComponent("synthetic.png")
        let destination = CGImageDestinationCreateWithURL(input as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf: input)
        var settings = ImageSettings(); settings.resize = true; settings.width = 400; settings.format = "jpeg"
        let processed = try ImageTool.process(input, outputDirectory: root.appendingPathComponent("output"), settings: settings)
        let source = CGImageSourceCreateWithURL(processed.url as CFURL, nil)!
        let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
        precondition(values[kCGImagePropertyPixelWidth] as? Int == 400 && values[kCGImagePropertyPixelHeight] as? Int == 240)
        precondition(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let after = try Data(contentsOf: input)
        precondition(after == original)
        print("PASS PNG→JPEG and proportional resize; generated source unchanged")
        let result = try await DumpOCREngine().recognize(input)
        precondition(result.text.contains("DUMP") && result.text.contains("2026"), "synthetic OCR failed")
        print("PASS local Vision OCR on generated fixture; no screen or user image read")
    }
}
