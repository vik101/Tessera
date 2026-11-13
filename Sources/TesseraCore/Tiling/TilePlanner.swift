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

    public var next: LayoutStyle { step(1) }
    public var previous: LayoutStyle { step(-1) }

    private func step(_ by: Int) -> LayoutStyle {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + by + all.count) % all.count]
    }
}

/// Works out where each tiled window goes. Pure maths, no AppKit.
///
/// Every window always gets its own slot: auto-tile never hides a window.
///
/// Layouts are built from "lines": rows stacked top to bottom, or columns side by side,
/// each holding some windows. Space is shared out evenly, except that a window an app
/// won't shrink gets at least its minimum size and its neighbours share the rest.
public enum TilePlanner {
    /// The cell shape we aim for in Auto and Grid: a little wider than tall, like most windows.
    static let idealAspect: CGFloat = 4.0 / 3.0

    /// The result of planning one screen.
    public struct Plan: Equatable, Sendable {
        /// One frame per window, in window order.
        public var frames: [CGRect]
        /// False if some window can't get its minimum size in any arrangement.
        public var fits: Bool
    }

    /// One way to arrange windows.
    struct Arrangement: Equatable {
        /// True: lines are rows, stacked top to bottom. False: lines are columns, side by side.
        var rows: Bool
        /// Windows per line, in order.
        var counts: [Int]
        /// Relative line sizes; nil shares equally.
        var weights: [CGFloat]?
    }

    /// Frames for `count` windows in `area`, in window order. The first window is the main one.
    public static func frames(
        count: Int,
        in area: CGRect,
        style: LayoutStyle,
        gap: CGFloat = 0,
        mainRatio: CGFloat = 0.5,
        minimumSizes: [CGSize?] = []
    ) -> [CGRect] {
        plan(count: count, in: area, style: style, gap: gap, mainRatio: mainRatio, minimumSizes: minimumSizes).frames
    }

    /// Plans a screen.
    ///
    /// - Parameter minimumSizes: sizes some windows refuse to go below. Auto picks the best
    ///   arrangement in which every window fits. A style you chose (say Columns) always keeps
    ///   its shape: if the windows can't all fit, neighbours share the overlap and `fits` is false.
    public static func plan(
        count: Int,
        in area: CGRect,
        style: LayoutStyle,
        gap: CGFloat = 0,
        mainRatio: CGFloat = 0.5,
        minimumSizes: [CGSize?] = []
    ) -> Plan {
        guard count > 0, area.width > 0, area.height > 0 else { return Plan(frames: [], fits: true) }
        let shape = ScreenShape.of(area.size)
        let minimums = (0..<count).map { $0 < minimumSizes.count ? minimumSizes[$0] ?? .zero : .zero }

        if style == .auto, count == 1, shape == .ultrawide, minimums[0].width <= area.width * 2 / 3 {
            // One window on a very wide screen: centred, not stretched edge to edge.
            let frame = area.part(UnitRect(x: 1.0 / 6, y: 0, width: 2.0 / 3, height: 1))
            return Plan(frames: [applyGap(frame, in: area, gap: gap)], fits: true)
        }

        var best: (frames: [CGRect], overflow: CGFloat)?
        for arrangement in candidates(count, style: style, shape: shape, area: area, mainRatio: mainRatio) {
            // Auto may move a window that can't shrink to a roomier slot. A chosen style keeps
            // your window order, so the main window stays main and columns stay in order.
            let orders = style == .auto
                ? assignments(arrangement, minimums: minimums, area: area, gap: gap)
                : [Array(0..<count)]
            for order in orders {
                let frames = build(arrangement, order: order, minimums: minimums, in: area, gap: gap)
                let over = overflow(frames, minimums)
                if over == 0 { return Plan(frames: frames, fits: true) }
                if best == nil || over < best!.overflow { best = (frames, over) }
            }
        }
        return Plan(frames: best?.frames ?? [], fits: false)
    }

    // MARK: Candidates

