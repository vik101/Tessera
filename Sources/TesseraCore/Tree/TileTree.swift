import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Which way a container lays out its children.
public enum Orientation: String, Codable, Sendable, CaseIterable {
    /// Side by side, left to right.
    case horizontal
    /// One above the other, top to bottom.
    case vertical

    public var opposite: Orientation { self == .horizontal ? .vertical : .horizontal }

    /// Left and right are horizontal; up and down are vertical.
    public static func of(_ direction: Direction) -> Orientation {
        direction == .left || direction == .right ? .horizontal : .vertical
    }

    /// The long side of a rectangle: a wide tile splits side by side, a tall one top to bottom.
    public static func along(_ size: CGSize) -> Orientation { size.width >= size.height ? .horizontal : .vertical }

    /// The direction that adds a child after the others (right, or down).
    public var forward: Direction { self == .horizontal ? .right : .down }
    public var backward: Direction { self == .horizontal ? .left : .up }
}

extension Direction {
    /// Right and down point to later children.
    public var isForward: Bool { self == .right || self == .down }

    public var opposite: Direction {
        switch self {
        case .left: .right
        case .right: .left
        case .up: .down
        case .down: .up
        }
    }

    /// Reads left/right/up/down, and the compass names (west/east/north/south).
    public init?(word: String) {
        switch word.lowercased() {
        case "left", "west", "l": self = .left
        case "right", "east", "r": self = .right
        case "up", "north", "top", "u": self = .up
        case "down", "south", "bottom", "d": self = .down
        default: return nil
        }
    }
}

/// How a container shares its space: in tiles, or stacked with a strip of each neighbour showing.
public enum ContainerLayout: String, Codable, Sendable, CaseIterable {
    case tiles
    /// Every child gets the whole container, less a strip (the padding) for each neighbour,
    /// so you can see there are more. AeroSpace's accordion.
    case accordion
}

/// The Tree layout: windows are leaves of a tree of containers, like i3, AeroSpace and bspwm.
///
/// A new window splits the tile it opens next to. Closing a window lets its neighbour grow into
/// the space. Every container lays its children out side by side or one above the other, in
/// tiles or as an accordion, sharing the space by weight.
///
/// The tree stays tidy ("normalised") after every change: a container with one child is replaced
/// by that child, and a container laid out the same way as its parent is merged into it.
/// Pure maths: no AppKit, so every change is unit-tested.
public struct TileTree<ID: Hashable & Sendable>: Equatable, Sendable {
    public enum Node: Equatable, Sendable {
        case window(ID)
        case container(Container)
    }

    public struct Container: Equatable, Sendable {
        public var orientation: Orientation
        public var layout: ContainerLayout
        public var children: [Node]
        /// One per child: its share of the container's length. Only the ratios matter.
        public var weights: [CGFloat]

        public init(orientation: Orientation, layout: ContainerLayout = .tiles, children: [Node] = [], weights: [CGFloat]? = nil) {
            self.orientation = orientation
            self.layout = layout
            self.children = children
            self.weights = weights ?? Array(repeating: 1, count: children.count)
        }
    }

    /// Where a window was, so it can go back there (after being minimised or hidden).
    public struct Hint: Equatable, Sendable {
        /// The window it sat next to.
        public var anchor: ID
        /// Which side of the anchor it was on.
        public var direction: Direction
    }

    public var root: Container

    public init(orientation: Orientation = .horizontal) {
        root = Container(orientation: orientation)
    }

    public init(root: Container) {
        self.root = root
        normalize()
    }

    // MARK: Reading

    /// Every window, in depth-first order (left to right, top to bottom).
    public var windows: [ID] { Self.leaves(of: .container(root)) }

    public var isEmpty: Bool { root.children.isEmpty }
    public var count: Int { windows.count }

    public func contains(_ id: ID) -> Bool { path(of: id) != nil }

    /// The child indexes from the root down to the window.
    public func path(of id: ID) -> [Int]? { Self.path(of: id, in: root) }

    /// The container holding a window.
    public func parent(of id: ID) -> Container? {
        guard let path = path(of: id) else { return nil }
        return container(at: Array(path.dropLast()))
    }

