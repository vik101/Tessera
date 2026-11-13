import Foundation

/// An app in a setup. Only the app is stored — never window titles or documents.
public struct SetupApp: Codable, Hashable, Sendable {
    public var bundleID: String
    public var name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// One tile in a saved setup: the app showing first, then any stacked behind it.
public struct SetupTile: Codable, Hashable, Sendable {
    public var apps: [SetupApp]
    public init(apps: [SetupApp]) { self.apps = apps }
}

/// One screen's arrangement inside a setup.
public struct SetupScreen: Codable, Hashable, Sendable {
    /// Stable screen ID (vendor-model-serial), so it survives reconnects.
    public var screenID: String
    public var screenName: String
    public var layout: LayoutKind
    public var capacity: Int
    public var sizes: [String: [String: [Double]]]
    public var tiles: [SetupTile]

    public init(screenID: String, screenName: String, layout: LayoutKind, capacity: Int, sizes: [String: [String: [Double]]], tiles: [SetupTile]) {
        self.screenID = screenID
        self.screenName = screenName
        self.layout = layout
        self.capacity = capacity
        self.sizes = sizes
        self.tiles = tiles
    }

    /// The showing app of each tile, in order — used to tell if a setup is still on screen.
    public var signature: [String] { tiles.compactMap { $0.apps.first?.bundleID } }
}

/// A named arrangement of apps across screens.
public struct Setup: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var shortcut: KeyCombo?
    public var screens: [SetupScreen]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, shortcut: KeyCombo? = nil, screens: [SetupScreen], createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.shortcut = shortcut
        self.screens = screens
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var allApps: [SetupApp] {
        var seen = Set<String>()
        var result: [SetupApp] = []
        for screen in screens {
            for tile in screen.tiles {
                for app in tile.apps where seen.insert(app.bundleID).inserted {
                    result.append(app)
                }
            }
        }
        return result
    }

    public var bundleIDs: Set<String> { Set(allApps.map(\.bundleID)) }

    /// Compares the setup with what is on screen now. Window sizes and stack order don't count.
    public func matches(current: [String: [String]]) -> Bool {
        for screen in screens {
            guard let now = current[screen.screenID] else { return false }
            if now != screen.signature { return false }
        }
        return true
    }
}

/// Plans where each app of a setup goes when screens may be missing.
public enum SetupPlanner {
    public struct Placement: Equatable, Sendable {
        public var bundleID: String
        public var screenID: String
        public var tile: Int
        /// True if the app joins the tile as a stacked window.
        public var stacked: Bool
    }

    /// Maps saved screens onto connected ones. A missing screen's layout moves to a free
    /// screen; if none is free, its apps stack in the main screen's last tile.
    public static func plan(setup: Setup, connected: [String], main: String) -> (screens: [String: SetupScreen], placements: [Placement]) {
        var assigned: [String: SetupScreen] = [:]
        var leftovers: [SetupScreen] = []
        for screen in setup.screens {
            if connected.contains(screen.screenID), assigned[screen.screenID] == nil {
                assigned[screen.screenID] = screen
            } else {
                leftovers.append(screen)
            }
        }
        var placements: [Placement] = []
        for screen in leftovers {
            if let free = connected.first(where: { assigned[$0] == nil }) {
                var moved = screen
                moved.screenID = free
                assigned[free] = moved
            } else {
                let mainTiles = assigned[main]?.tiles.count ?? 1
                for app in screen.tiles.flatMap(\.apps) {
                    placements.append(Placement(bundleID: app.bundleID, screenID: main, tile: max(0, mainTiles - 1), stacked: true))
                }
            }
        }
        for (screenID, screen) in assigned {
            for (index, tile) in screen.tiles.enumerated() {
                for (position, app) in tile.apps.enumerated() {
                    placements.append(Placement(bundleID: app.bundleID, screenID: screenID, tile: index, stacked: position > 0))
                }
            }
        }
        placements.sort { ($0.screenID, $0.tile, $0.stacked ? 1 : 0) < ($1.screenID, $1.tile, $1.stacked ? 1 : 0) }
        return (assigned, placements)
    }
}
