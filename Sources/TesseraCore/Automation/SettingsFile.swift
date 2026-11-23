import Foundation

/// Tessera's settings as a JSON file, for Export, Import and moving to another Mac.
/// Every field is optional: a file with only `gap` changes only the gap.
public struct SettingsFile: Codable, Equatable, Sendable {
    /// The file format. Bump when a field changes meaning.
    public var version: Int? = 1
    public var gap: Int?
    public var dragToSnap: Bool?
    public var restoreSizeOnDrag: Bool?
    public var cycleSizes: Bool?
    public var autoTile: Bool?
    /// Layout per screen, by the screen's stable id: "columns", "rows", "grid", "mainAndSide" or "auto".
    public var layouts: [String: String]?
    /// 0 = Auto, -1 = no limit, 2…6 = that many windows in front.
    public var frontLimit: Int?
    public var mainRatio: Double?
    public var ignoredApps: [String]?
    public var specifiedWidth: Double?
    public var specifiedHeight: Double?
    public var shortcuts: ShortcutSet?
    /// Per-app rules: float, keep in front, open on a screen.
    public var appRules: [AppRule]?
    /// Saved setups: apps and where their windows go.
    public var setups: [Setup]?

    public init() {}

    /// The same settings with every value brought into its allowed range, and unknown layouts dropped.
    public var cleaned: SettingsFile {
        var copy = self
        copy.gap = gap.map { min(max($0, 0), 30) }
        copy.mainRatio = mainRatio.map { min(max($0, 0.3), 0.7) }
        copy.frontLimit = frontLimit.map { $0 == 0 || $0 == -1 ? $0 : min(max($0, 2), 6) }
        copy.layouts = layouts?.filter { LayoutStyle(rawValue: $0.value) != nil }
        copy.specifiedWidth = specifiedWidth.map { max($0, 0.1) }
        copy.specifiedHeight = specifiedHeight.map { max($0, 0.1) }
        copy.appRules = appRules?.filter { !$0.bundleID.isEmpty && !$0.isEmpty }
        return copy
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> SettingsFile {
        try JSONDecoder().decode(SettingsFile.self, from: data).cleaned
    }
}
