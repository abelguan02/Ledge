import AppKit
import SwiftUI

private typealias AboutState<Value> = SwiftUI.State<Value>

@MainActor final class AboutController: NSWindowController {
    init(preferences: AppPreferences = AppPreferences(), replay: @escaping () -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 470), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = preferences.interfaceLanguage.phrase("关于 %@", preferences.interfaceLanguage.label("搁这儿")); window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true; window.isOpaque = false; window.backgroundColor = .clear
        window.isReleasedWhenClosed = false; window.isMovableByWindowBackground = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: window)
        let host = NSHostingView(rootView: SkinRoot(preferences: preferences) {
            AboutView(update: UpdateCheck(), replay: { [weak window] in window?.orderOut(nil); replay() },
                      setWindowTitle: { [weak window] in window?.title = $0 })
        })
        host.sizingOptions = []
        host.safeAreaRegions = []
        window.contentView = host
        window.setFrame(NSRect(x: 0, y: 0, width: 340, height: 470), display: false)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func present() { showWindow(nil); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil) }
}

private struct AboutView: View {
    @Environment(\.ledgeSkin) private var skin
    @ObservedObject var update: UpdateCheck
    let replay: () -> Void
    var setWindowTitle: (String) -> Void = { _ in }
    @AboutState private var coffee = false
    @AboutState private var paymentMethod = CoffeePaymentMethod.wechat
    @Environment(\.colorScheme) private var scheme
    private var chinese: Bool { skin.language != .english }
    var body: some View {
        ZStack {
            GlassBackground()
            skin.palette.aboutTint(dark: scheme == .dark)
            if coffee { coffeePage } else { mainPage }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).ignoresSafeArea().clipShape(skin.shapes.dialog)
            .overlay(skin.shapes.dialog.stroke(skin.ink.floatingBorder, lineWidth: 0.5))
            .onChange(of: skin.phrase("关于 %@", skin.label("搁这儿")), initial: true) { _, title in
                setWindowTitle(title)
            }
    }
    private var mainPage: some View {
        VStack(spacing: 0) {
            if skin.isUnit {
                HStack(alignment: .bottom, spacing: 12) {
                    if chinese {
                        VStack(spacing: -16) { SkinDisplayText(wordmark: .appName, size: 120, fragment: 0..<1); SkinDisplayText(wordmark: .appName, size: 74, fragment: 1..<3) }
                    } else { SkinDisplayText("Ledge", size: 72, compression: 0.62) }
                    if !chinese { Text("LEDGE").font(.system(size: 14, design: .monospaced)).tracking(4).foregroundStyle(skin.palette.accent).padding(.bottom, 10) }
                }.frame(height: chinese ? 180 : 100)
            } else {
                Image(nsImage: NSImage(named: "Ledge") ?? NSImage()).resizable().frame(width: 84, height: 84).skinShadow(skin.shadows.appIcon)
                Text(skin.label("搁这儿")).font(skin.typography.applicationTitle).padding(.top, 16)
            }
            Text(skin.label("看中的东西，先搁这儿")).font(skin.typography.body).foregroundStyle(skin.ink.secondary).padding(.top, 6)
            HStack(spacing: 10) {
                (skin.isUnit || skin.language != .simplified ? Text(skin.phrase("版本 %@（%@）", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")) : Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")（\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")）")).font(skin.typography.caption).monospacedDigit().foregroundStyle(skin.ink.secondary)
                updateButton
            }.frame(height: 24).padding(.top, 14)
            VStack(spacing: 0) {
                linkRow("开源仓库", detail: "GitHub", symbol: "chevron.left.forwardslash.chevron.right", color: skin.palette.repositoryIcon, arrow: "arrow.up.right") { NSWorkspace.shared.open(ProjectLinks.repository) }
                Divider()
                linkRow("反馈与建议", detail: "问题反馈", symbol: "bubble.left.and.bubble.right", color: skin.palette.feedback, arrow: "arrow.up.right") { NSWorkspace.shared.open(ProjectLinks.feedback) }
                Divider()
                linkRow("自愿赞赏", detail: "请作者喝杯咖啡", symbol: "cup.and.saucer.fill", color: skin.palette.coffee, arrow: "chevron.right") { coffee = true }
            }.background(skin.ink.sectionInset, in: skin.shapes.card).padding(.top, 20)
            Button(skin.label("重新观看新手引导"), action: replay).buttonStyle(.plain).foregroundStyle(skin.palette.accent).font(skin.typography.caption).padding(.top, 18)
            Spacer(minLength: 0)
        }.padding(.horizontal, 20).padding(.top, 44)
    }
    @ViewBuilder private var updateButton: some View {
        switch update.status {
        case .checking: HStack(spacing: 4) { ProgressView().controlSize(.mini); Text(skin.label("正在检查…")) }.font(skin.typography.detail)
        case .current: Label(skin.label("已是最新版本"), systemImage: "checkmark").font(skin.typography.detail)
        case .unreleased: Text(skin.label("暂无正式发布")).font(skin.typography.detail).foregroundStyle(skin.ink.secondary)
        case .available(let version, let url): Button(skin.phrase("新版本 %@ · 前往下载 ↗", version)) { NSWorkspace.shared.open(url) }.buttonStyle(.borderedProminent).controlSize(.mini)
        case .idle, .failed:
            Button(skin.label(update.status == .failed ? "无法连接 · 重试" : "检查更新")) { Task { await update.check() } }.buttonStyle(.bordered).clipShape(skin.shapes.capsule).controlSize(.mini)
        }
    }
    private func linkRow(_ title: String, detail: String, symbol: String, color: Color, arrow: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                if !skin.isUnit { Image(systemName: symbol).font(skin.typography.actionIcon).foregroundStyle(skin.palette.light).frame(width: 26, height: 26).background(color, in: skin.shapes.compactControl) }
                Text(skin.label(title)).font(skin.typography.body); Spacer(minLength: 2)
                Text(skin.label(detail)).font(skin.typography.detail).foregroundStyle(skin.ink.secondary)
                Image(systemName: arrow).font(skin.typography.small).foregroundStyle(skin.ink.secondary)
            }.padding(.horizontal, 12).frame(height: skin.isUnit ? 38 : 46).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private var coffeePage: some View {
        VStack(spacing: 0) {
            Button { coffee = false } label: { Label(skin.label("关于"), systemImage: "chevron.left").font(skin.typography.body) }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
            if skin.isUnit {
                VStack(spacing: -6) { SkinDisplayText("请作者", size: 60, compression: 0.62); SkinDisplayText("喝杯咖啡", size: 60, compression: 0.62) }.padding(.top, 8)
            } else {
                Image(systemName: "cup.and.saucer.fill").font(skin.typography.mediaIcon).foregroundStyle(skin.palette.light).frame(width: 56, height: 56).background(skin.palette.coffee, in: skin.shapes.payment).padding(.top, 16)
                Text(skin.label("请作者喝杯咖啡")).font(skin.typography.sectionTitle).padding(.top, 14)
            }
            SkinSegments(title: "支付方式", choices: CoffeePaymentMethod.allCases.map { ($0, $0.rawValue) }, selection: $paymentMethod)
                .frame(width: 196).padding(.top, 10)
            CoffeePaymentCode(method: paymentMethod).padding(.top, 8)
            (skin.isUnit || skin.language != .simplified ? Text(skin.label("完全自愿，不影响任何功能")) : Text("完全自愿，不影响任何功能")).font(skin.typography.caption).foregroundStyle(skin.ink.secondary).padding(.top, 16)
            Spacer(minLength: 0)
        }.padding(.horizontal, 20).padding(.top, 44)
    }
}
