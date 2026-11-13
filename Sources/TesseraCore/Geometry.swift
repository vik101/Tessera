import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// All maths in TesseraCore uses screen points with the origin at the TOP-LEFT
// (the same as macOS Accessibility). "Top" is minY. "Bottom" is maxY.

/// The shape of a screen. Some layouts change with it.
public enum ScreenShape: Sendable, Equatable {
    case portrait
    case standard
    case ultrawide

    public static func of(_ size: CGSize) -> ScreenShape {
        guard size.width > 0, size.height > 0 else { return .standard }
        let ratio = size.width / size.height
        if ratio < 1 { return .portrait }
        if ratio >= 2.1 { return .ultrawide }   // 21:9 is 2.33. 16:9 is 1.78.
        return .standard
    }
}

/// A part of a screen, as fractions (0…1) of its width and height.
public struct UnitRect: Equatable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    public var width: CGFloat
    public var height: CGFloat

    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = UnitRect(x: 0, y: 0, width: 1, height: 1)

    /// The same part with width and height swapped (for portrait screens).
    public var transposed: UnitRect { UnitRect(x: y, y: x, width: height, height: width) }
}

public extension CGRect {
    /// A part of this rect. Edges are rounded to whole points, so neighbours meet exactly.
    func part(_ unit: UnitRect) -> CGRect {
        let left = (minX + width * unit.x).rounded()
        let right = (minX + width * (unit.x + unit.width)).rounded()
        let top = (minY + height * unit.y).rounded()
        let bottom = (minY + height * (unit.y + unit.height)).rounded()
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    func isClose(to other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance &&
            abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }

    var center: CGPoint { CGPoint(x: midX, y: midY) }

    func intersectionArea(_ other: CGRect) -> CGFloat {
        let overlap = intersection(other)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }

    /// Moves (and if needed shrinks) this rect so it sits inside `area`.
    func clamped(to area: CGRect) -> CGRect {
        let w = min(width, area.width)
        let h = min(height, area.height)
        let x = min(max(minX, area.minX), area.maxX - w)
        let y = min(max(minY, area.minY), area.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

public extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat { hypot(x - other.x, y - other.y) }
}

/// Leaves `gap` points between windows.
///
/// An edge on the border of `area` moves in by the full gap. An inner edge moves in by
/// half, so two neighbours together leave one full gap.
public func applyGap(_ rect: CGRect, in area: CGRect, gap: CGFloat) -> CGRect {
    guard gap > 0 else { return rect }
    func inset(_ onBorder: Bool) -> CGFloat { onBorder ? gap : gap / 2 }
    let left = (rect.minX + inset(abs(rect.minX - area.minX) < 1)).rounded()
    let right = (rect.maxX - inset(abs(rect.maxX - area.maxX) < 1)).rounded()
    let top = (rect.minY + inset(abs(rect.minY - area.minY) < 1)).rounded()
    let bottom = (rect.maxY - inset(abs(rect.maxY - area.maxY) < 1)).rounded()
    return CGRect(x: left, y: top, width: max(1, right - left), height: max(1, bottom - top))
}
