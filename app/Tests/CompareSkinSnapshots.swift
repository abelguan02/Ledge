import Foundation
import CoreGraphics
import ImageIO

// Repeated renders of the unchanged baseline vary by one 8-bit channel step
// at some antialiased edges. Compare canonical pixels, not PNG encoding or
// CGImage row padding. Larger differences and geometry changes always fail.
@main struct CompareSkinSnapshots {
    struct Bitmap {
        let width: Int
        let height: Int
        let pixels: [UInt8]
        init(_ url: URL) throws {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let context = CGContext(data: nil, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw NSError(domain: "SkinPixels", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot decode \(url.lastPathComponent)"])
            }
            width = image.width; height = image.height
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            pixels = Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        }
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        func manifest(_ version: String) throws -> [String: String] {
            try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appendingPathComponent("\(version)/manifest.json")))
        }
        let before = try manifest("baseline"), after = try manifest("candidate")
        guard !before.isEmpty, Set(before.keys) == Set(after.keys) else {
            print("FAIL snapshot inventory differs or is empty"); exit(1)
        }
        // The skin selector is an explicitly requested change to General only.
        // Still compare inventory and every other screen; report the exception.
        let newSelector = CommandLine.arguments.contains("--new-skin-selector")
        var exact = 0, rounded = 0, expectedChanges = 0, failures: [String] = []
        for name in before.keys.sorted() {
            if newSelector && name.hasSuffix("-settings-0") { expectedChanges += 1; continue }
            if before[name] == after[name] { exact += 1; continue }
            let a = try Bitmap(root.appendingPathComponent("baseline/\(name).png"))
            let b = try Bitmap(root.appendingPathComponent("candidate/\(name).png"))
            guard a.width == b.width, a.height == b.height else { failures.append("\(name): dimensions changed"); continue }
            let delta = zip(a.pixels, b.pixels).map { abs(Int($0) - Int($1)) }.max()!
            if delta == 0 { exact += 1 }
            else if delta == 1 { rounded += 1 }
            else { failures.append("\(name): maximum channel difference \(delta)/255") }
        }
        guard failures.isEmpty else { print("FAIL Classic render differences:\n" + failures.joined(separator: "\n")); exit(1) }
        print("PASS \(exact + rounded) Classic production renders: \(exact) pixel-identical, \(rounded) within measured baseline rounding (1/255 per channel); \(expectedChanges) General renders excluded for the new skin selector")
    }
}
