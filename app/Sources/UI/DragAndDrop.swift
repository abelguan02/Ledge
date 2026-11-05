import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CardResizeHandle: NSViewRepresentable {
    @Environment(\.ledgeSkin) private var skin
    let model: WorkbenchModel
    let item: Material
    func makeNSView(context: Context) -> CardResizeView { CardResizeView(model: model, item: item) }
    func updateNSView(_ view: CardResizeView, context: Context) { view.skin = skin; view.item = item; view.needsDisplay = true }
    static func dismantleNSView(_ view: CardResizeView, coordinator: ()) { view.cancelOperation(nil) }
}

@MainActor final class CardResizeView: NSView {
    var skin = LedgeSkin.classic
    let model: WorkbenchModel
    var item: Material
    private var start: CGPoint?
    private var moved = false
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(model: WorkbenchModel, item: Material) { self.model = model; self.item = item; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func draw(_ dirtyRect: NSRect) {
        let scale = model.canvasCoordinateScale
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = skin.palette.resizeShadow; shadow.shadowBlurRadius = skin.shadows.resizeBlur / scale; shadow.set()
        let path = skin.shapes.resizeGrip(scale: scale)
        skin.palette.resizeHandle.setStroke(); path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
    override func resetCursorRects() {
        let image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "调整卡片大小")!
        addCursorRect(bounds, cursor: NSCursor(image: image, hotSpot: CGPoint(x: image.size.width / 2, y: image.size.height / 2)))
    }
    override func mouseDown(with event: NSEvent) {
        model.beginResize(item)
        guard model.resizing != nil else { return }
        start = event.locationInWindow; moved = false; window?.makeFirstResponder(self)
        if let document = model.canvasDocumentView {
            let pointer = document.convert(event.locationInWindow, from: nil)
            model.resizePointer = CanvasPoint(x: pointer.x / model.canvasCoordinateScale, y: pointer.y / model.canvasCoordinateScale)
        }
    }
    private func update(_ event: NSEvent) {
        guard let start, let document = model.canvasDocumentView else { return }
        let scale = model.canvasCoordinateScale
        let pointer = document.convert(event.locationInWindow, from: nil)
        model.updateResize(delta: CanvasPoint(x: (event.locationInWindow.x - start.x) / scale, y: (start.y - event.locationInWindow.y) / scale),
                           pointer: CanvasPoint(x: pointer.x / scale, y: pointer.y / scale), free: event.modifierFlags.contains(.option))
    }
    override func mouseDragged(with event: NSEvent) { moved = true; update(event) }
    override func mouseUp(with event: NSEvent) { if start != nil { if moved { update(event) }; start = nil; model.endResize() } }
    override func cancelOperation(_ sender: Any?) { if start != nil { start = nil; model.endResize(cancelled: true) } }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window { NotificationCenter.default.addObserver(self, selector: #selector(resigned), name: NSWindow.didResignKeyNotification, object: window) }
        else { cancelOperation(nil) }
    }
    @objc private func resigned() { cancelOperation(nil) }
}

// Opt-in event diagnostics for native drag failures. Never log names or contents.
private func traceTransfer(_ event: String) {
    guard ProcessInfo.processInfo.environment["DUMP_TRACE_TRANSFERS"] == "1" else { return }
    FileHandle.standardError.write(Data("Dump transfer: \(event)\n".utf8))
}

struct MaterialDragSource: NSViewRepresentable {
    @ObservedObject var model: WorkbenchModel
    let item: Material
    var inTray = false
    func makeNSView(context: Context) -> MaterialDragView { MaterialDragView(model: model, item: item, inTray: inTray) }
    func updateNSView(_ view: MaterialDragView, context: Context) { view.item = item; view.inTray = inTray }
}
@MainActor final class MaterialDragView: NSView, NSDraggingSource {
    let model: WorkbenchModel
    var item: Material
    var inTray: Bool
    private var down: NSEvent?
    private var selectOnMouseUp = false
    private var openOnMouseUp = false
    private var pendingPreview: Task<Void, Never>?
    init(model: WorkbenchModel, item: Material, inTray: Bool = false) { self.model = model; self.item = item; self.inTray = inTray; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) {
        if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(); menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self; entry.isEnabled = enabled; menu.addItem(entry)
        }
        add(item.stackID != nil && !inTray ? "展开" : "打开", #selector(openMaterial))
        if item.kind == .link { add("复制", #selector(copyMaterials), enabled: !model.locked) }
        add("导出副本…", #selector(exportMaterial))
        if item.kind == .link {
            add("刷新网页预览", #selector(refreshWebPreview), enabled: model.webProgress[item.id] == nil && !model.missingCopies.contains(item.id))
        } else { add("复制选中", #selector(copyMaterials), enabled: !model.locked) }
        if item.displaySize != nil, item.stackID == nil { add("恢复默认大小", #selector(resetSize), enabled: !model.locked) }
        if let _ = item.stackID, !inTray { add("解除堆叠", #selector(dissolve), enabled: !model.locked) }
        if item.sourcePath != nil { add("查看原件位置", #selector(revealMaterial)) }
        if let error = model.errors[item.id] {
            let message = NSMenuItem(title: error, action: nil, keyEquivalent: ""); message.isEnabled = false; menu.addItem(message)
            add("关闭错误提示", #selector(clearError))
        }
        menu.addItem(.separator())
        add("删除…", #selector(deleteMaterial), enabled: !model.locked)
        return menu
    }
    @objc private func openMaterial() {
        if let stack = item.stackID, !inTray { model.openStack(stack) } else { model.open(item) }
    }
    @objc private func dissolve() { if let stack = item.stackID { model.dissolveStack(stack) } }
    @objc private func exportMaterial() { model.export(model.selectionUnit(item)) }
    @objc private func copyMaterials() {
        if !model.selected.contains(item.id) { model.select(item.id) }
        model.copySelected()
    }
    @objc private func revealMaterial() { model.revealOriginal(item) }
    @objc private func deleteMaterial() { model.askRemoval(ids: model.selectionUnit(item)) }
    @objc private func clearError() { model.errors[item.id] = nil; model.statusChanged?() }
    @objc private func resetSize() { model.resize(item.id, to: nil) }
    @objc private func refreshWebPreview() { model.generateWebPreview(item) }
    override func mouseDown(with event: NSEvent) {
        pendingPreview?.cancel(); pendingPreview = nil
        guard model.removal == nil else { return }
        window?.makeFirstResponder(self)
        traceTransfer("source.mouseDown")
        down = event
        let extending = event.modifierFlags.contains(.command)
        selectOnMouseUp = !extending && model.selected.contains(item.id) && model.selected.count > 1
        if !selectOnMouseUp { model.select(item.id, extending: extending) }
        let location = convert(event.locationInWindow, from: nil)
        let playHit = item.kind == .video ? hypot(location.x - bounds.midX, location.y - bounds.midY) < 24 : item.kind == .audio && location.x < 50
        openOnMouseUp = !extending && playHit && model.durations[item.id] != nil && (item.stackID == nil || inTray)
        if event.clickCount == 2 {
            down = nil; selectOnMouseUp = false; openOnMouseUp = false; model.select(item.id); openMaterial()
        }
    }
    override func mouseUp(with event: NSEvent) {
        if down != nil, selectOnMouseUp { model.select(item.id) }
        if down != nil, openOnMouseUp {
            model.select(item.id)
            // A double click must reach the external-open action before a
            // single click on the play badge can transfer focus to Quick Look.
            pendingPreview = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval)) } catch { return }
                guard let self, self.window != nil, self.model.selected == [self.item.id] else { return }
                self.model.previewSelected(); self.pendingPreview = nil
            }
        }
        down = nil; selectOnMouseUp = false; openOnMouseUp = false
    }
    override func mouseDragged(with event: NSEvent) {
        pendingPreview?.cancel(); pendingPreview = nil
        guard let down, model.selected.contains(item.id),
              hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y) > 4 else { return }
        self.down = nil; selectOnMouseUp = false; openOnMouseUp = false
        let dragging: [NSDraggingItem]
        do { dragging = try makeDraggingItems() }
        catch { model.fail(error); return }
        traceTransfer("source.begin")
        model.draggedIDs = Set(model.selectedItems.map(\.id))
        model.dragging = item.id
        model.dragFromStack = inTray
        let local = convert(down.locationInWindow, from: nil)
        model.dragOffset = inTray ? CanvasPoint(x: 0, y: 0) : CanvasPoint(x: local.x, y: bounds.height - local.y)
        beginDraggingSession(with: dragging, event: down, source: self)
    }
    // The complete set is validated before handing any payload to AppKit.
    // Keeping each file as a separate writer lets Finder copy mixed groups.
    func makeDraggingItems() throws -> [NSDraggingItem] {
        let members = model.selected.contains(item.id) ? model.selectedItems : [item]
        let writers = try MaterialTransfer.writers(members, urls: model.payloadURLs)
        return zip(members, writers).map { member, writer in
            let url = model.payloadURLs[member.id]!
            let dragging = NSDraggingItem(pasteboardWriter: writer)
            let preview = model.thumbnails[member.id] ?? NSWorkspace.shared.icon(forFile: url.path)
            dragging.setDraggingFrame(CGRect(x: bounds.minX + member.position.x - item.position.x,
                y: bounds.maxY - (member.position.y - item.position.y) - member.size.height,
                width: member.size.width, height: member.size.height), contents: preview)
            return dragging
        }
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : .copy
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        traceTransfer("source.end operation=\(operation.rawValue)")
        model.dragging = nil; model.dragPoint = nil; model.draggedIDs = []; model.dragFromStack = false; model.clearStackHover()
    }
}

enum PanelMode { case line, drop, canvas }
@MainActor final class DropSurface: NSView {
    static let supportedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string, .png, .tiff, .webURLsWithTitles, .dumpMaterial] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    let model: WorkbenchModel
    var mode: PanelMode = .line
    var showDrop: (() -> Void)?
    var showCanvas: (() -> Void)?
    var hideDrop: (() -> Void)?
    let host: NSHostingView<AnyView>
    override var isFlipped: Bool { true }
    init(model: WorkbenchModel) {
        self.model = model; host = NSHostingView(rootView: AnyView(EmptyView()))
        super.init(frame: .zero)
        addSubview(host); host.autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func layout() { super.layout(); host.frame = bounds }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // SwiftUI draws the collapsed rail; this native view owns its click
        // target and the stable panel receives the drag session.
        return mode == .line ? self : hit
    }
    override func mouseDown(with event: NSEvent) { if mode == .line { showCanvas?() } else { super.mouseDown(with: event) } }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        traceTransfer("destination.enter")
        guard !model.importing, model.removal == nil else { return [] }
        if internalMaterial(sender) != nil { return mode == .canvas ? .move : [] }
        guard describe(sender.draggingPasteboard) else { return [] }
        if mode == .line { showDrop?() }
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !model.importing, model.removal == nil else { return [] }
        let location = convert(sender.draggingLocation, from: nil)
        if internalMaterial(sender) != nil {
            guard mode == .canvas else { return [] }
            model.scrollCanvasDuringDrag?(sender.draggingLocation)
            guard let desired = internalPoint(convert(sender.draggingLocation, from: nil)) else { return [] }
            if let pointer = canvasPoint(location) { model.updateStackHover(at: pointer) }
            if let id = model.dragging, !model.dragFromStack { model.previewMove(anchor: id, to: desired) }
            return .move
        }
        if mode == .drop {
            let edge = model.preferences.dockEdge
            let bottomInset: CGFloat = edge == .top ? 20 : 24
            let contentX: CGFloat = edge == .right ? 20 : edge == .top ? 24 : 0
            model.dropZone = location.y > bounds.height - bottomInset - 82 && model.dropKind.hasActions && (model.dropKind == .image || model.canUseAI) ? (location.x < contentX + 150 ? 1 : 2) : 0
        }
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        traceTransfer("destination.exit")
        if mode == .drop { hideDrop?() }
        model.dragPoint = nil
        model.clearStackHover()
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !model.importing && model.removal == nil && (mode != .canvas || model.canvasDocumentView != nil)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        traceTransfer("destination.perform")
        guard prepareForDragOperation(sender) else { return false }
        let board = sender.draggingPasteboard
        let point = mode == .canvas ? canvasPoint(convert(sender.draggingLocation, from: nil)) : nil
        if let id = internalMaterial(sender), mode == .canvas {
            guard let point = internalPoint(convert(sender.draggingLocation, from: nil)) else { return false }
            if model.dragFromStack, !model.visibleCanvasRect.contains(CGPoint(x: point.x, y: point.y)) { return false }
            if model.dragFromStack, let tray = model.stackTrayView,
               tray.bounds.contains(tray.convert(sender.draggingLocation, from: nil)) { return false }
            if !model.dragFromStack, let pointer = canvasPoint(convert(sender.draggingLocation, from: nil)) { model.updateStackHover(at: pointer) }
            model.dropMaterial(id, at: point); return true
        }
        var action: String?
        if mode == .drop, model.dropKind.hasActions, model.dropZone > 0 {
            action = model.dropKind == .image ? (model.dropZone == 1 ? "压缩" : "识别文字") : (model.dropZone == 1 ? "翻译" : "解释")
        }
        if let receivers = board.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            traceTransfer("destination.promisedFiles")
            let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
            let items = board.pasteboardItems ?? []
            let promised = items.filter { $0.availableType(from: promiseTypes) != nil }
            let additional = MaterialTransfer.received(items.filter { $0.availableType(from: promiseTypes) == nil })
            model.receivePromises(receivers, point: point, action: action, metadata: promised.map(MaterialTransfer.source), additional: additional)
            showCanvas?(); return true
        }
        guard let payload = Self.payload(board) else { model.message = "这个拖入内容没有可读取的文件、文字或图片。"; return false }
        traceTransfer("destination.copy")
        model.importPayload(payload, at: point, action: action); showCanvas?(); return true
    }
    private func internalMaterial(_ sender: NSDraggingInfo) -> UUID? {
        // Only the actual source view may relocate a material. An external
        // pasteboard can advertise the same private type but is still a copy.
        guard let source = sender.draggingSource as? MaterialDragView, source.model === model else { return nil }
        return source.item.id
    }
    func paste() {
        guard mode == .canvas, model.removal == nil else { return }
        // This is the only read of the general clipboard, reached via explicit ⌘V.
        if let payload = Self.payload(.general) { model.importPayload(payload) }
        else { model.message = "剪贴板中没有可接收的文件、文字或图片。" }
    }
    private func canvasPoint(_ point: CGPoint) -> CanvasPoint? {
        guard let document = model.canvasDocumentView else { return nil }
        let position = document.convert(point, from: self)
        return CanvasPoint(x: max(0, position.x / model.canvasCoordinateScale),
                           y: max(0, (document.isFlipped ? position.y : document.bounds.height - position.y) / model.canvasCoordinateScale))
    }
    private func internalPoint(_ point: CGPoint) -> CanvasPoint? {
        guard let location = canvasPoint(point) else { return nil }
        return CanvasPoint(x: location.x - model.dragOffset.x, y: location.y - model.dragOffset.y)
    }
    @discardableResult func describe(_ board: NSPasteboard) -> Bool {
        guard board.availableType(from: Self.supportedTypes) != nil, !model.importing, model.removal == nil else { return false }
        if let promises = board.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !promises.isEmpty {
            let types = promises.flatMap(\.fileTypes)
            let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
            let others = (board.pasteboardItems ?? []).filter { $0.availableType(from: promiseTypes) == nil }.count
            model.dropCount = types.count + others
            model.dropKind = others == 0 && !types.isEmpty && types.allSatisfy { UTType($0)?.conforms(to: .image) == true } ? .image : .file
        } else {
            let kinds: [DropKind] = (board.pasteboardItems ?? []).flatMap { item -> [DropKind] in
                if let value = item.string(forType: .fileURL), let url = URL(string: value), url.isFileURL {
                    return [MediaPreview.kind(url) == .image ? .image : .file]
                }
                if item.availableType(from: [.png, .tiff]) != nil { return [.image] }
                if let text = item.string(forType: .URL) ?? item.string(forType: .string) {
                    return [Library.webURL(text.trimmingCharacters(in: .whitespacesAndNewlines)) == nil ? .text : .link]
                }
                if let pairs = item.propertyList(forType: .webURLsWithTitles) as? [[String]], pairs.count == 2 {
                    return pairs[0].compactMap { Library.webURL($0) == nil ? nil : .link }
                }
                return []
            }
            model.dropCount = kinds.count
            model.dropKind = kinds.first.map { first in kinds.allSatisfy { $0 == first } ? first : .file } ?? .file
        }
        model.dropZone = 0
        return true
    }
    static func payload(_ board: NSPasteboard) -> ImportPayload? {
        let materials = MaterialTransfer.received(board)
        return materials.isEmpty ? nil : .materials(materials)
    }
}

struct DropView: View {
    @Environment(\.ledgeSkin) private var skin
    @ObservedObject var model: WorkbenchModel
    var body: some View {
        PanelShell(width: 300, height: 420, edge: model.preferences.dockEdge) {
            VStack(spacing: 12) {
                Text("\(model.dropCount) \(model.dropKind == .image ? "张图片" : model.dropKind == .text ? "段文字" : model.dropKind == .link ? "个链接" : "个文件") → \(model.collectionName)")
                    .font(skin.typography.caption).foregroundStyle(skin.ink.secondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                tile("放进来", zone: 0).frame(maxHeight: .infinity)
                if model.dropKind.hasActions {
                    HStack(spacing: 10) {
                        tile(model.dropKind == .image ? "压缩" : "翻译", zone: 1)
                        tile(model.dropKind == .image ? "识别文字" : "解释", zone: 2)
                    }.frame(height: 64)
                }
            }.padding(16)
        }
    }
    private func tile(_ text: String, zone: Int) -> some View {
        Text(text).font(skin.typography.dropLabel(primary: zone == 0)).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(skin.ink.dropFill(active: model.dropZone == zone), in: skin.shapes.dropZone)
            .overlay(skin.shapes.dropZone.stroke(skin.ink.dropBorder(active: model.dropZone == zone), lineWidth: model.dropZone == zone ? 1.5 : 1))
            .opacity(zone > 0 && model.dropKind == .text && !model.canUseAI ? skin.opacity.disabled : 1)
            .help(zone > 0 && model.dropKind == .text ? model.aiHelp : "")
    }
}
