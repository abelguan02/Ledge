import AppKit
import SwiftUI

@main @MainActor struct CanvasSelectionTests {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dump-selection-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let library = try Library(root: root, makeBookmark: { _ in Data() })
        let collection = await library.index.currentCollection
        let first = try await library.importText("synthetic text", collection: collection, preferred: CanvasPoint(x: 240, y: 240))
        let folder = root.appendingPathComponent("synthetic-folder")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("nested file".utf8).write(to: folder.appendingPathComponent("sample.txt"))
        let second = try await library.importFile(folder, collection: collection, kind: .folder, preferred: CanvasPoint(x: 480, y: 432))
        let other = try await library.importText("obstacle", collection: collection, preferred: CanvasPoint(x: 1200, y: 1200))
        let members: Set<UUID> = [first.id, second.id]
        let model = WorkbenchModel(library: library); await model.refresh(); model.isExpanded = true
        let viewport = CanvasScrollView(model: model, usesSystemCursor: false)
        let surface = DropSurface(model: model); surface.mode = .canvas
        surface.frame = CGRect(x: 0, y: 0, width: 1120, height: 900)
        surface.host.removeFromSuperview(); surface.addSubview(viewport)
        viewport.frame = CGRect(x: 20, y: 52, width: 1100, height: 800)
        let window = DumpPanel(contentRect: surface.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = surface; window.receiveDrops(on: surface)
        viewport.layoutSubtreeIfNeeded(); viewport.configure()
        func descendant<T: NSView>(_ view: NSView, _ type: T.Type) -> T? {
            if let value = view as? T { return value }
            return view.subviews.lazy.compactMap { descendant($0, type) }.first
        }
        func card(_ id: UUID, in view: NSView) -> MaterialDragView? {
            if let source = view as? MaterialDragView, source.item.id == id { return source }
            return view.subviews.lazy.compactMap { card(id, in: $0) }.first
        }
        func windowPoint(_ x: Double, _ y: Double) -> CGPoint {
            viewport.canvasHost.convert(CGPoint(x: x * viewport.zoom, y: y * viewport.zoom), to: nil)
        }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0,
                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        for zoom in [0.25, 1, 2] {
            viewport.setZoom(zoom); viewport.scroll(to: .zero)
            try await Task.sleep(for: .milliseconds(50)); viewport.canvasHost.layoutSubtreeIfNeeded()
            let background = descendant(viewport.canvasHost, CanvasSelectionView.self)!
            let blank = viewport.canvasHost.convert(CGPoint(x: 120 * zoom, y: 120 * zoom), to: surface.superview)
            precondition(surface.hitTest(blank) === background, "blank canvas must own the marquee event")
            let source = card(first.id, in: viewport.canvasHost)!
            let center = source.convert(CGPoint(x: source.bounds.midX, y: source.bounds.midY), to: surface.superview)
            precondition(surface.hitTest(center) === source, "cards must retain their own hit region")
            // All four directions and a partial intersection, not full enclosure.
            for (a, b) in [(CGPoint(x: 180, y: 180), CGPoint(x: 260, y: 260)),
                           (CGPoint(x: 260, y: 260), CGPoint(x: 180, y: 180)),
                           (CGPoint(x: 180, y: 260), CGPoint(x: 260, y: 180)),
                           (CGPoint(x: 260, y: 180), CGPoint(x: 180, y: 260))] {
                model.selected = [other.id]
                background.mouseDown(with: mouse(.leftMouseDown, windowPoint(a.x, a.y)))
                background.mouseDragged(with: mouse(.leftMouseDragged, windowPoint(b.x, b.y)))
                precondition(model.selected == [first.id] && model.selectionRect != nil)
                background.mouseUp(with: mouse(.leftMouseUp, windowPoint(b.x, b.y)))
                precondition(!model.selecting && model.selectionRect == nil)
            }
            model.selected = [other.id]
            background.mouseDown(with: mouse(.leftMouseDown, windowPoint(180, 180), flags: .shift))
            background.mouseDragged(with: mouse(.leftMouseDragged, windowPoint(620, 600), flags: .shift))
            precondition(model.selected == members.union([other.id]))
            background.cancelOperation(nil)
            precondition(model.selected == [other.id] && !model.selecting, "cancel restores the pre-gesture selection")
            background.mouseDown(with: mouse(.leftMouseDown, windowPoint(180, 180)))
            background.mouseUp(with: mouse(.leftMouseUp, windowPoint(180, 180)))
            precondition(model.selected.isEmpty, "blank click clears selection")
            // A click collapses multi-select; the down event alone must not.
            model.selected = members
            source.mouseDown(with: mouse(.leftMouseDown, windowPoint(270, 270)))
            precondition(model.selected == members)
            source.mouseUp(with: mouse(.leftMouseUp, windowPoint(270, 270)))
            precondition(model.selected == [first.id])
            source.mouseDown(with: mouse(.leftMouseDown, windowPoint(270, 270), flags: .command))
            source.mouseUp(with: mouse(.leftMouseUp, windowPoint(270, 270), flags: .command))
            precondition(model.selected.isEmpty)
        }
        print("PASS 25/100/200%: native blank/card hits, four-direction partial selection, Shift addition, cancel, blank click and Command toggle")

        // Pressing a media play region must leave time to begin a group drag.
        var audio = first; audio.kind = .audio
        let mediaSource = MaterialDragView(model: model, item: audio)
        mediaSource.frame = CGRect(x: 100, y: 100, width: 216, height: 72); surface.addSubview(mediaSource)
        let playPoint = mediaSource.convert(CGPoint(x: 20, y: 30), to: nil)
        model.selected = members; model.durations[first.id] = "0:01"
        var previewRequests: [[UUID]] = []
        model.presentPreview = { previewRequests.append($0.map(\.materialID)) }
        mediaSource.mouseDown(with: mouse(.leftMouseDown, playPoint))
        precondition(model.selected == members && previewRequests.isEmpty, "play button cannot steal the initial group drag press")
        mediaSource.mouseUp(with: mouse(.leftMouseUp, playPoint))
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.05))
        precondition(previewRequests == [[first.id]] && model.selected == [first.id])
        var opened: [URL] = []
        model.openExternalURL = { opened.append($0); return true }
        mediaSource.mouseDown(with: mouse(.leftMouseDown, playPoint))
        mediaSource.mouseUp(with: mouse(.leftMouseUp, playPoint))
        let doubleClick = NSEvent.mouseEvent(with: .leftMouseDown, location: playPoint, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!
        mediaSource.mouseDown(with: doubleClick)
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.05))
        precondition(opened == [model.payloadURLs[first.id]!] && previewRequests.count == 1, "double click opens the copy and cancels the pending badge preview")
        model.durations[first.id] = nil; mediaSource.removeFromSuperview()
        print("PASS media play click waits for release, retaining the ability to drag a selected group")

        // The immutable original layout is moved in one storage transaction.
        let originals = await library.index.items
        let desired = CanvasPoint(x: other.position.x, y: other.position.y)
        let positions = Placement.locateGroup([first, second], anchor: second, occupied: [other.rect], preferred: desired)
        let p1 = positions[first.id]!, p2 = positions[second.id]!
        precondition(p2.x - p1.x == second.position.x - first.position.x && p2.y - p1.y == second.position.y - first.position.y)
        precondition(!CanvasRect(origin: p1, size: first.kind.size).intersects(other.rect))
        precondition(!CanvasRect(origin: p2, size: second.kind.size).intersects(other.rect))
        let boundary = Placement.locateGroup([first, second], anchor: second, occupied: [], preferred: CanvasPoint(x: -100, y: -100))
        precondition(boundary[first.id] == CanvasPoint(x: 24, y: 24), "whole group stays inside canvas")
        // Make the actual manifest unwritable without adding a production test hook.
        let manifest = root.appendingPathComponent("library.json"), backup = root.appendingPathComponent("saved-index.json")
        try fm.moveItem(at: manifest, to: backup)
        try fm.createDirectory(at: manifest, withIntermediateDirectories: false)
        do { try await library.move(members, anchor: second.id, to: desired); preconditionFailure("save should fail") }
        catch { }
        let afterFailure = await library.index.items
        precondition(afterFailure == originals, "failed save must not partially change memory")
        try fm.removeItem(at: manifest); try fm.moveItem(at: backup, to: manifest)
        let unchanged = try Library(root: root)
        let unchangedItems = await unchanged.index.items
        precondition(unchangedItems == originals, "disk still has the original whole layout")
        do { try await library.move(members.union([UUID()]), anchor: first.id, to: desired); preconditionFailure("missing member must reject whole move") }
        catch { }
        print("PASS group rigid offsets, whole-group collision/boundary placement, missing-member rejection and atomic failure")

        viewport.setZoom(1); viewport.scroll(to: CGPoint(x: 800, y: 800))
        try await Task.sleep(for: .milliseconds(50)); viewport.canvasHost.layoutSubtreeIfNeeded()
        let source = card(second.id, in: viewport.canvasHost)!
        model.selected = members
        let writers = try source.makeDraggingItems()
        precondition(writers.count == 2)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let payloads = writers.map { $0.item as! NSPasteboardItem }
        precondition(board.writeObjects(payloads))
        let copiedURLs = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as! [URL]
        precondition(Set(copiedURLs) == Set(members.map { model.payloadURLs[$0]! }), "one file URL for each mixed-type member")
        let text = try String(contentsOf: model.payloadURLs[first.id]!, encoding: .utf8)
        let nested = try String(contentsOf: model.payloadURLs[second.id]!.appendingPathComponent("sample.txt"), encoding: .utf8)
        precondition(text == "synthetic text" && nested == "nested file")
        let drag = SyntheticDrag(); defer { drag.draggingPasteboard.releaseGlobally() }
        drag.draggingDestinationWindow = window; drag.draggingSource = source
        for zoom in [0.25, 1, 2] {
            try await library.move(members, anchor: second.id, to: second.position); await model.refresh()
            viewport.setZoom(zoom)
            viewport.scroll(to: CGPoint(x: max(0, desired.x - viewport.visibleCanvasRect.width / 2),
                                        y: max(0, desired.y - viewport.visibleCanvasRect.height / 2)))
            model.draggedIDs = members; model.dragging = second.id; model.dragOffset = CanvasPoint(x: 20, y: 20)
            drag.draggingLocation = windowPoint(desired.x + 20, desired.y + 20)
            precondition(window.draggingEntered(drag) == .move && window.draggingUpdated(drag) == .move)
            let preview = model.dragPoint!
            precondition(preview == p2 && window.performDragOperation(drag))
            model.dragging = nil; model.dragPoint = nil; model.draggedIDs = []
            await model.waitForWrites()
            precondition(model.items.first { $0.id == first.id }?.position == p1 && model.items.first { $0.id == second.id }?.position == preview)
        }
        let reopened = try Library(root: root)
        let restored = await reopened.index.items
        precondition(restored == model.items, "group positions survive reopening")
        model.askRemoval(ids: members); await model.waitForWrites(); model.confirmRemoval(); await model.waitForWrites()
        model.undo(); await model.waitForWrites()
        precondition(model.items == restored, "clear/undo retains complete moved layout")
        let missing = model.payloadURLs[second.id]!
        try fm.removeItem(at: missing)
        model.selected = members
        do { _ = try source.makeDraggingItems(); preconditionFailure("missing copy must block entire export") }
        catch { }
        print("PASS mixed text/folder drag writers, full payloads, 25/100/200% native group preview/commit, reopen, clear/undo and all-or-nothing missing-copy export")

        viewport.setZoom(1)
        viewport.scroll(to: CGPoint(x: 300, y: 300))
        let before = viewport.visibleCanvasRect.origin
        let edge = viewport.contentView.convert(CGPoint(x: viewport.contentView.bounds.maxX - 2, y: viewport.contentView.bounds.maxY - 2), to: nil)
        viewport.scrollDuringDrag(at: edge)
        precondition(viewport.visibleCanvasRect.minX > before.x && viewport.visibleCanvasRect.minY > before.y)
        let after = viewport.visibleCanvasRect.origin
        viewport.scrollDuringDrag(at: CGPoint(x: -10000, y: -10000))
        precondition(viewport.visibleCanvasRect.origin == after, "external drag must not keep scrolling")
        let background = descendant(viewport.canvasHost, CanvasSelectionView.self)!
        let middle = viewport.contentView.convert(CGPoint(x: viewport.contentView.bounds.midX, y: viewport.contentView.bounds.midY), to: nil)
        background.mouseDown(with: mouse(.leftMouseDown, middle))
        background.mouseDragged(with: mouse(.leftMouseDragged, edge))
        let firstTick = viewport.visibleCanvasRect.origin
        try await Task.sleep(for: .milliseconds(120))
        precondition(viewport.visibleCanvasRect.minX > firstTick.x, "stationary edge marquee continues scrolling")
        background.cancelOperation(nil)
        let cancelledOrigin = viewport.visibleCanvasRect.origin
        try await Task.sleep(for: .milliseconds(120))
        precondition(viewport.visibleCanvasRect.origin == cancelledOrigin, "cancel stops the edge timer")
        precondition(!window.isVisible)
        viewport.stop(); window.contentView = nil; try await model.shutdown()
        print("PASS edge scrolling and cleanup; no visible windows or posted system input")
    }
}
