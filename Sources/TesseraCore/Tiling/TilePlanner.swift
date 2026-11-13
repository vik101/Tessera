import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// How auto-tile arranges the windows on a screen.
public enum LayoutStyle: String, CaseIterable, Codable, Sendable {
    /// Picks the best arrangement for the number of windows and the screen's shape.
    case auto
    /// Side by side.
    case columns
    /// One above the other.
    case rows
    /// An even grid.
    case grid
    /// One big main window, the rest stacked beside it.
    case mainAndSide

    public var title: String {
        switch self {
        case .auto: "Auto"
        case .columns: "Columns"
        case .rows: "Rows"
        case .grid: "Grid"
        case .mainAndSide: "Main + Side"
        }
    }

    public var next: LayoutStyle {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Works out where each tiled window goes. Pure maths, no AppKit.
///
/// Every window always gets its own slot: auto-tile never hides a window.
public enum TilePlanner {
    /// The cell shape we aim for in Auto and Grid: a little wider than tall, like most windows.
    static let idealAspect: CGFloat = 4.0 / 3.0

    /// Frames for `count` windows in `area`, in window order. The first window is the main one.
    ///
    /// - Parameter minimumSizes: sizes some windows refuse to go below. Auto and Grid pick
    ///   the best arrangement in which every window fits. If none fits, they use the best one anyway.
    public static func frames(
        count: Int,
        in area: CGRect,
        style: LayoutStyle,
        gap: CGFloat = 0,
        mainRatio: CGFloat = 0.5,
        minimumSizes: [CGSize?] = []
    ) -> [CGRect] {
        guard count > 0, area.width > 0, area.height > 0 else { return [] }
        let shape = ScreenShape.of(area.size)
        let ratio = min(max(mainRatio, 0.2), 0.8)

        let candidates: [[UnitRect]]
        switch style {
        case .columns: candidates = [columns(count)]
        case .rows: candidates = [rows(count)]
        case .mainAndSide: candidates = [mainAndSide(count, ratio: ratio, portrait: shape == .portrait)]
        case .grid: candidates = ranked(grids(count), in: area)
        case .auto:
            if count == 1, shape == .ultrawide {
                // One window on a very wide screen: centred, not stretched edge to edge.
                candidates = [[UnitRect(x: 1.0 / 6, y: 0, width: 2.0 / 3, height: 1)], [.full]]
            } else {
                var options = grids(count) + [columns(count), rows(count)]
                if count >= 3 { options.append(mainAndSide(count, ratio: ratio, portrait: shape == .portrait)) }
                candidates = ranked(options, in: area)
            }
        }

        let planned = candidates.map { units in units.map { applyGap(area.part($0), in: area, gap: gap) } }
        let fitting = planned.first { frames in
            frames.indices.allSatisfy { index in
                guard index < minimumSizes.count, let minimum = minimumSizes[index] else { return true }
                return frames[index].width + 1 >= minimum.width && frames[index].height + 1 >= minimum.height
            }
        }
        return fitting ?? planned[0]
    }

    // MARK: Shapes

    static func columns(_ n: Int) -> [UnitRect] {
        (0..<n).map { UnitRect(x: CGFloat($0) / CGFloat(n), y: 0, width: 1 / CGFloat(n), height: 1) }
    }

    static func rows(_ n: Int) -> [UnitRect] {
        (0..<n).map { UnitRect(x: 0, y: CGFloat($0) / CGFloat(n), width: 1, height: 1 / CGFloat(n)) }
    }

    /// Main window on the left (or top, on a portrait screen); the rest share the other part.
    static func mainAndSide(_ n: Int, ratio: CGFloat, portrait: Bool) -> [UnitRect] {
        guard n > 1 else { return [.full] }
        var units = [UnitRect(x: 0, y: 0, width: ratio, height: 1)]
        let others = n - 1
        for index in 0..<others {
            units.append(UnitRect(
                x: ratio,
                y: CGFloat(index) / CGFloat(others),
                width: 1 - ratio,
                height: 1 / CGFloat(others)
            ))
        }
        return portrait ? units.map(\.transposed) : units
    }

    /// Every grid with `columns` cells per row. The last row's windows widen to fill it, so there are no holes.
    static func grid(_ n: Int, columns: Int) -> [UnitRect] {
        let rowCount = Int((Double(n) / Double(columns)).rounded(.up))
        var units: [UnitRect] = []
        for row in 0..<rowCount {
            let inRow = row == rowCount - 1 ? n - columns * (rowCount - 1) : columns
            for col in 0..<inRow {
                units.append(UnitRect(
                    x: CGFloat(col) / CGFloat(inRow),
                    y: CGFloat(row) / CGFloat(rowCount),
                    width: 1 / CGFloat(inRow),
                    height: 1 / CGFloat(rowCount)
                ))
            }
        }
        return units
    }

    static func grids(_ n: Int) -> [[UnitRect]] {
        (1...n).map { grid(n, columns: $0) }
    }

    // MARK: Scoring

    /// Lower is better: how far the cells are from a comfortable window shape.
    /// The worst cell counts extra, so no window gets a silly strip.
    static func score(_ units: [UnitRect], in area: CGRect) -> CGFloat {
        let ideal = log(idealAspect)
        var costs: [CGFloat] = []
        var heights = Set<Int>()
        var widths = Set<Int>()
        for unit in units {
            let w = unit.width * area.width
            let h = unit.height * area.height
            costs.append(abs(log(max(w, 1) / max(h, 1)) - ideal))
            heights.insert(Int((unit.height * 1000).rounded()))
            widths.insert(Int((unit.width * 1000).rounded()))
        }
        let mean = costs.reduce(0, +) / CGFloat(costs.count)
        // A grid whose last row is shorter (equal heights, mixed widths) costs a little more.
        let uneven: CGFloat = widths.count > 1 && heights.count == 1 ? 0.15 : 0
        return 0.7 * mean + 0.3 * (costs.max() ?? 0) + uneven
    }

    static func ranked(_ options: [[UnitRect]], in area: CGRect) -> [[UnitRect]] {
        options.enumerated()
            .sorted { lhs, rhs in
                let a = score(lhs.element, in: area)
                let b = score(rhs.element, in: area)
                return abs(a - b) > 0.0001 ? a < b : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    // MARK: Space left by snapped windows

    /// The part of `visible` left for tiling after windows snapped by hand.
    ///
    /// A snapped window that fills the full height (like Left Half) cuts off its side;
    /// one that fills the full width (like Top Half) cuts off its top or bottom.
    /// Other snapped windows just float above the tiles.
    public static func freeArea(_ visible: CGRect, excluding pinned: [CGRect], tolerance: CGFloat = 2) -> CGRect {
        var area = visible
        for rect in pinned {
            let overlap = area.intersection(rect)
            guard !overlap.isNull, overlap.width > 1, overlap.height > 1 else { continue }
            let fullHeight = overlap.minY <= area.minY + tolerance && overlap.maxY >= area.maxY - tolerance
            let fullWidth = overlap.minX <= area.minX + tolerance && overlap.maxX >= area.maxX - tolerance
            if fullHeight && fullWidth { continue }   // Covers everything: tile underneath as usual.
            var pieces: [CGRect] = []
            if fullHeight {
                pieces = [
                    CGRect(x: area.minX, y: area.minY, width: overlap.minX - area.minX, height: area.height),
                    CGRect(x: overlap.maxX, y: area.minY, width: area.maxX - overlap.maxX, height: area.height),
                ]
            } else if fullWidth {
                pieces = [
                    CGRect(x: area.minX, y: area.minY, width: area.width, height: overlap.minY - area.minY),
                    CGRect(x: area.minX, y: overlap.maxY, width: area.width, height: area.maxY - overlap.maxY),
                ]
            }
            guard let best = pieces.max(by: { $0.width * $0.height < $1.width * $1.height }) else { continue }
            // Too thin to hold windows: tile underneath instead.
            if best.width >= visible.width * 0.2, best.height >= visible.height * 0.2 {
                area = best
            }
        }
        return area
    }
}

/// Keeps the order of tiled windows stable as windows come and go.
public enum TileOrder {
    /// Known windows keep their place. Missing ones drop out. New ones join at the end.
    public static func reconcile<ID: Hashable>(_ order: [ID], present: [ID]) -> [ID] {
        let presentSet = Set(present)
        var result = order.filter { presentSet.contains($0) }
        var seen = Set(result)
        for id in present where !seen.contains(id) {
            result.append(id)
            seen.insert(id)
        }
        return result
    }

    /// Moves `id` to the front (the main slot). If it is already there, swaps it with the second window.
    public static func promote<ID: Hashable>(_ id: ID, in order: [ID]) -> [ID] {
        guard let index = order.firstIndex(of: id) else { return order }
        var result = order
        if index == 0 {
            if result.count > 1 { result.swapAt(0, 1) }
        } else {
            result.swapAt(0, index)
        }
        return result
    }

    public static func swap<ID: Hashable>(_ a: ID, _ b: ID, in order: [ID]) -> [ID] {
        guard let i = order.firstIndex(of: a), let j = order.firstIndex(of: b) else { return order }
        var result = order
        result.swapAt(i, j)
        return result
    }
}
