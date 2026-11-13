import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// "Always float windows like this one."
///
/// Stores the app and the first two words of the window title. Windows of that app
/// whose titles start with those words float. Titles stay on this Mac.
public struct FloatRule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var bundleID: String
    public var appName: String
    public var titleWords: String

    public init(id: UUID = UUID(), bundleID: String, appName: String, titleWords: String) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.titleWords = titleWords
    }

    /// The first two words of a title, or nil if it has none.
    public static func words(from title: String) -> String? {
        let parts = title.split(whereSeparator: \.isWhitespace).prefix(2)
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }

    public func matches(bundleID: String, title: String) -> Bool {
        guard bundleID == self.bundleID, !titleWords.isEmpty else { return false }
        let normalized = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return normalized.lowercased().hasPrefix(titleWords.lowercased())
    }
}

/// An app that is never tiled.
public struct ExcludedApp: Codable, Hashable, Identifiable, Sendable {
    public var bundleID: String
    public var name: String
    /// Listed by default because it looks wrong stretched into a tile.
    public var isDefault: Bool

    public var id: String { bundleID }

    public init(bundleID: String, name: String, isDefault: Bool = false) {
        self.bundleID = bundleID
        self.name = name
        self.isDefault = isDefault
    }

    /// Small or fixed-shape apps excluded out of the box.
    public static let defaults: [ExcludedApp] = [
        ExcludedApp(bundleID: "com.apple.ScreenContinuity", name: "iPhone Mirroring", isDefault: true),
        ExcludedApp(bundleID: "com.apple.iphonesimulator", name: "Simulator", isDefault: true),
        ExcludedApp(bundleID: "com.apple.calculator", name: "Calculator", isDefault: true),
        ExcludedApp(bundleID: "com.apple.systempreferences", name: "System Settings", isDefault: true),
        ExcludedApp(bundleID: "com.apple.Stickies", name: "Stickies", isDefault: true),
        ExcludedApp(bundleID: "com.apple.clock", name: "Clock", isDefault: true),
        ExcludedApp(bundleID: "com.apple.PhotoBooth", name: "Photo Booth", isDefault: true),
        ExcludedApp(bundleID: "com.apple.QuickTimePlayerX", name: "QuickTime Player", isDefault: true),
        ExcludedApp(bundleID: "com.apple.Magnifier", name: "Magnifier", isDefault: true),
        ExcludedApp(bundleID: "com.apple.DeskView", name: "Desk View", isDefault: true),
        ExcludedApp(bundleID: "com.apple.DigitalColorMeter", name: "Digital Color Meter", isDefault: true),
        ExcludedApp(bundleID: "com.apple.screenshot.launcher", name: "Screenshot", isDefault: true),
        ExcludedApp(bundleID: "com.apple.archiveutility", name: "Archive Utility", isDefault: true),
        ExcludedApp(bundleID: "com.apple.installer", name: "Installer", isDefault: true),
        ExcludedApp(bundleID: "com.apple.iOSAppInstaller", name: "iOS App Installer", isDefault: true),
        ExcludedApp(bundleID: "com.apple.MigrateAssistant", name: "Migration Assistant", isDefault: true),
        ExcludedApp(bundleID: "com.apple.CaptiveNetworkAssistant", name: "Wi-Fi sign-in", isDefault: true),
        ExcludedApp(bundleID: "com.apple.problemreporter", name: "Problem Reporter", isDefault: true),
    ]
}
