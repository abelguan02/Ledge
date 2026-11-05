import AppKit
import CoreText
import SwiftUI

enum SkinFonts {
    private static let registered: Void = {
        guard let url = Bundle.main.url(forResource: "LedgeDisplay-Black", withExtension: "ttf", subdirectory: "Fonts") else {
            preconditionFailure("Missing bundled display font")
        }
        var error: Unmanaged<CFError>?
        let success = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        precondition(success, "Could not register bundled display font: \(String(describing: error?.takeRetainedValue()))")
    }()
    static func display(size: CGFloat) -> NSFont {
        _ = registered
        let descriptor = NSFontDescriptor(name: "LedgeDisplay-Black", size: size)
            .addingAttributes([.cascadeList: [NSFontDescriptor(name: "STSongti-SC-Black", size: size)]])
        return NSFont(descriptor: descriptor, size: size)!
    }
}

// The three named wordmarks are the replacement point for the designer's
// forthcoming outlines. Until those assets arrive, all use the same font path.
enum SkinWordmark: String { case all = "全部", clear = "清空", appName = "搁这儿" }

struct SkinDisplayText: View {
    @Environment(\.ledgeSkin) private var skin
    let text: String
    let size: CGFloat
    var compression: CGFloat = 0.72
    private var wordmark: SkinWordmark?
    private var fragment: Range<Int>?
    init(_ text: String, size: CGFloat, compression: CGFloat = 0.72) {
        self.text = text; self.size = size; self.compression = compression
    }
    init(wordmark: SkinWordmark, size: CGFloat, compression: CGFloat = 0.62, fragment: Range<Int>? = nil) {
        self.init(wordmark.rawValue, size: size, compression: compression)
        self.wordmark = wordmark; self.fragment = fragment
    }
    private var spread: CGFloat { size >= 170 ? 3.4 : size >= 90 ? 1.7 : size >= 44 ? 0.7 : 0 }
    var body: some View {
        let romanAlarm = skin.language == .english && (wordmark == .all || wordmark == .clear)
        let fullText = romanAlarm ? (wordmark == .all ? "CLEAR" : "ALL") : skin.label(text)
        let text = fragment.map { String(fullText.dropFirst($0.lowerBound).prefix($0.count)) } ?? fullText
        let font = romanAlarm ? NSFont(name: "Times-Bold", size: size)! : SkinFonts.display(size: size)
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        let glyph = Text(text).font(Font(font)).fixedSize()
            .mask { Text(text).font(Font(font)).fixedSize().offset(y: size >= 90 ? 0.2 : 0) }
        ZStack(alignment: .leading) {
            // Horizontal overprinting thickens vertical stems without thickening
            // horizontal strokes. No blur or rasterized text asset is involved.
            glyph.offset(x: -spread / 2).accessibilityHidden(true)
            glyph.offset(x: spread / 2).accessibilityHidden(true)
            glyph
        }
        .font(Font(font)).fixedSize()
        .scaleEffect(x: compression, y: 1, anchor: .leading)
        .frame(width: width * compression, alignment: .leading)
        .frame(height: size)
        .accessibilityElement(children: .ignore).accessibilityLabel(text)
    }
}
