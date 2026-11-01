import AppKit
import SwiftUI
import Combine

private typealias EdgeViewState<Value> = SwiftUI.State<Value>

@MainActor final class PanelController {
    let model: WorkbenchModel
    var edge: DockEdge
    func setEdge(_ value: DockEdge) { edge = value; reposition() }
    let panel: DumpPanel
    let surface: DropSurface
    var screen: NSScreen
    private var suspended = false
    func suspend() {
        suspended = true; edgeTimer?.invalidate(); edgeTimer = nil; edgeDrag = nil
        panel.dismissPreview(); panel.orderOut(nil)
    }
    func resume(_ mode: PanelMode) { suspended = false; show(mode) }
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var edgeTimer: Timer?
    private var edgeDrag: EdgeDragSession?
    private var screenObserver: NSObjectProtocol?
    init(model: WorkbenchModel, edge: DockEdge = .right) {
        self.model = model; self.edge = edge; screen = NSScreen.main ?? NSScreen.screens[0]
        panel = DumpPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        surface = DropSurface(model: model)
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = surface
        panel.receiveDrops(on: surface)
        model.presentationWindow = panel
        model.presentPreview = { [weak panel] items in panel?.presentPreview(items) }
        model.dismissPreview = { [weak panel] in panel?.dismissPreview() }
        surface.showCanvas = { [weak self] in self?.show(.canvas) }
        surface.showDrop = { [weak self] in self?.show(.drop) }
        surface.hideDrop = { [weak self] in self?.show(.line) }
        model.collapse = { [weak self] in self?.collapse() }
        model.restoreCanvas = { [weak self] in self?.show(.canvas) }
        model.resizeCanvas = { [weak self] in self?.reposition() }
        model.statusChanged = { [weak self] in if self?.surface.mode == .line { self?.updateRoot() } }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) == nil }
            return consumed ? nil : event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard self?.suspended == false else { return }
                if event.type == .leftMouseDown { self?.beginEdgeTracking() }
                // Wait for release so a Finder drag can reach an already open
                // canvas. A release inside the panel is a drop, not an outside click.
                if let self, self.surface.mode == .canvas,
                   event.type == .leftMouseUp || event.type == .rightMouseDown,
                   !self.panel.frame.contains(NSEvent.mouseLocation) { self.collapse() }
            }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reposition()
                if !NSScreen.screens.isEmpty, self?.suspended == false { self?.panel.orderFrontRegardless() }
            }
        }
    }
    private func beginEdgeTracking() {
        edgeTimer?.invalidate()
        let board = NSPasteboard(name: .drag)
        _ = board.types
        edgeDrag = EdgeDragSession(origin: NSEvent.mouseLocation, pasteboardRevision: board.changeCount)
        traceEdge("begin revision=\(board.changeCount)")
        // Finder can omit native entered callbacks on the collapsed rail.
        // A short-lived check requires a NEW supported drag pasteboard, so
        // window/selection/slider drags cannot reuse the last payload.
        edgeTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackEdgeDrag() }
        }
    }
    private func trackEdgeDrag() {
        let point = NSEvent.mouseLocation
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            edgeDrag = nil; edgeTimer?.invalidate(); edgeTimer = nil
            if surface.mode == .drop { show(.line) }
            return
        }
        guard !model.choosingFiles, panel.attachedSheet == nil else { return }
        let board = NSPasteboard(name: .drag)
        let supported = board.availableType(from: DropSurface.supportedTypes) != nil
        guard edgeDrag?.isExternalDrag(at: point, revision: board.changeCount, supported: supported) == true else { return }
        if surface.mode == .line, panel.frame.contains(point), surface.describe(board) {
            traceEdge("expand baseline=\(edgeDrag!.pasteboardRevision) current=\(board.changeCount)")
            show(.drop)
        }
        else if surface.mode == .drop, !panel.frame.contains(point) { show(.line) }
    }
    private func traceEdge(_ event: String) {
        if ProcessInfo.processInfo.environment["DUMP_TRACE_TRANSFERS"] == "1" {
            FileHandle.standardError.write(Data("Dump edge: \(event)\n".utf8))
        }
    }
    func show(_ mode: PanelMode) {
        guard !suspended else { return }
        surface.mode = mode
        model.canvasVisible = mode == .canvas
        reposition()
        if mode == .canvas {
            NSApp.activate(ignoringOtherApps: true)
            model.markViewed()
            if let failed = model.items.first(where: { model.errors[$0.id] != nil }) { model.select(failed.id) }
            panel.makeKeyAndOrderFront(nil)
        }
        else { panel.resignKey(); panel.orderFrontRegardless() }
    }
    private func reposition() {
        func identifier(_ screen: NSScreen) -> Int { (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? -1 }
        let available = NSScreen.screens
        guard let chosen = PanelPlacement.screenID(current: identifier(screen), available: available.map(identifier), main: NSScreen.main.map(identifier)),
              let target = available.first(where: { identifier($0) == chosen }) else { panel.orderOut(nil); return }
        screen = target
        let size: NSSize
        switch surface.mode {
        case .line: size = edge == .top ? NSSize(width: 160, height: 48) : NSSize(width: 48, height: 160)
        case .drop: size = edge == .top ? NSSize(width: 348, height: 440) : NSSize(width: 320, height: 468)
        case .canvas: size = model.isExpanded ? NSSize(width: 1120, height: 900) : edge == .top ? NSSize(width: 948, height: 560) : NSSize(width: 540, height: 768)
        }
        panel.setFrame(PanelPlacement.frame(size: size, visible: screen.visibleFrame, edge: edge), display: false)
        updateRoot()
    }
    func collapse() {
        guard model.removal == nil, !model.collectionDeleting, panel.attachedSheet == nil, !model.choosingFiles else { return }
        model.closeCollectionMenu()
        panel.dismissPreview()
        show(.line)
        Task { do { try await model.flushDrafts() } catch { model.fail(error) } }
    }
    private func updateRoot() {
        switch surface.mode {
        case .canvas: surface.host.rootView = AnyView(WorkbenchView(model: model, width: max(1, panel.frame.width - (edge == .top ? 48 : 20)), height: max(1, panel.frame.height - (edge == .top ? 20 : 48))))
        case .drop: surface.host.rootView = AnyView(DropView(model: model))
        case .line: surface.host.rootView = AnyView(EdgeLineView(model: model, open: { [weak self] in self?.show(.canvas) }))
        }
    }
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard !suspended, surface.mode == .canvas, panel.isKeyWindow, panel.attachedSheet == nil, !model.choosingFiles else { return event }
        let editing = panel.firstResponder is NSTextView
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v" where !editing: surface.paste(); return nil
            case "c" where !editing && model.removal == nil: model.copySelected(); return nil
            case "z" where !editing && model.removal == nil: model.undo(); return nil
            case "q": model.requestQuit?(); return nil
            case ",": model.requestSettings?(); return nil
            default: break
            }
        }
        if event.keyCode == 53 {
            if model.collectionPage != .closed { model.collectionEscape() }
            else if model.resizing != nil { model.endResize(cancelled: true) }
            else if model.selecting { model.endSelection(cancelled: true) }
            else if model.dragging != nil { return event } // AppKit cancels the native drag session.
            else if model.openStackID != nil { model.closeStack() }
            else if model.removal != nil { model.removal = nil }
            else if let id = model.activeAnswer { model.closeAnswer(id) }
            else { collapse() }
            return nil
        }
        if model.removal != nil { return event.keyCode == 36 || event.keyCode == 76 ? nil : event }
        if !editing, event.keyCode == 51, !model.selected.isEmpty { model.askRemoval(ids: model.selected); return nil }
        if !editing, event.keyCode == 36, let id = model.pasteActions, let item = model.items.first(where: { $0.id == id }) { model.runText(item, action: .explain); return nil }
        return event
    }
    func stop() {
        panel.dismissPreview()
        edgeTimer?.invalidate(); edgeTimer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        panel.orderOut(nil)
    }
}

