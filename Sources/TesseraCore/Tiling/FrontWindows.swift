import CoreGraphics

/// How many windows sit in front, laid out, on one screen. The others wait just off the
/// screen's edge until you use them.
public enum FrontLimit: Hashable, Sendable {
    /// As many as fit at a comfortable size (see `autoCount`).
    case auto
    case fixed(Int)
    case unlimited

    /// The choices offered in the menu and in Settings.
    public static let choices: [FrontLimit] = [.auto, .fixed(2), .fixed(3), .fixed(4), .fixed(5), .fixed(6), .unlimited]

    /// Saved as a number: 0 is Auto, below 0 is no limit.
    public init(raw: Int) {
        switch raw {
        case 0: self = .auto
        case ..<0: self = .unlimited
        default: self = .fixed(min(raw, 12))
        }
    }

    public var raw: Int {
        switch self {
        case .auto: 0
        case .unlimited: -1
        case .fixed(let count): count
        }
    }

    /// How many windows sit in front on a screen of this size. Nil means no limit.
    public func count(for screen: CGSize) -> Int? {
        switch self {
        case .auto: Self.autoCount(for: screen)
        case .fixed(let count): count
        case .unlimited: nil
        }
    }

    /// One front window for every 600 points along the screen's long side, from 2 to 6.
    /// 13-inch MacBook Air: 2. 14- and 16-inch MacBook Pro, 1920×1080: 3. 27-inch: 4.
    /// 32-inch 6K: 5. Ultrawide: 6.
    public static func autoCount(for screen: CGSize) -> Int {
        let long = max(screen.width, screen.height)
        return min(max(Int((long / 600).rounded()), 2), 6)
    }

    public var title: String {
        switch self {
        case .auto: "Auto"
        case .unlimited: "No Limit"
        case .fixed(let count): "\(count)"
        }
    }
}

/// Which windows sit in front and which wait, on one screen.
///
/// The windows taking part are kept in one list (the tile order). The first `limit` are in front;
/// the rest wait. Every function here only reorders that list, so swapping, "make main" and
/// dragging keep working the way they always have.
public enum FrontWindows {
    /// Splits the windows taking part into the front ones and the waiting ones.
    public static func split<ID>(_ tiled: [ID], limit: Int?) -> (front: [ID], waiting: [ID]) {
        guard let limit else { return (tiled, []) }
        let count = max(limit, 1)
        return (Array(tiled.prefix(count)), Array(tiled.dropFirst(count)))
    }

    /// Brings a waiting window to the front. It takes the spot of the front window used least
    /// lately; that one waits instead. The other front windows keep their spots.
    /// A kept window is never the one to go, unless every front window is kept.
    /// `recency`: a bigger number means used more lately.
    public static func bringForward<ID: Hashable>(
        _ id: ID, in tiled: [ID], limit: Int, kept: Set<ID>, recency: [ID: Int]
    ) -> [ID] {
        let count = max(limit, 1)
        guard let index = tiled.firstIndex(of: id), index >= count else { return tiled }
        let front = Array(tiled.indices.prefix(count))
        let free = front.filter { !kept.contains(tiled[$0]) }
        let used = { (spot: Int) in recency[tiled[spot]] ?? Int.min }
        guard let leaving = (free.isEmpty ? front : free).min(by: { used($0) < used($1) }) else { return tiled }
        var result = tiled
        result.swapAt(index, leaving)
        return result
    }

    /// Front windows left (closed, minimised, hidden, floated or snapped by hand). For each one,
    /// the waiting window used most lately takes its exact spot, so no other front window moves.
    /// The window that left goes to the waiting window's place, so if it comes back it asks for a
    /// spot like any other.
    ///
    /// `order` still holds the windows that left (a window not in it is skipped).
    public static func fillSpots<ID: Hashable>(left gone: [ID], in order: [ID], waiting: [ID], recency: [ID: Int]) -> [ID] {
        var result = order
        var candidates = waiting.filter { !gone.contains($0) && order.contains($0) }
        for id in gone where result.contains(id) {
            guard let next = candidates.max(by: { (recency[$0] ?? Int.min) < (recency[$1] ?? Int.min) }) else { break }
            candidates.removeAll { $0 == next }
            result = TileOrder.swap(id, next, in: result)
        }
        return result
    }

    /// Arranges the windows taking part on one screen:
    /// 1. kept windows are in front;
    /// 2. `wanted` windows (just opened or just used) come to the front, oldest wish first. A
    ///    window brought forward here isn't pushed back by the next one;
    /// 3. the waiting windows line up with the one used most lately first, so it is the next
    ///    to fill a free spot.
    public static func arrange<ID: Hashable>(
        _ tiled: [ID], limit: Int?, kept: Set<ID>, wanted: [ID], recency: [ID: Int]
    ) -> [ID] {
        guard let limit, tiled.count > max(limit, 1) else { return tiled }
        let count = max(limit, 1)
        var result = tiled
        for id in tiled where kept.contains(id) {
            result = bringForward(id, in: result, limit: count, kept: kept, recency: recency)
        }
        var staying = kept
        for id in wanted {
            staying.insert(id)
            result = bringForward(id, in: result, limit: count, kept: staying, recency: recency)
        }
        let waiting = result.dropFirst(count).enumerated().sorted { a, b in
            let ra = recency[a.element] ?? Int.min, rb = recency[b.element] ?? Int.min
            return ra != rb ? ra > rb : a.offset < b.offset
        }.map(\.element)
        return Array(result.prefix(count)) + waiting
    }

    /// Writes `tiled` back into `order`, in the places the windows taking part had. Windows that
    /// don't take part now (on other desktops, floating, snapped by hand) keep their places.
    /// `tiled` must hold the same windows as `order` filtered to them.
    public static func merge<ID: Hashable>(_ tiled: [ID], into order: [ID]) -> [ID] {
        let members = Set(tiled)
        var next = tiled.makeIterator()
        return order.map { members.contains($0) ? (next.next() ?? $0) : $0 }
    }

    /// Where a waiting window waits: just past the bottom corner of its screen, with one point
    /// still on the screen (macOS keeps windows at least partly on screen). Bottom right, or
    /// bottom left if that would reach onto another screen.
    public static func waitingFrame(size: CGSize, screen: CGRect, otherScreens: [CGRect]) -> CGRect {
        let right = CGRect(x: screen.maxX - 1, y: screen.maxY - 1, width: size.width, height: size.height)
        let left = CGRect(x: screen.minX - size.width + 1, y: screen.maxY - 1, width: size.width, height: size.height)
        func overlap(_ rect: CGRect) -> CGFloat {
            otherScreens.reduce(0) { $0 + $1.intersectionArea(rect) }
        }
        return overlap(left) < overlap(right) ? left : right
    }

    /// True if a window at `frame` is waiting off screen: no more than a sliver of it shows.
    public static func isWaiting(_ frame: CGRect, screens: [CGRect]) -> Bool {
        let showing = screens.map { $0.intersection(frame) }.filter { !$0.isNull }
        return !showing.contains { $0.width > 4 && $0.height > 4 }
    }
}
