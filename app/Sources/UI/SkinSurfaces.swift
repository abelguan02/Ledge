import AppKit
import SwiftUI

private typealias SkinSurfaceState<Value> = SwiftUI.State<Value>

// Production reads the system setting. Offscreen reviews may exercise both
// paths without changing the user's global macOS accessibility preference.
private struct SkinMotionOverrideKey: EnvironmentKey { static let defaultValue: Bool? = nil }
extension EnvironmentValues {
    var skinMotionOverride: Bool? {
        get { self[SkinMotionOverrideKey.self] }
        set { self[SkinMotionOverrideKey.self] = newValue }
    }
}
@propertyWrapper struct SkinReducedMotion: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var system
    @Environment(\.skinMotionOverride) private var override
    var wrappedValue: Bool { override ?? system }
}

// Classic surface geometry, kept verbatim during extraction.

struct GlassBackground: NSViewRepresentable {
    @Environment(\.ledgeSkin) private var skin
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(); view.material = skin.materials.glass; view.blendingMode = skin.materials.blending; view.state = skin.materials.state
        view.isHidden = skin.isUnit
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.isHidden = skin.isUnit }
}
struct EdgePanelShape: Shape {
    var edge: DockEdge = .right
    var cut = false
    var wing = 24.0
    var radius = 26.0
    func path(in rect: CGRect) -> Path {
        switch edge {
        case .right: return rightPath(in: rect)
        case .left: return rightPath(in: rect).applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.width, ty: 0))
        case .top: return rightPath(in: CGRect(x: 0, y: 0, width: rect.height, height: rect.width)).applying(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: rect.height))
        }
    }
    private func rightPath(in rect: CGRect) -> Path {
        if cut {
            let w = rect.width, h = rect.height
            var path = Path()
            path.move(to: CGPoint(x: 24, y: 20))
            for point in [CGPoint(x: w - 20, y: 20), CGPoint(x: w, y: 0),
                          CGPoint(x: w, y: h), CGPoint(x: w - 20, y: h - 20),
                          CGPoint(x: 0, y: h - 20), CGPoint(x: 0, y: 44)] { path.addLine(to: point) }
            path.closeSubpath(); return path
        }
        let w = rect.width, h = rect.height, s = wing, r = radius
        var path = Path()
        path.move(to: CGPoint(x: w, y: 0))
        path.addCurve(to: CGPoint(x: w-s, y: s), control1: CGPoint(x: w, y: s*0.55), control2: CGPoint(x: w-s*0.45, y: s))
        path.addLine(to: CGPoint(x: r, y: s))
        path.addQuadCurve(to: CGPoint(x: 0, y: s+r), control: CGPoint(x: 0, y: s))
        path.addLine(to: CGPoint(x: 0, y: h-s-r))
        path.addQuadCurve(to: CGPoint(x: r, y: h-s), control: CGPoint(x: 0, y: h-s))
        path.addLine(to: CGPoint(x: w-s, y: h-s))
        path.addCurve(to: CGPoint(x: w, y: h), control1: CGPoint(x: w-s*0.45, y: h-s), control2: CGPoint(x: w, y: h-s*0.55))
        path.closeSubpath(); return path
    }
}

struct TabGlass: NSViewRepresentable {
    @Environment(\.ledgeSkin) private var skin
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = skin.materials.glass
        view.blendingMode = skin.materials.blending
        view.state = skin.materials.state
        view.appearance = NSAppearance(named: skin.materials.tabAppearance)
        view.isHidden = skin.isUnit
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.isHidden = skin.isUnit }
}

// 64-point body, 8-point concave wings, 6-point inner corners.
struct GlassTabShape: Shape {
    var closed = true
    var cut = false
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        if cut {
            path.move(to: CGPoint(x: w, y: 0))
            for point in [CGPoint(x: 8, y: 0), CGPoint(x: 0, y: 8),
                          CGPoint(x: 0, y: h - 8), CGPoint(x: 8, y: h), CGPoint(x: w, y: h)] { path.addLine(to: point) }
            if closed { path.closeSubpath() }
            return path
        }
        path.move(to: CGPoint(x: w, y: 0))
        path.addCurve(to: CGPoint(x: w - 8, y: 8), control1: CGPoint(x: w, y: 4.418), control2: CGPoint(x: w - 3.582, y: 8))
        path.addLine(to: CGPoint(x: 6, y: 8))
        path.addQuadCurve(to: CGPoint(x: 0, y: 14), control: CGPoint(x: 0, y: 8))
        path.addLine(to: CGPoint(x: 0, y: h - 14))
        path.addQuadCurve(to: CGPoint(x: 6, y: h - 8), control: CGPoint(x: 0, y: h - 8))
        path.addLine(to: CGPoint(x: w - 8, y: h - 8))
        path.addCurve(to: CGPoint(x: w, y: h), control1: CGPoint(x: w - 3.582, y: h - 8), control2: CGPoint(x: w, y: h - 4.418))
        if closed { path.closeSubpath() }
        return path
    }
}