    public func container(at path: [Int]) -> Container {
        var c = root
        for index in path {
            guard c.children.indices.contains(index), case .container(let inner) = c.children[index] else { return c }
            c = inner
        }
        return c
    }

    // MARK: Adding and removing

    /// Adds a window by splitting the tile of `target` in `direction`: the new window takes half of
    /// that tile, on that side. With no target (or one not in the tree) it splits the last window.
    /// The first window fills the whole area, and the root takes `orientation` for the next split.
    public mutating func insert(_ id: ID, splitting target: ID?, direction: Direction, orientation: Orientation? = nil) {
        guard !contains(id) else { return }
        if root.children.isEmpty {
            if let orientation { root.orientation = orientation }
            root.children = [.window(id)]
            root.weights = [1]
            return
        }
        let anchor = target.flatMap { contains($0) ? $0 : nil } ?? windows.last!
        guard let path = path(of: anchor) else { return }
        let parentPath = Array(path.dropLast())
        let index = path.last!
        let axis = Orientation.of(direction)
        let forward = direction.isForward
        withContainer(at: parentPath) { parent in
            if parent.children.count == 1 { parent.orientation = axis }
            if parent.orientation == axis || parent.layout == .accordion {
                // The parent already runs this way: the tile's share is split in two.
                let half = parent.weights[index] / 2
                parent.weights[index] = half
                let at = forward ? index + 1 : index
                parent.children.insert(.window(id), at: at)
                parent.weights.insert(half, at: at)
            } else {
                let pair: [Node] = forward ? [.window(anchor), .window(id)] : [.window(id), .window(anchor)]
                parent.children[index] = .container(Container(orientation: axis, children: pair))
            }
        }
        normalize()
    }

    /// Adds a window back where it was before (see `remove`): beside the branch holding the anchor,
    /// in the nearest container that runs the hint's way. With no such container (the tree changed),
    /// it splits the anchor; with no anchor, it splits `fallback`.
    public mutating func insert(_ id: ID, hint: Hint?, fallback: ID?, direction: Direction) {
        guard !contains(id) else { return }
        guard let hint, let path = path(of: hint.anchor) else {
            insert(id, splitting: fallback, direction: direction)
            return
        }
        let axis = Orientation.of(hint.direction)
        for level in stride(from: path.count - 1, through: 0, by: -1) {
            let containerPath = Array(path[0..<level])
            guard container(at: containerPath).orientation == axis else { continue }
            let index = path[level]
            withContainer(at: containerPath) { c in
                let half = c.weights[index] / 2
                c.weights[index] = half
                let at = hint.direction.isForward ? index + 1 : index
                c.children.insert(.window(id), at: at)
                c.weights.insert(half, at: at)
            }
            normalize()
            return
        }
        insert(id, splitting: hint.anchor, direction: hint.direction)
    }

    /// Takes a window out. Its neighbour grows into the space it leaves.
    /// Returns where it was, so it can be put back in the same place.
    @discardableResult
    public mutating func remove(_ id: ID) -> Hint? {
        guard let path = path(of: id) else { return nil }
        let parentPath = Array(path.dropLast())
        let index = path.last!
        let parent = container(at: parentPath)
        var hint: Hint?
        if index > 0, let anchor = Self.leaves(of: parent.children[index - 1]).last {
            hint = Hint(anchor: anchor, direction: parent.orientation.forward)
        } else if index + 1 < parent.children.count, let anchor = Self.leaves(of: parent.children[index + 1]).first {
            hint = Hint(anchor: anchor, direction: parent.orientation.backward)
        }
        let weight = detach(at: path)
        withContainer(at: parentPath) { parent in
            guard !parent.children.isEmpty else { return }
            let neighbour = index > 0 ? index - 1 : 0
            parent.weights[neighbour] += weight
        }
        normalize()
        return hint
    }

    /// Keeps exactly these windows: the others are removed, and new ones are added in order, each
    /// splitting the window before it in the list (or `target`, if given).
    public mutating func reconcile(_ present: [ID], target: ID?, direction: (ID) -> Direction) {
        let keep = Set(present)
        for id in windows where !keep.contains(id) { remove(id) }
        for id in present where !contains(id) {
            insert(id, splitting: target ?? windows.last, direction: direction(target ?? windows.last ?? id))
        }
    }

    // MARK: Moving windows

