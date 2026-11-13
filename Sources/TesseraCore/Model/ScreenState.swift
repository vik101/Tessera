import Foundation

/// A window, as the core sees it: just a stable number (the macOS window ID).
public typealias WindowKey = UInt32

/// One tile position on a screen. It holds one window, or a stack of them.
///
/// `windows.last` is the window showing on top. The others wait behind it at the same size.
public struct Tile: Codable, Equatable, Sendable {
    public var windows: [WindowKey]

    public init(_ windows: [WindowKey]) { self.windows = windows }
    public init(_ window: WindowKey) { self.windows = [window] }

    public var showing: WindowKey? { windows.last }
    public var isStack: Bool { windows.count > 1 }

    /// Brings a window in this tile to the top (most recently used).
    public mutating func show(_ window: WindowKey) {
        guard let index = windows.firstIndex(of: window) else { return }
        windows.remove(at: index)
        windows.append(window)
    }

    /// Shows the next window in the stack (cycles forward).
    public mutating func cycleForward() {
        guard windows.count > 1 else { return }
        windows.append(windows.removeFirst())
    }

    /// Shows the previous window in the stack (cycles back).
    public mutating func cycleBackward() {
        guard windows.count > 1 else { return }
        windows.insert(windows.removeLast(), at: 0)
    }
}

/// Everything Tessera knows about one screen in one macOS Space.
public struct ScreenState: Codable, Equatable, Sendable {
    public var layout: LayoutKind
    /// Windows per screen the user asked for (1–5).
    public var capacity: Int
    /// Ordered tiles; index 0 is the primary.
    public var tiles: [Tile]
    /// User-dragged sizes, keyed by `LayoutEngine.sizeKey` then split path.
    public var sizes: [String: [String: [Double]]]

    public init(layout: LayoutKind = .grid, capacity: Int = 3, tiles: [Tile] = [], sizes: [String: [String: [Double]]] = [:]) {
        self.layout = layout
        self.capacity = capacity
        self.tiles = tiles
        self.sizes = sizes
    }

    // MARK: Queries

    public var allWindows: [WindowKey] { tiles.flatMap(\.windows) }
    public var showingWindows: [WindowKey] { tiles.compactMap(\.showing) }

    public func tileIndex(of window: WindowKey) -> Int? {
        tiles.firstIndex { $0.windows.contains(window) }
    }

    public func contains(_ window: WindowKey) -> Bool { tileIndex(of: window) != nil }

    public var isEmpty: Bool { tiles.isEmpty }

    // MARK: Adding

    public enum InsertResult: Equatable, Sendable {
        case tiled(tile: Int)
        case stacked(tile: Int)
        /// No room and the policy is to float.
        case floated
        case alreadyPresent
    }

    /// Adds a new window following the user's placement rules.
    ///
    /// - Parameters:
    ///   - capacity: how many tiles really fit right now (after size checks).
    ///   - activeTile: the tile the user is working in, used for stacking.
    @discardableResult
    public mutating func insert(
        _ window: WindowKey,
        capacity: Int,
        placement: NewWindowPlacement,
        whenFull: WhenScreenFull,
        activeTile: Int?
    ) -> InsertResult {
        if contains(window) { return .alreadyPresent }
        if tiles.count < capacity {
            switch placement {
            case .nextFreeTile:
                tiles.append(Tile(window))
                return .tiled(tile: tiles.count - 1)
            case .mainTile:
                tiles.insert(Tile(window), at: 0)
                return .tiled(tile: 0)
            }
        }
        switch whenFull {
        case .float:
            return .floated
        case .stack:
            guard !tiles.isEmpty else {
                tiles.append(Tile(window))
                return .tiled(tile: 0)
            }
            let target = activeTile.flatMap { tiles.indices.contains($0) ? $0 : nil } ?? tiles.count - 1
            tiles[target].windows.append(window)
            return .stacked(tile: target)
        }
    }

    /// Puts a window on top of a specific tile's stack.
    public mutating func stack(_ window: WindowKey, onto tile: Int) {
        let anchor = tiles.indices.contains(tile) ? tiles[tile].windows.first(where: { $0 != window }) : nil
        remove(window, rebalanceTo: nil)
        guard let anchor, let target = tileIndex(of: anchor) else {
            tiles.append(Tile(window))
            return
        }
        tiles[target].windows.append(window)
    }

    /// Inserts a window as its own tile at a position (used for setups and moves).
    public mutating func insertTile(_ window: WindowKey, at index: Int) {
        remove(window, rebalanceTo: nil)
        tiles.insert(Tile(window), at: min(max(0, index), tiles.count))
    }

    // MARK: Removing

