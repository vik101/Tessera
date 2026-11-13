import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Groups of snap actions, in menu order.
public enum SnapGroup: String, CaseIterable, Sendable {
    case halves, corners, thirds, size, displays, edges, quarters, sixths

    /// Groups shown in a submenu instead of the main menu.
    public var submenuTitle: String? {
        switch self {
        case .edges: "Move to Edge"
        case .quarters: "Quarters"
        case .sixths: "Sixths"
        default: nil
        }
    }
}

/// Every way Tessera can place one window. Names and shortcuts follow Rectangle.
public enum SnapAction: String, CaseIterable, Codable, Sendable {
    case leftHalf, rightHalf, centreHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case firstThird, centreThird, lastThird, firstTwoThirds, centreTwoThirds, lastTwoThirds
    case maximise, almostMaximise, maximiseHeight, larger, smaller, centre, restore
    case nextDisplay, previousDisplay
    case moveLeft, moveRight, moveUp, moveDown
    case firstQuarter, secondQuarter, thirdQuarter, lastQuarter
    case firstThreeQuarters, centreThreeQuarters, lastThreeQuarters
    case topLeftSixth, topCentreSixth, topRightSixth, bottomLeftSixth, bottomCentreSixth, bottomRightSixth

    public var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .centreHalf: "Centre Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .firstThird: "First Third"
        case .centreThird: "Centre Third"
        case .lastThird: "Last Third"
        case .firstTwoThirds: "First Two Thirds"
        case .centreTwoThirds: "Centre Two Thirds"
        case .lastTwoThirds: "Last Two Thirds"
        case .maximise: "Maximise"
        case .almostMaximise: "Almost Maximise"
        case .maximiseHeight: "Maximise Height"
        case .larger: "Make Larger"
        case .smaller: "Make Smaller"
        case .centre: "Centre"
        case .restore: "Restore"
        case .nextDisplay: "Next Display"
        case .previousDisplay: "Previous Display"
        case .moveLeft: "Move Left"
        case .moveRight: "Move Right"
        case .moveUp: "Move Up"
        case .moveDown: "Move Down"
        case .firstQuarter: "First Quarter"
        case .secondQuarter: "Second Quarter"
        case .thirdQuarter: "Third Quarter"
        case .lastQuarter: "Last Quarter"
        case .firstThreeQuarters: "First Three Quarters"
        case .centreThreeQuarters: "Centre Three Quarters"
        case .lastThreeQuarters: "Last Three Quarters"
        case .topLeftSixth: "Top Left Sixth"
        case .topCentreSixth: "Top Centre Sixth"
        case .topRightSixth: "Top Right Sixth"
        case .bottomLeftSixth: "Bottom Left Sixth"
        case .bottomCentreSixth: "Bottom Centre Sixth"
        case .bottomRightSixth: "Bottom Right Sixth"
        }
    }

    public var group: SnapGroup {
        switch self {
        case .leftHalf, .rightHalf, .centreHalf, .topHalf, .bottomHalf: .halves
        case .topLeft, .topRight, .bottomLeft, .bottomRight: .corners
        case .firstThird, .centreThird, .lastThird, .firstTwoThirds, .centreTwoThirds, .lastTwoThirds: .thirds
        case .maximise, .almostMaximise, .maximiseHeight, .larger, .smaller, .centre, .restore: .size
        case .nextDisplay, .previousDisplay: .displays
        case .moveLeft, .moveRight, .moveUp, .moveDown: .edges
        case .firstQuarter, .secondQuarter, .thirdQuarter, .lastQuarter,
             .firstThreeQuarters, .centreThreeQuarters, .lastThreeQuarters: .quarters
        case .topLeftSixth, .topCentreSixth, .topRightSixth,
             .bottomLeftSixth, .bottomCentreSixth, .bottomRightSixth: .sixths
        }
    }

    /// Rectangle's default shortcuts.
    public var defaultShortcut: KeyCombo? {
        let co: Modifiers = [.control, .option]
        switch self {
        case .leftHalf: return KeyCombo(KeyCode.leftArrow, co)
        case .rightHalf: return KeyCombo(KeyCode.rightArrow, co)
        case .topHalf: return KeyCombo(KeyCode.upArrow, co)
        case .bottomHalf: return KeyCombo(KeyCode.downArrow, co)
        case .topLeft: return KeyCombo(KeyCode.u, co)
        case .topRight: return KeyCombo(KeyCode.i, co)
        case .bottomLeft: return KeyCombo(KeyCode.j, co)
        case .bottomRight: return KeyCombo(KeyCode.k, co)
        case .firstThird: return KeyCombo(KeyCode.d, co)
        case .centreThird: return KeyCombo(KeyCode.f, co)
        case .lastThird: return KeyCombo(KeyCode.g, co)
        case .firstTwoThirds: return KeyCombo(KeyCode.e, co)
        case .lastTwoThirds: return KeyCombo(KeyCode.t, co)
        case .maximise: return KeyCombo(KeyCode.returnKey, co)
        case .maximiseHeight: return KeyCombo(KeyCode.upArrow, co.union(.shift))
        case .larger: return KeyCombo(KeyCode.equal, co)
        case .smaller: return KeyCombo(KeyCode.minus, co)
        case .centre: return KeyCombo(KeyCode.c, co)
        case .restore: return KeyCombo(KeyCode.delete, co)
        case .nextDisplay: return KeyCombo(KeyCode.rightArrow, co.union(.command))
        case .previousDisplay: return KeyCombo(KeyCode.leftArrow, co.union(.command))
        default: return nil
        }
    }

    /// Pressing these again cycles the size: ½ → ⅔ → ⅓.
    public var cycles: Bool {
        switch self {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf, .topLeft, .topRight, .bottomLeft, .bottomRight: true
        default: false
        }
    }

    /// Sizes used by cycling, in order.
    public static let cycleFractions: [CGFloat] = [1.0 / 2, 2.0 / 3, 1.0 / 3]

    /// The part of the screen this action fills, or nil if it depends on the window
    /// (size, centre, edges, displays, restore).
    ///
    /// Thirds and quarters run top to bottom on a portrait screen, like Rectangle.
    public func region(shape: ScreenShape, cycle: Int = 0) -> UnitRect? {
        let f = Self.cycleFractions[((cycle % 3) + 3) % 3]
        let third: CGFloat = 1.0 / 3
        let portrait = shape == .portrait
        func strip(_ x: CGFloat, _ w: CGFloat) -> UnitRect {
            let unit = UnitRect(x: x, y: 0, width: w, height: 1)
            return portrait ? unit.transposed : unit
        }
        switch self {
        case .leftHalf: return UnitRect(x: 0, y: 0, width: f, height: 1)
        case .rightHalf: return UnitRect(x: 1 - f, y: 0, width: f, height: 1)
        case .topHalf: return UnitRect(x: 0, y: 0, width: 1, height: f)
        case .bottomHalf: return UnitRect(x: 0, y: 1 - f, width: 1, height: f)
        case .centreHalf: return strip(0.25, 0.5)
        case .topLeft: return UnitRect(x: 0, y: 0, width: f, height: 0.5)
        case .topRight: return UnitRect(x: 1 - f, y: 0, width: f, height: 0.5)
        case .bottomLeft: return UnitRect(x: 0, y: 0.5, width: f, height: 0.5)
        case .bottomRight: return UnitRect(x: 1 - f, y: 0.5, width: f, height: 0.5)
        case .firstThird: return strip(0, third)
        case .centreThird: return strip(third, third)
        case .lastThird: return strip(2 * third, third)
        case .firstTwoThirds: return strip(0, 2 * third)
        case .centreTwoThirds: return strip(third / 2, 2 * third)
        case .lastTwoThirds: return strip(third, 2 * third)
        case .maximise: return .full
        case .firstQuarter: return strip(0, 0.25)
        case .secondQuarter: return strip(0.25, 0.25)
        case .thirdQuarter: return strip(0.5, 0.25)
        case .lastQuarter: return strip(0.75, 0.25)
        case .firstThreeQuarters: return strip(0, 0.75)
        case .centreThreeQuarters: return strip(0.125, 0.75)
        case .lastThreeQuarters: return strip(0.25, 0.75)
        case .topLeftSixth: return UnitRect(x: 0, y: 0, width: third, height: 0.5)
        case .topCentreSixth: return UnitRect(x: third, y: 0, width: third, height: 0.5)
        case .topRightSixth: return UnitRect(x: 2 * third, y: 0, width: third, height: 0.5)
        case .bottomLeftSixth: return UnitRect(x: 0, y: 0.5, width: third, height: 0.5)
        case .bottomCentreSixth: return UnitRect(x: third, y: 0.5, width: third, height: 0.5)
        case .bottomRightSixth: return UnitRect(x: 2 * third, y: 0.5, width: third, height: 0.5)
        default: return nil
        }
    }

    /// A small picture of the action for the menu, as a part of a landscape screen.
    public var iconRegion: UnitRect {
        switch self {
        case .almostMaximise: UnitRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        case .maximiseHeight: UnitRect(x: 0.3, y: 0, width: 0.4, height: 1)
        case .larger: UnitRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        case .smaller: UnitRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        case .centre: UnitRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        case .restore: UnitRect(x: 0.15, y: 0.2, width: 0.5, height: 0.5)
        case .nextDisplay: UnitRect(x: 0.5, y: 0.2, width: 0.5, height: 0.6)
        case .previousDisplay: UnitRect(x: 0, y: 0.2, width: 0.5, height: 0.6)
        case .moveLeft: UnitRect(x: 0, y: 0.25, width: 0.5, height: 0.5)
        case .moveRight: UnitRect(x: 0.5, y: 0.25, width: 0.5, height: 0.5)
        case .moveUp: UnitRect(x: 0.25, y: 0, width: 0.5, height: 0.5)
        case .moveDown: UnitRect(x: 0.25, y: 0.5, width: 0.5, height: 0.5)
        default: region(shape: .standard) ?? .full
        }
    }
}