    /// Puts `new` in the spot `old` had (for swapping windows between two trees).
    public mutating func replace(_ old: ID, with new: ID) {
        guard old != new, !contains(new), let path = path(of: old) else { return }
        setNode(.window(new), at: path)
    }

    /// Exchanges two windows. Each spot keeps its size, so the layout keeps its shape.
    public mutating func swap(_ a: ID, _ b: ID) {
        guard a != b, let pa = path(of: a), let pb = path(of: b) else { return }
        setNode(.window(b), at: pa)
        setNode(.window(a), at: pb)
    }

    /// Moves a window one step that way through the tree, like i3 and AeroSpace's `move`:
    /// - next to a window in a row that runs that way: they trade places;
    /// - next to a container: the window goes into it, at the near end;
    /// - at the end of its own row: it steps out, next to its row in the parent;
    /// - at the edge of a root that runs the other way: the root is split, and the window gets a side to itself.
    /// Returns false when the window is already as far as it can go (the caller may send it to the next screen).
    @discardableResult
    public mutating func move(_ id: ID, _ direction: Direction) -> Bool {
        guard let path = path(of: id) else { return false }
        let axis = Orientation.of(direction)
        let forward = direction.isForward
        for level in stride(from: path.count - 1, through: 0, by: -1) {
            let containerPath = Array(path[0..<level])
            let childIndex = path[level]
            let c = container(at: containerPath)
            guard c.orientation == axis else { continue }
            let neighbourIndex = forward ? childIndex + 1 : childIndex - 1
            guard c.children.indices.contains(neighbourIndex) else { continue }
            if level == path.count - 1 {
                switch c.children[neighbourIndex] {
                case .window(let other):
                    swap(id, other)
                case .container(let inner):
                    let weight = average(inner.weights)
                    _ = detach(at: path)
                    // Removing the window shifted later siblings back by one.
                    let target = forward ? neighbourIndex - 1 : neighbourIndex
                    let at = inner.orientation == axis ? (forward ? 0 : inner.children.count) : inner.children.count
                    attach(.window(id), weight: weight, into: containerPath + [target], at: at)
                    normalize()
                }
            } else {
                let weight = average(c.weights)
                _ = detach(at: path)
                attach(.window(id), weight: weight, into: containerPath, at: forward ? childIndex + 1 : childIndex)
                normalize()
            }
            return true
        }
        // At the edge of everything that way.
        if root.orientation != axis, root.children.count > 1 {
            _ = detach(at: path)
            normalize()
            let old = Node.container(root)
            root = Container(orientation: axis, children: forward ? [old, .window(id)] : [.window(id), old])
            normalize()
            return true
        }
        if path.count > 1 {
            let weight = average(root.weights)
            _ = detach(at: path)
            attach(.window(id), weight: weight, into: [], at: forward ? root.children.count : 0)
            normalize()
            return true
        }
        return false
    }

    /// Puts a window and its neighbour that way into a new container of their own, running the other
    /// way (AeroSpace's `join-with`). Joining with a container that already runs the other way adds
    /// the window to it. Returns false when there's nothing that way.
    @discardableResult
    public mutating func join(_ id: ID, _ direction: Direction) -> Bool {
        guard let path = path(of: id) else { return false }
        let axis = Orientation.of(direction)
        let forward = direction.isForward
        for level in stride(from: path.count - 1, through: 0, by: -1) {
            let containerPath = Array(path[0..<level])
            let childIndex = path[level]
            let c = container(at: containerPath)
            guard c.orientation == axis, c.layout == .tiles else { continue }
            let neighbourIndex = forward ? childIndex + 1 : childIndex - 1
            guard c.children.indices.contains(neighbourIndex) else { continue }
            let direct = level == path.count - 1
            let weight = detach(at: path)
            var target = neighbourIndex
            if direct && forward { target -= 1 }
            withContainer(at: containerPath) { parent in
                if direct { parent.weights[target] += weight }
                let other = parent.children[target]
                if case .container(var inner) = other, inner.orientation == axis.opposite, inner.layout == .tiles {
                    inner.children.insert(.window(id), at: forward ? 0 : inner.children.count)
                    inner.weights.insert(Self.mean(inner.weights), at: forward ? 0 : inner.weights.count)
                    parent.children[target] = .container(inner)
                } else {
                    let pair: [Node] = forward ? [.window(id), other] : [other, .window(id)]
                    parent.children[target] = .container(Container(orientation: axis.opposite, children: pair))
                }
            }
            normalize()
            return true
        }
        return false
    }

