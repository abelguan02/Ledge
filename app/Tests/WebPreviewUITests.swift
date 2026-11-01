import AppKit
import SwiftUI

@main @MainActor struct WebPreviewUITests {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dump-web-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Library(root: root, makeBookmark: { _ in Data() })
        let group = await library.index.currentCollection
        let link = try await library.importText("https://example.com/item?token=synthetic", collection: group, preferred: .init(x: 240, y: 240))
        let model = WorkbenchModel(library: library); await model.refresh(); model.isExpanded = true
        let surface = DropSurface(model: model); surface.mode = .canvas
        surface.frame = CGRect(x: 0, y: 0, width: 1140, height: 948)
        surface.host.rootView = AnyView(WorkbenchView(model: model, width: 1100, height: 900))
        let window = DumpPanel(contentRect: surface.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = surface
        func source(in view: NSView) -> MaterialDragView? {
            if let value = view as? MaterialDragView, value.item.id == link.id { return value }
            return view.subviews.lazy.compactMap { source(in: $0) }.first
        }
        func viewport(in view: NSView) -> CanvasScrollView? {
            if let value = view as? CanvasScrollView { return value }
            return view.subviews.lazy.compactMap { viewport(in: $0) }.first
        }
        surface.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100))
        for zoom in [0.25, 1.0, 2.0] {
            model.changeCanvasZoom?(zoom)
            viewport(in: surface)!.scroll(to: .zero)
            try await Task.sleep(for: .milliseconds(100)); surface.layoutSubtreeIfNeeded()
            let card = source(in: surface)!
            let buttonCenter = card.convert(CGPoint(x: 108, y: 192 - 84.5), to: surface.superview)
            let titlePoint = card.convert(CGPoint(x: 108, y: 20), to: surface.superview)
            precondition(surface.hitTest(titlePoint) === card, "ordinary link content must remain draggable at \(zoom)")
            let actionHit = surface.hitTest(buttonCenter)
            precondition(actionHit != nil && !(actionHit is MaterialDragView), "preview action must not be covered by the native drag view at \(zoom)")
        }
        let editor = NSTextView(frame: .zero); surface.addSubview(editor); window.makeFirstResponder(editor)
        let card = source(in: surface)!
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: card.convert(CGPoint(x: 20, y: 20), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        card.mouseDown(with: event)
        precondition(window.firstResponder === card, "clicking a card must end text-editor focus before space preview")
        precondition(!window.isVisible)
        window.contentView = nil; try await model.shutdown()
        print("PASS link preview action hit regions at 25/100/200%, retained card dragging, card focus after editing and no visible windows")
    }
}
