import CoreGraphics

/// How big a tiled window is next to its neighbours: a width share and a height share, where 1
/// is an even share. A window with a share of 1.25 gets a quarter more room than an even share,
/// and its neighbours share what's left.
///
/// Make Larger (⌃⌥=) and Make Smaller (⌃⌥-) change the shares one step at a time. Dragging the
/// edge between two tiles sets them to where you let go. Picking a layout evens them out.
public enum TileSizes {
    public static let even = CGSize(width: 1, height: 1)
    /// Each press of Make Larger or Make Smaller: a share 25% bigger, or smaller.
    public static let step: CGFloat = 1.25
    /// A share stays between a quarter of an even share and four times it.
    public static let range: ClosedRange<CGFloat> = 0.25...4

    /// One press of Make Larger (or Smaller): the window's width and height shares both grow
    /// (or shrink) one step. Nil if it's already as big (or as small) as it can be.
    public static func resized(_ size: CGSize, larger: Bool) -> CGSize? {
        func next(_ value: CGFloat) -> CGFloat {
            let stepped = larger ? value * step : value / step
            let clamped = min(max(stepped, range.lowerBound), range.upperBound)
            return abs(clamped - 1) < 0.001 ? 1 : clamped
        }
        let result = CGSize(width: next(size.width), height: next(size.height))
        return result == size ? nil : result
    }

    /// You dragged an edge of a tile with the mouse. Works out shares that put that edge where you
    /// let go and keep every other edge where it was: the tiles on the other side of the edge give
    /// (or take) the difference. Only the direction you dragged in changes.
    ///
    /// Every tile that ends where the dragged edge was moves with it; every tile that starts just
    /// past it (one gap away) gives way. In a grid that moves the whole line, like a real grid.
    ///
    /// - Parameters:
    ///   - frames: every tile on the screen, as laid out, and `shares` their shares now.
    ///   - index: the tile you resized; `new`: its frame after the drag.
    /// - Returns: new shares, or nil if only the screen's edges moved (nothing can give way there)
    ///   or a tile would get smaller than 60 points.
    public static func afterDrag(
        frames: [CGRect], shares: [CGSize], index: Int, to new: CGRect, area: CGRect, gap: CGFloat
    ) -> [CGSize]? {
        guard frames.indices.contains(index), shares.count == frames.count else { return nil }
        let old = frames[index]
        let gap = max(gap, 0)
        // Work with each tile's whole slot (the frame plus its share of the gaps), so the new
        // shares put the edges exactly where they should be.
        let cells = frames.map { cell(of: $0, in: area, gap: gap) }
        var widths = cells.map(\.width)
        var heights = cells.map(\.height)
        var movedAcross = false, movedDown = false
        // Each edge: where it was, how far it moved, and whether it's a left or right edge.
        let edges: [(ends: CGFloat, starts: CGFloat, by: CGFloat, vertical: Bool)] = [
            (old.minX - gap, old.minX, new.minX - old.minX, true),   // left edge
            (old.maxX, old.maxX + gap, new.maxX - old.maxX, true),   // right edge
            (old.minY - gap, old.minY, new.minY - old.minY, false),  // top edge
            (old.maxY, old.maxY + gap, new.maxY - old.maxY, false),  // bottom edge
        ]
        for edge in edges where abs(edge.by) > 4 {
            let before = frames.indices.filter { abs((edge.vertical ? frames[$0].maxX : frames[$0].maxY) - edge.ends) <= 3 }
            let after = frames.indices.filter { abs((edge.vertical ? frames[$0].minX : frames[$0].minY) - edge.starts) <= 3 }
            guard !before.isEmpty, !after.isEmpty else { continue }   // The screen's edge: nothing gives way.
            for i in before {
                if edge.vertical { widths[i] += edge.by } else { heights[i] += edge.by }
            }
            for i in after {
                if edge.vertical { widths[i] -= edge.by } else { heights[i] -= edge.by }
            }
            if edge.vertical { movedAcross = true } else { movedDown = true }
        }
        guard movedAcross || movedDown, widths.allSatisfy({ $0 >= 60 }), heights.allSatisfy({ $0 >= 60 }) else { return nil }
        // Shares only compare windows, so any scale works; dividing by the average keeps them near 1.
        let meanWidth = widths.reduce(0, +) / CGFloat(widths.count)
        let meanHeight = heights.reduce(0, +) / CGFloat(heights.count)
        return shares.indices.map { i in
            CGSize(width: movedAcross ? clamp(widths[i] / meanWidth) : shares[i].width,
                   height: movedDown ? clamp(heights[i] / meanHeight) : shares[i].height)
        }
    }

    /// A tile's whole slot: its frame plus the gap around it (a full gap at the screen's edge,
    /// half a gap between tiles). The opposite of `applyGap`.
    static func cell(of frame: CGRect, in area: CGRect, gap: CGFloat) -> CGRect {
        guard gap > 0 else { return frame }
        func outset(_ edge: CGFloat, _ border: CGFloat) -> CGFloat { abs(edge - border) < 1.5 ? gap : gap / 2 }
        let left = frame.minX - outset(frame.minX - gap, area.minX)
        let right = frame.maxX + outset(frame.maxX + gap, area.maxX)
        let top = frame.minY - outset(frame.minY - gap, area.minY)
        let bottom = frame.maxY + outset(frame.maxY + gap, area.maxY)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return abs(clamped - 1) < 0.001 ? 1 : clamped
    }
}