    /// Takes a window out of its container and puts it next to that container, one level up.
    @discardableResult
    public mutating func popOut(_ id: ID) -> Bool {
        guard let path = path(of: id), path.count >= 2 else { return false }
        let grandPath = Array(path.dropLast(2))
        let parentIndex = path[path.count - 2]
        let weight = average(container(at: grandPath).weights)
        _ = detach(at: path)
        attach(.window(id), weight: weight, into: grandPath, at: parentIndex + 1)
        normalize()
        return true
    }

    /// The opposite of `popOut`: joins the window with its next neighbour (or, at the end, the one before).
    @discardableResult
    public mutating func popIn(_ id: ID) -> Bool {
        guard let parent = parent(of: id) else { return false }
        return join(id, parent.orientation.forward) || join(id, parent.orientation.backward)
    }

    // MARK: Changing containers

    /// Sets how the window's container lays out its children. Either part may be left as it is.
    public mutating func setLayout(of id: ID, layout: ContainerLayout?, orientation: Orientation?) {
        guard let path = path(of: id) else { return }
        withContainer(at: Array(path.dropLast())) { parent in
            if let layout { parent.layout = layout }
            if let orientation { parent.orientation = orientation }
        }
        normalize()
    }

    /// Turns the window's container the other way (side by side ↔ one above the other).
    public mutating func toggleOrientation(of id: ID) {
        guard let parent = parent(of: id) else { return }
        setLayout(of: id, layout: nil, orientation: parent.orientation.opposite)
    }

    /// Reverses every container that runs this way: a horizontal mirror swaps left and right.
    public mutating func mirror(_ orientation: Orientation) {
        root = Self.mapContainers(root) { c in
            var c = c
            if c.orientation == orientation {
                c.children.reverse()
                c.weights.reverse()
            }
            return c
        }
    }

    /// Turns the whole layout a quarter turn: clockwise moves the left side to the top.
    public mutating func rotate(clockwise: Bool) {
        root = Self.mapContainers(root) { c in
            var c = c
            let wasHorizontal = c.orientation == .horizontal
            c.orientation = c.orientation.opposite
            // Clockwise: a row keeps its order top to bottom; a column's top goes to the right.
            if wasHorizontal != clockwise {
                c.children.reverse()
                c.weights.reverse()
            }
            return c
        }
        normalize()
    }

    /// Every tile gets an even share again.
    public mutating func balance() {
        root = Self.mapContainers(root) { c in
            var c = c
            c.weights = Array(repeating: 1, count: c.children.count)
            return c
        }
    }

    /// Every window becomes a child of the root, in the same order (AeroSpace's `flatten-workspace-tree`).
    public mutating func flatten() {
        let all = windows
        root = Container(orientation: root.orientation, children: all.map { .window($0) })
    }

    // MARK: Sizes

    /// Grows (or with a negative `delta`, shrinks) a window by `delta` points across `orientation`:
    /// the nearest container running that way gives the window's branch more room, taken from its
    /// siblings in proportion (AeroSpace's `resize`). Returns false when nothing can change.
    @discardableResult
    public mutating func resize(_ id: ID, along orientation: Orientation, by delta: CGFloat, in area: CGRect,
                                gap: CGFloat = 0, minimum: CGFloat = 40) -> Bool {
        guard let path = path(of: id) else { return false }
        let rects = layout(in: area, gap: gap).containers
        for level in stride(from: path.count - 1, through: 0, by: -1) {
            let containerPath = Array(path[0..<level])
            let c = container(at: containerPath)
            guard c.orientation == orientation, c.layout == .tiles, c.children.count > 1,
                  let rect = rects[containerPath] else { continue }
            let index = path[level]
            let length = orientation == .horizontal ? rect.width : rect.height
            let total = c.weights.reduce(0, +)
            guard length > 0, total > 0 else { return false }
            let now = c.weights[index] / total * length
            let others = CGFloat(c.children.count - 1)
            let wanted = min(max(now + delta, minimum), length - minimum * others)
            guard abs(wanted - now) >= 0.5 else { return false }
            let newWeight = wanted / length * total
            let rest = total - c.weights[index]
            withContainer(at: containerPath) { c in
                for i in c.weights.indices where i != index {
                    c.weights[i] = rest > 0 ? c.weights[i] * (total - newWeight) / rest : (total - newWeight) / others
                }
                c.weights[index] = newWeight
            }
            return true
        }
        return false
    }

