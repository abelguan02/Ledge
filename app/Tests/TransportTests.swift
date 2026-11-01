import AppKit
import SwiftUI

@main @MainActor struct TransportTests {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dump-transport-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Library(root: root, makeBookmark: { _ in Data() })
        let model = WorkbenchModel(library: library)
        await model.refresh()
        let surface = DropSurface(model: model)
        surface.frame = NSRect(x: 0, y: 0, width: 540, height: 768)
        surface.host.rootView = AnyView(WorkbenchView(model: model))
        let window = DumpPanel(contentRect: surface.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = surface
        window.receiveDrops(on: surface)
        surface.layoutSubtreeIfNeeded()
        precondition(!window.isVisible)
        precondition(surface.registeredDraggedTypes.isEmpty, "the stable panel owns native drop registration")
        precondition(surface.host.registeredDraggedTypes.isEmpty, "hosting view must not intercept the registered drop surface")
        precondition(surface.hitTest(NSPoint(x: 100, y: 100)) === surface, "collapsed rail routes input directly to its registered native view")
        let source = root.appendingPathComponent("synthetic.bin")
        let bytes = Data([0, 1, 2, 255]); try bytes.write(to: source)
        let drag = SyntheticDrag()
        drag.draggingDestinationWindow = window
        precondition(drag.draggingPasteboard.writeObjects([source as NSURL]), "Named test pasteboard is unavailable in this command sandbox")
        defer { drag.draggingPasteboard.releaseGlobally() }
        surface.showDrop = { surface.mode = .drop }
        surface.showCanvas = { surface.mode = .canvas }
        precondition(window.draggingEntered(drag) == .copy && surface.mode == .drop)
        precondition(window.performDragOperation(drag))
        await model.waitForWrites()
        precondition(model.items.count == 1 && model.items[0].kind == .file)
        let originalBytes = try Data(contentsOf: source)
        precondition(originalBytes == bytes)
        let item = model.items[0]
        let copiedBytes = try Data(contentsOf: model.payloadURLs[item.id]!)
        precondition(copiedBytes == bytes)
        // A matching private type from outside the app must never move a card.
        drag.draggingPasteboard.setString(item.id.uuidString, forType: .dumpMaterial)
        precondition(window.draggingEntered(drag) == .copy)
        model.importing = true
        precondition(!window.prepareForDragOperation(drag) && !window.performDragOperation(drag))
        model.importing = false
        drag.draggingSource = MaterialDragView(model: model, item: item)
        precondition(window.draggingEntered(drag) == .move)
        precondition(window.performDragOperation(drag))
        await model.waitForWrites()
        precondition(model.items.count == 1 && model.items[0].position != item.position)
        // The visible card, native drag region and playback hit target must
        // share one rectangle, regardless of the content's intrinsic size.
        func nativeCard(in view: NSView) -> MaterialDragView? {
            if let card = view as? MaterialDragView { return card }
            for child in view.subviews { if let card = nativeCard(in: child) { return card } }
            return nil
        }
        model.selected = [UUID()] // Every test card is visually dimmed.
        for kind: MaterialKind in [.image, .video, .audio, .file, .folder] {
            var sample = item; sample.kind = kind
            let host = NSHostingView(rootView: MaterialView(model: model, item: sample)
                .frame(width: kind.size.width, height: kind.size.height))
            host.frame = NSRect(x: 0, y: 0, width: kind.size.width, height: kind.size.height)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            guard let card = nativeCard(in: host) else { preconditionFailure("missing native card for \(kind)") }
            precondition(card.bounds.size == NSSize(width: kind.size.width, height: kind.size.height), "native card must match visible size for \(kind)")
            let center = card.convert(NSPoint(x: card.bounds.midX, y: card.bounds.midY), to: host)
            precondition(host.hitTest(center) === card, "visible card center must accept native clicks for \(kind)")
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
            let menu = card.menu(for: event)!
            precondition(menu.items.map(\.title).contains("打开") && menu.items.map(\.title).contains("删除…"))
        }
        print("PASS native drop entry, copy import, source unchanged, internal move, external marker isolation and busy rejection; no window shown")
        print("PASS visible card/native hit bounds and context menus for image, video, audio, file and folder")
        var neighbor = item; neighbor.kind = .folder
        var wideImage = item; wideImage.id = UUID(); wideImage.kind = .image
        model.thumbnails[wideImage.id] = NSImage(size: NSSize(width: 1000, height: 600), flipped: false) { rect in
            NSColor.white.setFill(); NSBezierPath(rect: rect).fill(); return true
        }
        let neighbors = NSHostingView(rootView: HStack(spacing: 12) {
            MaterialView(model: model, item: neighbor).frame(width: 120, height: 144)
            MaterialView(model: model, item: wideImage).frame(width: 144, height: 120)
        })
        neighbors.frame = NSRect(x: 0, y: 0, width: 276, height: 144)
        window.contentView = neighbors; neighbors.layoutSubtreeIfNeeded()
        let neighborView = nativeCard(in: neighbors)!
        precondition(neighborView.item.id == neighbor.id)
        let nearRightEdge = neighborView.convert(NSPoint(x: neighborView.bounds.maxX - 10, y: neighborView.bounds.midY), to: neighbors)
        precondition((neighbors.hitTest(nearRightEdge) as? MaterialDragView)?.item.id == neighbor.id,
                     "cropped image must not steal clicks from the visible neighboring card")
        print("PASS cropped thumbnail does not intercept neighboring card clicks")
        window.contentView = surface
        drag.draggingSource = nil
        drag.draggingPasteboard.clearContents()
        drag.draggingPasteboard.setString("https://example.com/test", forType: .string)
        surface.mode = .line
        precondition(window.draggingEntered(drag) == .copy && model.dropKind == .link && !model.dropKind.hasActions)
        drag.draggingLocation = NSPoint(x: 40, y: 20)
        _ = window.draggingUpdated(drag)
        precondition(model.dropZone == 0, "link drags cannot select a text action")
        model.dropZone = 2 // Even stale UI state must not dispatch unsupported AI.
        precondition(window.performDragOperation(drag))
        await model.waitForWrites()
        precondition(model.items.last?.kind == .link && model.busy.isEmpty && model.drafts.isEmpty)
        print("PASS URL drag classification, action-zone exclusion and safe import; no AI request")
        try await model.shutdown()
    }
}
