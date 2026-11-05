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
        window.contentView = NSHostingView(rootView: SkinRoot(preferences: model.preferences) { SettingsView(model: model, preferences: model.preferences, shortcut: shortcut, login: login, resize: { [weak window] title, height in
            guard let window else { return }
            window.title = title
            let frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 520, height: height))
            window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - frame.height, width: frame.width, height: frame.height), display: true, animate: LedgeSkin.selected(model.preferences.skin).motion.animateSettingsResize(reduced: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
        }) })
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func present() { showWindow(nil); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil) }
    func acceptCurrentShortcut() -> Bool { (window?.firstResponder as? ShortcutField)?.acceptCurrentShortcut() ?? false }
}

private enum SettingsTab: String, CaseIterable {
    case general = "通用", storage = "存储", ai = "AI", web = "网页预览"
    var symbol: String { switch self { case .general: "gearshape"; case .storage: "internaldrive"; case .ai: "sparkles"; case .web: "globe" } }
    var height: CGFloat { switch self { case .general: 291; case .storage: 380; case .ai: 195; case .web: 155 } }
}

private struct SettingsView: View {
    @Environment(\.ledgeSkin) private var skin
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
                        VStack(spacing: 4) {
                            if skin.isUnit { ViewThatFits(in: .horizontal) { SkinDisplayText(page.rawValue, size: 34); SkinDisplayText(page.rawValue, size: 24) } }
                            else { Image(systemName: page.symbol).font(skin.typography.settingsIcon); Text(page.rawValue).font(skin.typography.small) }
                        }
                            .frame(width: skin.isUnit ? 104 : 72, height: 54).foregroundStyle(tab == page ? skin.palette.accent : skin.palette.secondary)
                            .background(tab == page ? skin.palette.settingsTab : skin.palette.clear, in: skin.shapes.control)
                            .overlay(alignment: .bottom) { if skin.isUnit && tab == page { skin.palette.accent.frame(height: 3) } }
                    }.buttonStyle(.plain)
                }
            }.padding(.top, 10)
            VStack(spacing: 12) {
                switch tab {
                case .general:
                    group {
                        row("皮肤") {
                            SkinSegments(title: "皮肤", choices: SkinChoice.allCases.map { ($0, skin.isUnit ? $0.title(language: skin.language.rawValue) : $0.title()) }, selection: $preferences.skin).frame(width: 180)
                        }
                        Divider()
                        row("登录时启动") { Toggle("登录时启动", isOn: Binding(get: { login.enabled }, set: { login.set($0) })).labelsHidden().toggleStyle(SkinSwitchToggleStyle()).controlSize(.small) }
                        Divider()
                        row(skin.phrase("显示／收起 %@", skin.isUnit ? skin.label("搁这儿") : AppIdentity.name)) { ShortcutRecorder(shortcut: shortcut, preferences: preferences).frame(width: 182, height: 28) }
                        if !shortcut.error.isEmpty { Text(skin.label(shortcut.error)).font(skin.typography.small).foregroundStyle(skin.palette.destructive).frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, 12).padding(.bottom, 6) }
                        Divider()
                        row("停靠位置") {
                            SkinSegments(title: "停靠位置", choices: [(.right, "右侧"), (.left, "左侧"), (.top, "上方")], selection: $preferences.dockEdge).frame(width: 180)
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
                            VStack(alignment: .leading, spacing: 5) { Text(skin.label("数据位置")); Text(model.library.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(skin.typography.small).textSelection(.enabled).lineLimit(2) }
                            Spacer()
                            Button(skin.label("在访达中显示")) { NSWorkspace.shared.activateFileViewerSelecting([model.library.root]) }.controlSize(.small)
                        }.padding(12)
                        Divider()
                        row("已用空间") { Text(skin.phrase("%d 个收集区 · %@", model.index.collections.count, CapacityLimits.format(model.index.items.reduce(0) { $0 + $1.byteCount + ($1.linkPreview?.byteCount ?? 0) }))).foregroundStyle(skin.ink.secondary) }
                    }
                case .ai:
                    group {
                        row("AI 处理") { Toggle("AI 处理", isOn: $preferences.aiEnabled).labelsHidden().toggleStyle(SkinSwitchToggleStyle()).controlSize(.small).disabled(model.codexAvailable == false) }
                        HStack(spacing: 6) {
                            skin.shapes.circle.fill(model.codexAvailable == false ? skin.palette.destructive : preferences.aiEnabled && model.codexAvailable == true ? skin.palette.connected : skin.palette.inactive).frame(width: 6, height: 6)
                            Text(skin.label(model.aiStatus)).foregroundStyle(skin.ink.secondary); Spacer()
                            if model.codexAvailable == false { Button(skin.label("重新检查")) { Task { await model.checkCodex() } }.disabled(model.checkingCodex).controlSize(.small) }
                        }.padding(.horizontal, 12).padding(.bottom, 12)
                    }
                case .web:
                    group { row("自动生成网页截图") { Toggle("自动生成网页截图", isOn: $preferences.automaticWebPreviews).labelsHidden().toggleStyle(SkinSwitchToggleStyle()).controlSize(.small) } }
                }
            }.padding(.horizontal, 24)
            Spacer(minLength: 0)
        }.font(skin.typography.body).frame(width: 520)
            .background(scheme == .dark ? skin.palette.settingsDark : skin.palette.settingsLight)
            .onAppear { resize(skin.label(tab.rawValue), tab.height); login.refresh() }
            .onChange(of: preferences.skin) { _, _ in resize(skin.label(tab.rawValue), tab.height + (tab == .general && !shortcut.error.isEmpty ? 20 : 0)) }
            .onChange(of: tab) { _, value in resize(skin.label(value.rawValue), value.height + (value == .general && !shortcut.error.isEmpty ? 20 : 0)) }
            .onChange(of: shortcut.error) { _, value in if tab == .general { resize(skin.label(tab.rawValue), tab.height + (value.isEmpty ? 0 : 20)) } }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in login.refresh() }
            .alert("无法更改登录启动项", isPresented: Binding(get: { login.error != nil }, set: { if !$0 { login.error = nil } })) { Button(skin.label("好")) { login.error = nil } } message: { Text(login.error ?? "") }
    }
    private func group<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0, content: content).background(scheme == .dark ? skin.palette.darkSettingsGroup : skin.palette.lightSettingsGroup, in: skin.shapes.field)
            .overlay { if skin.isUnit { Rectangle().stroke(skin.palette.separator, lineWidth: 1).allowsHitTesting(false) } }
    }
    private func row<C: View>(_ title: String, @ViewBuilder control: () -> C) -> some View { HStack { Text(skin.label(title)); Spacer(); control() }.padding(.horizontal, 12).frame(height: 40) }
    private func capacityRow(_ title: String, value: Binding<Int64>, choices: [Int64]) -> some View {
        row(title) { Picker(title, selection: value) { ForEach(Array(Set(choices + [value.wrappedValue])).sorted(), id: \.self) { Text(CapacityLimits.format($0)).tag($0) } }.labelsHidden().frame(width: 100) }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @Environment(\.ledgeSkin) private var skin
    @ObservedObject var shortcut: GlobalShortcut
    @ObservedObject var preferences: AppPreferences
    func makeNSView(context: Context) -> ShortcutField {
        let view = ShortcutField()
        view.changed = { shortcut.set($0) }
        view.recordingFeedback = { shortcut.error = $0 }
        return view
    }
    func updateNSView(_ view: ShortcutField, context: Context) { view.skin = skin; view.label = preferences.shortcut?.display ?? ""; view.needsDisplay = true }
    static func dismantleNSView(_ view: ShortcutField, coordinator: ()) { view.stopRecording() }
}
final class ShortcutField: NSView {
    var skin = LedgeSkin.classic
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
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: skin.shapes.shortcutRadius, yRadius: skin.shapes.shortcutRadius)
        skin.palette.nativeControl.setFill(); shape.fill()
        (recording ? skin.palette.nativeAccent : skin.palette.nativeSeparator).setStroke(); shape.lineWidth = recording ? 2 : 0.5; shape.stroke()
        let text = recording ? skin.label("按下新的快捷键…") : label
        (text as NSString).draw(at: NSPoint(x: 9, y: 7), withAttributes: [.font: skin.typography.shortcut, .foregroundColor: skin.palette.nativeLabel])
        ("×" as NSString).draw(at: NSPoint(x: bounds.width-20, y: 6), withAttributes: [.font: skin.typography.shortcutClear, .foregroundColor: skin.palette.nativeSecondary])
        setAccessibilityRole(.button); setAccessibilityLabel(skin.label("全局快捷键")); setAccessibilityValue(text)
    }
    override func accessibilityPerformPress() -> Bool { beginRecording(); return true }
}