    /// Moves one edge of a window by `delta` points (positive: the window gets bigger). Only the
    /// neighbour across that edge gives or takes the room, so every other edge stays where it is.
    @discardableResult
    public mutating func moveEdge(_ id: ID, _ edge: Direction, by delta: CGFloat, in area: CGRect,
                                  gap: CGFloat = 0, minimum: CGFloat = 40) -> Bool {
        guard let path = path(of: id) else { return false }
        let axis = Orientation.of(edge)
        let rects = layout(in: area, gap: gap).containers
        for level in stride(from: path.count - 1, through: 0, by: -1) {
            let containerPath = Array(path[0..<level])
            let c = container(at: containerPath)
            let index = path[level]
            let other = edge.isForward ? index + 1 : index - 1
            guard c.orientation == axis, c.layout == .tiles, c.children.indices.contains(other),
                  let rect = rects[containerPath] else { continue }
            let length = axis == .horizontal ? rect.width : rect.height
            let total = c.weights.reduce(0, +)
            guard length > 0, total > 0 else { return false }
            let mine = c.weights[index] / total * length
            let theirs = c.weights[other] / total * length
            let newMine = min(max(mine + delta, minimum), mine + theirs - minimum)
            guard abs(newMine - mine) >= 0.5 else { return false }
            withContainer(at: containerPath) { c in
                c.weights[index] = newMine / length * total
                c.weights[other] = (mine + theirs - newMine) / length * total
            }
            return true
        }
        return false
    }

    // MARK: Frames

    /// Where every window goes in `area`. `gap` is the space between windows (and at the area's
    /// edges, as with the other layouts). `padding` is the strip each accordion neighbour shows.
    /// `minimums` are sizes some windows won't go below: their neighbours share what's left.
    public func frames(in area: CGRect, gap: CGFloat = 0, padding: CGFloat = 30,
                       minimums: [ID: CGSize] = [:]) -> [ID: CGRect] {
        layout(in: area, gap: gap, padding: padding, minimums: minimums).windows
    }

    /// Frames for windows, and the space each container covers (by its path).
    public func layout(in area: CGRect, gap: CGFloat = 0, padding: CGFloat = 30,
                       minimums: [ID: CGSize] = [:]) -> (windows: [ID: CGRect], containers: [[Int]: CGRect]) {
        var windows: [ID: CGRect] = [:]
        var containers: [[Int]: CGRect] = [:]
        func need(_ node: Node, horizontal: Bool) -> CGFloat {
            switch node {
            case .window(let id):
                guard let size = minimums[id] else { return 0 }
                let value = horizontal ? size.width : size.height
                return value > 0 ? value + 2 * gap : 0
            case .container(let c):
                let needs = c.children.map { need($0, horizontal: horizontal) }
                let along = (c.orientation == .horizontal) == horizontal && c.layout == .tiles
                return along ? needs.reduce(0, +) : (needs.max() ?? 0)
            }
        }
        func place(_ c: Container, in rect: CGRect, path: [Int]) {
            containers[path] = rect
            let n = c.children.count
            guard n > 0 else { return }
            let horizontal = c.orientation == .horizontal
            func put(_ node: Node, _ r: CGRect, _ i: Int) {
                switch node {
                case .window(let id): windows[id] = applyGap(r, in: area, gap: gap)
                case .container(let inner): place(inner, in: r, path: path + [i])
                }
            }
            switch c.layout {
            case .tiles:
                let length = horizontal ? rect.width : rect.height
                let total = c.weights.reduce(0, +)
                let weights = total > 0 ? c.weights : Array(repeating: 1, count: n)
                let sizes = TilePlanner.waterFill(length, needs: c.children.map { need($0, horizontal: horizontal) }, weights: weights)
                var start = horizontal ? rect.minX : rect.minY
                for (i, (child, size)) in zip(c.children, sizes).enumerated() {
                    let end = i == n - 1 ? (horizontal ? rect.maxX : rect.maxY) : start + size
                    let r = horizontal
                        ? CGRect(x: start.rounded(), y: rect.minY, width: end.rounded() - start.rounded(), height: rect.height)
                        : CGRect(x: rect.minX, y: start.rounded(), width: rect.width, height: end.rounded() - start.rounded())
                    put(child, r, i)
                    start = end
                }
            case .accordion:
                let length = horizontal ? rect.width : rect.height
                // Never squeeze a window to less than half the container.
                let strip = n > 1 ? min(max(padding, 0), max(0, length / 4)) : 0
                for (i, child) in c.children.enumerated() {
                    let before = i > 0 ? strip : 0
                    let after = i < n - 1 ? strip : 0
                    let r = horizontal
                        ? CGRect(x: rect.minX + before, y: rect.minY, width: rect.width - before - after, height: rect.height)
                        : CGRect(x: rect.minX, y: rect.minY + before, width: rect.width, height: rect.height - before - after)
                    put(child, r.integral, i)
                }
            }
        }
        place(root, in: area, path: [])
        return (windows, containers)
    }

