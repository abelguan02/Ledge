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
        var rendered: [String] = []
        // Render the actual production component before loading the source image:
        // a different loader or warmed AppKit cache must not hide a lookup bug.
        for scheme in [ColorScheme.light, .dark] {
            for scale: CGFloat in [1, 2] {
                let renderer = ImageRenderer(content: CoffeePaymentCode().environment(\.colorScheme, scheme))
                renderer.scale = scale
                guard let image = renderer.cgImage, image.width == Int(196 * scale), image.height == Int(196 * scale),
                      let value = try payload(image) else {
                    throw NSError(domain: "CoffeePaymentCodeTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Production payment component is blank or unreadable at \(scheme) \(scale)x"])
                }
                rendered.append(value)
            }
        }
        guard let url = Bundle.main.url(forResource: "CoffeePayment", withExtension: "jpg"),
              let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let expected = try payload(image), rendered.allSatisfy({ $0 == expected }) else {
            throw NSError(domain: "CoffeePaymentCodeTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Rendered code differs from supplied original"])
        }
        print("PASS actual CoffeePaymentCode in resource bundle: light/dark at 1x/2x, all QR payloads equal original; no windows or network")
    }
    static func main() {
        do { try check() }
        catch { print("FAIL \(error.localizedDescription)"); exit(1) }
    }
}