struct EdgeLineView: View {
    @ObservedObject var model: WorkbenchModel
    let open: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EdgeViewState private var hovering = false
    var body: some View {
        TimelineView(.animation(minimumInterval: 1/30, paused: reduceMotion || model.edgeState == .quiet)) { context in
            EdgeLineIndicator(state: model.edgeState, time: context.date.timeIntervalSinceReferenceDate, reduceMotion: reduceMotion, hovering: hovering, edge: model.preferences.dockEdge)
        }.frame(width: model.preferences.dockEdge == .top ? 160 : 48, height: model.preferences.dockEdge == .top ? 48 : 160, alignment: model.preferences.dockEdge == .top ? .top : model.preferences.dockEdge == .left ? .leading : .trailing).contentShape(Rectangle()).onTapGesture(perform: open)
            .onHover { hovering = $0 }
            .accessibilityElement(children: .ignore).accessibilityLabel("打开 \(AppIdentity.name) 收集区").accessibilityAddTraits(.isButton).accessibilityAction { open() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: WorkbenchModel?
    private var controller: PanelController?
    private var statusItem: NSStatusItem?
    private var quitting = false
    private var oldAppMonitor: Timer?
    private var menuObservation: AnyCancellable?
    private var settingsAction: (() -> Void)?
    private var aboutAction: (() -> Void)?
    private let showItem = NSMenuItem()
    private let addItem = NSMenuItem()
    private let undoItem = NSMenuItem()
    private let recheckItem = NSMenuItem()
    private var settingsController: SettingsController?
    private var aboutController: AboutController?
    private var onboardingController: OnboardingController?
    private var shortcutRegistry: NativeShortcutRegistry?
    private var globalShortcut: GlobalShortcut?
    private var preferenceObservation: AnyCancellable?
    func applicationDidFinishLaunching(_ notification: Notification) {
        UIFocusTrace.start()
        do {
            let root = try LibraryLocation.open()
            let preferences = AppPreferences(defaults: .standard)
            let library = try Library(root: root, limits: preferences.capacity)
            let model = WorkbenchModel(library: library, webSnapshot: { url, manual, progress in
                try await WebSnapshotCapture().capture(url, permitsOneTime: manual, progress: progress)
            }, preferences: preferences); self.model = model
            controller = PanelController(model: model, edge: preferences.dockEdge)
            let registry = NativeShortcutRegistry(); shortcutRegistry = registry
            let shortcut = GlobalShortcut(preferences: preferences, registry: registry); globalShortcut = shortcut
            registry.pressed = { [weak self, weak shortcut] id in
                UIFocusTrace.snapshot("hotkey=\(id) activeID=\(shortcut?.activeID ?? 0)")
                if shortcut?.activeID == id, self?.settingsController?.acceptCurrentShortcut() != true { self?.open() }
            }
            shortcut.start()
            let settingsWindow = SettingsController(model: model, shortcut: shortcut, login: LoginPreference())
            settingsController = settingsWindow; settingsAction = { [weak settingsWindow] in settingsWindow?.present() }
            let aboutWindow = AboutController { [weak self] in self?.presentOnboarding(automatic: false) }
            aboutController = aboutWindow; aboutAction = { [weak aboutWindow] in aboutWindow?.present() }
            preferenceObservation = preferences.objectWillChange.sink { [weak self, weak model] in
                Task { @MainActor in
                    guard let self, let model else { return }
                    self.controller?.setEdge(model.preferences.dockEdge)
                    await model.library.updateLimits(model.preferences.capacity)
                    self.updateMenu()
                }
            }
            model.requestQuit = { NSApp.terminate(nil) }
            model.requestSettings = { [weak self] in self?.settingsAction?() }
            makeMenu()
            menuObservation = model.objectWillChange.sink { [weak self] in
                Task { @MainActor in self?.updateMenu() }
            }
            // Workspace launch notifications did not trigger legacy-app shutdown
            // in on-device QA. Check the running identity directly instead.
            oldAppMonitor = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated {
                    if !NSRunningApplication.runningApplications(withBundleIdentifier: "local.dump.desktop").isEmpty {
                        NSApp.terminate(nil)
                    }
                }
            }
            Task {
                await model.refresh()
                let defaults = UserDefaults.standard
                if OnboardingSession.automaticallyPresent(eligible: defaults.bool(forKey: "ledge.onboardingEligible"), seen: defaults.bool(forKey: "ledge.onboardingSeen"), collectionCount: model.index.collections.count, materialCount: model.index.items.count) {
                    presentOnboarding(automatic: true)
                } else {
                    defaults.set(false, forKey: "ledge.onboardingEligible")
                    controller?.show(.line); await model.checkCodex()
                }
            }
        } catch {
            let alert = NSAlert(); alert.messageText = "\(AppIdentity.name)无法打开收集区"; alert.informativeText = error.localizedDescription
            alert.runModal(); NSApp.terminate(nil)
        }
    }
    private func presentOnboarding(automatic: Bool) {
        guard onboardingController == nil, let model else { return }
        let restore: PanelMode = automatic || model.canvasVisible ? .canvas : .line
        controller?.suspend(); settingsController?.window?.orderOut(nil)
        let guide = OnboardingController(preferences: model.preferences) { [weak self, weak model] in
            UserDefaults.standard.set(true, forKey: "ledge.onboardingSeen")
            UserDefaults.standard.set(false, forKey: "ledge.onboardingEligible")
            self?.onboardingController = nil
            self?.controller?.resume(restore)
            if automatic, let model { Task { await model.checkCodex() } }
        }
        onboardingController = guide; guide.present()
    }
    private func makeMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(named: "MenuBarTemplate")
        icon?.isTemplate = true; icon?.size = NSSize(width: 16, height: 16)
        item.button?.image = icon; item.button?.setAccessibilityLabel(AppIdentity.name)
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (entry, selector) in [(showItem, #selector(open)), (addItem, #selector(addFiles)), (undoItem, #selector(undo))] {
            entry.action = selector; entry.target = self; menu.addItem(entry)
        }
        menu.addItem(.separator())
        if let model {
            let aiItem = NSMenuItem()
            let host = NSHostingView(rootView: AIMenuRow(model: model)); host.frame = NSRect(x: 0, y: 0, width: 260, height: 57)
            aiItem.view = host; menu.addItem(aiItem)
        }
        recheckItem.title = "重新检查"; recheckItem.action = #selector(recheck); recheckItem.target = self; menu.addItem(recheckItem)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "设置…", action: #selector(settings), keyEquivalent: ","); settings.target = self; menu.addItem(settings)
        let about = NSMenuItem(title: "关于 \(AppIdentity.name)", action: #selector(about), keyEquivalent: ""); about.target = self; menu.addItem(about)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 \(AppIdentity.name)", action: #selector(quit), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        menu.delegate = self; item.menu = menu; statusItem = item
        updateMenu()
    }
    private func updateMenu() {
        guard let model else { return }
        showItem.title = "\(model.canvasVisible ? "收起" : "显示") \(AppIdentity.name)"
        showItem.keyEquivalent = model.preferences.shortcut?.menuKey ?? ""
        showItem.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: model.preferences.shortcut?.modifiers ?? 0)
        addItem.title = "添加文件到「\(model.collectionName)」…"
        undoItem.title = model.undoTitle ?? "撤销"; undoItem.isHidden = model.undoTitle == nil; undoItem.isEnabled = !model.locked
        recheckItem.isHidden = model.codexAvailable != false; recheckItem.isEnabled = !model.checkingCodex
    }
    func menuWillOpen(_ menu: NSMenu) { updateMenu() }
    @objc private func recheck() { if let model { Task { await model.checkCodex() } } }
    @objc private func settings() { settingsAction?() }
    @objc private func about() { aboutAction?() }
    @objc private func open() {
        UIFocusTrace.snapshot("toggle visible=\(model?.canvasVisible == true) guide=\(onboardingController != nil)")
        guard onboardingController == nil else { return }
        if model?.canvasVisible == true { controller?.collapse() } else { controller?.show(.canvas) }
    }
    @objc private func undo() { model?.undo() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func addFiles() {
        controller?.show(.canvas)
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = true
        model?.presentFilePicker(panel) { [weak self] response in
            if response == .OK { self?.model?.importPayload(.files(panel.urls)) }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !quitting else { return .terminateLater }; quitting = true
        Task {
            do { try await model.shutdown(); controller?.stop(); shortcutRegistry?.stop(); oldAppMonitor?.invalidate(); sender.reply(toApplicationShouldTerminate: true) }
            catch { quitting = false; model.fail(error); controller?.show(.canvas); sender.reply(toApplicationShouldTerminate: false) }
        }
        return .terminateLater
    }
}

@main @MainActor struct LedgeMain {
    static func main() {
        if CommandLine.arguments.contains("--check-codex-connection") {
            Task { @MainActor in
                let bridge = CodexBridge()
                do {
                    let catalog = try await bridge.catalog()
                    print("PASS embedded XPC and Codex catalog: \(catalog.models.count) models; no model request sent")
                    bridge.stop(); exit(0)
                } catch {
                    print("FAIL \(error.localizedDescription)")
                    bridge.stop(); exit(1)
                }
            }
            RunLoop.main.run()
            return
        }
        if CommandLine.arguments.contains("--verify-bundle") {
            do {
                _ = try PeerSignature.requirement(at: Bundle.main.bundleURL, identifier: "local.ledge.desktop")
                _ = try PeerSignature.requirement(at: Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/CodexService.xpc"), identifier: "local.ledge.desktop.CodexService")
                print("PASS Ledge and embedded XPC identities; no window or account connection opened")
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        let app = NSApplication.shared
        if let requested = CommandLine.arguments.first(where: { $0.hasPrefix("--qa-appearance=") }) {
            app.appearance = NSAppearance(named: requested.hasSuffix("dark") ? .darkAqua : .aqua)
        }
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
