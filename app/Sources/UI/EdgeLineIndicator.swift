import AppKit
import SwiftUI

struct EdgeLineIndicator: View {
    @Environment(\.ledgeSkin) private var skin
    let state: EdgeState
    let time: TimeInterval
    let reduceMotion: Bool
    var hovering = false
    var edge: DockEdge = .right

    var body: some View {
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
