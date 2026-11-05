import AppKit
import SwiftUI

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
    var body: some View {
        Canvas { context, size in
            for y in stride(from: 0.0, to: size.height, by: 3) {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.13)))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
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
        reduced ? .opacity : .asymmetric(insertion: .modifier(active: GuideTitleEffect(offset: 14, blur: 8, opacity: 0), identity: GuideTitleEffect(offset: 0, blur: 0, opacity: 1)), removal: .offset(y: -14).combined(with: .opacity))
    }
    func guidePanel(reduced: Bool) -> AnyTransition {
        reduced ? .opacity : .modifier(active: GuidePanelEffect(scale: 0.03, opacity: 0), identity: GuidePanelEffect(scale: 1, opacity: 1))
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
