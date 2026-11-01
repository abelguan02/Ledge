import AppKit
import SwiftUI

@main @MainActor struct CardStackTests {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dump-stack-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let library = try Library(root: root, makeBookmark: { _ in Data() })
        let collection = await library.index.currentCollection
        let a = try await library.importText("one", collection: collection, preferred: .init(x: 120, y: 240))
        let folder = root.appendingPathComponent("folder")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: folder.appendingPathComponent("payload.txt"))
        let b = try await library.importFile(folder, collection: collection, kind: .folder, preferred: .init(x: 384, y: 240))
        let c = try await library.importText("three", collection: collection, preferred: .init(x: 720, y: 240))
        try await library.resize(a.id, to: .init(width: 336, height: 240))
        let model = WorkbenchModel(library: library); await model.refresh()
        let stack = try await library.createStack([a.id, b.id]); await model.refresh()
        // Creation order follows the material order, independent of a Set's enumeration.
        precondition(model.canvasItems.count == 2 && model.canvasItems.contains { $0.id == a.id })
        model.select(a.id); precondition(model.selected == [a.id, b.id])
        model.select(a.id, extending: true); precondition(model.selected.isEmpty)
        model.beginSelection(at: .init(x: b.position.x - 1, y: b.position.y - 1), adding: false)
        model.updateSelection(to: .init(x: b.position.x + 10, y: b.position.y + 10)); model.endSelection()
        // The top's position is the last member's pre-stack position (a was raised by resize).
        model.select(a.id)
        model.dragging = a.id; model.draggedIDs = model.selected
        model.previewMove(anchor: a.id, to: .init(x: 960, y: 720))
        let preview = model.dragPoint!
        model.move(a.id, to: .init(x: 960, y: 720)); await model.waitForWrites()
        precondition(model.stackMembers(stack).allSatisfy { $0.position == preview })
        let source = MaterialDragView(model: model, item: model.items.first { $0.id == a.id }!)
        source.frame = CGRect(x: 0, y: 0, width: 336, height: 240)
        let writers = try source.makeDraggingItems()
        precondition(writers.count == 2)
        let summary = try await library.clearSummary(ids: model.selected)
        precondition(summary.total == 2 && summary.uniqueIDs == [a.id])
        model.dragging = c.id; model.draggedIDs = [c.id]; model.select(c.id)
        model.updateStackHover(at: .init(x: preview.x + 20, y: preview.y + 20))
        precondition(!model.stackDropReady)
        model.dropMaterial(c.id, at: preview); await model.waitForWrites()
        precondition(model.items.first { $0.id == c.id }!.stackID == nil, "release before dwell only moves the card")
        model.updateStackHover(at: .init(x: preview.x + 20, y: preview.y + 20))
        try await Task.sleep(for: .milliseconds(560)); precondition(model.stackDropReady)
        model.clearStackHover(); precondition(!model.stackDropReady)
        model.updateStackHover(at: .init(x: preview.x + 20, y: preview.y + 20))
        try await Task.sleep(for: .milliseconds(560))
        model.dropMaterial(c.id, at: preview); await model.waitForWrites()
        precondition(model.stackMembers(stack).count == 3 && model.canvasItems.count == 1 && model.canvasItems[0].id == c.id)
        model.dragging = nil; model.draggedIDs = []
        let reopened = try Library(root: root)
        let reopenedItems = await reopened.index.items
        precondition(CardStacks.valid(reopenedItems) && reopenedItems.count == 3)
        model.openStack(stack); model.select(a.id)
        precondition(model.selected == [a.id], "tray selection is one material")
        model.closeStack(); precondition(model.selected.count == 3)
        let export = fm.temporaryDirectory.appendingPathComponent("dump-stack-export-\(UUID())")
        defer { try? fm.removeItem(at: export) }
        try fm.createDirectory(at: export, withIntermediateDirectories: true)
        try await library.export(ids: model.selected, to: export)
        let names = try fm.contentsOfDirectory(atPath: export.path)
        precondition(names.count == 3)
        let exportedNested = try String(contentsOf: export.appendingPathComponent("folder/payload.txt"), encoding: .utf8)
        precondition(exportedNested == "nested")
        model.isExpanded = true
        let surface = DropSurface(model: model); surface.mode = .canvas
        surface.frame = CGRect(x: 0, y: 0, width: 1120, height: 948)
        surface.host.rootView = AnyView(WorkbenchView(model: model, width: 1100, height: 900))
        let window = DumpPanel(contentRect: surface.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = surface; window.receiveDrops(on: surface)
        func findSource(_ id: UUID, in view: NSView, tray: Bool) -> MaterialDragView? {
            if let value = view as? MaterialDragView, value.item.id == id, value.inTray == tray { return value }
            return view.subviews.lazy.compactMap { findSource(id, in: $0, tray: tray) }.first
        }
        try await Task.sleep(for: .milliseconds(100)); surface.layoutSubtreeIfNeeded()
        let topSource = findSource(c.id, in: surface, tray: false)!
        var previewRequests = 0
        model.presentPreview = { _ in previewRequests += 1 }
        let doubleClick = NSEvent.mouseEvent(with: .leftMouseDown, location: topSource.convert(.zero, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!
        topSource.mouseDown(with: doubleClick)
        precondition(model.openStackID == stack && model.activeAnswer == nil && previewRequests == 0)
        try await Task.sleep(for: .milliseconds(100)); surface.layoutSubtreeIfNeeded()
        let tray = model.stackTrayView!
        precondition(abs(tray.convert(tray.bounds, to: nil).width - 332) < 0.01)
        let memberSource = findSource(a.id, in: surface, tray: true)!
        let cellFrame = memberSource.convert(memberSource.bounds, to: nil)
        precondition(abs(cellFrame.width - 96) < 0.01 && abs(cellFrame.height - 80) < 0.01)
        for zoom in [0.25, 2, 1] {
            model.changeCanvasZoom?(zoom)
            try await Task.sleep(for: .milliseconds(70)); surface.layoutSubtreeIfNeeded()
            let trayFrame = model.stackTrayView!.convert(model.stackTrayView!.bounds, to: nil)
            let cell = findSource(a.id, in: surface, tray: true)!
            let frame = cell.convert(cell.bounds, to: nil)
            precondition(abs(trayFrame.width - 332) < 0.01 && abs(frame.width - 96) < 0.01 && abs(frame.height - 80) < 0.01)
        }
        if let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) {
            surface.cacheDisplay(in: surface.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/qa-phase3-stack-hidden.png"))
        }
        let drag = SyntheticDrag(); defer { drag.draggingPasteboard.releaseGlobally() }
        drag.draggingSource = memberSource; drag.draggingSourceOperationMask = .move
        model.select(a.id); model.dragging = a.id; model.draggedIDs = [a.id]; model.dragFromStack = true
        drag.draggingLocation = tray.convert(CGPoint(x: tray.bounds.midX, y: tray.bounds.midY), to: nil)
        precondition(!surface.performDragOperation(drag), "drop inside tray must keep membership")
        let document = model.canvasDocumentView!
        drag.draggingLocation = document.convert(CGPoint(x: (model.visibleCanvasRect.minX + 48) * model.canvasCoordinateScale, y: (model.visibleCanvasRect.maxY - 48) * model.canvasCoordinateScale), to: nil)
        precondition(surface.performDragOperation(drag), "drop into visible blank canvas detaches")
        await model.waitForWrites(); model.dragging = nil; model.draggedIDs = []; model.dragFromStack = false
        precondition(model.stackMembers(stack).count == 2 && model.items.first { $0.id == a.id }!.displaySize == .init(width: 336, height: 240))
        try await library.remove(ids: [b.id]); await model.refresh()
        precondition(model.items.allSatisfy { $0.stackID == nil }, "one remaining member dissolves")
        try await library.undoRemoval(); await model.refresh()
        precondition(model.stackMembers(stack).count == 2, "undo restores surviving member's relation")
        model.dissolveStack(stack); await model.waitForWrites()
        precondition(model.items.allSatisfy { $0.stackID == nil } && model.index.dissolved != nil)
        let spread = model.items.filter { $0.id != a.id }
        precondition(!spread[0].rect.intersects(spread[1].rect))
        model.undo(); await model.waitForWrites()
        precondition(model.stackMembers(stack).count == 2 && model.index.dissolved == nil)
        try await library.remove(ids: Set(model.items.map(\.id))); try await library.undoRemoval(); await model.refresh()
        precondition(model.items.count == 3 && model.stackMembers(stack).count == 2)
        let before = await library.index.items
        let manifest = root.appendingPathComponent("library.json"), bytes = try Data(contentsOf: manifest)
        try fm.removeItem(at: manifest); try fm.createDirectory(at: manifest, withIntermediateDirectories: true)
        do { try await library.dissolveStack(stack); preconditionFailure("save failure must propagate") } catch { }
        let after = await library.index.items
        precondition(before == after)
        try fm.removeItem(at: manifest); try bytes.write(to: manifest)
        do { _ = try await library.createStack([a.id, b.id]); preconditionFailure("nested stack must reject") } catch { }
        let other = try await library.createCollection("other")
        let d = try await library.importText("elsewhere", collection: other.id)
        do { try await library.joinStack(d.id, stack: stack); preconditionFailure("cross-collection join must reject") } catch { }
        window.contentView = nil
        print("PASS stacks: mixed creation, top order/size, whole selection/move/export, half-second hover and cancellation, join, restart, native double-click/tray size/cell size/drop, singleton, removal/clear undo, dissolve/undo, atomic failure and no nesting/cross-collection joins")
    }
}
