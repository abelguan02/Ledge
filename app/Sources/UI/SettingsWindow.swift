import AppKit
import SwiftUI
import ServiceManagement

private typealias SettingsState<Value> = SwiftUI.State<Value>

@MainActor final class LoginPreference: ObservableObject {
    @Published var enabled = false
    @Published var error: String?
    init() { refresh() }
    func refresh() { enabled = SMAppService.mainApp.status == .enabled }
    func set(_ value: Bool) {
        do {
            let status = SMAppService.mainApp.status
            if value && status != .enabled && status != .requiresApproval { try SMAppService.mainApp.register() }
            else if !value && status != .notRegistered { try SMAppService.mainApp.unregister() }
            refresh()
            if SMAppService.mainApp.status == .requiresApproval {
                let alert = NSAlert(); alert.messageText = "请在系统设置中允许登录时启动"
                alert.addButton(withTitle: "打开系统设置"); alert.addButton(withTitle: "取消")
                if alert.runModal() == .alertFirstButtonReturn { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch { refresh(); self.error = error.localizedDescription }
    }
}

@MainActor final class SettingsController: NSWindowController {
    init(model: WorkbenchModel, shortcut: GlobalShortcut, login: LoginPreference) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 250), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: SettingsView(model: model, preferences: model.preferences, shortcut: shortcut, login: login, resize: { [weak window] title, height in
            guard let window else { return }
            window.title = title
            let frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 520, height: height))
            window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - frame.height, width: frame.width, height: frame.height), display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }))
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func present() { showWindow(nil); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil) }
    func acceptCurrentShortcut() -> Bool { (window?.firstResponder as? ShortcutField)?.acceptCurrentShortcut() ?? false }
}

private enum SettingsTab: String, CaseIterable {
    case general = "通用", storage = "存储", ai = "AI", web = "网页预览"
    var symbol: String { switch self { case .general: "gearshape"; case .storage: "internaldrive"; case .ai: "sparkles"; case .web: "globe" } }
    var height: CGFloat { switch self { case .general: 250; case .storage: 380; case .ai: 195; case .web: 155 } }
}