    /// Arrangements for a style, best first.
    static func candidates(_ n: Int, style: LayoutStyle, shape: ScreenShape, area: CGRect, mainRatio: CGFloat) -> [Arrangement] {
        switch style {
        case .columns:
            return [Arrangement(rows: true, counts: [n])]
        case .rows:
            return [Arrangement(rows: false, counts: [n])]
        case .mainAndSide:
            guard n > 1 else { return [Arrangement(rows: true, counts: [1])] }
            let ratio = min(max(mainRatio, 0.2), 0.8)
            return [Arrangement(rows: shape == .portrait, counts: [1, n - 1], weights: [ratio, 1 - ratio])]
        case .grid:
            return ranked(grids(n), in: area)
        case .auto:
            // Every way to split the windows into rows or columns (fewer windows in earlier lines).
            // Above 12 windows that gets slow, so stick to grids.
            let options = n <= 12
                ? partitions(n).flatMap { [Arrangement(rows: true, counts: $0), Arrangement(rows: false, counts: $0)] }
                : grids(n)
            return ranked(options, in: area)
        }
    }

    /// Even grids with `c` windows per row. A shorter row goes first, so its windows get more room.
    static func grids(_ n: Int) -> [Arrangement] {
        (1...n).map { c in
            let lines = Int((Double(n) / Double(c)).rounded(.up))
            let first = n - c * (lines - 1)
            return Arrangement(rows: true, counts: [first] + Array(repeating: c, count: lines - 1))
        }
    }

    /// Ways to write n as a sum of whole numbers in rising order: 4 = 1+1+2 = 2+2 = 1+3 = 4 …
    static func partitions(_ n: Int) -> [[Int]] {
        var result: [[Int]] = []
        func build(_ remaining: Int, _ smallest: Int, _ current: [Int]) {
            if remaining == 0 {
                result.append(current)
                return
            }
            guard smallest <= remaining else { return }
            for part in smallest...remaining {
                build(remaining - part, part, current + [part])
            }
        }
        build(n, 1, [])
        return result
    }

    // MARK: Scoring

    /// Lower is better: how far the cells are from a comfortable window shape.
    /// The worst cell counts extra, so no window gets a silly strip. Mixed line lengths cost a little.
    static func score(_ arrangement: Arrangement, in area: CGRect) -> CGFloat {
        let n = arrangement.counts.reduce(0, +)
        let frames = build(arrangement, order: Array(0..<n), minimums: Array(repeating: .zero, count: n), in: area, gap: 0)
        let ideal = log(idealAspect)
        let costs = frames.map { abs(log(max($0.width, 1) / max($0.height, 1)) - ideal) }
        let mean = costs.reduce(0, +) / CGFloat(costs.count)
        let uneven = CGFloat(Set(arrangement.counts).count - 1) * 0.1
        return 0.7 * mean + 0.3 * (costs.max() ?? 0) + uneven
    }

    static func ranked(_ options: [Arrangement], in area: CGRect) -> [Arrangement] {
        options.map { ($0, score($0, in: area)) }
            .enumerated()
            .sorted { lhs, rhs in
                let a = lhs.element.1
                let b = rhs.element.1
                return abs(a - b) > 0.0001 ? a < b : lhs.offset < rhs.offset
            }
            .map(\.element.0)
    }

    // MARK: Building frames

    /// Which window goes in which slot. First try window order; if some line can't hold its
    /// windows' minimum sizes, also try spreading the demanding windows across lines.
    static func assignments(_ arrangement: Arrangement, minimums: [CGSize], area: CGRect, gap: CGFloat) -> [[Int]] {
        let n = minimums.count
        let identity = Array(0..<n)
        guard minimums.contains(where: { $0 != .zero }) else { return [identity] }
        let length = arrangement.rows ? area.width : area.height
        func demand(_ i: Int) -> CGFloat { (arrangement.rows ? minimums[i].width : minimums[i].height) + 2 * gap }
        var lines = arrangement.counts.map { (free: $0, used: CGFloat(0), windows: [Int]()) }
        for window in identity.sorted(by: { demand($0) > demand($1) }) {
            guard let line = lines.indices.filter({ lines[$0].free > 0 })
                .max(by: { length - lines[$0].used < length - lines[$1].used }) else { break }
            lines[line].free -= 1
            lines[line].used += demand(window)
            lines[line].windows.append(window)
        }
        let spread = lines.flatMap { $0.windows.sorted() }
        return spread == identity ? [identity] : [identity, spread]
    }

