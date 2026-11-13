import AppKit
import Observation
import TesseraCore

/// Highlight color: the Mac's accent color, or a specific color.
enum HighlightColor: Codable, Hashable {
    case accent
    case custom(hex: String)

    static let presets: [String] = ["#FF9F0A", "#FF453A", "#FF375F", "#BF5AF2", "#5E5CE6", "#0A84FF", "#64D2FF", "#30D158", "#FFD60A"]

    @MainActor
    var nsColor: NSColor {
        switch self {
        case .accent: .controlAccentColor
        case .custom(let hex): NSColor(hex: hex) ?? .controlAccentColor
        }
    }
}

/// Per-screen choices that survive restarts.
struct ScreenPrefs: Codable, Hashable {
    var landscapeLayout: LayoutKind?
    var verticalLayout: LayoutKind?
    var capacity: Int?
}

/// All settings, saved to UserDefaults as they change.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    // MARK: General
    var automaticTiling: Bool { didSet { save(automaticTiling, "automaticTiling") } }
    var openAtLogin: Bool { didSet { save(openAtLogin, "openAtLogin") } }
    var appearance: AppearanceChoice { didSet { saveCodable(appearance, "appearance") } }
    var appIcon: String { didSet { save(appIcon, "appIcon") } }
    var checkForUpdatesAutomatically: Bool { didSet { save(checkForUpdatesAutomatically, "checkForUpdatesAutomatically") } }
    var language: LanguageChoice { didSet { saveCodable(language, "language") } }

    // MARK: Layout
    var defaultLayout: LayoutKind { didSet { saveCodable(defaultLayout, "defaultLayout") } }
    var mainSize: MainSize { didSet { saveCodable(mainSize, "mainSize") } }
    var defaultCapacity: Int { didSet { save(defaultCapacity, "defaultCapacity") } }
    var newWindowPlacement: NewWindowPlacement { didSet { saveCodable(newWindowPlacement, "newWindowPlacement") } }
    var whenFull: WhenScreenFull { didSet { saveCodable(whenFull, "whenFull") } }
    var moveIntoFull: MoveIntoFullScreen { didSet { saveCodable(moveIntoFull, "moveIntoFull") } }
    var gap: Double { didSet { save(gap, "gap") } }
    var screenPrefs: [String: ScreenPrefs] { didSet { saveCodable(screenPrefs, "screenPrefs") } }

    // MARK: Docks and bars
    var reservedEdges: [String: ReservedEdges] { didSet { saveCodable(reservedEdges, "reservedEdges") } }
    var sameEdgesOnEveryScreen: Bool { didSet { save(sameEdgesOnEveryScreen, "sameEdgesOnEveryScreen") } }
    var sharedEdges: ReservedEdges { didSet { saveCodable(sharedEdges, "sharedEdges") } }

    // MARK: Highlight
    var highlight: HighlightStyle { didSet { saveCodable(highlight, "highlight") } }
    var lastBorderStyle: HighlightStyle { didSet { saveCodable(lastBorderStyle, "lastBorderStyle") } }
    var borderThickness: Double { didSet { save(borderThickness, "borderThickness") } }
    var highlightColor: HighlightColor { didSet { saveCodable(highlightColor, "highlightColor") } }

    // MARK: Focus
    var noPeek: Bool { didSet { save(noPeek, "noPeek") } }
    var dimAmount: Double { didSet { save(dimAmount, "dimAmount") } }
    var blurOthers: Bool { didSet { save(blurOthers, "blurOthers") } }
    var cleanSpaceBackground: CleanSpaceBackground { didSet { saveCodable(cleanSpaceBackground, "cleanSpaceBackground") } }

    // MARK: Mouse
    var quickActions: Bool { didSet { save(quickActions, "quickActions") } }
    var hoverFocus: Bool { didSet { save(hoverFocus, "hoverFocus") } }

    // MARK: Keyboard
    var shortcutsEnabled: Bool { didSet { save(shortcutsEnabled, "shortcutsEnabled") } }
    var shortcutPrefix: ShortcutPrefix { didSet { saveCodable(shortcutPrefix, "shortcutPrefix") } }
    var shortcutBindings: [String: ShortcutBinding] { didSet { saveCodable(shortcutBindings, "shortcutBindings") } }
    var countModifiers: Modifiers? { didSet { saveCodable(countModifiers, "countModifiers") } }

    // MARK: Apps
    var excludedApps: [ExcludedApp] { didSet { saveCodable(excludedApps, "excludedApps") } }
    var floatRules: [FloatRule] { didSet { saveCodable(floatRules, "floatRules") } }
    var learnedMinimums: [String: LearnedMinimum] { didSet { saveCodable(learnedMinimums, "learnedMinimums") } }
    var learnedMinimumNames: [String: String] { didSet { saveCodable(learnedMinimumNames, "learnedMinimumNames") } }
    var neverLearn: [String: String] { didSet { saveCodable(neverLearn, "neverLearn") } }
    var hiddenRoomNotices: [String: String] { didSet { saveCodable(hiddenRoomNotices, "hiddenRoomNotices") } }

    // MARK: Activity
    var countActivity: Bool { didSet { save(countActivity, "countActivity") } }
    var activity: ActivityCounts { didSet { saveCodable(activity, "activity") } }

    // MARK: State
    var onboardingComplete: Bool { didSet { save(onboardingComplete, "onboardingComplete") } }
    var lastSeenVersion: String { didSet { save(lastSeenVersion, "lastSeenVersion") } }
    var seenStackNotice: Bool { didSet { save(seenStackNotice, "seenStackNotice") } }
    var lastSetupID: String? { didSet { save(lastSetupID, "lastSetupID") } }
    var roomNoticeShownOn: [String: Date] { didSet { saveCodable(roomNoticeShownOn, "roomNoticeShownOn") } }

    private init() {
        let d = UserDefaults.standard
        func load<T: Decodable>(_ key: String, _ fallback: T) -> T {
            guard let data = d.data(forKey: key), let value = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
            return value
        }
        automaticTiling = d.object(forKey: "automaticTiling") as? Bool ?? true
        openAtLogin = d.object(forKey: "openAtLogin") as? Bool ?? true
        appearance = load("appearance", .matchMac)
        appIcon = d.string(forKey: "appIcon") ?? "paper"
        checkForUpdatesAutomatically = d.object(forKey: "checkForUpdatesAutomatically") as? Bool ?? true
        language = load("language", .system)

        defaultLayout = load("defaultLayout", .grid)
        mainSize = load("mainSize", .half)
        defaultCapacity = d.object(forKey: "defaultCapacity") as? Int ?? 3
        newWindowPlacement = load("newWindowPlacement", .nextFreeTile)
        whenFull = load("whenFull", .stack)
        moveIntoFull = load("moveIntoFull", .swap)
        gap = d.object(forKey: "gap") as? Double ?? 8
        screenPrefs = load("screenPrefs", [:])

        reservedEdges = load("reservedEdges", [:])
        sameEdgesOnEveryScreen = d.object(forKey: "sameEdgesOnEveryScreen") as? Bool ?? false
        sharedEdges = load("sharedEdges", .zero)

        highlight = load("highlight", .none)
        lastBorderStyle = load("lastBorderStyle", .borderOnAll)
        borderThickness = d.object(forKey: "borderThickness") as? Double ?? 3
        highlightColor = load("highlightColor", .accent)

        noPeek = d.object(forKey: "noPeek") as? Bool ?? false
        dimAmount = d.object(forKey: "dimAmount") as? Double ?? 0.5
        blurOthers = d.object(forKey: "blurOthers") as? Bool ?? true
        cleanSpaceBackground = load("cleanSpaceBackground", .graphite)

        quickActions = d.object(forKey: "quickActions") as? Bool ?? true
        hoverFocus = d.object(forKey: "hoverFocus") as? Bool ?? false

        shortcutsEnabled = d.object(forKey: "shortcutsEnabled") as? Bool ?? true
        shortcutPrefix = load("shortcutPrefix", .controlOption)
        shortcutBindings = load("shortcutBindings", [:])
        countModifiers = load("countModifiers", nil)

        excludedApps = load("excludedApps", ExcludedApp.defaults)
        floatRules = load("floatRules", [])
        learnedMinimums = load("learnedMinimums", [:])
        learnedMinimumNames = load("learnedMinimumNames", [:])
        neverLearn = load("neverLearn", [:])
        hiddenRoomNotices = load("hiddenRoomNotices", [:])

        countActivity = d.object(forKey: "countActivity") as? Bool ?? true
        activity = load("activity", ActivityCounts())

        onboardingComplete = d.bool(forKey: "onboardingComplete")
        lastSeenVersion = d.string(forKey: "lastSeenVersion") ?? ""
        seenStackNotice = d.bool(forKey: "seenStackNotice")
        lastSetupID = d.string(forKey: "lastSetupID")
        roomNoticeShownOn = load("roomNoticeShownOn", [:])
    }

    private func save(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: key)
    }

    private func saveCodable<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    // MARK: Helpers

    func isExcluded(_ bundleID: String) -> Bool {
        excludedApps.contains { $0.bundleID == bundleID }
    }

    func setExcluded(_ bundleID: String, name: String, excluded: Bool) {
        if excluded {
            guard !isExcluded(bundleID) else { return }
            excludedApps.append(ExcludedApp(bundleID: bundleID, name: name))
        } else {
            excludedApps.removeAll { $0.bundleID == bundleID }
        }
    }

    func reservedEdges(for screenID: String) -> ReservedEdges {
        sameEdgesOnEveryScreen ? sharedEdges : (reservedEdges[screenID] ?? .zero)
    }

    func setReservedEdges(_ edges: ReservedEdges, for screenID: String) {
        if sameEdgesOnEveryScreen {
            sharedEdges = edges
        } else {
            reservedEdges[screenID] = edges
        }
    }

    var shortcutResolver: ShortcutResolver {
        var bindings: [ShortcutAction: ShortcutBinding] = [:]
        for (key, value) in shortcutBindings {
            if let action = ShortcutAction(rawValue: key) { bindings[action] = value }
        }
        return ShortcutResolver(prefix: shortcutPrefix, bindings: bindings, countModifiers: countModifiers)
    }

    func setBinding(_ binding: ShortcutBinding, for action: ShortcutAction) {
        if case .standard = binding {
            shortcutBindings.removeValue(forKey: action.rawValue)
        } else {
            shortcutBindings[action.rawValue] = binding
        }
    }

    func count(_ keyPath: WritableKeyPath<ActivityCounts, Int>) {
        guard countActivity else { return }
        activity[keyPath: keyPath] += 1
    }

    /// The effective space between windows, widened to fit borders or glow.
    var effectiveGap: Double {
        switch highlight {
        case .borderOnActive, .borderOnAll: max(gap, borderThickness * 2 + 2)
        case .glowOnActive: max(gap, 4)
        case .none: gap
        }
    }
}
