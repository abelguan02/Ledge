import AppKit
import SwiftUI

private typealias AboutState<Value> = SwiftUI.State<Value>

@MainActor final class AboutController: NSWindowController {
    init(replay: @escaping () -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 470), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "关于 \(AppIdentity.name)"; window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true; window.isOpaque = false; window.backgroundColor = .clear
        window.isReleasedWhenClosed = false; window.isMovableByWindowBackground = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: window)
        let host = NSHostingView(rootView: AboutView(update: UpdateCheck(), replay: { [weak window] in window?.orderOut(nil); replay() }))
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
    @ObservedObject var update: UpdateCheck
    let replay: () -> Void
    @AboutState private var coffee = false
    @Environment(\.colorScheme) private var scheme
    private var chinese: Bool { AppIdentity.name == "搁这儿" }
    var body: some View {
        ZStack {
            GlassBackground()
            (scheme == .dark ? Color(red: 30/255, green: 30/255, blue: 36/255) : Color(red: 248/255, green: 248/255, blue: 250/255)).opacity(scheme == .dark ? 0.78 : 0.86)
            if coffee { coffeePage } else { mainPage }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).ignoresSafeArea().clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.primary.opacity(0.12), lineWidth: 0.5))
    }
    private var mainPage: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSImage(named: "Ledge") ?? NSImage()).resizable().frame(width: 84, height: 84).shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            Text(AppIdentity.name).font(.system(size: 24, weight: .bold)).padding(.top, 16)
            if chinese { Text("Ledge").font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 2) }
            Text(chinese ? "看中的东西，先搁这儿" : "Set it here for now.").font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 6)
            HStack(spacing: 10) {
                Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")（\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")）").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                updateButton
            }.frame(height: 24).padding(.top, 14)
            VStack(spacing: 0) {
                linkRow("开源仓库", detail: "GitHub", symbol: "chevron.left.forwardslash.chevron.right", color: Color(red: 36/255, green: 41/255, blue: 47/255), arrow: "arrow.up.right") { NSWorkspace.shared.open(ProjectLinks.repository) }
                Divider()
                linkRow("反馈与建议", detail: "Issues", symbol: "bubble.left.and.bubble.right", color: .blue, arrow: "arrow.up.right") { NSWorkspace.shared.open(ProjectLinks.feedback) }
                Divider()
                linkRow("自愿赞赏", detail: "请作者喝杯咖啡", symbol: "cup.and.saucer.fill", color: .orange, arrow: "chevron.right") { coffee = true }
            }.background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12)).padding(.top, 20)
            Button("重新观看新手引导", action: replay).buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.system(size: 12)).padding(.top, 18)
            Spacer(minLength: 0)
        }.padding(.horizontal, 20).padding(.top, 44)
    }
    @ViewBuilder private var updateButton: some View {
        switch update.status {
        case .checking: HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("正在检查…") }.font(.system(size: 11.5))
        case .current: Label("已是最新版本", systemImage: "checkmark").font(.system(size: 11.5))
        case .unreleased: Text("暂无正式发布").font(.system(size: 11.5)).foregroundStyle(.secondary)
        case .available(let version, let url): Button("新版本 \(version) · 前往下载 ↗") { NSWorkspace.shared.open(url) }.buttonStyle(.borderedProminent).controlSize(.mini)
        case .idle, .failed:
            Button(update.status == .failed ? "无法连接 · 重试" : "检查更新") { Task { await update.check() } }.buttonStyle(.bordered).clipShape(Capsule()).controlSize(.mini)
        }
    }
    private func linkRow(_ title: String, detail: String, symbol: String, color: Color, arrow: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(.white).frame(width: 26, height: 26).background(color, in: RoundedRectangle(cornerRadius: 7))
                Text(title).font(.system(size: 13)); Spacer(minLength: 2)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                Image(systemName: arrow).font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.horizontal, 12).frame(height: 46).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private var coffeePage: some View {
        VStack(spacing: 0) {
            Button { coffee = false } label: { Label("关于", systemImage: "chevron.left").font(.system(size: 13)) }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "cup.and.saucer.fill").font(.system(size: 28)).foregroundStyle(.white).frame(width: 56, height: 56).background(Color.orange, in: RoundedRectangle(cornerRadius: 14)).padding(.top, 24)
            Text("请作者喝杯咖啡").font(.system(size: 18, weight: .semibold)).padding(.top, 14)
            CoffeePaymentCode().padding(.top, 20)
            Text("完全自愿，不影响任何功能").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 16)
            Spacer(minLength: 0)
        }.padding(.horizontal, 20).padding(.top, 44)
    }
}
