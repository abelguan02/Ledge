import AppKit
import SwiftUI
import UniformTypeIdentifiers

private typealias GuideState<Value> = SwiftUI.State<Value>
private final class GuidePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

private struct GuideTitleEffect: ViewModifier {
    var offset: CGFloat
    var blur: CGFloat
    var opacity: Double
    func body(content: Content) -> some View { content.offset(y: offset).blur(radius: blur).opacity(opacity) }
}
private struct GuidePanelEffect: ViewModifier {
    var scale: CGFloat
    var opacity: Double
    func body(content: Content) -> some View { content.scaleEffect(x: scale, y: 1, anchor: .trailing).opacity(opacity) }
}

@MainActor final class OnboardingController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var session: OnboardingSession?
    private let preferences: AppPreferences
    private let completion: () -> Void
    init(preferences: AppPreferences, completion: @escaping () -> Void) { self.preferences = preferences; self.completion = completion }
    func present() {
        if let panel { panel.makeKeyAndOrderFront(nil); return }
        guard let screen = NSScreen.main else { return }
        let session = OnboardingSession(); self.session = session
        let panel = GuidePanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.fullScreenAuxiliary]; panel.delegate = self
        panel.contentView = NSHostingView(rootView: OnboardingView(session: session, preferences: preferences, finish: { [weak self] in self?.close() }))
        self.panel = panel; NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
    }
    private func close() { panel?.close() }
    func windowWillClose(_ notification: Notification) {
        session?.finish(); session = nil; panel?.contentView = nil; panel = nil
        completion()
    }
}