// Decoration is local to the UI, never part of an image, export, or drag payload.
struct SkinScanlines: View {
    var excluding: CGRect? = nil
    var body: some View {
        Canvas { context, size in
            if let excluding {
                var mask = Path(CGRect(origin: .zero, size: size))
                mask.addRect(excluding)
                context.clip(to: mask, style: FillStyle(eoFill: true))
            }
            for y in stride(from: 0.0, to: size.height, by: 3) {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.13)))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

// Brackets deliberately sit outside the material bounds; they never receive input.
struct UnitLockCorners: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let length = min(22, min(rect.width, rect.height) / 3)
        for (x, y, dx, dy) in [(rect.minX, rect.minY, 1.0, 1.0), (rect.maxX, rect.minY, -1.0, 1.0),
                               (rect.minX, rect.maxY, 1.0, -1.0), (rect.maxX, rect.maxY, -1.0, -1.0)] {
            path.move(to: CGPoint(x: x, y: y + dy * length))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + dx * length, y: y))
        }
        return path
    }
}

struct UnitWarningStripe: View {
    var color = LedgeSkin.unit01.palette.warning
    var band: CGFloat = 8
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            for x in stride(from: -size.height, through: size.width + size.height, by: band * 2) {
                var stripe = Path()
                stripe.move(to: CGPoint(x: x, y: 0))
                stripe.addLine(to: CGPoint(x: x + band, y: 0))
                stripe.addLine(to: CGPoint(x: x + band + size.height, y: size.height))
                stripe.addLine(to: CGPoint(x: x + size.height, y: size.height))
                stripe.closeSubpath(); context.fill(stripe, with: .color(color))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct SkinImageTreatment: ViewModifier {
    @Environment(\.ledgeSkin) private var skin
    var selected: Bool
    func body(content: Content) -> some View {
        if skin.isUnit && !selected {
            content.saturation(0).colorMultiply(Color(red: 0.72, green: 0.50, blue: 1)).opacity(0.72)
        } else { content }
    }
}

struct SkinActionButtonStyle: PrimitiveButtonStyle {
    @Environment(\.ledgeSkin) private var skin
    var prominent = false
    var destructive = false
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if skin.isUnit {
            Button(action: configuration.trigger) {
                configuration.label.padding(.horizontal, 12).padding(.vertical, 7)
                    .foregroundStyle(prominent ? skin.palette.base : destructive ? skin.palette.destructive : skin.palette.primary)
                    .background(prominent ? (destructive ? skin.palette.alarm : skin.palette.accent) : skin.palette.inset)
                    .overlay(Rectangle().stroke(destructive ? skin.palette.destructive : skin.palette.line, lineWidth: 1).allowsHitTesting(false))
            }.buttonStyle(.plain)
        } else if prominent { Button(configuration).buttonStyle(.borderedProminent) }
        else { Button(configuration).buttonStyle(.bordered) }
    }
}

struct SkinSwitchToggleStyle: ToggleStyle {
    @Environment(\.ledgeSkin) private var skin
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if skin.isUnit {
            Button { configuration.isOn.toggle() } label: {
                Rectangle().fill(configuration.isOn ? skin.palette.accent : skin.palette.separator)
                    .frame(width: 44, height: 22)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Rectangle().fill(configuration.isOn ? skin.palette.base : skin.palette.secondary).frame(width: 16, height: 16).padding(3)
                    }
            }.buttonStyle(.plain).accessibilityRepresentation { Toggle(configuration).toggleStyle(.switch) }
        } else { Toggle(configuration).toggleStyle(.switch) }
    }
}

