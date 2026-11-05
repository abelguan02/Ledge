import AppKit
import SwiftUI
import Vision

@main @MainActor struct CoffeePaymentCodeTests {
    static func payload(_ image: CGImage) throws -> String? {
        let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard request.results?.count == 1 else { return nil }
        return request.results?.first?.payloadStringValue
    }
    static func check() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard Bundle.main.bundleIdentifier == "local.ledge.coffee-tests" else {
            throw NSError(domain: "CoffeePaymentCodeTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Test must run in its isolated resource bundle"])
        }
        var originals = Set<String>()
        for method in CoffeePaymentMethod.allCases {
            var rendered: [String] = []
            // Render the production component before the reference load to catch bundle lookup failures.
            for scheme in [ColorScheme.light, .dark] {
                for scale: CGFloat in [1, 2] {
                    let renderer = ImageRenderer(content: CoffeePaymentCode(method: method).environment(\.colorScheme, scheme))
                    renderer.scale = scale
                    guard let image = renderer.cgImage, image.width == Int(196 * scale), image.height == Int(196 * scale),
                          let value = try payload(image) else {
                        throw NSError(domain: "CoffeePaymentCodeTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unreadable \(method) at \(scheme) \(scale)x"])
                    }
                    rendered.append(value)
                }
            }
            let original = method == .wechat ? "CoffeePayment" : "AlipayPayment"
            guard let url = Bundle.main.url(forResource: original, withExtension: "jpg"),
                  let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let expected = try payload(image), originals.insert(expected).inserted,
                  rendered.allSatisfy({ $0 == expected }) else {
                throw NSError(domain: "CoffeePaymentCodeTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Rendered \(method) differs from supplied original or duplicates the other method"])
            }
        }
        print("PASS both production payment codes decode to their respective originals in light/dark at 1x/2x; no windows or network")
    }
    static func main() {
        do { try check() }
        catch { print("FAIL \(error.localizedDescription)"); exit(1) }
    }
}
