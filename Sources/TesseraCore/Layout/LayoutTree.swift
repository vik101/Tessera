import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Direction a split lays its children out in.
/// Coordinates follow the Accessibility API: origin top-left, y grows downward.
public enum SplitAxis: String, Codable, Sendable {
    /// Children sit left to right.
    case horizontal
    /// Children sit top to bottom.
    case vertical
}

/// A layout is a small tree. Leaves are tile positions (0 is the primary).
/// Splits divide their space between children by weight.
public indirect enum LayoutNode: Equatable, Sendable {
    case leaf(Int)
    case split(SplitAxis, [LayoutNode], [Double])

    /// Tile positions in this subtree, in tree order.
    public var leaves: [Int] {
        switch self {
        case .leaf(let index): [index]
        case .split(_, let children, _): children.flatMap(\.leaves)
        }
    }

    public func contains(leaf: Int) -> Bool { leaves.contains(leaf) }
}

/// Why a layout could not be solved.
public enum LayoutFailure: Error, Equatable, Sendable {
    /// These tiles cannot all fit at their minimum sizes.
    case doesNotFit(tiles: [Int])
}

/// Turns a layout tree into frames, honouring user-dragged sizes and app minimum sizes.
public struct LayoutSolver: Sendable {
    /// Space between tiles, in points.
    public var gap: Double
    /// User-adjusted weights, keyed by split path ("r", "r.1", …).
    public var overrides: [String: [Double]]
    /// Known minimum sizes per tile position (learned from stubborn apps).
    public var minimumSizes: [Int: CGSize]
    /// The smallest size any tile may be squeezed to.
    public var defaultMinimum: CGSize

    public init(
        gap: Double = 8,
        overrides: [String: [Double]] = [:],
        minimumSizes: [Int: CGSize] = [:],
        defaultMinimum: CGSize = CGSize(width: 120, height: 80)
    ) {
        self.gap = gap
        self.overrides = overrides
        self.minimumSizes = minimumSizes
        self.defaultMinimum = defaultMinimum
    }

    public static let rootPath = "r"

    public static func childPath(_ parent: String, _ index: Int) -> String { "\(parent).\(index)" }

    // MARK: Solving

    /// Frames for every tile, or the tiles that cannot fit together.
    public func solve(_ node: LayoutNode, in rect: CGRect) -> Result<[Int: CGRect], LayoutFailure> {
        var frames: [Int: CGRect] = [:]
        if let failure = place(node, in: rect, path: Self.rootPath, into: &frames) {
            return .failure(failure)
        }
        return .success(frames)
    }

    private func place(_ node: LayoutNode, in rect: CGRect, path: String, into frames: inout [Int: CGRect]) -> LayoutFailure? {
        switch node {
        case .leaf(let index):
            frames[index] = rect.integralized
            return nil

        case .split(let axis, let children, let baseWeights):
            let lengths: [Double]
            switch distribute(node: node, axis: axis, children: children, baseWeights: baseWeights, rect: rect, path: path) {
            case .success(let value): lengths = value
            case .failure(let failure): return failure
            }
            var cursor = axis == .horizontal ? rect.minX : rect.minY
            for (index, child) in children.enumerated() {
                let length = lengths[index]
                let childRect: CGRect
                switch axis {
                case .horizontal:
                    childRect = CGRect(x: cursor, y: rect.minY, width: length, height: rect.height)
                case .vertical:
                    childRect = CGRect(x: rect.minX, y: cursor, width: rect.width, height: length)
                }
                if let failure = place(child, in: childRect, path: Self.childPath(path, index), into: &frames) {
                    return failure
                }
                cursor += length + gap
            }
            return nil
        }
    }

    /// Lengths of each child along the split axis.
    private func distribute(
        node: LayoutNode,
        axis: SplitAxis,
        children: [LayoutNode],
        baseWeights: [Double],
        rect: CGRect,
        path: String
    ) -> Result<[Double], LayoutFailure> {
        let total = (axis == .horizontal ? rect.width : rect.height) - gap * Double(children.count - 1)
        let weights = effectiveWeights(path: path, base: baseWeights)
        let mins = children.map { minimum(of: $0, along: axis) }
        // Children must also fit across the split.
        for child in children where minimum(of: child, along: axis.other) > (axis == .horizontal ? rect.height : rect.width) + 0.5 {
            return .failure(.doesNotFit(tiles: culprits(in: child)))
        }
        guard let lengths = Self.waterFill(total: total, weights: weights, minimums: mins) else {
            return .failure(.doesNotFit(tiles: culprits(in: node)))
        }
        return .success(lengths)
    }