private struct SettingsView: View {
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var shortcut: GlobalShortcut
    @ObservedObject var login: LoginPreference
    let resize: (String, CGFloat) -> Void
    @SettingsState private var tab = SettingsTab.general
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                ForEach(SettingsTab.allCases, id: \.self) { page in
                    Button { tab = page } label: {
                        VStack(spacing: 4) { Image(systemName: page.symbol).font(.system(size: 20)); Text(page.rawValue).font(.system(size: 11)) }
                            .frame(width: 72, height: 54).foregroundStyle(tab == page ? Color.accentColor : .secondary)
                            .background(tab == page ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
            }.padding(.top, 10)
            VStack(spacing: 12) {
                switch tab {
                case .general:
                    group {
                        row("登录时启动") { Toggle("登录时启动", isOn: Binding(get: { login.enabled }, set: { login.set($0) })).labelsHidden().toggleStyle(.switch).controlSize(.small) }
                        Divider()
                        row("显示／收起 \(AppIdentity.name)") { ShortcutRecorder(shortcut: shortcut, preferences: preferences).frame(width: 182, height: 28) }
                        if !shortcut.error.isEmpty { Text(shortcut.error).font(.system(size: 11)).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, 12).padding(.bottom, 6) }
                        Divider()
                        row("停靠位置") {
                            Picker("停靠位置", selection: $preferences.dockEdge) { Text("右侧").tag(DockEdge.right); Text("左侧").tag(DockEdge.left); Text("上方").tag(DockEdge.top) }
                                .labelsHidden().pickerStyle(.segmented).frame(width: 180)
                        }
                    }
                case .storage:
                    group {
                        capacityRow("每个收集区最多", value: $preferences.collectionLimit, choices: [1,2,5,10,20,50].map { Int64($0) * 1_000_000_000 })
                        Divider()
                        capacityRow("单个材料最多", value: $preferences.itemLimit, choices: [100_000_000,500_000_000,1_000_000_000,2_000_000_000,5_000_000_000])
                        Divider()
                        capacityRow("电脑剩余空间低于此值时暂停接收", value: $preferences.freeDiskLimit, choices: [1,5,10,20,50].map { Int64($0) * 1_000_000_000 })
                    }
                    group {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) { Text("数据位置"); Text(model.library.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 11)).textSelection(.enabled).lineLimit(2) }
                            Spacer()
                            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([model.library.root]) }.controlSize(.small)
                        }.padding(12)
                        Divider()
                        row("已用空间") { Text("\(model.index.collections.count) 个收集区 · \(CapacityLimits.format(model.index.items.reduce(0) { $0 + $1.byteCount + ($1.linkPreview?.byteCount ?? 0) }))").foregroundStyle(.secondary) }
                    }
                case .ai:
                    group {
                        row("AI 处理") { Toggle("AI 处理", isOn: $preferences.aiEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(model.codexAvailable == false) }
                        HStack(spacing: 6) {
                            Circle().fill(model.codexAvailable == false ? Color.red : preferences.aiEnabled && model.codexAvailable == true ? .green : .gray).frame(width: 6, height: 6)
                            Text(model.aiStatus).foregroundStyle(.secondary); Spacer()
                            if model.codexAvailable == false { Button("重新检查") { Task { await model.checkCodex() } }.disabled(model.checkingCodex).controlSize(.small) }
                        }.padding(.horizontal, 12).padding(.bottom, 12)
                    }
                case .web:
                    group { row("自动生成网页截图") { Toggle("自动生成网页截图", isOn: $preferences.automaticWebPreviews).labelsHidden().toggleStyle(.switch).controlSize(.small) } }
                }
            }.padding(.horizontal, 24)
            Spacer(minLength: 0)
        }.font(.system(size: 13)).frame(width: 520)
            .background(scheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color(red: 236/255, green: 236/255, blue: 238/255))
            .onAppear { resize(tab.rawValue, tab.height); login.refresh() }
            .onChange(of: tab) { _, value in resize(value.rawValue, value.height + (value == .general && !shortcut.error.isEmpty ? 20 : 0)) }
            .onChange(of: shortcut.error) { _, value in if tab == .general { resize(tab.rawValue, tab.height + (value.isEmpty ? 0 : 20)) } }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in login.refresh() }
            .alert("无法更改登录启动项", isPresented: Binding(get: { login.error != nil }, set: { if !$0 { login.error = nil } })) { Button("好") { login.error = nil } } message: { Text(login.error ?? "") }
    }
    private func group<C: View>(@ViewBuilder _ content: () -> C) -> some View { VStack(spacing: 0, content: content).background(scheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 10)) }
    private func row<C: View>(_ title: String, @ViewBuilder control: () -> C) -> some View { HStack { Text(title); Spacer(); control() }.padding(.horizontal, 12).frame(height: 40) }
    private func capacityRow(_ title: String, value: Binding<Int64>, choices: [Int64]) -> some View {
        row(title) { Picker(title, selection: value) { ForEach(Array(Set(choices + [value.wrappedValue])).sorted(), id: \.self) { Text(CapacityLimits.format($0)).tag($0) } }.labelsHidden().frame(width: 100) }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject var shortcut: GlobalShortcut
    @ObservedObject var preferences: AppPreferences
    func makeNSView(context: Context) -> ShortcutField {
        let view = ShortcutField()
        view.changed = { shortcut.set($0) }
        view.recordingFeedback = { shortcut.error = $0 }
        return view
    }
    func updateNSView(_ view: ShortcutField, context: Context) { view.label = preferences.shortcut?.display ?? ""; view.needsDisplay = true }
    static func dismantleNSView(_ view: ShortcutField, coordinator: ()) { view.stopRecording() }
}
final class ShortcutField: NSView {
    var label = ""
    var changed: ((AppShortcut?) -> Void)?
    var recordingFeedback: ((String) -> Void)?
    private let session: ShortcutRecording
    private var recording: Bool { session.isRecording }
    init(session: ShortcutRecording = ShortcutRecording()) { self.session = session; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        stopRecording()
        NotificationCenter.default.removeObserver(self)
        if let newWindow {
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(stopRecording), name: name, object: newWindow)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(stopRecording), name: NSApplication.didResignActiveNotification, object: NSApp)
        }
        super.viewWillMove(toWindow: newWindow)
    }
    private func beginRecording() {
        guard window?.makeFirstResponder(self) == true else { return }
        session.begin(); recordingFeedback?(session.error); needsDisplay = true
    }
    @objc func stopRecording() { session.stop(); needsDisplay = true }
    func acceptCurrentShortcut() -> Bool {
        guard recording else { return false }
        if !session.canRecordKey() { recordingFeedback?(session.error) }
        stopRecording(); return true
    }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        if convert(event.locationInWindow, from: nil).x > bounds.width - 25 { stopRecording(); changed?(nil) }
        else { beginRecording() }
        UIFocusTrace.snapshot("recorder-click recording=\(recording)")
        needsDisplay = true
    }
    override func resignFirstResponder() -> Bool { stopRecording(); return true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { guard recording else { return false }; keyDown(with: event); return true }
    override func keyDown(with event: NSEvent) {
        UIFocusTrace.snapshot("recorder-key recording=\(recording)")
        guard recording else {
            if event.keyCode == 49 || event.keyCode == 36 { beginRecording() }
            else if event.keyCode == 51 { changed?(nil) }
            else { super.keyDown(with: event) }
            return
        }
        if event.keyCode == 53 { stopRecording(); return }
        guard session.canRecordKey() else { recordingFeedback?(session.error); needsDisplay = true; return }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift]).rawValue
        guard modifiers & (AppShortcut.command | AppShortcut.control | AppShortcut.option) != 0 else { return }
        let special: [UInt16: String] = [49:"空格",36:"↩",76:"⌅",48:"⇥",51:"⌫",117:"⌦",115:"↖",119:"↘",116:"⇞",121:"⇟",123:"←",124:"→",125:"↓",126:"↑"]
        let key = AppShortcut.functionKeys[UInt32(event.keyCode)].map { "F\($0)" } ?? special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        stopRecording()
        changed?(AppShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: key))
    }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill(); shape.fill()
        (recording ? NSColor.controlAccentColor : .separatorColor).setStroke(); shape.lineWidth = recording ? 2 : 0.5; shape.stroke()
        let text = recording ? "按下新的快捷键…" : label
        (text as NSString).draw(at: NSPoint(x: 9, y: 7), withAttributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.labelColor])
        ("×" as NSString).draw(at: NSPoint(x: bounds.width-20, y: 6), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor])
        setAccessibilityRole(.button); setAccessibilityLabel("全局快捷键"); setAccessibilityValue(text)
    }
    override func accessibilityPerformPress() -> Bool { beginRecording(); return true }
}
