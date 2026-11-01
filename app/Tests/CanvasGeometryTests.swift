import Foundation

@main struct CanvasGeometryTests {
    static func main() throws {
        let size = CanvasSize(width: 144, height: 120)
        let point = Placement.locate(size: size, occupied: [], preferred: CanvasPoint(x: 1200, y: 240))
        guard point == CanvasPoint(x: 1200, y: 240) else {
            print("FAIL: wide-canvas drop was clamped to the old panel width: \(point)")
            exit(1)
        }
        let occupied = [CanvasRect(origin: point, size: size)]
        let moved = Placement.locate(size: size, occupied: occupied, preferred: point)
        guard !CanvasRect(origin: moved, size: size).intersects(occupied[0]), abs(moved.x - point.x) < 240 else {
            print("FAIL: collision recovery must stay near the wide-canvas drop")
            exit(1)
        }
        let auto = Placement.locate(size: size, occupied: [], preferred: nil)
        guard auto == CanvasPoint(x: 24, y: 24) else { exit(1) }
        for visible in [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: -1280, y: 40, width: 1280, height: 720), CGRect(x: 0, y: 0, width: 1024, height: 600)] {
            for edge in DockEdge.allCases {
                let panel = PanelPlacement.frame(size: CGSize(width: 1120, height: 900), visible: visible, edge: edge)
                guard visible.contains(panel) else { exit(1) }
                switch edge {
                case .right: precondition(panel.maxX == visible.maxX)
                case .left: precondition(panel.minX == visible.minX)
                case .top: precondition(panel.maxY == visible.maxY)
                }
            }
        }
        print("PASS canvas geometry: wide placement, nearby collision recovery and original automatic placement")
        print("PASS expanded panel stays inside large, offset and small screen frames")
    }
}