    func effectiveWeights(path: String, base: [Double]) -> [Double] {
        if let custom = overrides[path], custom.count == base.count, custom.allSatisfy({ $0 > 0 }) {
            return custom
        }
        return base
    }

    /// Tiles in a subtree that carry an explicit (learned) minimum. If none do, all of them.
    private func culprits(in node: LayoutNode) -> [Int] {
        let leaves = node.leaves
        let explicit = leaves.filter { minimumSizes[$0] != nil }
        return explicit.isEmpty ? leaves : explicit
    }

    /// The smallest a subtree can be along an axis.
    public func minimum(of node: LayoutNode, along axis: SplitAxis) -> Double {
        switch node {
        case .leaf(let index):
            let explicit = minimumSizes[index]
            switch axis {
            case .horizontal: return max(defaultMinimum.width, explicit?.width ?? 0)
            case .vertical: return max(defaultMinimum.height, explicit?.height ?? 0)
            }
        case .split(let splitAxis, let children, _):
            let values = children.map { minimum(of: $0, along: axis) }
            if splitAxis == axis {
                return values.reduce(0, +) + gap * Double(children.count - 1)
            }
            return values.max() ?? 0
        }
    }

    /// Splits `total` by weight while giving every child at least its minimum.
    /// Returns nil when the minimums alone do not fit.
    public static func waterFill(total: Double, weights: [Double], minimums: [Double]) -> [Double]? {
        precondition(weights.count == minimums.count)
        if minimums.reduce(0, +) > total + 0.5 { return nil }
        var result = Array(repeating: 0.0, count: weights.count)
        var fixed = Array(repeating: false, count: weights.count)
        while true {
            let used = zip(result, fixed).filter(\.1).map(\.0).reduce(0, +)
            let remaining = total - used
            let freeWeight = zip(weights, fixed).filter { !$0.1 }.map(\.0).reduce(0, +)
            var changed = false
            for index in result.indices where !fixed[index] {
                let share = freeWeight > 0 ? weights[index] / freeWeight : 1.0 / Double(fixed.filter { !$0 }.count)
                result[index] = remaining * share
            }
            for index in result.indices where !fixed[index] && result[index] < minimums[index] - 0.01 {
                result[index] = minimums[index]
                fixed[index] = true
                changed = true
            }
            if !changed { return result }
        }
    }

    // MARK: Resizing

    /// Weights after the user dragged one tile's edges to `newFrame`.
    public func overridesAfterDrag(
        tile: Int,
        to newFrame: CGRect,
        tree: LayoutNode,
        in rect: CGRect
    ) -> [String: [Double]] {
        var result = overrides
        adjustForDrag(node: tree, rect: rect, path: Self.rootPath, tile: tile, newFrame: newFrame, overrides: &result)
        return result
    }

    private func adjustForDrag(
        node: LayoutNode,
        rect: CGRect,
        path: String,
        tile: Int,
        newFrame: CGRect,
        overrides: inout [String: [Double]]
    ) {
        guard case .split(let axis, let children, let baseWeights) = node,
              let childIndex = children.firstIndex(where: { $0.contains(leaf: tile) }),
              case .success(var lengths) = distribute(node: node, axis: axis, children: children, baseWeights: baseWeights, rect: rect, path: path)
        else { return }

        let start = axis == .horizontal ? rect.minX : rect.minY
        var edges: [(min: Double, max: Double)] = []
        var cursor = start
        for length in lengths {
            edges.append((cursor, cursor + length))
            cursor += length + gap
        }
        let newMin = axis == .horizontal ? newFrame.minX : newFrame.minY
        let newMax = axis == .horizontal ? newFrame.maxX : newFrame.maxY
        let mins = children.map { minimum(of: $0, along: axis) }

        var changed = false
        if childIndex > 0 {
            let delta = newMin - edges[childIndex].min
            if abs(delta) > 1 {
                let applied = Self.clampTransfer(delta: delta, grow: childIndex - 1, shrink: childIndex, lengths: lengths, mins: mins)
                lengths[childIndex - 1] += applied
                lengths[childIndex] -= applied
                changed = changed || abs(applied) > 0.5
            }
        }
        if childIndex < children.count - 1 {
            let delta = newMax - edges[childIndex].max
            if abs(delta) > 1 {
                let applied = Self.clampTransfer(delta: delta, grow: childIndex, shrink: childIndex + 1, lengths: lengths, mins: mins)
                lengths[childIndex] += applied
                lengths[childIndex + 1] -= applied
                changed = changed || abs(applied) > 0.5
            }
        }
        if changed {
            let sum = lengths.reduce(0, +)
            overrides[path] = lengths.map { $0 / sum }
        }

        // Recurse into the child with its updated rect.
        var childStart = start
        for index in 0..<childIndex { childStart += lengths[index] + gap }
        let childRect: CGRect = axis == .horizontal
            ? CGRect(x: childStart, y: rect.minY, width: lengths[childIndex], height: rect.height)
            : CGRect(x: rect.minX, y: childStart, width: rect.width, height: lengths[childIndex])
        let nested = LayoutSolver(gap: gap, overrides: overrides, minimumSizes: minimumSizes, defaultMinimum: defaultMinimum)
        nested.adjustForDrag(
            node: children[childIndex],
            rect: childRect,
            path: Self.childPath(path, childIndex),
            tile: tile,
            newFrame: newFrame,
            overrides: &overrides
        )
    }

