import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Keyboard moves between windows and desktops: focus the window to the left, send a window to desktop 3.
public enum MoveAction: String, CaseIterable, Codable, Sendable {
    case focusLeft, focusRight, focusUp, focusDown
    case desktop1, desktop2, desktop3, desktop4, desktop5, desktop6, desktop7, desktop8, desktop9
    case nextDesktop, previousDesktop

    public var title: String {
        switch self {
        case .focusLeft: "Focus Window Left"
        case .focusRight: "Focus Window Right"
        case .focusUp: "Focus Window Above"
        case .focusDown: "Focus Window Below"
        case .nextDesktop: "Send to Next Desktop"
        case .previousDesktop: "Send to Previous Desktop"
        default: "Send to Desktop \(desktopNumber ?? 0)"
        }
    }

    /// 1…9 for the Send to Desktop actions.
    public var desktopNumber: Int? {
        guard rawValue.hasPrefix("desktop"), let n = Int(rawValue.dropFirst(7)) else { return nil }
        return n
    }

    public var direction: Direction? {
        switch self {
        case .focusLeft: .left
        case .focusRight: .right
        case .focusUp: .up
        case .focusDown: .down
        default: nil
        }
    }

    /// Focus: ⌃⇧⌘ + arrow. Send to Desktop N: ⌃⌥⇧N. (Neither clashes with Rectangle's keys.)
    public var defaultShortcut: KeyCombo? {
        let focus: Modifiers = [.control, .shift, .command]
        switch self {
        case .focusLeft: return KeyCombo(KeyCode.leftArrow, focus)
        case .focusRight: return KeyCombo(KeyCode.rightArrow, focus)
        case .focusUp: return KeyCombo(KeyCode.upArrow, focus)
        case .focusDown: return KeyCombo(KeyCode.downArrow, focus)
        case .nextDesktop, .previousDesktop: return nil
        default:
            guard let n = desktopNumber, n - 1 < KeyCode.digits.count else { return nil }
            return KeyCombo(KeyCode.digits[n - 1], [.control, .option, .shift])
        }
    }

    /// `focus-left`, `send-to-desktop-3`, `send-to-next-desktop`.
    public var urlName: String {
        if let n = desktopNumber { return "send-to-desktop-\(n)" }
        switch self {
        case .nextDesktop: return "send-to-next-desktop"
        case .previousDesktop: return "send-to-previous-desktop"
        default: return kebab(rawValue)
        }
    }
}

public enum Direction: String, CaseIterable, Sendable {
    case left, right, up, down
}

/// Finds windows by direction. Coordinates: origin top-left, y grows down.
public enum Navigation {
    /// The window to `direction` of `source`: one in line with it if there is one, else the nearest.
    public static func neighbour(of source: CGRect, direction: Direction,
                                 among candidates: [(id: UInt32, frame: CGRect)]) -> UInt32? {
        struct Scored { let id: UInt32; let inLine: Bool; let gap: CGFloat; let cross: CGFloat; let order: CGFloat }
        var scored: [Scored] = []
        for c in candidates {
            let f = c.frame
            let along, gap, overlap, cross, order: CGFloat
            switch direction {
            case .left:
                along = source.midX - f.midX; gap = source.minX - f.maxX
                overlap = min(source.maxY, f.maxY) - max(source.minY, f.minY); cross = abs(f.midY - source.midY); order = f.minY
            case .right:
                along = f.midX - source.midX; gap = f.minX - source.maxX
                overlap = min(source.maxY, f.maxY) - max(source.minY, f.minY); cross = abs(f.midY - source.midY); order = f.minY
            case .up:
                along = source.midY - f.midY; gap = source.minY - f.maxY
                overlap = min(source.maxX, f.maxX) - max(source.minX, f.minX); cross = abs(f.midX - source.midX); order = f.minX
            case .down:
                along = f.midY - source.midY; gap = f.minY - source.maxY
                overlap = min(source.maxX, f.maxX) - max(source.minX, f.minX); cross = abs(f.midX - source.midX); order = f.minX
            }
            // Clearly in that direction (its centre a quarter of the window's size away), not just beside it.
            let size = direction == .left || direction == .right ? source.width : source.height
            guard along > max(8, size / 4) else { continue }
            scored.append(Scored(id: c.id, inLine: overlap > 8, gap: max(gap, 0).rounded(), cross: cross.rounded(), order: order))
        }
        return scored.min { a, b in
            if a.inLine != b.inLine { return a.inLine }
            if a.gap != b.gap { return a.gap < b.gap }
            if a.cross != b.cross { return a.cross < b.cross }
            return a.order < b.order
        }?.id
    }
}

/// How many "Move a space" key presses take a window from the desktop it's on to another one.
public enum DesktopSteps {
    /// `spaces`: the screen's Spaces in Mission Control order; `isDesktop` is false for full-screen apps.
    /// Returns presses to the right (negative: to the left), or nil when there is no such desktop.
    public static func presses(spaces: [(id: UInt64, isDesktop: Bool)], current: UInt64, toDesktop number: Int) -> Int? {
        guard let from = spaces.firstIndex(where: { $0.id == current }) else { return nil }
        let desktops = spaces.indices.filter { spaces[$0].isDesktop }
        guard number >= 1, number <= desktops.count else { return nil }
        return desktops[number - 1] - from
    }

    /// Presses to the next (or previous) desktop, skipping full-screen apps; nil at the end of the row.
    public static func presses(spaces: [(id: UInt64, isDesktop: Bool)], current: UInt64, forward: Bool) -> Int? {
        guard let from = spaces.firstIndex(where: { $0.id == current }) else { return nil }
        let targets = forward ? Array(spaces.indices.filter { $0 > from }) : Array(spaces.indices.filter { $0 < from }.reversed())
        guard let to = targets.first(where: { spaces[$0].isDesktop }) else { return nil }
        return to - from
    }
}
