import AppKit
import SwiftUI

@main @MainActor struct CardResizeTests {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original = MaterialKind.image.size
        for free in [true, false] {
            for delta in [CanvasPoint(x: -900, y: -900), CanvasPoint(x: 27, y: 3), CanvasPoint(x: 3, y: 27), CanvasPoint(x: 900, y: 900)] {
                let size = CardResize.size(kind: .image, original: original, delta: delta, free: free)
                precondition(CardResize.valid(size, kind: .image))
                precondition(abs(size.width / size.height - 1.2) < 0.000001)
            }
        }
        precondition(CardResize.size(kind: .image, original: original, delta: CanvasPoint(x: 27, y: 0), free: false) == CanvasSize(width: 168, height: 140))
        precondition(CardResize.size(kind: .image, original: original, delta: CanvasPoint(x: -900, y: 0), free: false) == CanvasSize(width: 120, height: 100), "bounds must not break primary-axis snapping")
        precondition(CardResize.size(kind: .text, original: .init(width: 192, height: 144), delta: .init(x: -1000, y: 1000), free: false) == CanvasSize(width: 144, height: 480))
        precondition(CardResize.size(kind: .link, original: .init(width: 216, height: 96), delta: .init(x: 5, y: 7), free: true) == CanvasSize(width: 221, height: 103))
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dump-resize-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let library = try Library(root: root)
        let collection = await library.index.currentCollection
        let item = try await library.importText(String(repeating: "Synthetic text for wrapping. ", count: 50), collection: collection, preferred: .init(x: 240, y: 240))
        let neighbor = try await library.importText("neighbor", collection: collection, preferred: .init(x: 456, y: 240))
        let bytes = try Data(contentsOf: await library.url(for: item))
        let model = WorkbenchModel(library: library); await model.refresh(); model.isExpanded = true; model.select(item.id)
        let viewport = CanvasScrollView(model: model, usesSystemCursor: false)
        let window = DumpPanel(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 800), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = viewport
        func handle(in view: NSView) -> CardResizeView? {
            if let value = view as? CardResizeView { return value }
            return view.subviews.lazy.compactMap { handle(in: $0) }.first
        }
        for zoom in [0.25, 1, 2] {
            viewport.configure(); viewport.setZoom(zoom); viewport.scroll(to: .zero)
            try await Task.sleep(for: .milliseconds(80)); viewport.canvasHost.layoutSubtreeIfNeeded()
            let grip = handle(in: viewport.canvasHost)!
            let rect = grip.convert(grip.bounds, to: nil)
            precondition(abs(rect.width - 16) < 0.01 && abs(rect.height - 16) < 0.01, "screen handle stays 16 points")
            let down = CGPoint(x: rect.midX, y: rect.midY)
            let dragged = CGPoint(x: down.x + 48 * zoom, y: down.y - 24 * zoom)
            func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            grip.mouseDown(with: mouse(.leftMouseDown, down)); grip.mouseDragged(with: mouse(.leftMouseDragged, dragged))
            precondition(model.resizeSize == CanvasSize(width: 240, height: 168), "native deltas must use world coordinates")
            grip.cancelOperation(nil)
            precondition(model.items.first(where: { $0.id == item.id })!.displaySize == nil)
        }
        model.resize(item.id, to: .init(width: 480, height: 480)); await model.waitForWrites()
        let saved = model.items.first(where: { $0.id == item.id })!
        precondition(saved.rect.intersects(neighbor.rect), "resize permits overlap")
        precondition(model.items.first(where: { $0.id == neighbor.id })!.position == neighbor.position)
        precondition(model.items.last!.id == item.id, "most recently resized card draws last")
        let reopened = try Library(root: root)
        let persisted = await reopened.index.items.first(where: { $0.id == item.id })!
        let payloadAfter = try Data(contentsOf: await library.url(for: item))
        precondition(persisted.size == saved.size && bytes == payloadAfter)
        let manifest = root.appendingPathComponent("library.json")
        let backup = try Data(contentsOf: manifest)
        try fm.removeItem(at: manifest); try fm.createDirectory(at: manifest, withIntermediateDirectories: true)
        do { try await library.resize(item.id, to: .init(width: 240, height: 240)); preconditionFailure("save must fail") } catch { }
        let afterFailure = await library.index.items.first(where: { $0.id == item.id })!
        precondition(afterFailure.size == saved.size)
        try fm.removeItem(at: manifest); try backup.write(to: manifest)
        try await library.remove(ids: [item.id]); try await library.undoRemoval()
        let restored = await library.index.items.first(where: { $0.id == item.id })!
        precondition(restored.size == saved.size)
        try await library.resize(item.id, to: nil)
        let reset = await library.index.items.first(where: { $0.id == item.id })!
        precondition(reset.size == reset.kind.size && reset.displaySize == nil)
        viewport.stop()
        print("PASS resize: ratio, grid/Option, limits, 16-point native handle at 25/100/200%, cancel, overlap, z-order, restart, unchanged payload, atomic failure, clear/undo and reset")
    }
}
