import Foundation

/// The four ways a screen can be split into tiles.
public enum LayoutKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case grid, columns, rows, side
    public var id: String { rawValue }

    /// The shortcut digit used for this layout (⌃⌥⇧1–4 by default).
    public var shortcutDigit: Int {
        switch self {
        case .grid: 1
        case .columns: 2
        case .rows: 3
        case .side: 4
        }
    }
}

/// How large the primary window starts.
public enum MainSize: String, Codable, CaseIterable, Sendable, Identifiable {
    case half, sixty, twoThirds
    public var id: String { rawValue }

    public var fraction: Double {
        switch self {
        case .half: 0.5
        case .sixty: 0.6
        case .twoThirds: 2.0 / 3.0
        }
    }
}

/// The shape of a screen changes which layouts make sense.
public enum ScreenShape: String, Codable, Sendable {
    /// A normal wide screen (16:10, 16:9, …).
    case landscape
    /// 21:9 or wider.
    case ultrawide
    /// Taller than it is wide (a rotated monitor).
    case vertical

    public static func of(width: Double, height: Double) -> ScreenShape {
        guard width > 0, height > 0 else { return .landscape }
        if height > width { return .vertical }
        if width / height >= 2.2 { return .ultrawide }
        return .landscape
    }

    /// The layouts offered on this shape. Columns is not offered on tall screens.
    public var availableLayouts: [LayoutKind] {
        switch self {
        case .vertical: [.grid, .rows, .side]
        default: LayoutKind.allCases
        }
    }

    /// Most windows a layout may hold on this shape (before size checks).
    public func maxCapacity(for layout: LayoutKind) -> Int {
        switch (self, layout) {
        case (.vertical, .rows): 3
        case (.vertical, .side), (.ultrawide, .side): 5
        default: 4
        }
    }
}

/// What happens when a new window opens on a screen that is already full.
public enum WhenScreenFull: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Join the active tile, on top. The previous window waits behind it.
    case stack
    /// Float in the middle of the screen until there is room.
    case float
    public var id: String { rawValue }
}

/// What happens when a window is moved onto a screen that is already full.
public enum MoveIntoFullScreen: String, Codable, CaseIterable, Sendable, Identifiable {
    case swap
    case stack
    public var id: String { rawValue }
}

/// Where a new window goes when there is room.
public enum NewWindowPlacement: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The next free tile, after the existing windows.
    case nextFreeTile
    /// The large main tile; the others move down one place.
    case mainTile
    public var id: String { rawValue }
}

public enum Direction: String, Codable, CaseIterable, Sendable {
    case left, right, up, down

    public var opposite: Direction {
        switch self {
        case .left: .right
        case .right: .left
        case .up: .down
        case .down: .up
        }
    }
}
