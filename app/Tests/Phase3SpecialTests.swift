import AppKit
import SwiftUI

@main @MainActor struct Phase3SpecialTests {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dump-phase3-special-\(UUID())")
        let output = fm.temporaryDirectory.appendingPathComponent("dump-phase3-special-export-\(UUID())")
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: output) }
        let library = try Library(root: root, makeBookmark: { _ in Data() })
        let group = await library.index.currentCollection
        let videoURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let video = try await library.importFile(videoURL, collection: group, kind: MediaPreview.kind(videoURL), preferred: .init(x: 240, y: 240))
        let link = try await library.importText("https://example.com/dump-phase3-special?test=resize", collection: group, preferred: .init(x: 600, y: 240))
        precondition(video.kind == .video && link.kind == .link, "fixture classification: video=\(video.kind.rawValue), link=\(link.kind.rawValue)")
        let videoBytes = try Data(contentsOf: await library.url(for: video))
        let linkBytes = try Data(contentsOf: await library.url(for: link))
        let model = WorkbenchModel(library: library); await model.refresh(); model.isExpanded = true
        var previewRequests = 0
        model.presentPreview = { _ in previewRequests += 1 }
        precondition(model.thumbnails[video.id] != nil && model.durations[video.id] == "0:03", "fixture must decode a real video cover and duration")
        let surface = DropSurface(model: model); surface.mode = .canvas
        surface.frame = CGRect(x: 0, y: 0, width: 1120, height: 948)
        surface.host.rootView = AnyView(WorkbenchView(model: model, width: 1100, height: 900))
        let window = DumpPanel(contentRect: surface.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = surface; window.receiveDrops(on: surface)
        func grip(in view: NSView) -> CardResizeView? {
            if let value = view as? CardResizeView { return value }
            return view.subviews.lazy.compactMap { grip(in: $0) }.first
        }
        func source(_ id: UUID, in view: NSView) -> MaterialDragView? {
            if let value = view as? MaterialDragView, value.item.id == id, value.inTray { return value }
            return view.subviews.lazy.compactMap { source(id, in: $0) }.first
        }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint, free: Bool = false) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: free ? .option : [], timestamp: 0,
                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        surface.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        precondition(model.changeCanvasZoom != nil)
        for item in [video, link] {
            for zoom in [0.25, 1, 2] {
                model.select(item.id); model.changeCanvasZoom?(zoom)
                try await Task.sleep(for: .milliseconds(100)); surface.layoutSubtreeIfNeeded()
                let handle = grip(in: surface)!
                let rect = handle.convert(handle.bounds, to: nil)
                precondition(abs(rect.width - 16) < 0.01 && abs(rect.height - 16) < 0.01)
                let down = CGPoint(x: rect.midX, y: rect.midY)
                let end = CGPoint(x: down.x + 48 * zoom, y: down.y - 24 * zoom)
                handle.mouseDown(with: mouse(.leftMouseDown, down))
                handle.mouseDragged(with: mouse(.leftMouseDragged, end))
                let expected = item.kind == .video ? CanvasSize(width: 192, height: 160) : CanvasSize(width: 264, height: 216)
                precondition(model.resizeSize == expected)
                handle.cancelOperation(nil)
                precondition(model.items.first { $0.id == item.id }!.displaySize == nil && previewRequests == 0)
                handle.mouseDown(with: mouse(.leftMouseDown, down)); handle.mouseDragged(with: mouse(.leftMouseDragged, end))
                handle.mouseUp(with: mouse(.leftMouseUp, end)); await model.waitForWrites()
                precondition(model.items.first { $0.id == item.id }!.size == expected)
                model.resize(item.id, to: nil); await model.waitForWrites()
            }
            model.select(item.id); model.beginResize(item)
            model.updateResize(delta: .init(x: 13, y: 7), pointer: .init(x: 0, y: 0), free: true); model.endResize()
            await model.waitForWrites()
            let resized = model.items.first { $0.id == item.id }!
            if item.kind == .video { precondition(abs(resized.size.width / resized.size.height - 1.2) < 0.000001) }
            else { precondition(resized.size == .init(width: 229, height: 199)) }
        }
        let stack = try await library.createStack([video.id, link.id]); await model.refresh(); model.openStack(stack)
        try await Task.sleep(for: .milliseconds(100)); surface.layoutSubtreeIfNeeded()
        let memberSource = source(video.id, in: surface)!
        let drag = SyntheticDrag(); defer { drag.draggingPasteboard.releaseGlobally() }
        drag.draggingSource = memberSource; drag.draggingSourceOperationMask = .move
        model.select(video.id); model.dragging = video.id; model.draggedIDs = [video.id]; model.dragFromStack = true
        let document = model.canvasDocumentView!, visible = model.visibleCanvasRect
        drag.draggingLocation = document.convert(CGPoint(x: (visible.minX + 48) * model.canvasCoordinateScale, y: (visible.maxY - 48) * model.canvasCoordinateScale), to: nil)
        precondition(surface.performDragOperation(drag)); await model.waitForWrites()
        model.dragging = nil; model.draggedIDs = []; model.dragFromStack = false
        precondition(model.openStackID == nil && model.items.count == 2 && model.canvasItems.count == 2)
        precondition(model.items.allSatisfy { $0.stackID == nil && $0.stackOrder == nil })
        model.select(link.id)
        try await Task.sleep(for: .milliseconds(100)); surface.layoutSubtreeIfNeeded()
        precondition(grip(in: surface)?.item.id == link.id, "remaining member must regain ordinary resize controls")
        let restarted = try Library(root: root)
        let saved = await restarted.index.items
        precondition(saved == model.items)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        try await library.export(ids: [video.id, link.id], to: output)
        let exportedVideo = try Data(contentsOf: output.appendingPathComponent(video.filename))
        let exportedLink = try Data(contentsOf: output.appendingPathComponent(link.filename))
        precondition(exportedVideo == videoBytes && exportedLink == linkBytes)
        window.contentView = nil
        print("PASS phase3 special: real H.264 cover/duration, video/link native 25/100/200% handles, ratio/free dimensions, cancel/commit/reset, singleton tray detach and close, ordinary controls restored, restart and unchanged exported bytes; no visible windows, network or posted input")
    }
}
