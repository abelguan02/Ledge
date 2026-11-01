import Foundation
import CoreGraphics

enum DockEdge: String, CaseIterable, Sendable { case right, left, top }

enum PanelPlacement {
    static func frame(size: CGSize, visible: CGRect, edge: DockEdge) -> CGRect {
        let size = CGSize(width: min(size.width, visible.width), height: min(size.height, visible.height))
        switch edge {
        case .right: return CGRect(x: visible.maxX - size.width, y: visible.midY - size.height / 2, width: size.width, height: size.height)
        case .left: return CGRect(x: visible.minX, y: visible.midY - size.height / 2, width: size.width, height: size.height)
        case .top: return CGRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height, width: size.width, height: size.height)
        }
    }
    static func screenID(current: Int, available: [Int], main: Int?) -> Int? {
        if available.contains(current) { return current }
        if let main, available.contains(main) { return main }
        return available.first
    }
}

struct EdgeDragSession {
    let origin: CGPoint
    let pasteboardRevision: Int
    func isExternalDrag(at point: CGPoint, revision: Int, supported: Bool) -> Bool {
        supported && revision != pasteboardRevision && hypot(point.x - origin.x, point.y - origin.y) > 4
    }
}
