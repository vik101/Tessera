import Foundation

/// Builds the layout tree for a layout, screen shape and window count.
///
/// Tile 0 is always the primary. The rule of thumb: each new window takes
/// half of the newest space.
public enum LayoutEngine {
    /// The smallest tile we consider usable when deciding how many windows fit.
    public static let usableTileSize = CGSize(width: 320, height: 200)

    public static func tree(layout: LayoutKind, shape: ScreenShape, count: Int, mainSize: MainSize) -> LayoutNode {
        let n = max(1, count)
        if n == 1 { return .leaf(0) }
        let m = mainSize.fraction
        let layout = shape.availableLayouts.contains(layout) ? layout : .rows

        switch shape {
        case .vertical:
            return verticalTree(layout: layout, n: n, m: m, mainSize: mainSize)
        case .ultrawide where layout == .side:
            return ultrawideSide(n: n, m: m)
        default:
            return landscapeTree(layout: layout, n: n, m: m, mainSize: mainSize)
        }
    }

    // MARK: Landscape

    private static func landscapeTree(layout: LayoutKind, n: Int, m: Double, mainSize: MainSize) -> LayoutNode {
        switch layout {
        case .grid:
            switch n {
            case 2:
                return .split(.horizontal, [.leaf(0), .leaf(1)], [m, 1 - m])
            case 3:
                return .split(.horizontal, [.leaf(0), even(.vertical, [1, 2])], [m, 1 - m])
            default:
                // 2×2. The primary keeps the top of its column; the fourth takes the bottom.
                return .split(
                    .horizontal,
                    [even(.vertical, [0, 3]), even(.vertical, [1, 2])],
                    [m, 1 - m]
                )
            }
        case .columns:
            return line(.horizontal, n: n, mainSize: mainSize)
        case .rows:
            return line(.vertical, n: n, mainSize: mainSize)
        case .side:
            return .split(.horizontal, [.leaf(0), even(.vertical, Array(1..<n))], [m, 1 - m])
        }
    }

    // MARK: Ultrawide

    /// Two large windows, the rest in a narrow column on the right (about a quarter).
    private static func ultrawideSide(n: Int, m: Double) -> LayoutNode {
        if n == 2 {
            return .split(.horizontal, [.leaf(0), .leaf(1)], [m, 1 - m])
        }
        let wide = 0.75
        return .split(
            .horizontal,
            [.leaf(0), .leaf(1), even(.vertical, Array(2..<n))],
            [wide * m, wide * (1 - m), 1 - wide]
        )
    }

    // MARK: Vertical

    private static func verticalTree(layout: LayoutKind, n: Int, m: Double, mainSize: MainSize) -> LayoutNode {
        switch layout {
        case .grid:
            switch n {
            case 2:
                return .split(.vertical, [.leaf(0), .leaf(1)], [m, 1 - m])
            case 3:
                return .split(.vertical, [.leaf(0), even(.horizontal, [1, 2])], [m, 1 - m])
            default:
                return .split(.vertical, [even(.horizontal, [0, 1]), even(.horizontal, [3, 2])], [m, 1 - m])
            }
        case .side:
            // Main on top; the others share the bottom.
            let others = Array(1..<n)
            let bottom: LayoutNode
            if others.count == 1 {
                bottom = .leaf(others[0])
            } else if others.count <= 2 {
                bottom = even(.horizontal, others)
            } else {
                let firstRow = Array(others.prefix((others.count + 1) / 2))
                let secondRow = Array(others.dropFirst(firstRow.count))
                bottom = .split(.vertical, [even(.horizontal, firstRow), even(.horizontal, secondRow)], [0.5, 0.5])
            }
            return .split(.vertical, [.leaf(0), bottom], [m, 1 - m])
        case .rows, .columns:
            return line(.vertical, n: n, mainSize: mainSize)
        }
    }

    // MARK: Helpers

    /// A single row or column. With Half, every window gets an equal share;
    /// otherwise the first gets the main size and the rest share what is left.
    private static func line(_ axis: SplitAxis, n: Int, mainSize: MainSize) -> LayoutNode {
        let leaves = (0..<n).map { LayoutNode.leaf($0) }
        if mainSize == .half {
            return .split(axis, leaves, Array(repeating: 1, count: n))
        }
        let m = mainSize.fraction
        let rest = (1 - m) / Double(n - 1)
        return .split(axis, leaves, [m] + Array(repeating: rest, count: n - 1))
    }

    private static func even(_ axis: SplitAxis, _ indices: [Int]) -> LayoutNode {
        if indices.count == 1 { return .leaf(indices[0]) }
        return .split(axis, indices.map { .leaf($0) }, Array(repeating: 1, count: indices.count))
    }

    // MARK: Capacity

    /// How many windows a layout can really hold in `area`, up to `requested`.
    public static func effectiveCapacity(
        layout: LayoutKind,
        shape: ScreenShape,
        requested: Int,
        area: CGRect,
        gap: Double,
        mainSize: MainSize
    ) -> Int {
        let upper = min(max(1, requested), shape.maxCapacity(for: layout))
        for n in stride(from: upper, through: 1, by: -1) {
            let node = tree(layout: layout, shape: shape, count: n, mainSize: mainSize)
            let solver = LayoutSolver(gap: gap, defaultMinimum: usableTileSize)
            if case .success = solver.solve(node, in: area) { return n }
        }
        return 1
    }

    /// The counts (1…5) a screen can offer for a layout, and the largest that fits.
    public static func allowedCounts(layout: LayoutKind, shape: ScreenShape, area: CGRect, gap: Double, mainSize: MainSize) -> [Int: Bool] {
        var result: [Int: Bool] = [:]
        let maxForShape = shape.maxCapacity(for: layout)
        for n in 1...5 {
            if n > maxForShape {
                result[n] = false
                continue
            }
            result[n] = effectiveCapacity(layout: layout, shape: shape, requested: n, area: area, gap: gap, mainSize: mainSize) == n
        }
        return result
    }

    /// A key that scopes user-dragged sizes to one layout, shape and count.
    public static func sizeKey(layout: LayoutKind, shape: ScreenShape, count: Int) -> String {
        "\(layout.rawValue)-\(shape.rawValue)-\(count)"
    }
}
