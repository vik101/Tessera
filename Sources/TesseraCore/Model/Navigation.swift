import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Finds neighbours among rectangles (tiles, screens, Tab View items).
/// Coordinates: origin top-left, y grows downward.
/// A candidate neighbour with the facts used to rank it.
private struct Scored<K> {
    let key: K
    let overlaps: Bool
    let distance: Double
    let crossDistance: Double
    let order: Double
}

public enum Navigation {
    /// The best rectangle in `direction` from `source`, or nil.
    ///
    /// Prefers rectangles that overlap on the cross axis, then the closest,
    /// then the top-most / left-most. From the primary, → picks the top window
    /// of the right-hand column.
    public static func neighbor<Key: Hashable>(
        of source: CGRect,
        direction: Direction,
        among candidates: [Key: CGRect],
        tolerance: Double = 4
    ) -> Key? {
        var scored: [Scored<Key>] = []
        for (key, rect) in candidates {
            if rect == source { continue }
            let inDirection: Bool
            let distance: Double
            let overlap: Double
            let crossDistance: Double
            let order: Double
            switch direction {
            case .left:
                inDirection = rect.midX < source.midX && rect.maxX <= source.minX + tolerance
                distance = source.minX - rect.maxX
                overlap = min(source.maxY, rect.maxY) - max(source.minY, rect.minY)
                crossDistance = abs(rect.midY - source.midY)
                order = rect.minY
            case .right:
                inDirection = rect.midX > source.midX && rect.minX >= source.maxX - tolerance
                distance = rect.minX - source.maxX
                overlap = min(source.maxY, rect.maxY) - max(source.minY, rect.minY)
                crossDistance = abs(rect.midY - source.midY)
                order = rect.minY
            case .up:
                inDirection = rect.midY < source.midY && rect.maxY <= source.minY + tolerance
                distance = source.minY - rect.maxY
                overlap = min(source.maxX, rect.maxX) - max(source.minX, rect.minX)
                crossDistance = abs(rect.midX - source.midX)
                order = rect.minX
            case .down:
                inDirection = rect.midY > source.midY && rect.minY >= source.maxY - tolerance
                distance = rect.minY - source.maxY
                overlap = min(source.maxX, rect.maxX) - max(source.minX, rect.minX)
                crossDistance = abs(rect.midX - source.midX)
                order = rect.minX
            }
            guard inDirection else { continue }
            scored.append(Scored(key: key, overlaps: overlap > tolerance, distance: max(0, distance), crossDistance: crossDistance, order: order))
        }
        return scored.min { a, b in
            if a.overlaps != b.overlaps { return a.overlaps }
            if abs(a.distance - b.distance) > 1 { return a.distance < b.distance }
            if !a.overlaps, abs(a.crossDistance - b.crossDistance) > 1 { return a.crossDistance < b.crossDistance }
            return a.order < b.order
        }?.key
    }

    /// The rectangle (from `candidates`) that contains `point`, preferring the smallest.
    public static func hit<Key: Hashable>(_ point: CGPoint, in candidates: [Key: CGRect]) -> Key? {
        candidates
            .filter { $0.value.contains(point) }
            .min { $0.value.width * $0.value.height < $1.value.width * $1.value.height }?
            .key
    }

    /// Orders screens left to right, then top to bottom, as System Settings arranges them.
    public static func arrangementOrder<Key: Hashable>(_ screens: [Key: CGRect]) -> [Key] {
        screens.sorted { a, b in
            if abs(a.value.minX - b.value.minX) > 1 { return a.value.minX < b.value.minX }
            return a.value.minY < b.value.minY
        }.map(\.key)
    }
}
