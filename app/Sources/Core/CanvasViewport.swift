import Foundation
import CoreGraphics

struct CanvasViewportKey: Hashable {
    let collection: UUID
    let expanded: Bool
}

struct CanvasViewportState {
    static let zoomRange = 0.25...2.0
    var zoom = 1.0
    var origin = CGPoint.zero
}