    // MARK: Building from frames

    /// A tree that puts windows exactly where they are now, when the frames can be cut into rows
    /// and columns (every layout Tessera makes can). Switching to the Tree layout uses it, so
    /// nothing moves. Frames that can't be cut that way end up side by side.
    ///
    /// - Parameter area: the space the frames were laid out in, so gaps at the edges don't count
    ///   against the outer tiles. Without it, the frames' own bounds are used.
    public static func fromFrames(_ items: [(id: ID, frame: CGRect)], in area: CGRect? = nil,
                                  orientation fallback: Orientation = .horizontal, tolerance: CGFloat = 4) -> TileTree {
        guard !items.isEmpty else { return TileTree(orientation: fallback) }
        let bounds = items.dropFirst().reduce(items[0].frame) { $0.union($1.frame) }
        func build(_ items: [(id: ID, frame: CGRect)], _ cell: CGRect) -> Node {
            if items.count == 1 { return .window(items[0].id) }
            for axis in [Orientation.horizontal, .vertical] {
                let horizontal = axis == .horizontal
                let sorted = items.sorted {
                    horizontal ? ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY)
                        : ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX)
                }
                var groups: [[(id: ID, frame: CGRect)]] = []
                var current: [(id: ID, frame: CGRect)] = []
                var reach = -CGFloat.infinity
                for item in sorted {
                    let start = horizontal ? item.frame.minX : item.frame.minY
                    let end = horizontal ? item.frame.maxX : item.frame.maxY
                    if !current.isEmpty && start >= reach - tolerance {
                        groups.append(current)
                        current = []
                    }
                    current.append(item)
                    reach = current.count == 1 ? end : max(reach, end)
                }
                groups.append(current)
                guard groups.count >= 2 else { continue }
                // Each group's cell runs from the middle of the gap before it to the middle of the gap after it.
                func low(_ g: [(id: ID, frame: CGRect)]) -> CGFloat { g.map { horizontal ? $0.frame.minX : $0.frame.minY }.min() ?? 0 }
                func high(_ g: [(id: ID, frame: CGRect)]) -> CGFloat { g.map { horizontal ? $0.frame.maxX : $0.frame.maxY }.max() ?? 0 }
                var cuts = [horizontal ? cell.minX : cell.minY]
                for i in 1..<groups.count { cuts.append(((high(groups[i - 1]) + low(groups[i])) / 2).rounded()) }
                cuts.append(horizontal ? cell.maxX : cell.maxY)
                var children: [Node] = []
                var weights: [CGFloat] = []
                for (i, group) in groups.enumerated() {
                    let length = max(cuts[i + 1] - cuts[i], 1)
                    let sub = horizontal
                        ? CGRect(x: cuts[i], y: cell.minY, width: length, height: cell.height)
                        : CGRect(x: cell.minX, y: cuts[i], width: cell.width, height: length)
                    children.append(build(group, sub))
                    weights.append(length)
                }
                return .container(Container(orientation: axis, children: children, weights: weights))
            }
            return .container(Container(orientation: fallback, children: items.map { .window($0.id) }))
        }
        let top = build(items, area ?? bounds)
        switch top {
        case .window(let id): return TileTree(root: Container(orientation: fallback, children: [.window(id)]))
        case .container(let c): return TileTree(root: c)
        }
    }

    // MARK: Tidying

    /// Replaces containers with one child by that child, merges a container into a parent that runs
    /// the same way, and drops empty ones. The root may keep a single window.
    public mutating func normalize() {
        root = Self.normalized(root)
        while root.children.count == 1, case .container(let only) = root.children[0] {
            root = only
        }
    }

    static func normalized(_ c: Container) -> Container {
        var out = Container(orientation: c.orientation, layout: c.layout)
        func absorb(_ node: Node, _ weight: CGFloat) {
            switch node {
            case .window:
                out.children.append(node)
                out.weights.append(weight)
            case .container(let inner):
                let n = normalized(inner)
                if n.children.isEmpty { return }
                if n.children.count == 1 {
                    absorb(n.children[0], weight)
                } else if n.orientation == c.orientation, n.layout == .tiles, c.layout == .tiles {
                    let total = n.weights.reduce(0, +)
                    for (child, w) in zip(n.children, n.weights) {
                        out.children.append(child)
                        out.weights.append(total > 0 ? weight * w / total : weight / CGFloat(n.children.count))
                    }
                } else {
                    out.children.append(.container(n))
                    out.weights.append(weight)
                }
            }
        }
        for (child, weight) in zip(c.children, c.weights) { absorb(child, max(weight, 0.0001)) }
        return out
    }

    // MARK: Helpers

    static func leaves(of node: Node) -> [ID] {
        switch node {
        case .window(let id): return [id]
        case .container(let c): return c.children.flatMap(leaves)
        }
    }

    static func path(of id: ID, in c: Container) -> [Int]? {
        for (i, child) in c.children.enumerated() {
            switch child {
            case .window(let w) where w == id: return [i]
            case .window: continue
            case .container(let inner):
                if let rest = path(of: id, in: inner) { return [i] + rest }
            }
        }
        return nil
    }

    static func mapContainers(_ c: Container, _ transform: (Container) -> Container) -> Container {
        var c = transform(c)
        c.children = c.children.map { child in
            if case .container(let inner) = child { return .container(mapContainers(inner, transform)) }
            return child
        }
        return c
    }

    static func mean(_ values: [CGFloat]) -> CGFloat {
        values.isEmpty ? 1 : values.reduce(0, +) / CGFloat(values.count)
    }

    private func average(_ values: [CGFloat]) -> CGFloat { Self.mean(values) }

    /// Runs `body` on the container at `path` (an empty path is the root).
    mutating func withContainer<T>(at path: [Int], _ body: (inout Container) -> T) -> T {
        Self.edit(&root, path[...], body)
    }

    private static func edit<T>(_ c: inout Container, _ path: ArraySlice<Int>, _ body: (inout Container) -> T) -> T {
        guard let first = path.first else { return body(&c) }
        guard c.children.indices.contains(first), case .container(var inner) = c.children[first] else { return body(&c) }
        let result = edit(&inner, path.dropFirst(), body)
        c.children[first] = .container(inner)
        return result
    }

    private mutating func setNode(_ node: Node, at path: [Int]) {
        guard let index = path.last else { return }
        withContainer(at: Array(path.dropLast())) { parent in
            if parent.children.indices.contains(index) { parent.children[index] = node }
        }
    }

    /// Takes the node at `path` out of its container without tidying. Returns its weight.
    private mutating func detach(at path: [Int]) -> CGFloat {
        guard let index = path.last else { return 0 }
        return withContainer(at: Array(path.dropLast())) { parent -> CGFloat in
            guard parent.children.indices.contains(index) else { return 0 }
            parent.children.remove(at: index)
            return parent.weights.remove(at: index)
        }
    }

    private mutating func attach(_ node: Node, weight: CGFloat, into path: [Int], at index: Int) {
        withContainer(at: path) { c in
            let at = min(max(index, 0), c.children.count)
            c.children.insert(node, at: at)
            c.weights.insert(weight, at: at)
        }
    }
}
