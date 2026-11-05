import AppKit
import SwiftUI
import UniformTypeIdentifiers

private typealias GuideState<Value> = SwiftUI.State<Value>
private final class GuidePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
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
        panel.contentView = NSHostingView(rootView: SkinRoot(preferences: preferences) { OnboardingView(session: session, preferences: preferences, finish: { [weak self] in self?.close() }) })
        self.panel = panel; NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
    }
    private func close() { panel?.close() }
    func windowWillClose(_ notification: Notification) {
        session?.finish(); session = nil; panel?.contentView = nil; panel = nil
        completion()
    }
}

private struct OnboardingView: View {
    @Environment(\.ledgeSkin) private var skin
    @ObservedObject var session: OnboardingSession
    @ObservedObject var preferences: AppPreferences
    let finish: () -> Void
    @SkinReducedMotion private var reduceMotion
    @GuideState private var phase = 0
    @GuideState private var cursorDemo = false
    @GuideState private var drag = CGSize.zero
    @GuideState private var targeted = false
    @GuideState private var keyDown = -1
    @GuideState private var glow = false
    @GuideState private var exiting = false
    private var spring: Animation { skin.motion.guideSpring(reduced: reduceMotion) }
    private var ease: Animation { skin.motion.guideEase(reduced: reduceMotion) }
    private var title: String {
        let key = switch session.step { case .welcome: "搁这儿"; case .edge: "它住在屏幕边上"; case .drop: "什么都能丢进来"; case .paste: "复制了，就按 ⌘V"; case .export: "用完，拖走就行"; case .shortcut: "随时叫它出来" }
        return skin.label(key)
    }
    private var detail: String {
        switch session.step {
        case .welcome: "看中的东西，先搁这儿。"
        case .edge: "平时只是一条细线。把鼠标移过去试试。"
        case .drop: "把这张图拖到右边。"
        case .paste: "文字、网址、截图，按一下就落到画布上。"
        case .export: "拖到桌面、文件夹或聊天框，就是一份完整的文件。"
        case .shortcut: preferences.shortcut.map { skin.phrase("按 %@，或者把鼠标移到那条细线上。", $0.keyCaps.map(skin.label).joined()) } ?? "把鼠标移到那条细线上就能打开。"
        }
    }
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                skin.palette.guideDim
                    .mask {
                        if session.step == .edge {
                            RadialGradient(stops: [.init(color: skin.palette.clear, location: 0), .init(color: skin.palette.clear, location: 0.53), .init(color: skin.palette.shade, location: 1)], center: UnitPoint(x: 1, y: 0.5), startRadius: 0, endRadius: 86)
                        } else { skin.palette.shade }
                    }
                scene(size)
                Button(skin.label("跳过"), action: exitGuide).buttonStyle(.plain).font(skin.typography.body).foregroundStyle(skin.palette.guideSkip).padding(32)
                VStack(alignment: .leading, spacing: 14) {
                    if skin.isUnit {
                        SkinDisplayText(title, size: 52, compression: 0.62).opacity(session.step != .welcome || phase > 0 ? 1 : 0)
                    } else if session.step == .welcome {
                        Image(nsImage: NSImage(named: "Ledge") ?? NSImage()).resizable().frame(width: 84, height: 84)
                            .opacity(phase > 0 ? 1 : 0).offset(y: reduceMotion || phase > 0 ? 0 : 14)
                        HStack(spacing: 0) {
                            ForEach(Array(Array(title).enumerated()), id: \.offset) { index, letter in
                                Text(String(letter)).opacity(phase >= index + 2 ? 1 : 0)
                                    .offset(y: reduceMotion || phase >= index + 2 ? 0 : 14).blur(radius: reduceMotion || phase >= index + 2 ? 0 : 8)
                            }
                        }.font(skin.typography.onboardingTitle)
                    } else {
                        Text(title).font(skin.typography.onboardingTitle).id(title)
                            .transition(skin.motion.guideTitle(reduced: reduceMotion))
                    }
                    Text(skin.label(detail)).font(skin.typography.answer).foregroundStyle(skin.palette.guideDetail).opacity(session.step != .welcome || phase == 20 ? 1 : 0)
                    HStack(spacing: 18) {
                        Button(skin.label(session.step == .welcome ? "开始" : session.step == .shortcut ? "开始使用" : "继续")) {
                            withAnimation(ease) { session.next() }
                            if session.finished { exitGuide() }
                        }.buttonStyle(.plain).font(skin.typography.bodyStrong).foregroundStyle(skin.palette.shade)
                            .padding(.horizontal, 24).frame(height: 36).background(skin.isUnit ? skin.palette.accent : skin.palette.light, in: skin.shapes.capsule)
                            .opacity(session.canContinue ? 1 : skin.opacity.disabled).disabled(!session.canContinue)
                        HStack(spacing: 6) { ForEach(0..<6) { n in skin.shapes.capsule.fill(skin.palette.light.opacity(n == session.step.rawValue ? 1 : 0.3)).frame(width: n == session.step.rawValue ? 18 : 6, height: 6) } }
                    }.padding(.top, 8).opacity(session.step != .welcome || phase == 20 ? 1 : 0)
                }.foregroundStyle(skin.palette.light).frame(maxWidth: min(600, size.width - 100), alignment: .leading)
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
                Group {
                    if skin.isUnit {
                        EdgePanelShape(edge: .right, cut: true).fill(skin.palette.base)
                            .overlay { UnitPanelTrim(edge: .right).clipShape(EdgePanelShape(edge: .right, cut: true)) }
                            .overlay { EdgePanelShape(edge: .right, cut: true).stroke(skin.palette.line, lineWidth: 2) }
                    } else { skin.shapes.dialog.fill(skin.materials.ultraThin) }
                }.frame(width: 300, height: min(460, size.height * 0.58))
                    .overlay(alignment: .topLeading) { Text(skin.label("示例画布")).font(skin.typography.captionStrong).foregroundStyle(skin.palette.guideDetail).padding(18) }
                    .position(target).transition(skin.motion.guidePanel(reduced: reduceMotion))
            }
            if session.step == .welcome || session.step == .edge || session.step == .shortcut || session.step == .drop {
                EdgeLineIndicator(state: .quiet, time: 0, reduceMotion: reduceMotion, hovering: session.edgeCompleted || cursorDemo || targeted)
                    .frame(width: 48, height: 160, alignment: .trailing)
                    .offset(x: session.step == .welcome && phase == 0 && !reduceMotion ? 48 : 0)
                    .contentShape(Rectangle()).onHover { hover in if hover { withAnimation(spring) { session.hoveredEdge() } } }
                    .position(x: size.width - 24, y: size.height * 0.5)
                    .skinShadow(skin.shadows.guideGlow(glow))
                    .accessibilityLabel(skin.label("示例屏幕边缘"))
                if session.step == .shortcut, phase == 4, !reduceMotion && !skin.isUnit {
                    skin.shapes.capsule.fill(skin.palette.light).frame(width: 3, height: 28).blur(radius: 3)
                        .position(x: size.width - 5, y: size.height * 0.5 - 64).offset(y: glow ? 128 : 0).opacity(glow ? 0 : 1)
                }
            }
            if session.step == .edge && !session.edgeCompleted && !reduceMotion {
                Image(systemName: "cursorarrow").font(skin.typography.cursor).foregroundStyle(skin.palette.light).skinShadow(skin.shadows.cursor)
                    .position(x: cursorDemo ? size.width - 18 : size.width - 268, y: cursorDemo ? size.height * 0.5 : size.height * 0.5 + 62)
                    .allowsHitTesting(false)
            }
            if session.step == .drop {
                sampleImage.frame(width: 180, height: 130).overlay(alignment: .bottom) { Text(skin.label("试试拖我")).font(skin.typography.captionMedium).foregroundStyle(skin.palette.light).padding(8) }
                    .scaleEffect(session.dropCompleted && !reduceMotion ? 0.62 : 1)
                    .position(session.dropCompleted ? target : middle).offset(session.dropCompleted ? .zero : drag)
                    .gesture(DragGesture().onChanged { value in drag = value.translation }.onEnded { value in
                        withAnimation(spring) {
                            if middle.x + value.translation.width > size.width - 320 { session.dropped() }
                            drag = .zero
                        }
                    }).accessibilityLabel(skin.label("试试拖我"))
                    .id(reduceMotion && session.dropCompleted).transition(.opacity)
                skin.palette.clear.frame(width: 320, height: size.height * 0.65).contentShape(Rectangle()).position(target)
                    .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: $targeted) { providers in
                        guard !providers.isEmpty else { return false }
                        withAnimation(spring) { session.dropped() }; return true
                    }
                if session.dropCompleted { skin.shapes.circle.stroke(skin.palette.guideRing(glowing: glow), lineWidth: 3).frame(width: 120, height: 120).scaleEffect(reduceMotion ? 1 : glow ? 1.8 : 0.4).position(target).allowsHitTesting(false).onAppear { withAnimation(skin.motion.dropGlow(reduced: reduceMotion)) { glow = true } } }
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
                VStack(spacing: 8) { Image(systemName: "doc.richtext").font(skin.typography.sampleFile); Text(skin.label("灵感.png")).font(skin.typography.caption) }
                    .foregroundStyle(skin.palette.light).scaleEffect(reduceMotion || phase >= 3 ? 1 : 0.7).opacity(phase >= 3 ? 1 : 0).position(CGPoint(x: middle.x, y: middle.y + 40))
            }
            if session.step == .shortcut, let shortcut = preferences.shortcut {
                keys(shortcut.keyCaps.map(skin.label)).position(middle)
            }
        }.animation(spring, value: hasPanel).animation(spring, value: session.dropCompleted)
    }
    private var sampleImage: some View {
        ZStack {
            LinearGradient(colors: [skin.palette.sampleSkyTop, skin.palette.sampleSkyMiddle, skin.palette.sampleSkyBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
            skin.shapes.circle.fill(skin.palette.sampleSun).frame(width: 24, height: 24).offset(x: -42, y: -22)
            GeometryReader { g in Path { p in p.move(to: CGPoint(x: 0, y: g.size.height)); p.addLine(to: CGPoint(x: g.size.width*0.3,y:g.size.height*0.5)); p.addLine(to: CGPoint(x:g.size.width*0.5,y:g.size.height*0.7)); p.addLine(to: CGPoint(x:g.size.width*0.7,y:g.size.height*0.4)); p.addLine(to: CGPoint(x:g.size.width,y:g.size.height*0.8)); p.addLine(to: CGPoint(x:g.size.width,y:g.size.height)); p.closeSubpath() }.fill(skin.palette.sampleMountain) }
        }.clipShape(skin.shapes.control).modifier(SkinImageTreatment(selected: false)).padding(5)
            .background(skin.isUnit ? skin.palette.line : skin.palette.light, in: skin.shapes.card).skinShadow(skin.shadows.sample)
    }
    private var sampleNote: some View {
        Group {
            if skin.isUnit { SkinDisplayText("周三 10:00", size: 22).frame(width: 180, height: 130).background(skin.palette.base).overlay(Rectangle().stroke(skin.palette.line)) }
            else { Text(skin.label("看中的东西，\n先搁这儿。")).font(skin.typography.sampleNote).foregroundStyle(skin.palette.feedbackBackdrop).frame(width: 180, height: 130).background(skin.palette.sampleNote, in: skin.shapes.card) }
        }
    }
    private func keys(_ values: [String]) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, key in
                Text(key).font(skin.typography.keyCap).foregroundStyle(skin.palette.light).frame(minWidth: 54, minHeight: 54).background(skin.materials.ultraThin, in: skin.shapes.field)
                    .overlay(skin.shapes.field.stroke(skin.palette.keyBorder, lineWidth: 0.5))
                    .skinShadow(skin.shadows.key(pressed: keyDown == index && !reduceMotion)).offset(y: keyDown == index && !reduceMotion ? 3 : 0)
            }
        }
    }
    private func animateStep() async {
        phase = 0; cursorDemo = false; drag = .zero; glow = false; keyDown = -1
        if reduceMotion { phase = 20; return }
        if skin.isUnit && session.step == .welcome { phase = 20; return }
        do {
            switch session.step {
            case .welcome:
                withAnimation(spring) { phase = 1 }
                for index in 0..<title.count { try await Task.sleep(for: skin.motion.letterDelay); withAnimation(ease) { phase = index + 2 } }
                try await Task.sleep(for: skin.motion.welcomeDelay); withAnimation(ease) { phase = 20 }
            case .edge:
                repeat {
                    try await Task.sleep(for: skin.motion.cursorDelay)
                    withAnimation(skin.motion.cursor) { cursorDemo = true }
                    try await Task.sleep(for: skin.motion.cursorHold)
                    withAnimation(ease) { cursorDemo = false }
                    try await Task.sleep(for: skin.motion.cursorRepeat)
                } while !session.edgeCompleted && !Task.isCancelled
            case .drop: break
            case .paste, .shortcut:
                let count = session.step == .paste ? 2 : preferences.shortcut?.keyCaps.count ?? 0
                for index in 0..<count {
                    withAnimation(skin.motion.keyDown) { keyDown = index }
                    try await Task.sleep(for: skin.motion.keyHold)
                    withAnimation(skin.motion.keyUp) { keyDown = -1 }
                    try await Task.sleep(for: skin.motion.keyGap)
                }
                withAnimation(spring) { phase = session.step == .paste ? 3 : 4 }
                if session.step == .shortcut { try await Task.sleep(for: skin.motion.glowDelay); withAnimation(skin.motion.glow) { glow = true } }
            case .export:
                try await Task.sleep(for: skin.motion.exportDelay); withAnimation(spring) { phase = 1 }
                try await Task.sleep(for: skin.motion.exportLift); withAnimation(skin.motion.export) { phase = 2 }
                try await Task.sleep(for: skin.motion.exportTravel); withAnimation(spring) { phase = 3 }
            }
        } catch is CancellationError { } catch { assertionFailure("Unexpected animation clock error: \(error)") }
    }
    private func exitGuide() {
        guard !exiting else { return }
        withAnimation(skin.motion.exit) { exiting = true }
        Task { try? await Task.sleep(for: skin.motion.exitDelay); finish() }
    }
}
