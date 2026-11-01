import Foundation

enum Placement {
    static let grid = 24.0
    static let width = 520.0
    // Snap and avoid collisions as one footprint, preserving every member's
    // offset (including layouts imported from older, non-grid positions).
    static func locateGroup(_ items: [Material], anchor: Material, occupied: [CanvasRect], preferred: CanvasPoint) -> [UUID: CanvasPoint] {
        let left = items.map(\.position.x).min()!
        let top = items.map(\.position.y).min()!
        let size = CanvasSize(width: items.map(\.rect.maxX).max()! - left,
                              height: items.map(\.rect.maxY).max()! - top)
        let origin = locate(size: size, occupied: occupied,
                            preferred: CanvasPoint(x: preferred.x + left - anchor.position.x,
                                                   y: preferred.y + top - anchor.position.y))
        return Dictionary(uniqueKeysWithValues: items.map {
            ($0.id, CanvasPoint(x: $0.position.x + origin.x - left, y: $0.position.y + origin.y - top))
        })
    }
    static func locate(size: CanvasSize, occupied: [CanvasRect], preferred: CanvasPoint?) -> CanvasPoint {
        let availableWidth = max(width, (occupied.map(\.maxX).max() ?? 0) + grid,
                                 (preferred?.x ?? 0) + size.width + grid)
        let maxColumn = max(1, Int((availableWidth - grid - size.width) / grid))
        if let preferred {
            let point = CanvasPoint(x: min(Double(maxColumn) * grid, max(grid, (preferred.x / grid).rounded() * grid)),
                                    y: max(grid, (preferred.y / grid).rounded() * grid))
            let rect = CanvasRect(origin: point, size: size)
            if !occupied.contains(where: { rect.intersectionArea($0) > min(size.width * size.height, $0.size.width * $0.size.height) / 2 }) { return point }
            // Search a finite rectangle containing all content; the extra bottom row always fits.
            let bottom = max(point.y, occupied.map(\.maxY).max() ?? 0) + size.height + grid
            var best: CanvasPoint?
            var distance = Double.infinity
            for row in 1...max(1, Int(ceil(bottom / grid))) {
                for column in 1...maxColumn {
                    let candidate = CanvasPoint(x: Double(column) * grid, y: Double(row) * grid)
                    let d = pow(candidate.x - point.x, 2) + pow(candidate.y - point.y, 2)
                    if d < distance, !occupied.contains(where: { CanvasRect(origin: candidate, size: size).intersects($0) }) {
                        best = candidate; distance = d
                    }
                }
            }
            return best!
        }
        let bottom = (occupied.map(\.maxY).max() ?? 0) + grid
        for row in 1...max(1, Int(ceil(bottom / grid))) {
            for column in 1...maxColumn {
                let point = CanvasPoint(x: Double(column) * grid, y: Double(row) * grid)
                // One grid cell of breathing room for automatic placement.
                let padded = CanvasRect(origin: CanvasPoint(x: point.x - 12, y: point.y - 12),
                                        size: CanvasSize(width: size.width + 24, height: size.height + 24))
                if !occupied.contains(where: { padded.intersects($0) }) { return point }
            }
        }
        return CanvasPoint(x: grid, y: ceil(bottom / grid) * grid)
    }
}
