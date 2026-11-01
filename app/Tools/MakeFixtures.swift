import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
try Data("Dump 验收材料\n这是一段测试文字，用来检查粘贴、解释和草稿保护。".utf8).write(to: directory.appendingPathComponent("测试文字.txt"))
try Data([0, 1, 2, 3, 255]).write(to: directory.appendingPathComponent("任意格式.bin"))
try PropertyListSerialization.data(fromPropertyList: ["URL": "https://example.com/dump"], format: .xml, options: 0).write(to: directory.appendingPathComponent("测试链接.webloc"))
let context = CGContext(data: nil, width: 1000, height: 600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(gray: 0.94, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 600))
let font = CTFontCreateWithName("Helvetica" as CFString, 64, nil)
let title = NSAttributedString(string: "DUMP SAMPLE 2026", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.12, alpha: 1)])
context.textPosition = CGPoint(x: 90, y: 300); CTLineDraw(CTLineCreateWithAttributedString(title), context)
let imageURL = directory.appendingPathComponent("测试图片.png")
let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
print("Generated 4 synthetic files in \(directory.path)")
