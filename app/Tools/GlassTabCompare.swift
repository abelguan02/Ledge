import AppKit
import SwiftUI

// Live comparison only when explicitly launched. A separate opaque synthetic
// window supplies the backdrop for real behind-window vibrancy. No screen read.
private struct Backdrops: View {
    var body: some View {
        VStack(spacing: 0) {
            Color(white: 0.96).frame(height: 64)
            Color.white
            Color(white: 0.92)
            Color(white: 0.12)
        }.frame(width: 600, height: 604)
    }
}
private struct Comparison: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("玻璃小舌片 · 实屏比较").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("关闭") { NSApp.terminate(nil) }.buttonStyle(.bordered)
            }.padding(.horizontal, 20).frame(height: 64)
            row("白色背景", dark: false)
            row("浅灰背景", dark: false)
            row("深色背景", dark: true)
        }.frame(width: 600, height: 604).environment(\.colorScheme, .light)
    }
    private func row(_ title: String, dark: Bool) -> some View {
        HStack(spacing: 24) {
            Text(title).font(.system(size: 12)).frame(width: 80, alignment: .leading)
            VStack(spacing: 8) {
                Text("上一版").font(.system(size: 12))
                BeforeEdgeLineIndicator(state: .quiet, time: 0, reduceMotion: true)
                    .frame(width: 150, height: 100, alignment: .trailing)
            }
            VStack(spacing: 8) {
                Text("整体 0.62 · 小投影").font(.system(size: 12))
                EdgeLineIndicator(state: .quiet, time: 0, reduceMotion: true)
                    .frame(width: 150, height: 100, alignment: .trailing)
            }
        }.foregroundStyle(dark ? Color.white : .black).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@main @MainActor struct GlassTabCompare {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let size = CGSize(width: 600, height: 604)
        let screen = NSScreen.main?.visibleFrame ?? CGRect(origin: .zero, size: size)
        let frame = CGRect(x: screen.maxX - size.width - 60, y: screen.midY - size.height / 2, width: size.width, height: size.height)
        let backdrop = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.title = "Dump comparison synthetic backdrop"
        backdrop.level = .floating; backdrop.isReleasedWhenClosed = false
        backdrop.contentView = NSHostingView(rootView: Backdrops())
        let window = NSPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.title = "Dump Glass Tab Comparison"
        window.level = .floating; window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.contentView = NSHostingView(rootView: Comparison())
        if CommandLine.arguments.contains("--check") {
            window.contentView?.layoutSubtreeIfNeeded()
            precondition(!window.isVisible && !backdrop.isVisible)
            precondition(window.contentView?.fittingSize == size)
            print("PASS hidden comparison layout; no window displayed")
            return
        }
        backdrop.orderFrontRegardless()
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.order(.above, relativeTo: backdrop.windowNumber)
        let timeout = Timer.scheduledTimer(withTimeInterval: 75, repeats: false) { _ in
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        withExtendedLifetime((backdrop, window, timeout)) { NSApp.run() }
    }
}