    /// Moves `delta` points from `shrink` to `grow` (negative delta reverses), within minimums.
    static func clampTransfer(delta: Double, grow: Int, shrink: Int, lengths: [Double], mins: [Double]) -> Double {
        if delta >= 0 {
            return min(delta, max(0, lengths[shrink] - mins[shrink]))
        }
        return -min(-delta, max(0, lengths[grow] - mins[grow]))
    }

    /// Result of a keyboard grow or shrink.
    public struct StepResult: Sendable, Equatable {
        public var overrides: [String: [Double]]
        public var changed: Bool
    }

    /// Grows (positive) or shrinks (negative) a tile by `step` points along every split it belongs to.
    public func overridesAfterStep(tile: Int, step: Double, tree: LayoutNode, in rect: CGRect) -> StepResult {
        var result = overrides
        var changed = false
        applyStep(node: tree, rect: rect, path: Self.rootPath, tile: tile, amount: step, overrides: &result, changed: &changed)
        return StepResult(overrides: result, changed: changed)
    }

    private func applyStep(
        node: LayoutNode,
        rect: CGRect,
        path: String,
        tile: Int,
        amount: Double,
        overrides: inout [String: [Double]],
        changed: inout Bool
    ) {
        guard case .split(let axis, let children, let baseWeights) = node,
              let childIndex = children.firstIndex(where: { $0.contains(leaf: tile) })
        else { return }
        let current = LayoutSolver(gap: gap, overrides: overrides, minimumSizes: minimumSizes, defaultMinimum: defaultMinimum)
        guard case .success(var lengths) = current.distribute(node: node, axis: axis, children: children, baseWeights: baseWeights, rect: rect, path: path)
        else { return }
        let mins = children.map { minimum(of: $0, along: axis) }

        let others = children.indices.filter { $0 != childIndex }
        if !others.isEmpty {
            if amount > 0 {
                let spare = others.map { max(0, lengths[$0] - mins[$0]) }
                let available = spare.reduce(0, +)
                let take = min(amount, available)
                if take > 0.5 {
                    for (offset, index) in others.enumerated() {
                        lengths[index] -= take * (spare[offset] / available)
                    }
                    lengths[childIndex] += take
                    changed = true
                }
            } else {
                let give = min(-amount, max(0, lengths[childIndex] - mins[childIndex]))
                if give > 0.5 {
                    let share = give / Double(others.count)
                    for index in others { lengths[index] += share }
                    lengths[childIndex] -= give
                    changed = true
                }
            }
            let sum = lengths.reduce(0, +)
            overrides[path] = lengths.map { $0 / sum }
        }

        var childStart = axis == .horizontal ? rect.minX : rect.minY
        for index in 0..<childIndex { childStart += lengths[index] + gap }
        let childRect: CGRect = axis == .horizontal
            ? CGRect(x: childStart, y: rect.minY, width: lengths[childIndex], height: rect.height)
            : CGRect(x: rect.minX, y: childStart, width: rect.width, height: lengths[childIndex])
        applyStep(node: children[childIndex], rect: childRect, path: Self.childPath(path, childIndex), tile: tile, amount: amount, overrides: &overrides, changed: &changed)
    }
}

extension SplitAxis {
    var other: SplitAxis { self == .horizontal ? .vertical : .horizontal }
}

extension CGRect {
    /// Rounds edges to whole points so neighbouring tiles never overlap by a fraction.
    var integralized: CGRect {
        let x0 = minX.rounded(), y0 = minY.rounded()
        let x1 = maxX.rounded(), y1 = maxY.rounded()
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
