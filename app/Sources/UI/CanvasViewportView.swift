import AppKit
import SwiftUI
private typealias CanvasLocalState<Value> = SwiftUI.State<Value>

struct CanvasViewportView: NSViewRepresentable {
    @ObservedObject var model: WorkbenchModel
    func makeNSView(context: Context) -> CanvasScrollView { CanvasScrollView(model: model) }
    func updateNSView(_ view: CanvasScrollView, context: Context) { view.configure() }
    static func dismantleNSView(_ view: CanvasScrollView, coordinator: ()) { view.stop() }
}

// AppKit scrolls the document; SwiftUI scales its own content so native card
// and editor hit regions follow the same transform as the rendered controls.
@MainActor final class CanvasScrollView: NSScrollView {
    let model: WorkbenchModel
    let canvasHost: NSHostingView<ScaledCanvasContent>
    private(set) var zoom = 1.0
    private var renderedZoom = 0.0
    private var documentWorldSize = CGSize.zero
    var visibleCanvasRect: CGRect {
        let rect = documentVisibleRect
        return CGRect(x: rect.minX / zoom, y: rect.minY / zoom, width: rect.width / zoom, height: rect.height / zoom)
    }
    private var boundKey: CanvasViewportKey?
    private var configuring = false
    private var stopped = false
    private var monitor: Any?
    private var spacePressed = false
    private var spaceDragged = false
    private var panStart: (mouse: CGPoint, origin: CGPoint)?
    private var lastAnswer: UUID?
    private var revealedItem: UUID?
    private let usesSystemCursor: Bool

