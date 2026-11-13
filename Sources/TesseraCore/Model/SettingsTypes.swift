import Foundation

public enum HighlightStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case none
    case borderOnActive
    case borderOnAll
    case glowOnActive
    public var id: String { rawValue }
}

public enum CleanSpaceBackground: String, Codable, CaseIterable, Sendable, Identifiable {
    case graphite, mist, stone
    public var id: String { rawValue }

    /// sRGB components 0–1.
    public var rgb: (Double, Double, Double) {
        switch self {
        case .graphite: (0.169, 0.176, 0.192)
        case .mist: (0.902, 0.910, 0.922)
        case .stone: (0.812, 0.784, 0.737)
        }
    }
}

public enum AppearanceChoice: String, Codable, CaseIterable, Sendable, Identifiable {
    case matchMac, light, dark
    public var id: String { rawValue }
}

public enum LanguageChoice: String, Codable, CaseIterable, Sendable, Identifiable {
    case system
    case english = "en"
    case spanish = "es"
    case japanese = "ja"
    case korean = "ko"
    case chineseSimplified = "zh-Hans"
    public var id: String { rawValue }

    /// Each language names itself.
    public var nativeName: String {
        switch self {
        case .system: "System"
        case .english: "English"
        case .spanish: "Español"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .chineseSimplified: "简体中文"
        }
    }
}

/// Space kept free along a screen's edges for another app's dock or bar.
public struct ReservedEdges: Codable, Hashable, Sendable {
    public var top: Double
    public var bottom: Double
    public var left: Double
    public var right: Double

    public init(top: Double = 0, bottom: Double = 0, left: Double = 0, right: Double = 0) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
    }

    public static let zero = ReservedEdges()
    public var isZero: Bool { top == 0 && bottom == 0 && left == 0 && right == 0 }

    public func inset(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX + left,
            y: rect.minY + top,
            width: max(0, rect.width - left - right),
            height: max(0, rect.height - top - bottom)
        )
    }
}

/// Activity counts. Numbers only — never titles or app names.
public struct ActivityCounts: Codable, Hashable, Sendable {
    public var windowsArranged: Int = 0
    public var swaps: Int = 0
    public var layoutChanges: Int = 0
    public var focusSessions: Int = 0
    public var noPeekSessions: Int = 0
    public var cleanSpaceSessions: Int = 0
    public var setupsOpened: Int = 0
    public var shortcutsUsed: Int = 0
    public var tabViewSwitches: Int = 0
    public var since: Date = Date()

    public init() {}
}