    /// Frames for an arrangement, returned in window order. `order[slot]` is the window in that slot.
    static func build(_ arrangement: Arrangement, order: [Int], minimums: [CGSize], in area: CGRect, gap: CGFloat) -> [CGRect] {
        let rows = arrangement.rows
        var lines: [[Int]] = []
        var next = 0
        for count in arrangement.counts {
            lines.append(Array(order[next..<min(next + count, order.count)]))
            next += count
        }
        func need(_ window: Int, across: Bool) -> CGFloat {
            // `across` = along the line; otherwise the line's thickness.
            let size = minimums[window]
            let value = rows == across ? size.width : size.height
            // A window alone on a line loses a full gap on both sides, so allow for two.
            return value > 0 ? value + 2 * gap : 0
        }
        let thickness = waterFill(
            rows ? area.height : area.width,
            needs: lines.map { line in line.map { need($0, across: false) }.max() ?? 0 },
            weights: arrangement.weights ?? Array(repeating: 1, count: lines.count)
        )
        var frames = [CGRect](repeating: .zero, count: order.count)
        var lineStart = rows ? area.minY : area.minX
        for (line, size) in zip(lines, thickness) {
            let lineEnd = lineStart + size
            let lengths = waterFill(
                rows ? area.width : area.height,
                needs: line.map { need($0, across: true) },
                weights: Array(repeating: 1, count: line.count)
            )
            var start = rows ? area.minX : area.minY
            for (window, length) in zip(line, lengths) {
                let end = start + length
                let rect = rows
                    ? CGRect(x: start.rounded(), y: lineStart.rounded(), width: end.rounded() - start.rounded(), height: lineEnd.rounded() - lineStart.rounded())
                    : CGRect(x: lineStart.rounded(), y: start.rounded(), width: lineEnd.rounded() - lineStart.rounded(), height: end.rounded() - start.rounded())
                frames[window] = applyGap(rect, in: area, gap: gap)
                start = end
            }
            lineStart = lineEnd
        }
        return frames
    }

    /// Shares `length` by `weights`, but gives every item at least its need.
    /// If the needs don't fit at all, shares by need, counting each item as needing at least
    /// an equal share, so a window with no known minimum still gets a fair slice.
    static func waterFill(_ length: CGFloat, needs: [CGFloat], weights: [CGFloat]) -> [CGFloat] {
        var sizes = [CGFloat?](repeating: nil, count: needs.count)
        while true {
            let free = sizes.indices.filter { sizes[$0] == nil }
            if free.isEmpty { break }
            let rest = length - sizes.compactMap { $0 }.reduce(0, +)
            let totalWeight = free.map { weights[$0] }.reduce(0, +)
            var changed = false
            for i in free where needs[i] > rest * weights[i] / totalWeight {
                sizes[i] = needs[i]
                changed = true
            }
            if !changed {
                for i in free { sizes[i] = rest * weights[i] / totalWeight }
                break
            }
        }
        let result = sizes.map { $0 ?? 0 }
        if result.reduce(0, +) > length + 0.5 {
            let fair = length / CGFloat(needs.count)
            let claims = needs.map { max($0, fair) }
            let total = claims.reduce(0, +)
            return claims.map { length * $0 / total }
        }
        return result
    }

    /// How badly windows fail to fit their frames (0 = they all fit).
    static func overflow(_ frames: [CGRect], _ minimums: [CGSize]) -> CGFloat {
        zip(frames, minimums).reduce(0) { total, pair in
            let (frame, minimum) = pair
            let wide = max(0, minimum.width - frame.width - 1) * frame.height
            let tall = max(0, minimum.height - frame.height - 1) * frame.width
            return total + wide + tall
        }
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
