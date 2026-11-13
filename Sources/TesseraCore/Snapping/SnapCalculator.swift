import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// What a snap needs to know about the window and its screen.
public struct SnapContext: Sendable {
    /// The window's frame now.
    public var window: CGRect
    /// The screen area windows may use (no menu bar, no Dock).
    public var visible: CGRect
    /// Points between windows, and between windows and the screen edge.
    public var gap: CGFloat
    /// 0 for the first press, 1 for the second, and so on.
    public var cycle: Int
    /// How far Make Larger and Make Smaller move each edge.
    public var step: CGFloat

    public init(window: CGRect, visible: CGRect, gap: CGFloat = 0, cycle: Int = 0, step: CGFloat = 30) {
        self.window = window
        self.visible = visible
        self.gap = gap
        self.cycle = cycle
        self.step = step
    }
}

/// Works out where a snap action puts a window. Pure maths, no AppKit.
public enum SnapCalculator {
    /// The new frame, or nil for actions the caller handles (Restore, Next/Previous Display).
    public static func frame(for action: SnapAction, _ c: SnapContext) -> CGRect? {
        let shape = ScreenShape.of(c.visible.size)
        if let unit = action.region(shape: shape, cycle: c.cycle) {
            return applyGap(c.visible.part(unit), in: c.visible, gap: c.gap)
        }
        let usable = c.visible.insetBy(dx: c.gap, dy: c.gap)
        switch action {
        case .almostMaximise:
            return c.visible.part(UnitRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9))
        case .maximiseHeight:
            let width = min(c.window.width, usable.width)
            let x = min(max(c.window.minX, usable.minX), usable.maxX - width)
            return CGRect(x: x, y: usable.minY, width: width, height: usable.height)
        case .centre:
            let size = CGSize(width: min(c.window.width, usable.width), height: min(c.window.height, usable.height))
            return CGRect(
                x: (usable.midX - size.width / 2).rounded(),
                y: (usable.midY - size.height / 2).rounded(),
                width: size.width,
                height: size.height
            )
        case .larger:
            return resize(c.window, in: usable, by: c.step)
        case .smaller:
            return resize(c.window, in: usable, by: -c.step)
        case .moveLeft, .moveRight, .moveUp, .moveDown:
            var frame = c.window.clamped(to: usable)
            switch action {
            case .moveLeft: frame.origin.x = usable.minX
            case .moveRight: frame.origin.x = usable.maxX - frame.width
            case .moveUp: frame.origin.y = usable.minY
            default: frame.origin.y = usable.maxY - frame.height
            }
            return frame
        default:
            return nil
        }
    }

    /// Grows (`by` > 0) or shrinks (`by` < 0) a window.
    ///
    /// An edge touching the screen edge stays put, so a left-half window stays on the left.
    /// The result never leaves `area` and never gets smaller than a quarter of it.
    public static func resize(_ window: CGRect, in area: CGRect, by step: CGFloat) -> CGRect {
        func stuck(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 2 }
        let fillsWidth = stuck(window.minX, area.minX) && stuck(window.maxX, area.maxX)
        let fillsHeight = stuck(window.minY, area.minY) && stuck(window.maxY, area.maxY)

        func axis(_ low: CGFloat, _ high: CGFloat, _ areaLow: CGFloat, _ areaHigh: CGFloat, keepFull: Bool) -> (CGFloat, CGFloat) {
            let lowStuck = stuck(low, areaLow)
            let highStuck = stuck(high, areaHigh)
            var newLow = low
            var newHigh = high
            if step > 0 {
                if !lowStuck { newLow -= step }
                if !highStuck { newHigh += step }
            } else if lowStuck && highStuck && keepFull {
                // A full-height column (or full-width strip) keeps that side when shrinking.
                return (low, high)
            } else if lowStuck != highStuck {
                // One edge on the screen edge: only the free edge moves in.
                if lowStuck { newHigh += step } else { newLow -= step }
            } else {
                newLow -= step
                newHigh += step
            }
            newLow = max(newLow, areaLow)
            newHigh = min(newHigh, areaHigh)
            let minimum = (areaHigh - areaLow) / 4
            if newHigh - newLow < minimum { return (low, high) }
            return (newLow.rounded(), newHigh.rounded())
        }
        // Only a window filling the whole screen shrinks on both sides at once.
        let (left, right) = axis(window.minX, window.maxX, area.minX, area.maxX, keepFull: !fillsHeight)
        let (top, bottom) = axis(window.minY, window.maxY, area.minY, area.maxY, keepFull: !fillsWidth)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// Places a window on another screen at the same relative spot and size.
    public static func moveProportionally(_ window: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return window.clamped(to: target) }
        let x = (window.minX - source.minX) / source.width
        let y = (window.minY - source.minY) / source.height
        let w = window.width / source.width
        let h = window.height / source.height
        return target.part(UnitRect(x: x, y: y, width: w, height: h)).clamped(to: target)
    }
}
