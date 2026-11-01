import AppKit
import SwiftUI

// Synthetic backgrounds; does not display windows or sample the desktop.
// Behind-window vibrancy cannot reproduce another app's content offscreen.
private struct TabPreview: View {
    let name: String
    let background: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("玻璃小舌片 · \(name)").font(.system(size: 20, weight: .semibold))
            Text("离屏预览 · 上排实际尺寸，下排 3 倍细节").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                sample("平静", .quiet)
                sample("处理中", .processing)
                sample("需要你看", .attention)
                sample("出错", .failed)
                sample("悬停 +4", .quiet, hover: true)
            }
            Text("主体 14×64 / 外框 14×80 · 把手 3×28 · 感应区 48×160\n真实跨窗口模糊、动画节奏和鼠标悬停仍需上屏确认。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(24).background(Color(white: 0.96)).environment(\.colorScheme, .light)
    }
    private func sample(_ title: String, _ state: EdgeState, hover: Bool = false) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 13, weight: .medium))
            ZStack(alignment: .trailing) {
                background
                EdgeLineIndicator(state: state, time: 0.8, reduceMotion: false, hovering: hover)
            }.frame(width: 140, height: 160).clipped()
            ZStack(alignment: .trailing) {
                background
                EdgeLineIndicator(state: state, time: 0.8, reduceMotion: false, hovering: hover)
                    .scaleEffect(3, anchor: .trailing)
            }.frame(width: 140, height: 260).clipped()
        }
    }
}

@main @MainActor struct EdgeLinePreview {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        for reduced in [false, true] {
            for hover in [false, true] {
                let host = NSHostingView(rootView: EdgeLineIndicator(state: .quiet, time: 0, reduceMotion: reduced, hovering: hover))
                let expected = CGSize(width: hover && !reduced ? 18 : 14, height: 80)
                precondition(host.fittingSize == expected, "hover/reduced-motion layout changed")
            }
        }
        let shape = GlassTabShape().path(in: CGRect(x: 0, y: 0, width: 14, height: 80))
        precondition(shape.contains(CGPoint(x: 7, y: 40)) && !shape.contains(CGPoint(x: 1, y: 1)))
        print("PASS tab dimensions, hover extension, reduced motion and concave outline")
        for (key, title, white) in [("white", "白色背景", 1.0), ("light-gray", "浅灰背景", 0.92), ("dark", "深色背景", 0.12)] {
            let host = NSHostingView(rootView: TabPreview(name: title, background: Color(white: white)))
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let output = URL(fileURLWithPath: "app/build/glass-tab-\(key).png")
            try bitmap.representation(using: .png, properties: [:])!.write(to: output)
            print(output.path)
        }
    }
}
