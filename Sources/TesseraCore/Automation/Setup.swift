import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A saved arrangement of apps and windows across your screens, opened again with one click or a shortcut.
public struct Setup: Codable, Equatable, Sendable, Identifiable {
    /// One window: which app, which screen, and where on it (as shares of the screen, so it fits any size).
    public struct Entry: Codable, Equatable, Sendable {
        public var bundleID: String
        public var screen: String
        public var place: UnitRect

        public init(bundleID: String, screen: String, place: UnitRect) {
            self.bundleID = bundleID
            self.screen = screen
            self.place = place
        }
    }

    public var name: String
    /// Front to back, as they were when saved.
    public var entries: [Entry]
    /// Auto-tile's layout per screen when saved (empty when auto-tile was off).
    public var layouts: [String: String]
    /// Hide apps that aren't in the setup when it opens (they keep running).
    public var hideOthers: Bool
    /// Open by itself when the screens it was saved on connect (nil in setups saved before 3.0).
    public var openOnConnect: Bool?

    /// The screens the setup puts windows on.
    public var screens: Set<String> { Set(entries.map(\.screen)) }

    /// Whether this setup should open now that `added` screens joined, with `connected` all the screens there are.
    public func opens(whenAdded added: Set<String>, connected: Set<String>) -> Bool {
        openOnConnect == true && !added.isDisjoint(with: screens) && screens.isSubset(of: connected)
    }

    public var id: String { name }

    public init(name: String, entries: [Entry], layouts: [String: String] = [:], hideOthers: Bool = true) {
        self.name = name
        self.entries = entries
        self.layouts = layouts
        self.hideOthers = hideOthers
    }

    /// The apps in the setup, in the order they first appear.
    public var apps: [String] {
        var seen = Set<String>()
        return entries.map(\.bundleID).filter { seen.insert($0).inserted }
    }

    /// Pairs open windows with the setup's entries: each app's windows, front to back, take that app's
    /// entries in order. Windows beyond an app's entries are left alone; entries without a window are skipped.
    public func assign<ID: Hashable>(_ windows: [(id: ID, bundleID: String)]) -> [(id: ID, entry: Entry)] {
        var byApp: [String: [ID]] = [:]
        for window in windows { byApp[window.bundleID, default: []].append(window.id) }
        var used: [String: Int] = [:]
        var result: [(id: ID, entry: Entry)] = []
        for entry in entries {
            let index = used[entry.bundleID, default: 0]
            guard let ids = byApp[entry.bundleID], index < ids.count else { continue }
            used[entry.bundleID] = index + 1
            result.append((id: ids[index], entry: entry))
        }
        return result
    }

    /// Where a window sits on a screen, as shares of the screen's usable area.
    public static func unit(of frame: CGRect, in visible: CGRect) -> UnitRect {
        guard visible.width > 0, visible.height > 0 else { return .full }
        let clipped = frame.intersection(visible).isNull ? frame : frame.intersection(visible)
        func r(_ v: CGFloat) -> CGFloat { (v * 10_000).rounded() / 10_000 }
        return UnitRect(x: r((clipped.minX - visible.minX) / visible.width), y: r((clipped.minY - visible.minY) / visible.height),
                        width: r(clipped.width / visible.width), height: r(clipped.height / visible.height))
    }
}
