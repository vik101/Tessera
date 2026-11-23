import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Rectangle's actions that move every window on a screen at once.
public enum ArrangeAction: String, CaseIterable, Codable, Sendable {
    case tileAll, tileRows, tileColumns, cascadeAll, cascadeApp, reverseAll, nextInStack, previousInStack

    public var title: String {
        switch self {
        case .tileAll: "Tile All"
        case .tileRows: "Tile in Rows"
        case .tileColumns: "Tile in Columns"
        case .cascadeAll: "Cascade All"
        case .cascadeApp: "Cascade This App"
        case .reverseAll: "Reverse All"
        case .nextInStack: "Next Stacked Window"
        case .previousInStack: "Previous Stacked Window"
        }
    }

    /// The name in Rectangle's (and Tessera's) URLs.
    public var urlName: String {
        switch self {
        case .tileAll: "tile-all"
        case .tileRows: "tile-rows"
        case .tileColumns: "tile-columns"
        case .cascadeAll: "cascade-all"
        case .cascadeApp: "cascade-active-app"
        case .reverseAll: "reverse-all"
        case .nextInStack: "cycle-stacked-windows"
        case .previousInStack: "cycle-stacked-windows-backward"
        }
    }

    public init?(urlName: String) {
        if let action = ArrangeAction(rawValue: urlName) {
            self = action
            return
        }
        guard let action = ArrangeAction.allCases.first(where: { $0.urlName == urlName.lowercased() }) else { return nil }
        self = action
    }
}

/// The maths for arranging many windows. Pure, no AppKit.
public enum Arrange {
    /// Even rows, each split evenly. `perRow[i]` windows go in row i. Edges meet exactly; `gap` sits between and around.
    public static func bands(_ perRow: [Int], in area: CGRect, gap: CGFloat) -> [CGRect] {
        let inner = area.insetBy(dx: gap, dy: gap)
        let rows = perRow.filter { $0 > 0 }
        guard !rows.isEmpty else { return [] }
        let rowHeight = (inner.height - gap * CGFloat(rows.count - 1)) / CGFloat(rows.count)
        var frames: [CGRect] = []
        for (r, count) in rows.enumerated() {
            let top = (inner.minY + CGFloat(r) * (rowHeight + gap)).rounded()
            let bottom = (inner.minY + CGFloat(r) * (rowHeight + gap) + rowHeight).rounded()
            let width = (inner.width - gap * CGFloat(count - 1)) / CGFloat(count)
            for c in 0..<count {
                let left = (inner.minX + CGFloat(c) * (width + gap)).rounded()
                let right = (inner.minX + CGFloat(c) * (width + gap) + width).rounded()
                frames.append(CGRect(x: left, y: top, width: right - left, height: bottom - top))
            }
        }
        return frames
    }

    /// How many windows go in each of `lines` lines, as evenly as possible, bigger lines last.
    public static func spread(_ count: Int, over lines: Int) -> [Int] {
        guard count > 0, lines > 0 else { return [] }
        let lines = min(lines, count)
        let base = count / lines
        let extra = count % lines
        return (0..<lines).map { $0 >= lines - extra ? base + 1 : base }
    }

    /// Tile All: a near-square grid with no empty cells (the last row has fewer, wider windows).
    public static func tileAll(_ count: Int, in area: CGRect, gap: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        let columns = Int(ceil(sqrt(Double(count))))
        let rows = Int(ceil(Double(count) / Double(columns)))
        var perRow = Array(repeating: columns, count: rows)
        perRow[rows - 1] = count - columns * (rows - 1)
        return bands(perRow, in: area, gap: gap)
    }

    /// Tile in Rows: up to `maxLines` rows, one above another; more windows share rows side by side.
    public static func rows(_ count: Int, in area: CGRect, gap: CGFloat, maxLines: Int = 3) -> [CGRect] {
        bands(Array(spread(count, over: maxLines).reversed()), in: area, gap: gap)
    }

    /// Tile in Columns: up to `maxLines` columns side by side; more windows stack within columns.
    public static func columns(_ count: Int, in area: CGRect, gap: CGFloat, maxLines: Int = 3) -> [CGRect] {
        let flipped = CGRect(x: area.minY, y: area.minX, width: area.height, height: area.width)
        return bands(Array(spread(count, over: maxLines).reversed()), in: flipped, gap: gap)
            .map { CGRect(x: $0.minY, y: $0.minX, width: $0.height, height: $0.width) }
            .sorted { ($0.minX, $0.minY) < ($1.minX, $1.minY) }
    }

    /// Cascade: each window down and right of the one before, by `step`. Sizes shrink only to fit.
    public static func cascade(_ sizes: [CGSize], in area: CGRect, step: CGFloat = 30) -> [CGRect] {
        let room = CGSize(width: area.width - step * CGFloat(max(sizes.count - 1, 0)),
                          height: area.height - step * CGFloat(max(sizes.count - 1, 0)))
        return sizes.enumerated().map { i, size in
            CGRect(x: area.minX + step * CGFloat(i), y: area.minY + step * CGFloat(i),
                   width: min(size.width, max(room.width, area.width / 2)),
                   height: min(size.height, max(room.height, area.height / 2)))
        }
    }

    /// Reverse All: the window's mirror image, left to right, across the screen.
    public static func reversed(_ frame: CGRect, in area: CGRect) -> CGRect {
        CGRect(x: area.minX + area.maxX - frame.maxX, y: frame.minY, width: frame.width, height: frame.height)
    }

    /// The windows stacked with `focused`: those sitting on almost the same spot (corners within `tolerance`),
    /// or cascaded from it by up to `cascade` points. Sorted by ID so presses visit each one in turn.
    public static func stack(of focused: (id: UInt32, frame: CGRect), among windows: [(id: UInt32, frame: CGRect)],
                             tolerance: CGFloat = 24, cascade: CGFloat = 40) -> [UInt32] {
        func stacked(_ a: CGRect, _ b: CGRect) -> Bool {
            let sameSize = abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
            let dx = abs(a.minX - b.minX), dy = abs(a.minY - b.minY)
            let samePlace = dx <= tolerance && dy <= tolerance
            let cascaded = sameSize && dx <= cascade * 8 && dy <= cascade * 8 && abs(dx - dy) <= tolerance
            let overlap = a.intersection(b)
            let mostlyCovered = !overlap.isNull && overlap.width * overlap.height >= 0.8 * min(a.width * a.height, b.width * b.height)
            return samePlace || (cascaded && mostlyCovered) || (sameSize && mostlyCovered)
        }
        var ids = windows.filter { $0.id == focused.id || stacked($0.frame, focused.frame) }.map(\.id)
        if !ids.contains(focused.id) { ids.append(focused.id) }
        return ids.sorted()
    }

    /// The next (or previous) window in a stack after `current`.
    public static func step(_ stack: [UInt32], from current: UInt32, forward: Bool) -> UInt32? {
        guard stack.count > 1, let index = stack.firstIndex(of: current) else { return nil }
        return stack[(index + (forward ? 1 : stack.count - 1)) % stack.count]
    }
}