private struct OnboardingView: View {
    @ObservedObject var session: OnboardingSession
    @ObservedObject var preferences: AppPreferences
    let finish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GuideState private var phase = 0
    @GuideState private var cursorDemo = false
    @GuideState private var drag = CGSize.zero
    @GuideState private var targeted = false
    @GuideState private var keyDown = -1
    @GuideState private var glow = false
    @GuideState private var exiting = false
    private var spring: Animation { reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.75) }
    private var ease: Animation { reduceMotion ? .easeInOut(duration: 0.2) : .timingCurve(0.25, 0.8, 0.25, 1, duration: 0.35) }
    private var title: String {
        switch session.step { case .welcome: AppIdentity.name; case .edge: "它住在屏幕边上"; case .drop: "什么都能丢进来"; case .paste: "复制了，就按 ⌘V"; case .export: "用完，拖走就行"; case .shortcut: "随时叫它出来" }
    }
    private var detail: String {
        switch session.step {
        case .welcome: AppIdentity.name == "搁这儿" ? "看中的东西，先搁这儿。" : "Set it here for now."
        case .edge: "平时只是一条细线。把鼠标移过去试试。"
        case .drop: "把这张图拖到右边。"
        case .paste: "文字、网址、截图，按一下就落到画布上。"
        case .export: "拖到桌面、文件夹或聊天框，就是一份完整的文件。"
        case .shortcut: preferences.shortcut.map { "按 \($0.display)，或者把鼠标移到那条细线上。" } ?? "把鼠标移到那条细线上就能打开。"
        }
    }
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                Color(red: 8/255, green: 8/255, blue: 14/255).opacity(0.62)
                    .mask {
                        if session.step == .edge {
                            RadialGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.53), .init(color: .black, location: 1)], center: UnitPoint(x: 1, y: 0.5), startRadius: 0, endRadius: 86)
                        } else { Color.black }
                    }
                scene(size)
                Button("跳过", action: exitGuide).buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.white.opacity(0.65)).padding(32)
                VStack(alignment: .leading, spacing: 14) {
                    if session.step == .welcome {
                        Image(nsImage: NSImage(named: "Ledge") ?? NSImage()).resizable().frame(width: 84, height: 84)
                            .opacity(phase > 0 ? 1 : 0).offset(y: reduceMotion || phase > 0 ? 0 : 14)
                        HStack(spacing: 0) {
                            ForEach(Array(Array(title).enumerated()), id: \.offset) { index, letter in
                                Text(String(letter)).opacity(phase >= index + 2 ? 1 : 0)
                                    .offset(y: reduceMotion || phase >= index + 2 ? 0 : 14).blur(radius: reduceMotion || phase >= index + 2 ? 0 : 8)
                            }
                        }.font(.system(size: 26, weight: .bold))
                    } else {
                        Text(title).font(.system(size: 26, weight: .bold)).id(title)
                            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .modifier(active: GuideTitleEffect(offset: 14, blur: 8, opacity: 0), identity: GuideTitleEffect(offset: 0, blur: 0, opacity: 1)), removal: .offset(y: -14).combined(with: .opacity)))
                    }
                    Text(detail).font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.7)).opacity(session.step != .welcome || phase == 20 ? 1 : 0)
                    HStack(spacing: 18) {
                        Button(session.step == .welcome ? "开始" : session.step == .shortcut ? "开始使用" : "继续") {
                            withAnimation(ease) { session.next() }
                            if session.finished { exitGuide() }
                        }.buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
                            .padding(.horizontal, 24).frame(height: 36).background(.white, in: Capsule())
                            .opacity(session.canContinue ? 1 : 0.35).disabled(!session.canContinue)
                        HStack(spacing: 6) { ForEach(0..<6) { n in Capsule().fill(.white.opacity(n == session.step.rawValue ? 1 : 0.3)).frame(width: n == session.step.rawValue ? 18 : 6, height: 6) } }
                    }.padding(.top, 8).opacity(session.step != .welcome || phase == 20 ? 1 : 0)
                }.foregroundStyle(.white).frame(maxWidth: min(600, size.width - 100), alignment: .leading)
                    .position(x: min(360, size.width * 0.30), y: size.height - 160)
            }.opacity(exiting ? 0 : 1).onExitCommand(perform: exitGuide)
                .task(id: "\(session.step.rawValue)-\(reduceMotion)") { await animateStep() }
        }
    }
    @ViewBuilder private func scene(_ size: CGSize) -> some View {
        let middle = CGPoint(x: size.width * 0.48, y: size.height * 0.42)
        let target = CGPoint(x: size.width - 165, y: size.height * 0.42)
        let hasPanel = session.step.rawValue >= 2 && (session.step != .drop || targeted || session.dropCompleted || drag.width > size.width * 0.16) && (session.step != .shortcut || phase < 4)
        ZStack {
            if hasPanel {
                RoundedRectangle(cornerRadius: 22).fill(.ultraThinMaterial).frame(width: 300, height: min(460, size.height * 0.58))
                    .overlay(alignment: .topLeading) { Text("示例画布").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7)).padding(18) }
                    .position(target).transition(reduceMotion ? .opacity : .modifier(active: GuidePanelEffect(scale: 0.03, opacity: 0), identity: GuidePanelEffect(scale: 1, opacity: 1)))
            }
            if session.step == .welcome || session.step == .edge || session.step == .shortcut || session.step == .drop {
                EdgeLineIndicator(state: .quiet, time: 0, reduceMotion: reduceMotion, hovering: session.edgeCompleted || cursorDemo || targeted)
                    .frame(width: 48, height: 160, alignment: .trailing)
                    .offset(x: session.step == .welcome && phase == 0 && !reduceMotion ? 48 : 0)
                    .contentShape(Rectangle()).onHover { hover in if hover { withAnimation(spring) { session.hoveredEdge() } } }
                    .position(x: size.width - 24, y: size.height * 0.5)
                    .shadow(color: .white.opacity(glow ? 0.7 : 0), radius: 18)
                    .accessibilityLabel("示例屏幕边缘")
                if session.step == .shortcut, phase == 4, !reduceMotion {
                    Capsule().fill(.white).frame(width: 3, height: 28).blur(radius: 3)
                        .position(x: size.width - 5, y: size.height * 0.5 - 64).offset(y: glow ? 128 : 0).opacity(glow ? 0 : 1)
                }
            }
            if session.step == .edge && !session.edgeCompleted && !reduceMotion {
                Image(systemName: "cursorarrow").font(.system(size: 24)).foregroundStyle(.white).shadow(color: .black, radius: 2)
                    .position(x: cursorDemo ? size.width - 18 : size.width - 268, y: cursorDemo ? size.height * 0.5 : size.height * 0.5 + 62)
                    .allowsHitTesting(false)
            }
            if session.step == .drop {
                sampleImage.frame(width: 180, height: 130).overlay(alignment: .bottom) { Text("试试拖我").font(.system(size: 12, weight: .medium)).foregroundStyle(.white).padding(8) }
                    .scaleEffect(session.dropCompleted && !reduceMotion ? 0.62 : 1)
                    .position(session.dropCompleted ? target : middle).offset(session.dropCompleted ? .zero : drag)
                    .gesture(DragGesture().onChanged { value in drag = value.translation }.onEnded { value in
                        withAnimation(spring) {
                            if middle.x + value.translation.width > size.width - 320 { session.dropped() }
                            drag = .zero
                        }
                    }).accessibilityLabel("试试拖我")
                    .id(reduceMotion && session.dropCompleted).transition(.opacity)
                Color.clear.frame(width: 320, height: size.height * 0.65).contentShape(Rectangle()).position(target)
                    .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: $targeted) { providers in
                        guard !providers.isEmpty else { return false }
                        withAnimation(spring) { session.dropped() }; return true
                    }
                if session.dropCompleted { Circle().stroke(.white.opacity(glow ? 0 : 0.7), lineWidth: 3).frame(width: 120, height: 120).scaleEffect(reduceMotion ? 1 : glow ? 1.8 : 0.4).position(target).allowsHitTesting(false).onAppear { withAnimation(.easeOut(duration: reduceMotion ? 0.2 : 0.6)) { glow = true } } }
            }
            if session.step == .paste {
                keys(["⌘", "V"]).position(middle)
                sampleNote.opacity(phase >= 3 ? 1 : 0).offset(y: reduceMotion || phase >= 3 ? 0 : -60)
                    .rotationEffect(.degrees(reduceMotion || phase >= 3 ? 0 : -6)).scaleEffect(reduceMotion || phase >= 3 ? 1 : 0.9).position(target)
            }
            if session.step == .export {
                sampleImage.frame(width: 140, height: 100).opacity(phase > 0 ? 0.16 : 0).position(target)
                sampleImage.frame(width: 140, height: 100).scaleEffect(reduceMotion || phase == 0 ? 1 : 1.04).rotationEffect(.degrees(reduceMotion || phase == 0 ? 0 : -2))
                    .position(phase >= 2 ? CGPoint(x: middle.x, y: middle.y + 40) : target).opacity(phase >= 3 ? 0 : 1)
                VStack(spacing: 8) { Image(systemName: "doc.richtext").font(.system(size: 64)); Text("灵感.png").font(.system(size: 12)) }
                    .foregroundStyle(.white).scaleEffect(reduceMotion || phase >= 3 ? 1 : 0.7).opacity(phase >= 3 ? 1 : 0).position(CGPoint(x: middle.x, y: middle.y + 40))
            }
            if session.step == .shortcut, let shortcut = preferences.shortcut {
                keys(shortcut.keyCaps).position(middle)
            }
        }.animation(spring, value: hasPanel).animation(spring, value: session.dropCompleted)
    }
    private var sampleImage: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 1, green: 0.7, blue: 0.48), Color(red: 1, green: 0.43, blue: 0.57), Color(red: 0.48, green: 0.36, blue: 1)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color(red: 1, green: 0.94, blue: 0.79)).frame(width: 24, height: 24).offset(x: -42, y: -22)
            GeometryReader { g in Path { p in p.move(to: CGPoint(x: 0, y: g.size.height)); p.addLine(to: CGPoint(x: g.size.width*0.3,y:g.size.height*0.5)); p.addLine(to: CGPoint(x:g.size.width*0.5,y:g.size.height*0.7)); p.addLine(to: CGPoint(x:g.size.width*0.7,y:g.size.height*0.4)); p.addLine(to: CGPoint(x:g.size.width,y:g.size.height*0.8)); p.addLine(to: CGPoint(x:g.size.width,y:g.size.height)); p.closeSubpath() }.fill(Color(red: 0.17, green: 0.12, blue: 0.36).opacity(0.5)) }
        }.clipShape(RoundedRectangle(cornerRadius: 8)).padding(5).background(.white, in: RoundedRectangle(cornerRadius: 12)).shadow(color: .black.opacity(0.3), radius: 12, y: 6)
    }
    private var sampleNote: some View { Text("看中的东西，\n先搁这儿。").font(.system(size: 18, weight: .medium)).foregroundStyle(.black.opacity(0.8)).frame(width: 180, height: 130).background(Color(red: 1, green: 0.85, blue: 0.35), in: RoundedRectangle(cornerRadius: 12)) }
    private func keys(_ values: [String]) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, key in
                Text(key).font(.system(size: 30, weight: .medium)).foregroundStyle(.white).frame(minWidth: 54, minHeight: 54).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.3), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.35), radius: 0, y: keyDown == index && !reduceMotion ? 1 : 4).offset(y: keyDown == index && !reduceMotion ? 3 : 0)
            }
        }
    }
    private func animateStep() async {
        phase = 0; cursorDemo = false; drag = .zero; glow = false; keyDown = -1
        if reduceMotion { phase = 20; return }
        do {
            switch session.step {
            case .welcome:
                withAnimation(spring) { phase = 1 }
                for index in 0..<title.count { try await Task.sleep(for: .milliseconds(80)); withAnimation(ease) { phase = index + 2 } }
                try await Task.sleep(for: .milliseconds(650)); withAnimation(ease) { phase = 20 }
            case .edge:
                repeat {
                    try await Task.sleep(for: .milliseconds(400))
                    withAnimation(.easeInOut(duration: 0.8)) { cursorDemo = true }
                    try await Task.sleep(for: .milliseconds(1300))
                    withAnimation(ease) { cursorDemo = false }
                    try await Task.sleep(for: .milliseconds(2300))
                } while !session.edgeCompleted && !Task.isCancelled
            case .drop: break
            case .paste, .shortcut:
                let count = session.step == .paste ? 2 : preferences.shortcut?.keyCaps.count ?? 0
                for index in 0..<count {
                    withAnimation(.easeIn(duration: 0.08)) { keyDown = index }
                    try await Task.sleep(for: .milliseconds(80))
                    withAnimation(.easeOut(duration: 0.12)) { keyDown = -1 }
                    try await Task.sleep(for: .milliseconds(55))
                }
                withAnimation(spring) { phase = session.step == .paste ? 3 : 4 }
                if session.step == .shortcut { try await Task.sleep(for: .milliseconds(350)); withAnimation(.easeOut(duration: 0.6)) { glow = true } }
            case .export:
                try await Task.sleep(for: .milliseconds(400)); withAnimation(spring) { phase = 1 }
                try await Task.sleep(for: .milliseconds(150)); withAnimation(.easeInOut(duration: 1)) { phase = 2 }
                try await Task.sleep(for: .seconds(1)); withAnimation(spring) { phase = 3 }
            }
        } catch is CancellationError { } catch { assertionFailure("Unexpected animation clock error: \(error)") }
    }
    private func exitGuide() {
        guard !exiting else { return }
        withAnimation(.easeOut(duration: 0.2)) { exiting = true }
        Task { try? await Task.sleep(for: .milliseconds(200)); finish() }
    }
}
