import AppKit
import SwiftUI

struct EdgeLineIndicator: View {
    @Environment(\.ledgeSkin) private var skin
    let state: EdgeState
    let time: TimeInterval
    let reduceMotion: Bool
    var hovering = false
    var edge: DockEdge = .right

    @ViewBuilder var body: some View {
        if skin.isUnit { unitTab } else { classicTab }
    }
    private var unitTab: some View {
        let width = hovering ? 22.0 : 18.0
        let phase = time.truncatingRemainder(dividingBy: 0.7) / 0.7
        let opacity = reduceMotion ? 1 : state == .failed ? (phase < 0.5 ? 1 : 0.12) : skin.motion.tabPulse(time: time, reduced: false)
        return VStack(alignment: .trailing, spacing: 4) {
            UnitWarningStripe(band: 5).frame(height: 10)
            ZStack {
                skin.palette.armor
                Rectangle().fill(state == .failed ? skin.palette.destructive : state == .attention ? skin.palette.light : skin.palette.accent)
                    .opacity(state == .processing && !reduceMotion ? 0.35 : state == .attention || state == .failed ? opacity : 1)
                    .frame(width: 4, height: 56)
                    .overlay {
                        if state == .processing && !reduceMotion {
                            Rectangle().fill(skin.palette.accent).frame(width: 4, height: 16)
                                .offset(y: -36 + time.truncatingRemainder(dividingBy: 1.6) / 1.6 * 72)
                                .frame(width: 4, height: 56).clipped()
                        }
                    }
            }.frame(width: width, height: 112).clipShape(GlassTabShape(cut: true))
            UnitWarningStripe(band: 5).frame(height: 10)
        }.frame(width: width + 2).overlay { SkinScanlines() }
            .scaleEffect(x: edge == .left ? -1 : 1)
            .rotationEffect(.degrees(edge == .top ? -90 : 0))
            .frame(width: edge == .top ? 140 : width + 2, height: edge == .top ? width + 2 : 140)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
    }
    @ViewBuilder private var classicTab: some View {
        let width = hovering && !reduceMotion ? 18.0 : 14.0
        let pulse = skin.motion.tabPulse(time: time, reduced: reduceMotion)
        ZStack {
            ZStack {
                TabGlass()
                skin.palette.tab
            }.opacity(skin.isUnit ? 1 : 0.62)
            ZStack(alignment: .top) {
                switch state {
                case .quiet: skin.palette.tabQuiet
                case .processing:
                    skin.palette.tabBusy
                    if !reduceMotion {
                        LinearGradient(colors: [skin.palette.clear, skin.palette.light, skin.palette.clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 14)
                            .offset(y: skin.motion.tabFlow(time: time))
                    }
                case .attention: skin.palette.light.opacity(pulse)
                case .failed: skin.palette.tabError.opacity(pulse)
                }
            }.frame(width: 3, height: 28).clipShape(skin.shapes.capsule)
        }
        .frame(width: width, height: 80)
        .overlay { if skin.isUnit { SkinScanlines() } }
        .clipShape(GlassTabShape(cut: skin.isUnit))
        .overlay {
            GlassTabShape(closed: false, cut: skin.isUnit).stroke(
                LinearGradient(stops: [.init(color: skin.palette.tabBorderTop, location: 0),
                                       .init(color: skin.palette.stackBorder, location: 0.3),
                                       .init(color: skin.palette.stackBorder, location: 0.7),
                                       .init(color: skin.palette.tabBorderBottom, location: 1)],
                               startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
        }
        .skinShadow(skin.shadows.tab)
        .scaleEffect(x: edge == .left ? -1 : 1, y: 1)
        .rotationEffect(.degrees(edge == .top ? -90 : 0))
        .frame(width: edge == .top ? 80 : width, height: edge == .top ? width : 80)
        .animation(reduceMotion ? nil : skin.motion.hover, value: hovering)
    }
}