    init(model: WorkbenchModel, usesSystemCursor: Bool = true) {
        self.model = model
        self.usesSystemCursor = usesSystemCursor
        canvasHost = NSHostingView(rootView: ScaledCanvasContent(model: model, size: model.canvasContentSize, zoom: 1))
        lastAnswer = model.activeAnswer
        super.init(frame: .zero)
        drawsBackground = false; borderType = .noBorder
        hasHorizontalScroller = true; hasVerticalScroller = true
        autohidesScrollers = true; scrollerStyle = .overlay
        horizontalScrollElasticity = .none; verticalScrollElasticity = .none
        allowsMagnification = false
        canvasHost.sizingOptions = []
        canvasHost.unregisterDraggedTypes()
        documentView = canvasHost
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportMoved), name: NSView.boundsDidChangeNotification, object: contentView)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handlePanEvent(event) ?? false }
            return handled ? nil : event
        }
        model.canvasDocumentView = canvasHost
        model.changeCanvasZoom = { [weak self] zoom in self?.setZoom(zoom) }
        model.scrollCanvasDuringDrag = { [weak self] point in self?.scrollDuringDrag(at: point) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure() {
        guard !stopped, !configuring else { return }
        configuring = true
        defer { configuring = false; recordViewport() }
        let key = model.viewportKey
        let changed = boundKey != key
        if changed {
            saveBoundViewport()
            boundKey = key; lastAnswer = model.activeAnswer; revealedItem = nil
            stopPanning()
            model.endSelection(cancelled: true)
        }
        let state = model.viewportStates[key] ?? CanvasViewportState()
        if changed { zoom = state.zoom }
        updateDocumentSize()
        if changed {
            scroll(to: state.origin)
        }
        if let id = model.scrollTo, id != revealedItem, let item = model.items.first(where: { $0.id == id }) {
            reveal(CGRect(x: item.position.x, y: item.position.y, width: item.size.width, height: item.size.height))
            revealedItem = id
            Task { @MainActor [weak self] in
                guard let self, self.model.scrollTo == id else { return }
                self.model.scrollTo = nil
            }
        }
        if model.scrollTo == nil { revealedItem = nil }
        if lastAnswer != model.activeAnswer {
            lastAnswer = model.activeAnswer
            if let id = lastAnswer, let item = model.items.first(where: { $0.id == id }) {
                let point = model.answerPosition(item)
                reveal(CGRect(x: point.x, y: point.y, width: 284, height: 430))
            }
        }
    }
    override func layout() {
        super.layout()
        configure()
    }
    private func updateDocumentSize() {
        let content = model.canvasContentSize
        let size = CGSize(width: max(content.width, contentSize.width / zoom), height: max(content.height, contentSize.height / zoom))
        if documentWorldSize != size || renderedZoom != zoom {
            documentWorldSize = size; renderedZoom = zoom
            canvasHost.rootView = ScaledCanvasContent(model: model, size: size, zoom: zoom)
            canvasHost.setFrameSize(CGSize(width: size.width * zoom, height: size.height * zoom))
        }
        model.canvasCoordinateScale = zoom
    }
    func setZoom(_ requested: Double) {
        setZoom(requested, anchor: CGPoint(x: contentSize.width / 2, y: contentSize.height / 2))
    }
    private func setZoom(_ requested: Double, anchor: CGPoint) {
        guard model.isExpanded, requested.isFinite, !model.selecting, model.dragging == nil, model.resizing == nil else { return }
        let point = CGPoint(x: visibleCanvasRect.minX + anchor.x / zoom, y: visibleCanvasRect.minY + anchor.y / zoom)
        configuring = true
        zoom = min(max(requested, CanvasViewportState.zoomRange.lowerBound), CanvasViewportState.zoomRange.upperBound)
        updateDocumentSize()
        scroll(to: CGPoint(x: point.x - anchor.x / zoom, y: point.y - anchor.y / zoom))
        configuring = false
        recordViewport()
    }
    override func magnify(with event: NSEvent) {
        let point = contentView.convert(event.locationInWindow, from: nil)
        setZoom(zoom * (1 + event.magnification),
                anchor: CGPoint(x: point.x - contentView.bounds.minX, y: point.y - contentView.bounds.minY))
    }
    func scroll(to origin: CGPoint) {
        let scaled = CGPoint(x: origin.x * zoom, y: origin.y * zoom)
        let target = contentView.constrainBoundsRect(CGRect(origin: scaled, size: contentView.bounds.size)).origin
        contentView.scroll(to: target)
        reflectScrolledClipView(contentView)
        recordViewport()
    }
    func scrollDuringDrag(at point: CGPoint) {
        let local = contentView.convert(point, from: nil)
        let bounds = contentView.bounds
        // A small outside margin keeps an edge drag scrolling, but a pointer
        // over another app must not scroll this canvas during an export.
        guard bounds.insetBy(dx: -24, dy: -24).contains(local) else { return }
        func step(_ value: Double, _ low: Double, _ high: Double) -> Double {
            if value < low + 28 { return -16 / zoom }
            if value > high - 28 { return 16 / zoom }
            return 0
        }
        let dx = step(local.x, bounds.minX, bounds.maxX), dy = step(local.y, bounds.minY, bounds.maxY)
        if dx != 0 || dy != 0 {
            scroll(to: CGPoint(x: visibleCanvasRect.minX + dx, y: visibleCanvasRect.minY + dy))
        }
    }
    private func reveal(_ rect: CGRect) {
        let visible = visibleCanvasRect
        if !visible.insetBy(dx: 16, dy: 48).contains(rect) {
            scroll(to: CGPoint(x: max(0, rect.midX - visible.width / 2), y: max(0, rect.midY - visible.height / 2)))
        }
    }
    @objc private func viewportMoved(_ notification: Notification) { recordViewport() }
    private func saveBoundViewport() {
        if let key = boundKey { model.viewportStates[key] = CanvasViewportState(zoom: zoom, origin: visibleCanvasRect.origin) }
    }
    private func recordViewport() {
        guard !configuring, boundKey != nil else { return }
        saveBoundViewport()
        guard boundKey == model.viewportKey else { return }
        model.visibleCanvasRect = visibleCanvasRect
        // Bounds notifications can arrive during a SwiftUI update. Publish the
        // displayed percentage on the next MainActor turn, using current state.
        Task { @MainActor [weak self] in
            guard let self, self.boundKey == self.model.viewportKey else { return }
            if abs(self.model.canvasZoom - self.zoom) > 0.0001 { self.model.canvasZoom = self.zoom }
        }
    }
    func handlePanEvent(_ event: NSEvent) -> Bool {
        if event.type == .keyUp, event.keyCode == 49, spacePressed {
            let preview = !spaceDragged && event.window === window && model.removal == nil
            stopPanning()
            if preview { model.previewSelected() }
            return true
        }
        guard event.window === window, model.removal == nil, window?.attachedSheet == nil, !model.choosingFiles else { return false }
        if event.type == .keyDown, event.keyCode == 53, spacePressed { stopPanning(); return true }
        if event.type == .keyDown, event.keyCode == 49, !model.selecting, model.dragging == nil, model.resizing == nil, !(window?.firstResponder is NSTextView),
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            if !spacePressed { spacePressed = true; spaceDragged = false; if usesSystemCursor { NSCursor.openHand.push() } }
            return true
        }
        if event.type == .leftMouseDown, spacePressed, bounds.contains(convert(event.locationInWindow, from: nil)) {
            panStart = (event.locationInWindow, visibleCanvasRect.origin)
            if usesSystemCursor { NSCursor.closedHand.set() }; return true
        }
        if event.type == .leftMouseDragged, let start = panStart {
            spaceDragged = true
            scroll(to: CGPoint(x: start.origin.x - (event.locationInWindow.x - start.mouse.x) / zoom,
                               y: start.origin.y + (event.locationInWindow.y - start.mouse.y) / zoom))
            return true
        }
        if event.type == .leftMouseUp, panStart != nil {
            panStart = nil; if usesSystemCursor { NSCursor.openHand.set() }; return true
        }
        return false
    }
    private func stopPanning() {
        panStart = nil; spaceDragged = false
        if spacePressed { spacePressed = false; if usesSystemCursor { NSCursor.pop() } }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopPanning()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window { NotificationCenter.default.addObserver(self, selector: #selector(windowResigned), name: NSWindow.didResignKeyNotification, object: window) }
    }
    @objc private func windowResigned(_ notification: Notification) { stopPanning(); model.endSelection(cancelled: true) }
    func stop() {
        saveBoundViewport(); stopPanning(); model.endSelection(cancelled: true)
        boundKey = nil; stopped = true
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        NotificationCenter.default.removeObserver(self)
        if model.canvasDocumentView === canvasHost { model.canvasDocumentView = nil; model.changeCanvasZoom = nil; model.scrollCanvasDuringDrag = nil }
    }
}

struct CanvasSelectionSurface: NSViewRepresentable {
    let model: WorkbenchModel
    func makeNSView(context: Context) -> CanvasSelectionView { CanvasSelectionView(model: model) }
    func updateNSView(_ view: CanvasSelectionView, context: Context) { }
    static func dismantleNSView(_ view: CanvasSelectionView, coordinator: ()) { view.finish(cancelled: true) }
}

// Behind cards and editors: only an actual blank-canvas hit begins a marquee.
@MainActor final class CanvasSelectionView: NSView {
    let model: WorkbenchModel
    private var start: CGPoint?
    private var pointer = CGPoint.zero
    private var timer: Timer?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(model: WorkbenchModel) { self.model = model; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    private func worldPoint(_ point: CGPoint) -> CanvasPoint {
        let local = convert(point, from: nil)
        return CanvasPoint(x: max(0, local.x), y: max(0, local.y))
    }
    override func mouseDown(with event: NSEvent) {
        guard model.removal == nil else { return }
        window?.makeFirstResponder(self)
        start = event.locationInWindow; pointer = event.locationInWindow
        model.beginSelection(at: worldPoint(pointer), adding: event.modifierFlags.contains(.shift))
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start, model.selecting else { return }
        pointer = event.locationInWindow
        guard hypot(pointer.x - start.x, pointer.y - start.y) > 4 else { return }
        tick()
        if timer == nil {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        }
    }
    private func tick() {
        guard model.selecting, window != nil else { finish(cancelled: true); return }
        model.scrollCanvasDuringDrag?(pointer)
        model.updateSelection(to: worldPoint(pointer))
    }
    override func mouseUp(with event: NSEvent) {
        if model.selectionRect != nil { model.updateSelection(to: worldPoint(event.locationInWindow)) }
        finish()
    }
    override func cancelOperation(_ sender: Any?) { finish(cancelled: true) }
    func finish(cancelled: Bool = false) {
        timer?.invalidate(); timer = nil; start = nil
        model.endSelection(cancelled: cancelled)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { finish(cancelled: true) }
    }
}

struct ScaledCanvasContent: View {
    @ObservedObject var model: WorkbenchModel
    let size: CGSize
    let zoom: Double
    var body: some View {
        CanvasContent(model: model, size: size)
            .scaleEffect(zoom, anchor: .topLeading)
            .frame(width: size.width * zoom, height: size.height * zoom, alignment: .topLeading)
    }
}

struct CanvasContent: View {
    @ObservedObject var model: WorkbenchModel
    @CanvasLocalState private var capsuleWidth: CGFloat = 0
    let size: CGSize
    var body: some View {
        ZStack(alignment: .topLeading) {
            CanvasSelectionSurface(model: model).frame(width: size.width, height: size.height)
            if model.dragging != nil || model.resizing != nil {
                Canvas { context, _ in
                    let visible = model.visibleCanvasRect
                    for x in stride(from: max(24, floor(visible.minX / 24) * 24), through: visible.maxX, by: 24) {
                        for y in stride(from: max(24, floor(visible.minY / 24) * 24), through: visible.maxY, by: 24) {
                            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)), with: .color(.primary.opacity(0.14)))
                        }
                    }
                }.allowsHitTesting(false)
            }
            if let point = model.dragPoint, let id = model.dragging, let item = model.items.first(where: { $0.id == id }) {
                ForEach(CardStacks.visible(model.dragMembers)) { member in
                    RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .frame(width: member.size.width, height: member.size.height)
                        .offset(x: member.position.x + point.x - item.position.x, y: member.position.y + point.y - item.position.y).allowsHitTesting(false)
                }
            }
            ForEach(model.canvasItems) { item in
                ZStack(alignment: .topTrailing) {
                    if item.stackID != nil {
                        RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.10))
                            .overlay { RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.28), lineWidth: 0.5) }.offset(x: 12, y: 12)
                        RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.16))
                            .overlay { RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.28), lineWidth: 0.5) }.offset(x: 6, y: 6)
                    }
                    MaterialView(model: model, item: item)
                    if let stack = item.stackID {
                        Text("\(model.stackMembers(stack).count)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 7).frame(height: 22).background(Color(red: 60/255, green: 60/255, blue: 66/255).opacity(0.88), in: Capsule())
                            .offset(x: 7, y: -9).allowsHitTesting(false)
                        if model.stackHoverID == stack && model.stackDropReady {
                            RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.24), lineWidth: 12)
                                .overlay { RoundedRectangle(cornerRadius: 12).stroke(.white, lineWidth: 2) }.allowsHitTesting(false)
                        }
                    }
                }.frame(width: item.size.width, height: item.size.height)
                    .opacity(item.stackID != nil && model.openStackID == item.stackID ? 0.35 : 1)
                    .offset(x: item.position.x, y: item.position.y)
                    .zIndex(model.resizing?.id == item.id ? 1 : 0)
            }
            if let original = model.resizing, let current = model.resizeSize {
                RoundedRectangle(cornerRadius: 12).stroke(.white, style: StrokeStyle(lineWidth: 1 / model.canvasCoordinateScale, dash: [5, 4]))
                    .frame(width: original.size.width, height: original.size.height)
                    .offset(x: original.position.x, y: original.position.y).allowsHitTesting(false).zIndex(2)
                Text("\(Int(current.width.rounded())) × \(Int(current.height.rounded()))")
                    .font(.system(size: 11, design: .monospaced)).padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .scaleEffect(1 / model.canvasCoordinateScale, anchor: .topLeading)
                    .offset(x: model.resizePointer.x + 14 / model.canvasCoordinateScale, y: model.resizePointer.y + 14 / model.canvasCoordinateScale)
                    .allowsHitTesting(false).zIndex(30)
            }
            if let id = model.pasteActions, let item = model.items.first(where: { $0.id == id }) {
                HStack(spacing: 2) {
                    ForEach(TextAction.allCases) { action in
                        Button(action.rawValue) { model.runText(item, action: action) }
                            .font(.system(size: 11)).buttonStyle(.bordered).tint(action == .explain ? .primary : nil)
                            .disabled(!model.canUseAI).opacity(model.canUseAI ? 1 : 0.35).help(model.aiHelp)
                    }
                    Button("只放进来") { model.pasteActions = nil }.buttonStyle(.plain).font(.system(size: 11))
                    if model.canUseAI { Text("↩").font(.system(size: 10)).foregroundStyle(.secondary) }
                }.padding(6).background(.regularMaterial, in: Capsule())
                    .fixedSize()
                    .background { GeometryReader { geometry in Color.clear.onAppear { capsuleWidth = geometry.size.width }.onChange(of: geometry.size.width) { _, width in capsuleWidth = width } } }
                    .offset(x: max(4, min(item.position.x, size.width - capsuleWidth - 4)), y: max(4, item.position.y - 44))
            }
            if let id = model.activeAnswer, let item = model.items.first(where: { $0.id == id }), model.drafts[id] != nil {
                let point = model.answerPosition(item)
                let anchor = item.stackID.flatMap { stack in model.canvasItems.first { $0.stackID == stack } } ?? item
                Path { path in
                    if point.y > anchor.position.y {
                        path.move(to: CGPoint(x: anchor.position.x + anchor.size.width / 2, y: anchor.rect.maxY))
                        path.addLine(to: CGPoint(x: point.x + anchor.size.width / 2, y: point.y))
                    } else {
                        path.move(to: CGPoint(x: point.x < anchor.position.x ? anchor.position.x : anchor.rect.maxX, y: anchor.position.y + 32))
                        path.addLine(to: CGPoint(x: point.x < anchor.position.x ? point.x + 284 : point.x, y: point.y + 32))
                    }
                }.stroke(.primary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3])).allowsHitTesting(false)
                AnswerCard(model: model, item: item).frame(width: 284).offset(x: point.x, y: point.y).zIndex(10)
            }
            if let rect = model.selectionRect {
                Rectangle().fill(Color.accentColor.opacity(0.1))
                    .overlay { Rectangle().stroke(Color.accentColor, lineWidth: 1 / model.canvasCoordinateScale) }
                    .frame(width: rect.size.width, height: rect.size.height)
                    .offset(x: rect.origin.x, y: rect.origin.y).allowsHitTesting(false).zIndex(20)
            }
        }.frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}
