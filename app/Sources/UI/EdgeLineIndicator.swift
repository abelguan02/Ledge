import AppKit
import SwiftUI

private struct TabGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { }
}

// 64-point body, 8-point concave wings, 6-point inner corners.
struct GlassTabShape: Shape {
    var closed = true
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
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

struct EdgeLineIndicator: View {
    let state: EdgeState
    let time: TimeInterval
    let reduceMotion: Bool
    var hovering = false
    var edge: DockEdge = .right

    var body: some View {
        let width = hovering && !reduceMotion ? 18.0 : 14.0
        let pulse = reduceMotion ? 1 : 0.775 - 0.225 * cos(time * 2 * Double.pi / 2.4)
        ZStack {
            ZStack {
                TabGlass()
                Color(red: 44 / 255, green: 44 / 255, blue: 50 / 255).opacity(0.62)
            }.opacity(0.62)
            ZStack(alignment: .top) {
                switch state {
                case .quiet: Color.white.opacity(0.88)
                case .processing:
                    Color.white.opacity(0.4)
                    if !reduceMotion {
                        LinearGradient(colors: [.clear, .white, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 14)
                            .offset(y: -14 + time.truncatingRemainder(dividingBy: 1.6) / 1.6 * 54)
                    }
                case .attention: Color.white.opacity(pulse)
                case .failed: Color(red: 1, green: 69 / 255, blue: 58 / 255).opacity(pulse)
                }
            }.frame(width: 3, height: 28).clipShape(Capsule())
        }
        .frame(width: width, height: 80)
        .clipShape(GlassTabShape())
        .overlay {
            GlassTabShape(closed: false).stroke(
                LinearGradient(stops: [.init(color: .white.opacity(0.22), location: 0),
                                       .init(color: .white.opacity(0.28), location: 0.3),
                                       .init(color: .white.opacity(0.28), location: 0.7),
                                       .init(color: .white.opacity(0.12), location: 1)],
                               startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 4, x: -1)
        .scaleEffect(x: edge == .left ? -1 : 1, y: 1)
        .rotationEffect(.degrees(edge == .top ? -90 : 0))
        .frame(width: edge == .top ? 80 : width, height: edge == .top ? width : 80)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
    }
}