struct SkinSegments<Value: Hashable>: View {
    @Environment(\.ledgeSkin) private var skin
    let title: String
    let choices: [(Value, String)]
    @Binding var selection: Value
    var body: some View {
        if skin.isUnit {
            HStack(spacing: 0) {
                ForEach(choices, id: \.0) { value, label in
                    Button { selection = value } label: {
                        Text(skin.label(label)).font(.system(size: choices.count >= 5 ? 11 : 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.65)
                            .frame(maxWidth: .infinity).padding(.horizontal, choices.count >= 5 ? 2 : 6).frame(height: 28)
                            .foregroundStyle(selection == value ? skin.palette.base : skin.palette.primary)
                            .background(selection == value ? skin.palette.accent : skin.palette.inset)
                    }.buttonStyle(.plain).accessibilityLabel(skin.label(label)).accessibilityAddTraits(selection == value ? .isSelected : [])
                }
            }.overlay(Rectangle().stroke(skin.palette.line, lineWidth: 1).allowsHitTesting(false)).accessibilityElement(children: .contain).accessibilityLabel(skin.label(title))
        } else {
            Picker(skin.label(title), selection: $selection) { ForEach(choices, id: \.0) { value, label in Text(skin.label(label)).tag(value) } }
                .labelsHidden().pickerStyle(.segmented)
        }
    }
}

struct UnitBootBlock: ViewModifier {
    @Environment(\.ledgeSkin) private var skin
    @SkinReducedMotion private var reduced
    let index: Int
    @SkinSurfaceState private var visible = true
    func body(content: Content) -> some View {
        content.opacity(skin.isUnit && !reduced && !visible ? 0 : 1)
            .task {
                visible = true
                guard skin.isUnit && !reduced else { return }
                visible = false
                do {
                    try await Task.sleep(for: .seconds(0.32 + Double(index) * 0.24))
                    visible = true
                    try await Task.sleep(for: .milliseconds(80)); visible = false
                    try await Task.sleep(for: .milliseconds(80)); visible = true
                } catch { visible = true }
            }
            .onChange(of: reduced) { _, value in if value { visible = true } }
    }
}

struct UnitLandingLock: View {
    @SkinReducedMotion private var reduced
    @SkinSurfaceState private var settled = false
    @SkinSurfaceState private var blink = false
    var body: some View {
        UnitLockCorners().stroke(LedgeSkin.unit01.palette.accent, lineWidth: 4).padding(-10)
            .scaleEffect(reduced || settled ? 1 : 1.5)
            .opacity(reduced || !blink ? 1 : 0.3)
            .task {
                guard !reduced else { return }
                do { try await Task.sleep(for: .milliseconds(270)); blink = true
                    try await Task.sleep(for: .milliseconds(45)); blink = false
                } catch { blink = false }
            }
            .onAppear { withAnimation(reduced ? nil : .timingCurve(0.9, 0, 0.1, 1, duration: 0.27)) { settled = true } }
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct UnitRemovalEffect: AnimatableModifier {
    nonisolated var phase: Double
    nonisolated var animatableData: Double { get { phase } set { phase = newValue } }
    func body(content: Content) -> some View { content.opacity(phase < 0.35 ? 1 : phase < 0.55 ? 0.2 : phase < 0.7 ? 1 : 0) }
}

struct UnitSignalPulse: ViewModifier {
    @Environment(\.ledgeSkin) private var skin
    @SkinReducedMotion private var reduced
    var alarm = false
    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: !skin.isUnit || reduced)) { context in
            content.opacity(skin.motion.signalOpacity(time: context.date.timeIntervalSinceReferenceDate, alarm: alarm, reduced: reduced))
        }
    }
}

struct UnitAlarmFlash: ViewModifier {
    @SkinReducedMotion private var reduced
    @SkinSurfaceState private var flashing = false
    func body(content: Content) -> some View {
        content.overlay { if flashing && !reduced { LedgeSkin.unit01.palette.alarm.allowsHitTesting(false).accessibilityHidden(true) } }
            .task {
                guard !reduced else { return }
                flashing = true
                do { try await Task.sleep(for: .milliseconds(200)) } catch { }
                flashing = false
            }
    }
}

