import Foundation

/// What Tessera always does with one app's windows. Set in Settings › App Rules, or from the menu.
public struct AppRule: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var bundleID: String
    /// Auto-tile leaves the app's windows where you put them (snapping still works).
    public var float: Bool
    /// The app's windows never step back to wait when the screen has more windows than fit in front.
    public var keepInFront: Bool
    /// The stable id of the screen the app's new windows open on, or nil for wherever macOS puts them.
    public var screen: String?

    public var id: String { bundleID }

    public init(bundleID: String, float: Bool = false, keepInFront: Bool = false, screen: String? = nil) {
        self.bundleID = bundleID
        self.float = float
        self.keepInFront = keepInFront
        self.screen = screen
    }

    // A file written by hand may leave out the switches that are off.
    private enum CodingKeys: String, CodingKey { case bundleID, float, keepInFront, screen }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        float = try c.decodeIfPresent(Bool.self, forKey: .float) ?? false
        keepInFront = try c.decodeIfPresent(Bool.self, forKey: .keepInFront) ?? false
        screen = try c.decodeIfPresent(String.self, forKey: .screen)
    }

    /// True when the rule changes nothing, so it can be dropped.
    public var isEmpty: Bool { !float && !keepInFront && screen == nil }
}

public enum AppRules {
    /// The windows that stay in front because their app's rule says so: the ones used most lately,
    /// at most `room` of them (so a spot is always left for the window you use next).
    public static func kept<ID: Hashable>(_ tiled: [ID], app: (ID) -> String?, rules: [String: AppRule],
                                          room: Int, recency: [ID: Int]) -> Set<ID> {
        guard room > 0 else { return [] }
        let wanted = tiled.filter { id in app(id).flatMap { rules[$0] }?.keepInFront == true }
        let ranked = wanted.enumerated().sorted { a, b in
            let ra = recency[a.element] ?? Int.min, rb = recency[b.element] ?? Int.min
            return ra != rb ? ra > rb : a.offset < b.offset
        }.map(\.element)
        return Set(ranked.prefix(room))
    }
}