    /// Removes a window. If its tile empties, later tiles move up to fill the space.
    /// Waiting windows in stacks get their own tile again if there is room.
    @discardableResult
    public mutating func remove(_ window: WindowKey, rebalanceTo capacity: Int?) -> Int? {
        guard let index = tileIndex(of: window) else { return nil }
        tiles[index].windows.removeAll { $0 == window }
        if tiles[index].windows.isEmpty {
            tiles.remove(at: index)
        }
        if let capacity { rebalance(capacity: capacity) }
        return index
    }

    // MARK: Capacity

    /// Fits the tiles to a capacity. Lowering it folds the last tile into the one before.
    /// Raising it gives waiting windows their own tile.
    public mutating func rebalance(capacity: Int) {
        let capacity = max(1, capacity)
        while tiles.count > capacity {
            let last = tiles.removeLast()
            // The folded windows wait behind the tile's current window.
            tiles[tiles.count - 1].windows.insert(contentsOf: last.windows, at: 0)
        }
        while tiles.count < capacity {
            // Take the longest-waiting window from the biggest stack.
            guard let donor = tiles.indices.filter({ tiles[$0].isStack }).max(by: { tiles[$0].windows.count < tiles[$1].windows.count })
            else { break }
            let waiting = tiles[donor].windows.removeFirst()
            tiles.append(Tile(waiting))
        }
    }

    // MARK: Rearranging

    /// Swaps the showing windows of two tiles. Stacks stay with their tiles.
    public mutating func swapShowing(_ a: Int, _ b: Int) {
        guard a != b, tiles.indices.contains(a), tiles.indices.contains(b),
              let wa = tiles[a].showing, let wb = tiles[b].showing else { return }
        tiles[a].windows[tiles[a].windows.count - 1] = wb
        tiles[b].windows[tiles[b].windows.count - 1] = wa
    }

    /// Swaps two specific windows, wherever they are in this screen.
    public mutating func swapWindows(_ a: WindowKey, _ b: WindowKey) {
        guard let ta = tileIndex(of: a), let tb = tileIndex(of: b), ta != tb,
              let ia = tiles[ta].windows.firstIndex(of: a),
              let ib = tiles[tb].windows.firstIndex(of: b) else { return }
        tiles[ta].windows[ia] = b
        tiles[tb].windows[ib] = a
    }

    /// Moves a window's tile to the primary position by swapping with the primary.
    public mutating func makePrimary(_ window: WindowKey) {
        guard let index = tileIndex(of: window), index != 0 else { return }
        tiles[index].show(window)
        swapShowing(0, index)
    }

    /// Records which window in a stack is showing.
    public mutating func markShowing(_ window: WindowKey) {
        guard let index = tileIndex(of: window) else { return }
        tiles[index].show(window)
    }

    /// Replaces a window with another in place (used when a window is swapped across screens).
    public mutating func replace(_ old: WindowKey, with new: WindowKey) {
        guard let t = tileIndex(of: old), let i = tiles[t].windows.firstIndex(of: old) else { return }
        tiles[t].windows[i] = new
    }

    // MARK: Sizes

    public func customSizes(layout: LayoutKind, shape: ScreenShape, count: Int) -> [String: [Double]] {
        sizes[LayoutEngine.sizeKey(layout: layout, shape: shape, count: count)] ?? [:]
    }

    public mutating func setCustomSizes(_ value: [String: [Double]], layout: LayoutKind, shape: ScreenShape, count: Int) {
        let key = LayoutEngine.sizeKey(layout: layout, shape: shape, count: count)
        sizes[key] = value.isEmpty ? nil : value
    }

    public func hasCustomSizes(layout: LayoutKind, shape: ScreenShape, count: Int) -> Bool {
        !(customSizes(layout: layout, shape: shape, count: count).isEmpty)
    }

    public mutating func resetSizes() { sizes.removeAll() }

    // MARK: Reconciling

    /// Brings the model in line with the windows that really exist on this screen.
    /// Keeps known windows in place, drops missing ones, and appends new ones in order.
    public mutating func reconcile(present: [WindowKey], capacity: Int, whenFull: WhenScreenFull) -> [WindowKey] {
        let presentSet = Set(present)
        for index in tiles.indices.reversed() {
            tiles[index].windows.removeAll { !presentSet.contains($0) }
            if tiles[index].windows.isEmpty { tiles.remove(at: index) }
        }
        var floated: [WindowKey] = []
        for window in present where !contains(window) {
            let result = insert(window, capacity: capacity, placement: .nextFreeTile, whenFull: whenFull, activeTile: nil)
            if result == .floated { floated.append(window) }
        }
        rebalance(capacity: capacity)
        return floated
    }
}