struct UnitPanelTrim: View {
    let edge: DockEdge
    var body: some View {
        Canvas { context, size in
            let palette = LedgeSkin.unit01.palette
            let height = edge == .top ? size.width : size.height
            if edge == .left { context.concatenate(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0)) }
            if edge == .top { context.concatenate(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.height)) }
            context.fill(Path(CGRect(x: 0, y: 44, width: 16, height: max(0, height - 64))), with: .color(palette.armor))
            var warning = context
            warning.clip(to: Path(CGRect(x: 0, y: 44, width: 16, height: 96)))
            warning.fill(Path(CGRect(x: 0, y: 44, width: 16, height: 96)), with: .color(palette.warning))
            for y in stride(from: 28.0, to: 160, by: 16) {
                var stripe = Path(); stripe.move(to: CGPoint(x: 0, y: y))
                for point in [CGPoint(x: 16, y: y + 16), CGPoint(x: 16, y: y + 24), CGPoint(x: 0, y: y + 8)] { stripe.addLine(to: point) }
                stripe.closeSubpath(); warning.fill(stripe, with: .color(palette.base))
            }
            for y in stride(from: 44.0, to: height - 20, by: 20) {
                context.fill(Path(CGRect(x: 16, y: y, width: 6, height: 1)), with: .color(palette.line))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}


struct TrayPointer: Shape {
    let target: CGPoint
    func path(in rect: CGRect) -> Path {
        // Keep the small pointer attached to the nearest tray edge when the
        // tray is shifted into the visible viewport.
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = target.x - center.x, dy = target.y - center.y
        let vertical = abs(dy) / max(1, rect.height) >= abs(dx) / rect.width
        var path = Path()
        if vertical {
            let x = min(rect.maxX - 22, max(22, target.x)), y = dy < 0 ? rect.minY : rect.maxY
            path.move(to: CGPoint(x: x - 9, y: y)); path.addLine(to: CGPoint(x: x, y: y + (dy < 0 ? -12 : 12))); path.addLine(to: CGPoint(x: x + 9, y: y))
        } else {
            let y = min(rect.maxY - 22, max(22, target.y)), x = dx < 0 ? rect.minX : rect.maxX
            path.move(to: CGPoint(x: x, y: y - 9)); path.addLine(to: CGPoint(x: x + (dx < 0 ? -12 : 12), y: y)); path.addLine(to: CGPoint(x: x, y: y + 9))
        }
        path.closeSubpath(); return path
    }
}


struct GuideTitleEffect: ViewModifier {
    var offset: CGFloat
    var blur: CGFloat
    var opacity: Double
    func body(content: Content) -> some View { content.offset(y: offset).blur(radius: blur).opacity(opacity) }
}
struct GuidePanelEffect: ViewModifier {
    var scale: CGFloat
    var opacity: Double
    func body(content: Content) -> some View { content.scaleEffect(x: scale, y: 1, anchor: .trailing).opacity(opacity) }
}


extension LedgeSkin.Motion {
    func guideTitle(reduced: Bool) -> AnyTransition {
        reduced || isUnit ? .opacity : .asymmetric(insertion: .modifier(active: GuideTitleEffect(offset: 14, blur: 8, opacity: 0), identity: GuideTitleEffect(offset: 0, blur: 0, opacity: 1)), removal: .offset(y: -14).combined(with: .opacity))
    }
    func guidePanel(reduced: Bool) -> AnyTransition {
        reduced || isUnit ? .opacity : .modifier(active: GuidePanelEffect(scale: 0.03, opacity: 0), identity: GuidePanelEffect(scale: 1, opacity: 1))
    }
}

extension LedgeSkin.Shapes {
    func resizeGrip(scale: Double) -> NSBezierPath {
        let path = NSBezierPath()
        if isUnit {
            path.move(to: CGPoint(x: 1 / scale, y: 1.5 / scale))
            path.line(to: CGPoint(x: 14.5 / scale, y: 1.5 / scale))
            path.line(to: CGPoint(x: 14.5 / scale, y: 15 / scale))
            path.lineWidth = 3 / scale; path.lineCapStyle = .butt
            return path
        }
        path.move(to: CGPoint(x: 1 / scale, y: 1.5 / scale))
        path.line(to: CGPoint(x: 7 / scale, y: 1.5 / scale))
        path.curve(to: CGPoint(x: 14.5 / scale, y: 9 / scale), controlPoint1: CGPoint(x: 13 / scale, y: 1.5 / scale), controlPoint2: CGPoint(x: 14.5 / scale, y: 3 / scale))
        path.line(to: CGPoint(x: 14.5 / scale, y: 15 / scale))
        path.lineWidth = 3 / scale; path.lineCapStyle = .round
        return path
    }
}
