import AppKit
import SwiftUI

final class SyntheticMagnification: NSEvent {
    override var magnification: CGFloat { 0.25 }
    override var locationInWindow: NSPoint { NSPoint(x: 400, y: 400) }
}

@main @MainActor struct CanvasViewportTests {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let fm = FileManager.default, root = FileManager.default.temporaryDirectory.appendingPathComponent("dump-viewport-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let library = try Library(root: root, makeBookmark: { _ in Data() })
        let group = await library.index.currentCollection
        let item = try await library.importText("synthetic viewport source", collection: group, preferred: CanvasPoint(x: 1800, y: 1200))
        _ = try await library.importText("far marker", collection: group, preferred: CanvasPoint(x: 4800, y: 4200))
        let image = NSImage(size: CGSize(width: 1000, height: 600), flipped: false) { rect in
            NSColor.white.setFill(); NSBezierPath(rect: rect).fill(); return true
        }
        let imageURL = root.appendingPathComponent("synthetic-neighbor.png")
        try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: imageURL)
        let neighbor = try await library.importFile(imageURL, collection: group, kind: .image, preferred: CanvasPoint(x: 2016, y: 1200))
        let model = WorkbenchModel(library: library); await model.refresh(); model.isExpanded = true
        let view = CanvasScrollView(model: model, usesSystemCursor: false)
        let surface = DropSurface(model: model)
        surface.mode = .canvas; surface.frame = CGRect(x: 0, y: 0, width: 1140, height: 900)
        surface.host.removeFromSuperview(); surface.addSubview(view)
        view.frame = CGRect(x: 20, y: 76, width: 1100, height: 800)
        let window = DumpPanel(contentRect: surface.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = surface; window.receiveDrops(on: surface)
        view.layoutSubtreeIfNeeded(); view.configure()
        precondition(!window.isVisible && view.canvasHost.isFlipped, "native document uses the canvas top-left origin without showing a window")
        view.scroll(to: CGPoint(x: 1000, y: 800))
        let center = CGPoint(x: view.visibleCanvasRect.midX, y: view.visibleCanvasRect.midY)
        view.setZoom(0.5)
        let scaledCenter = CGPoint(x: view.visibleCanvasRect.midX, y: view.visibleCanvasRect.midY)
        precondition(hypot(center.x - scaledCenter.x, center.y - scaledCenter.y) < 1, "zoom preserves the visible center")
        let documentPoint = CGPoint(x: item.position.x + 30, y: item.position.y + 40)
        let windowPoint = view.canvasHost.convert(CGPoint(x: documentPoint.x * view.zoom, y: documentPoint.y * view.zoom), to: nil)
        let roundTrip = view.canvasHost.convert(windowPoint, from: nil)
        precondition(hypot(roundTrip.x / view.zoom - documentPoint.x, roundTrip.y / view.zoom - documentPoint.y) < 0.01)
        let state = model.viewportStates[model.viewportKey]!
        model.toggleExpanded(); view.configure()
        precondition(view.zoom == 1)
        model.toggleExpanded(); view.configure()
        precondition(view.zoom == state.zoom && abs(view.visibleCanvasRect.minX - state.origin.x) < 1)
        view.setZoom(99); precondition(view.zoom == 2)
        view.setZoom(0.001); precondition(view.zoom == 0.25)
        view.setZoom(1); view.scroll(to: CGPoint(x: 900, y: 700))
        precondition(view.visibleCanvasRect.minX > 0 && view.visibleCanvasRect.minY > 0)
        let originalItems = await library.index.items
        precondition(model.items == originalItems, "zoom and pan must not rewrite material positions")
        print("PASS native viewport: anchored zoom, coordinate round-trip, both axes, limits and separate expanded/docked views")

        // Local method calls on hidden views: never post events or change the system cursor.
        func key(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                            context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.setZoom(0.5); view.scroll(to: CGPoint(x: 1000, y: 1000))
        let start = view.convert(CGPoint(x: 400, y: 400), to: nil)
        let origin = view.visibleCanvasRect.origin
        var previewRequests: [[UUID]] = []
        model.presentPreview = { previewRequests.append($0.map(\.materialID)) }
        precondition(view.handlePanEvent(key(.keyDown)))
        precondition(view.handlePanEvent(mouse(.leftMouseDown, start)))
        precondition(view.handlePanEvent(mouse(.leftMouseDragged, CGPoint(x: start.x - 40, y: start.y + 40))))
        precondition(abs(view.visibleCanvasRect.minX - origin.x - 80) < 1 && abs(view.visibleCanvasRect.minY - origin.y - 80) < 1)
        precondition(view.handlePanEvent(mouse(.leftMouseUp, start)) && view.handlePanEvent(key(.keyUp)))
        precondition(previewRequests.isEmpty, "space drag must not open Quick Look")
        for expanded in [false, true] {
            model.isExpanded = expanded
            model.select(item.id)
            let before = previewRequests.count
            precondition(view.handlePanEvent(key(.keyDown)))
            precondition(view.handlePanEvent(key(.keyDown)))
            precondition(previewRequests.count == before, "space opens only on release, never on repeat")
            precondition(view.handlePanEvent(key(.keyUp)))
            precondition(previewRequests.last == [item.id] && previewRequests.count == before + 1)
        }
        model.selected = []
        let requests = previewRequests.count
        precondition(view.handlePanEvent(key(.keyDown)) && view.handlePanEvent(key(.keyUp)))
        precondition(previewRequests.count == requests, "empty selection must not open Quick Look")
        let editor = NSTextView(frame: CGRect(x: 20, y: 20, width: 100, height: 30))
        surface.addSubview(editor); precondition(window.makeFirstResponder(editor))
        precondition(!view.handlePanEvent(key(.keyDown)), "space must remain text input while editing")
        editor.string = "QA"; editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.keyDown(with: key(.keyDown))
        precondition(editor.string == "QA ", "a space after committed text must reach the native editor")
        window.makeFirstResponder(nil); editor.removeFromSuperview()
        let nameField = NSTextField(string: "QA")
        nameField.frame = CGRect(x: 20, y: 20, width: 200, height: 24)
        surface.addSubview(nameField); precondition(window.makeFirstResponder(nameField))
        guard let fieldEditor = window.firstResponder as? NSTextView else { preconditionFailure("native field editor missing") }
        fieldEditor.setSelectedRange(NSRange(location: 2, length: 0))
        precondition(!view.handlePanEvent(key(.keyDown)), "space in a native field must not trigger canvas preview")
        fieldEditor.keyDown(with: key(.keyDown))
        precondition(fieldEditor.string == "QA ", "native name field must preserve a literal space")
        window.makeFirstResponder(nil); nameField.removeFromSuperview()
        print("PASS space-drag uses world distances at 50%; editing preserves spaces")

        let pinch = SyntheticMagnification()
        let beforePinch = view.canvasHost.convert(pinch.locationInWindow, from: nil)
        let worldAnchor = CGPoint(x: beforePinch.x / view.zoom, y: beforePinch.y / view.zoom)
        view.magnify(with: pinch)
        let afterPinch = view.canvasHost.convert(pinch.locationInWindow, from: nil)
        precondition(abs(view.zoom - 0.625) < 0.001 && hypot(afterPinch.x / view.zoom - worldAnchor.x, afterPinch.y / view.zoom - worldAnchor.y) < 1)
        print("PASS pinch handler preserves its pointer anchor")

        func nativeCard(in host: NSView, id: UUID) -> MaterialDragView? {
            if let card = host as? MaterialDragView, card.item.id == id { return card }
            for child in host.subviews { if let card = nativeCard(in: child, id: id) { return card } }
            return nil
        }
        let drag = SyntheticDrag(); drag.draggingDestinationWindow = window
        defer { drag.draggingPasteboard.releaseGlobally() }
        for zoom in [1.0, 0.5, 2.0] {
            view.setZoom(zoom); view.scroll(to: CGPoint(x: 1680, y: 1100))
            try await Task.sleep(for: .milliseconds(40))
            view.layoutSubtreeIfNeeded(); view.canvasHost.layoutSubtreeIfNeeded()
            guard let source = nativeCard(in: view.canvasHost, id: item.id) else { preconditionFailure("missing native card") }
            // NSView.hitTest takes its parent's coordinates; the surface is
            // flipped while the borderless window's frame view is not.
            let hitPoint = source.convert(CGPoint(x: source.bounds.midX, y: source.bounds.midY), to: surface.superview)
            precondition(surface.hitTest(hitPoint) === source, "scaled card must own its visible center")
            let nearRightEdge = source.convert(CGPoint(x: source.bounds.maxX - 10, y: source.bounds.midY), to: surface.superview)
            precondition(surface.hitTest(nearRightEdge) === source, "scaled image must not intercept its neighbor")
            let imageSource = nativeCard(in: view.canvasHost, id: neighbor.id)!
            let imageCenter = imageSource.convert(CGPoint(x: imageSource.bounds.midX, y: imageSource.bounds.midY), to: surface.superview)
            precondition(surface.hitTest(imageCenter) === imageSource)
            let target = CGPoint(x: 2000, y: 1400)
            drag.draggingLocation = view.canvasHost.convert(CGPoint(x: target.x * view.zoom, y: target.y * view.zoom), to: nil)
            drag.draggingSource = source
            model.dragging = item.id; model.dragOffset = CanvasPoint(x: 32, y: 32)
            precondition(drag.draggingPasteboard.setString(item.id.uuidString, forType: .dumpMaterial))
            precondition(window.draggingEntered(drag) == .move && window.draggingUpdated(drag) == .move)
            let preview = model.dragPoint
            precondition(preview == CanvasPoint(x: 1968, y: 1368), "drag preview uses unscaled material coordinates")
            precondition(window.performDragOperation(drag)); await model.waitForWrites()
            precondition(model.items.first { $0.id == item.id }?.position == preview, "preview and committed move agree")
            model.dragging = nil; model.dragPoint = nil
            try await library.move(item.id, to: item.position); await model.refresh()

            drag.draggingSource = nil; drag.draggingPasteboard.clearContents()
            precondition(drag.draggingPasteboard.setString("synthetic drop at \(zoom)", forType: .string))
            drag.draggingLocation = view.canvasHost.convert(CGPoint(x: 2100 * view.zoom, y: 1200 * view.zoom), to: nil)
            precondition(window.draggingEntered(drag) == .copy && window.performDragOperation(drag))
            await model.waitForWrites()
            let added = model.items.first { $0.id != item.id && $0.position == CanvasPoint(x: 2112, y: 1200) }
            precondition(added != nil, "external drop follows the scaled native document")
            model.askRemoval(ids: [added!.id]); await model.waitForWrites()
            model.confirmRemoval(); await model.waitForWrites()
            model.scrollTo = nil
        }
        print("PASS 50%, 100% and 200% native card hits, internal preview/commit and external text drops")

        view.setZoom(0.5); view.scroll(to: CGPoint(x: 1000, y: 800))
        let saved = model.viewportStates[model.viewportKey]!
        let second = try await library.createCollection("second synthetic canvas")
        await model.refresh(); view.configure()
        precondition(model.index.currentCollection == second.id && view.zoom == 1 && view.visibleCanvasRect.origin == .zero)
        model.selectCollection(group); await model.waitForWrites(); view.configure()
        precondition(view.zoom == saved.zoom && hypot(view.visibleCanvasRect.minX - saved.origin.x, view.visibleCanvasRect.minY - saved.origin.y) < 1)
        view.setZoom(1); view.scroll(to: .zero)
        model.drafts[item.id] = AnswerDraft(sourceID: item.id, answer: "synthetic answer; no AI request")
        model.activeAnswer = item.id; view.configure()
        let answer = model.answerPosition(item)
        precondition(view.visibleCanvasRect.contains(CGRect(x: answer.x, y: answer.y, width: 284, height: 430)), "offscreen answer is brought into view")
        precondition(model.items.first { $0.id == item.id }?.position == item.position)
        precondition(!window.isVisible)
        print("PASS collection-specific view restoration and offscreen answer reveal without changing materials")
        func answerEditor(in parent: NSView) -> NSTextView? {
            if let text = parent as? NSTextView { return text }
            return parent.subviews.lazy.compactMap { answerEditor(in: $0) }.first
        }
        for zoom in [0.5, 2.0] {
            view.setZoom(zoom); view.scroll(to: CGPoint(x: answer.x - 24, y: answer.y - 24))
            try await Task.sleep(for: .milliseconds(40)); view.canvasHost.layoutSubtreeIfNeeded()
            guard let field = answerEditor(in: view.canvasHost) else { preconditionFailure("missing answer editor") }
            let point = field.convert(CGPoint(x: 20, y: 20), to: surface.superview)
            precondition(surface.hitTest(point) === field, "scaled answer editor must accept input")
            precondition(window.makeFirstResponder(field))
            precondition(!view.handlePanEvent(key(.keyDown)), "space in scaled editor must not pan")
        }
        window.makeFirstResponder(nil)
        model.activeAnswer = nil
        view.setZoom(0.8); view.stop(); view.removeFromSuperview()
        model.canvasZoom = 1.25
        try await Task.sleep(for: .milliseconds(40))
        precondition(model.canvasZoom == 1.25, "removed viewport must not overwrite a new view's zoom display")

        // Exercise the actual shell's resize and lifecycle, including a close
        // to the rail and reopening, rather than only changing a model flag.
        surface.addSubview(surface.host)
        func viewport(in parent: NSView) -> CanvasScrollView? {
            if let canvas = parent as? CanvasScrollView { return canvas }
            return parent.subviews.lazy.compactMap { viewport(in: $0) }.first
        }
        func resizeShell(expanded: Bool) async throws -> CanvasScrollView {
            let size = expanded ? CGSize(width: 1120, height: 900) : CGSize(width: 540, height: 768)
            window.setFrame(CGRect(origin: .zero, size: size), display: false)
            surface.host.rootView = AnyView(WorkbenchView(model: model, width: size.width - 20, height: size.height - 48))
            surface.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40)); surface.layoutSubtreeIfNeeded()
            return viewport(in: surface)!
        }
        var actual = try await resizeShell(expanded: true)
        actual.setZoom(0.8); actual.scroll(to: CGPoint(x: 1000, y: 800))
        model.toggleExpanded(); actual = try await resizeShell(expanded: false)
        precondition(actual.zoom == 1 && actual.frame.width <= 520)
        model.toggleExpanded(); actual = try await resizeShell(expanded: true)
        precondition(actual.zoom == 0.8 && abs(actual.visibleCanvasRect.minX - 1000) < 1 && abs(actual.visibleCanvasRect.minY - 800) < 1)
        surface.host.rootView = AnyView(EmptyView())
        try await Task.sleep(for: .milliseconds(40)); surface.layoutSubtreeIfNeeded()
        precondition(model.canvasDocumentView == nil)
        actual = try await resizeShell(expanded: true)
        precondition(actual.zoom == 0.8 && abs(actual.visibleCanvasRect.minX - 1000) < 1 && abs(actual.visibleCanvasRect.minY - 800) < 1)
        precondition(!window.isVisible)
        print("PASS scaled answer editor; actual shell expansion, contraction and rail reopening restore views")
        let beforeDockChange = model.items
        for edge in DockEdge.allCases {
            model.preferences.dockEdge = edge
            let size = edge == .top ? CGSize(width: 948, height: 560) : CGSize(width: 540, height: 768)
            window.setFrame(CGRect(origin: .zero, size: size), display: false)
            surface.host.rootView = AnyView(WorkbenchView(model: model, width: size.width - (edge == .top ? 48 : 20), height: size.height - (edge == .top ? 20 : 48)))
            surface.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40)); surface.layoutSubtreeIfNeeded()
            actual = viewport(in: surface)!
            precondition(actual.frame.width <= size.width && actual.frame.height <= size.height)
            precondition(model.items == beforeDockChange, "docking must preserve positions, sizes and stacks")
            precondition(!window.isVisible)
        }
        print("PASS right/left/top actual shell layouts preserve all material coordinates without showing windows")
        actual.stop(); window.contentView = nil
        try await model.shutdown()
        let reopened = try Library(root: root)
        let restored = await reopened.index.items.first { $0.id == item.id }
        precondition(restored?.position == item.position, "wide coordinates survive reopen")
    }
}
