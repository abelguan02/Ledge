import AppKit
import SwiftUI
import CoreText
import Vision

@MainActor final class SnapshotShortcuts: ShortcutRegistry {
    func register(_ shortcut: AppShortcut, id: UInt32) throws { fatalError("No real shortcuts in skin tests") }
    func unregister(id: UInt32) throws { fatalError("No real shortcuts in skin tests") }
}

@MainActor private final class SkinTestBackend: TextBackend {
    func catalog() async throws -> CodexCatalog { fatalError("No account access in skin tests") }
    func respond(input: String, instructions: String, model: String) async throws -> String { fatalError("No network in skin tests") }
    func stop() { }
}

@MainActor private final class ProbeState { var skin = LedgeSkin.classic; var scheme = ColorScheme.light }
private struct SkinProbe: NSViewRepresentable {
    @Environment(\.ledgeSkin) var skin
    @Environment(\.colorScheme) var scheme
    let state: ProbeState
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) { state.skin = skin; state.scheme = scheme }
}

@main @MainActor struct SkinSwitchTests {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .aqua)
        let motion = LedgeSkin.unit01.motion
        for time in [0.0, 0.36, 0.7, 1.06, 2.25, 4.65] {
            precondition(motion.signalOpacity(time: time, alarm: true, reduced: true) == 1)
            precondition(motion.signalOpacity(time: time, alarm: false, reduced: true) == 1)
        }
        for time in [2.25, 4.65] { precondition(motion.signalOpacity(time: time, alarm: false, reduced: false) < 1) }
        for time in [0.36, 1.06] { precondition(motion.signalOpacity(time: time, alarm: true, reduced: false) < 1) }
        func luminance(_ color: Color) -> Double {
            let rgb = NSColor(color).usingColorSpace(.sRGB)!
            func channel(_ c: CGFloat) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(rgb.redComponent) + 0.7152 * channel(rgb.greenComponent) + 0.0722 * channel(rgb.blueComponent)
        }
        func contrast(_ a: Color, _ b: Color) -> Double {
            let x = luminance(a), y = luminance(b)
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        let palette = LedgeSkin.unit01.palette
        for color in [palette.primary, palette.secondary, palette.warning, palette.accent, palette.destructive] {
            precondition(contrast(color, palette.inset) >= 4.5)
        }
        precondition(contrast(palette.base, palette.alarm) >= 3)
        precondition(contrast(palette.primary, palette.armor) >= 4.5)
        print("PASS signal periods, steady reduced-motion signals and text palette contrast")
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let library = try Library(root: root.appendingPathComponent("library"), makeBookmark: { _ in Data() })
        let group = await library.index.currentCollection
        let a = try await library.importText("synthetic note", collection: group, preferred: CanvasPoint(x: 100, y: 150))
        let b = try await library.importText("second note", collection: group, preferred: CanvasPoint(x: 340, y: 150))
        let preferences = AppPreferences(); preferences.automaticWebPreviews = false
        let model = WorkbenchModel(library: library, bridge: SkinTestBackend(), preferences: preferences)
        await model.refresh()
        model.selected = [a.id, b.id]; model.createStack(); await model.waitForWrites()
        let stack = model.items.first!.stackID!
        model.openStack(stack)
        model.drafts[a.id] = AnswerDraft(sourceID: a.id, answer: "uncommitted synthetic input")
        model.isExpanded = true
        model.viewportStates[model.viewportKey] = CanvasViewportState(zoom: 1.25, origin: CGPoint(x: 120, y: 80))
        let probe = ProbeState()
        let host = NSHostingView(rootView: SkinRoot(preferences: preferences, scanlines: false) {
            WorkbenchView(model: model)
                .overlay { AnswerCard(model: model, item: a).frame(width: 284, height: 430) }
                .background(SkinProbe(state: probe).frame(width: 1, height: 1))
        }.environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 540, height: 768), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.hasShadow = true
        let originalShadow = window.hasShadow
        window.contentView = host
        func settle() async throws {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            host.layoutSubtreeIfNeeded()
            precondition(!window.isVisible, "Tests must never show a window")
        }
        try await settle()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        guard let scroll = descendants(host).compactMap({ $0 as? CanvasScrollView }).first else { fatalError("Missing production canvas") }
        let document = scroll.canvasHost
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let index = try encoder.encode(model.index)
        let viewport = scroll.visibleCanvasRect
        precondition(viewport.minX > 0 && viewport.minY > 0 && scroll.zoom == 1.25)
        // Preserve a real native text editor's in-progress state as well as the
        // canvas identity. Local first-responder changes never activate a window.
        guard let editor = descendants(host).compactMap({ $0 as? NSTextView }).first(where: { $0.isEditable && $0.string == "uncommitted synthetic input" }) else { fatalError("Missing production answer editor") }
        editor.setSelectedRange(NSRange(location: 3, length: 4))
        window.makeFirstResponder(editor)
        for choice in [SkinChoice.unit01, .classic, .unit01, .classic] {
            preferences.skin = choice
            try await settle()
            precondition(model.canvasDocumentView === document && scroll.documentView === document)
            precondition(descendants(host).contains { $0 === scroll })
            precondition(scroll.visibleCanvasRect.origin == viewport.origin && scroll.visibleCanvasRect.width == viewport.width && model.openStackID == stack)
            precondition(scroll.zoom == 1.25)
            let currentIndex = try encoder.encode(model.index)
            precondition(currentIndex == index)
            precondition(editor.string == "uncommitted synthetic input" && editor.selectedRange() == NSRange(location: 3, length: 4))
            precondition(window.firstResponder === editor)
            precondition(probe.skin.isUnit == (choice == .unit01))
            precondition(probe.scheme == (choice == .unit01 ? .dark : .light))
            precondition(window.hasShadow == (choice == .unit01 ? false : originalShadow))
            precondition(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (choice == .unit01 ? .darkAqua : .aqua))
            precondition(choice == .unit01 || window.appearance == nil, "Classic must restore inherited appearance")
            precondition(NSApp.appearance?.name == .aqua, "Skin must not change application/system appearance")
        }
        // Independent system panels continue to inherit the application's appearance.
        preferences.skin = .unit01; try await settle()
        let picker = NSOpenPanel()
        precondition(!picker.isVisible && picker.appearance == nil)
        precondition(picker.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
        model.closeStack(); model.askRemoval(ids: [a.id]); await model.waitForWrites()
        let removalID = model.removal?.id
        preferences.skin = .unit01; try await settle()
        precondition(model.removal?.id == removalID && model.removal?.ids == [a.id])
        model.removal = nil
        model.dragging = a.id
        preferences.skin = .classic; try await settle()
        precondition(model.dragging == a.id && model.canvasDocumentView === document)
        model.dragging = nil
        // Menu state itself is checked without asking NSPopover to show; actual
        // popover appearance is reserved for an authorized foreground review.
        window.contentView = nil
        precondition(window.appearance == nil && window.hasShadow == originalShadow)
        model.collectionPage = .manager; model.collectionSelection = [group]
        preferences.skin = .unit01
        precondition(model.collectionPage == .manager && model.collectionSelection == [group])
        scroll.stop()
        print("PASS live skin environment, fixed dark mode, canvas/document identity, editor input/focus, positions/sizes/stack, viewport, confirmation, drag and collection state")

        let font = SkinFonts.display(size: 44)
        precondition(font.fontName == "LedgeDisplay-Black")
        let fallback = CTFontCreateForString(font as CTFont, "猫" as CFString, CFRange(location: 0, length: 1))
        precondition((CTFontCopyPostScriptName(fallback) as String).contains("Songti"), "User names outside the subset must use Songti")
        let rect = CGRect(x: 0, y: 0, width: 520, height: 760)
        let outline = EdgePanelShape(edge: .right, cut: true).path(in: rect)
        precondition(outline.contains(CGPoint(x: 50, y: 25)) && !outline.contains(CGPoint(x: 1, y: 21)))
        precondition(outline.contains(CGPoint(x: 1, y: 45)) && !outline.contains(CGPoint(x: 500, y: 10)))
        let leftOutline = EdgePanelShape(edge: .left, cut: true).path(in: rect)
        precondition(leftOutline.contains(CGPoint(x: 470, y: 25)) && !leftOutline.contains(CGPoint(x: 519, y: 21)))
        let topOutline = EdgePanelShape(edge: .top, cut: true).path(in: CGRect(x: 0, y: 0, width: 760, height: 520))
        precondition(topOutline.contains(CGPoint(x: 25, y: 470)) && !topOutline.contains(CGPoint(x: 21, y: 519)))
        var foundationImages: [String: Data] = [:]
        let rareFont = CTFontCreateForString(font as CTFont, "龘" as CFString, CFRange(location: 0, length: 1))
        var character: UniChar = 0x9F98, glyph: CGGlyph = 0
        precondition(CTFontGetGlyphsForCharacters(rareFont, &character, &glyph, 1) && glyph != 0, "Rare user names must remain readable through system fallback")
        for edge in DockEdge.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let view = SkinRoot(preferences: preferences, scanlines: false) {
                    PanelShell(width: 520, height: 720, edge: edge) {
                        VStack(spacing: 24) {
                            SkinDisplayText("通用 Settings 初號機", size: 34)
                            SkinDisplayText(wordmark: .all, size: 190)
                            SkinDisplayText(wordmark: .clear, size: 190)
                            Text("合成正文 · synthetic text").font(LedgeSkin.unit01.typography.body)
                        }.foregroundStyle(LedgeSkin.unit01.palette.primary)
                    }
                }.environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                guard let image = renderer.cgImage else { fatalError("Cannot render foundation") }
                let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                if scheme == .light { foundationImages[edge.rawValue] = png }
                else { precondition(foundationImages[edge.rawValue] == png, "Unit foundation must be identical under light/dark environments") }
                try png.write(to: root.appendingPathComponent("foundation-\(edge)-\(scheme).png"))
            }
        }
        for choice in SkinChoice.allCases {
            preferences.skin = choice
            let renderer = ImageRenderer(content: SkinRoot(preferences: preferences) {
                skinSnapshotSettings(model: model, tab: 0).frame(width: 520, height: 291)
            })
            guard let image = renderer.cgImage else { fatalError("Cannot render General settings") }
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                .write(to: root.appendingPathComponent("settings-\(choice).png"))
        }
        try checkCoffee(preferences: preferences, root: root)
        let photo = Bundle.main.url(forResource: "SyntheticTabletop", withExtension: "jpg")!
        let item = try await library.importFile(photo, collection: group, kind: .image)
        await model.refresh()
        let stored = model.payloadURLs[item.id]!
        let original = try Data(contentsOf: photo)
        var renders: [Data] = []
        for (choice, selected) in [(SkinChoice.classic, true), (.unit01, false), (.unit01, true)] {
            preferences.skin = choice; model.selected = selected ? [item.id] : []
            let renderer = ImageRenderer(content: SkinRoot(preferences: preferences, scanlines: false) {
                MaterialView(model: model, item: item).snapshotArtwork
            })
            let image = renderer.cgImage!
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            renders.append(png)
            try png.write(to: root.appendingPathComponent("tabletop-\(choice)-\(selected).png"))
        }
        let payload = try Data(contentsOf: stored)
        precondition(renders[0] == renders[2] && renders[0] != renders[1] && payload == original)
        print("PASS production imported thumbnail: Unit idle toned, selected matches original rendering; stored copy unchanged")
        try checkLanguages(preferences: preferences, model: model, root: root)
        print("PASS bundled renamed Black font, Songti fallback, identical fixed-dark renders, both General settings; no visible windows or network")
    }

    static func checkLanguages(preferences: AppPreferences, model: WorkbenchModel, root: URL) throws {
        preferences.skin = .unit01
        model.index.collections[0].name = String(String(repeating: "海貓 · Collection 龘 ", count: 8).prefix(80))
        for (id, expected) in [("en-US", "General"), ("zh-Hant-TW", "通用"), ("zh-Hans-CN", "通用")] {
            let locale = Locale(identifier: id)
            let skin = LedgeSkin.selected(.unit01, locale: locale)
            precondition(skin.label("通用") == expected)
            precondition(skin.phrase("清空“%@”中的%d样材料？", "海貓", 7).contains("海貓"))
            if skin.language == .traditional { precondition(skin.label("皮肤") == "皮膚") }
            func save<V: View>(_ view: V, _ name: String, _ width: CGFloat, _ height: CGFloat) throws {
                let renderer = ImageRenderer(content: SkinRoot(preferences: preferences) { view.frame(width: width, height: height) }
                    .environment(\.locale, locale).environment(\.skinMotionOverride, true))
                guard let image = renderer.cgImage else { fatalError("Missing locale render") }
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                    .write(to: root.appendingPathComponent("locale-\(id)-\(name).png"))
            }
            try save(WorkbenchView(model: model).snapshotHeader, "long-header", 520, 128)
            try save(skinSnapshotSettings(model: model, tab: 0), "settings", 520, 291)
            try save(skinSnapshotAbout(coffee: false), "about", 340, 470)
            let request = RemovalRequest(ids: Set(model.items.map(\.id)), title: "清空", summary: ClearSummary(backedUp: 1, unique: [.pastedText: [UUID()]]))
            try save(ClearConfirmation(model: model, request: request), "clear", 520, 720)
        }
        print("PASS three language tables and production layout fixtures; custom collection names preserved")
    }

    static func checkCoffee(preferences: AppPreferences, root: URL) throws {
        func barcode(_ image: CGImage) throws -> VNBarcodeObservation {
            let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]
            try VNImageRequestHandler(cgImage: image).perform([request])
            precondition(request.results?.count == 1, "Production About QR must decode")
            return request.results![0]
        }
        func pixels(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                        bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return bytes
        }
        for choice in SkinChoice.allCases {
            preferences.skin = choice
            for scale: CGFloat in [1, 2] {
                func render(scanlines: Bool) -> CGImage {
                    let renderer = ImageRenderer(content: SkinRoot(preferences: preferences, scanlines: scanlines) {
                        skinSnapshotAbout(coffee: true).frame(width: 340, height: 470)
                    })
                    renderer.scale = scale
                    return renderer.cgImage!
                }
                let plain = render(scanlines: false), decorated = render(scanlines: true)
                let code = try barcode(plain), scanned = try barcode(decorated)
                precondition(code.payloadStringValue == scanned.payloadStringValue)
                let before = pixels(plain), after = pixels(decorated)
                if choice == .classic { precondition(before == after) }
                else {
                    precondition(before != after, "Surrounding About content must retain scanlines")
                    // Vision uses a bottom-left origin; bitmap rows start at the
                    // top. Include the white quiet zone around the dark modules.
                    var rect = VNImageRectForNormalizedRect(code.boundingBox, plain.width, plain.height).insetBy(dx: -6 * scale, dy: -6 * scale).integral
                    rect.origin.y = CGFloat(plain.height) - rect.maxY
                    for y in Int(rect.minY)..<Int(rect.maxY) {
                        for x in Int(rect.minX)..<Int(rect.maxX) {
                            let offset = (y * plain.width + x) * 4
                            precondition(before[offset..<offset+4] == after[offset..<offset+4], "Scanlines must leave QR and white quiet zone untouched")
                        }
                    }
                }
                try NSBitmapImageRep(cgImage: decorated).representation(using: .png, properties: [:])!
                    .write(to: root.appendingPathComponent("coffee-\(choice)-\(Int(scale))x.png"))
            }
        }
        print("PASS actual About + SkinRoot composite: QR payload/white quiet zone intact at 1x/2x, surrounding scanlines retained, Classic unchanged")
    }
}
