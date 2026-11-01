import AppKit
import QuickLookUI

@MainActor final class DumpPanel: NSPanel, NSDraggingDestination, @preconcurrency QLPreviewPanelDataSource {
    private weak var dropSurface: DropSurface?
    private var previewItems: [SystemPreviewItem] = []
    private weak var controlledPreview: QLPreviewPanel?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    func presentPreview(_ items: [SystemPreviewItem]) {
        guard !items.isEmpty else { return }
        previewItems = items
        if let panel = controlledPreview {
            panel.reloadData(); panel.currentPreviewItemIndex = 0
            panel.makeKeyAndOrderFront(nil)
        } else { QLPreviewPanel.shared()?.makeKeyAndOrderFront(nil) }
    }
    func dismissPreview() { controlledPreview?.close() }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { !previewItems.isEmpty }
    }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { controlledPreview = panel; panel.dataSource = self }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil; controlledPreview = nil; previewItems = [] }
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewItems.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { previewItems[index] }
    func receiveDrops(on surface: DropSurface) {
        dropSurface = surface
        registerForDraggedTypes(DropSurface.supportedTypes)
    }
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dropSurface?.draggingEntered(sender) ?? [] }
    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dropSurface?.draggingUpdated(sender) ?? [] }
    func draggingExited(_ sender: NSDraggingInfo?) { dropSurface?.draggingExited(sender) }
    func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { dropSurface?.prepareForDragOperation(sender) ?? false }
    func performDragOperation(_ sender: NSDraggingInfo) -> Bool { dropSurface?.performDragOperation(sender) ?? false }
}
