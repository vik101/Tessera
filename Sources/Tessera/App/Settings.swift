import AppKit
import ServiceManagement
import TesseraCore

/// Everything you can change, saved in UserDefaults (domain com.vikram.Tessera).
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    enum Change { case shortcuts, tiling, appearance, other }

    private let store = UserDefaults.standard
    private var listeners: [@MainActor (Change) -> Void] = []

    /// Points between snapped or tiled windows (0–30).
    @Published var gap: Int { didSet { save("gap", gap, .tiling) } }
    /// Points at the screen's edges around tiled windows (-1: the same as `gap`).
    @Published var outerGap: Int { didSet { save("outerGap", outerGap, .tiling) } }
    /// Gaps on or off without losing their sizes (Spacetile's "toggle spacing").
    @Published var spacing: Bool { didSet { save("spacing", spacing, .tiling) } }
    /// The strip each neighbour shows in an accordion (Tree layout), in points.
    @Published var accordionPadding: Double { didSet { save("accordionPadding", accordionPadding, .tiling) } }

    /// Dim every window except the focused one (off by default).
    @Published var dim: Bool { didSet { save("dim", dim, .appearance) } }
    /// How dark the dimming is (0.05–0.9).
    @Published var dimAmount: Double { didSet { save("dimAmount", dimAmount, .appearance) } }
    /// A border round the focused window (off by default).
    @Published var border: Bool { didSet { save("border", border, .appearance) } }
    @Published var borderWidth: Double { didSet { save("borderWidth", borderWidth, .appearance) } }
    /// As #rrggbb.
    @Published var borderColor: String { didSet { save("borderColor", borderColor, .appearance) } }
    /// The desktop's number beside Tessera's menu bar icon (off by default).
    @Published var showDesktopNumber: Bool { didSet { save("showDesktopNumber", showDesktopNumber, .appearance) } }

    /// Focus the window under the pointer when the pointer rests on it (off by default).
    @Published var focusFollowsMouse: Bool { didSet { save("focusFollowsMouse", focusFollowsMouse, .other) } }
    /// Hold this and drag anywhere in a window to move it: "fn", "ctrl-cmd", "cmd-alt", "ctrl-alt" or "none".
    @Published var moveModifier: String { didSet { save("moveModifier", moveModifier, .other) } }
    /// Extra built-in keys: "tessera", "spectacle", "aerospace", "spacetile" or "none".
    @Published var preset: String { didSet { save("preset", preset, .shortcuts) } }
    /// Undo ⌘H: hidden apps come straight back (AeroSpace's automatically-unhide-macos-hidden-apps).
    @Published var unhideHiddenApps: Bool { didSet { save("unhideHiddenApps", unhideHiddenApps, .other) } }
    /// Drag a window to a screen edge or corner to snap it.
    @Published var dragToSnap: Bool { didSet { save("dragToSnap", dragToSnap, .other) } }
    /// Dragging a snapped window away gives it back its old size.
    @Published var restoreSizeOnDrag: Bool { didSet { save("restoreSizeOnDrag", restoreSizeOnDrag, .other) } }
    /// Pressing Left Half again cycles ½ → ⅔ → ⅓.
    @Published var cycleSizes: Bool { didSet { save("cycleSizes", cycleSizes, .other) } }

    @Published var autoTile: Bool { didSet { save("autoTile", autoTile, .tiling) } }
    /// Layout per screen, keyed by the screen's stable id.
    @Published var layouts: [String: LayoutStyle] {
        didSet { save("layouts", layouts.mapValues(\.rawValue), .tiling) }
    }
    /// How many windows sit in front on each screen; the rest wait off screen until you use them.
    @Published var frontLimit: FrontLimit { didSet { save("frontLimit", frontLimit.raw, .tiling) } }
    /// Share of the screen the main window takes in Main + Side (0.3–0.7).
    @Published var mainRatio: Double { didSet { save("mainRatio", mainRatio, .tiling) } }

    /// The size Specified Size gives a window, in points (1 or less: a share of the screen).
    @Published var specifiedWidth: Double { didSet { save("specifiedWidth", specifiedWidth, .other) } }
    @Published var specifiedHeight: Double { didSet { save("specifiedHeight", specifiedHeight, .other) } }

    /// Apps Tessera leaves alone (bundle identifiers).
    @Published var ignoredApps: [String] { didSet { save("ignoredApps", ignoredApps, .tiling) } }

    /// Per-app rules: float, keep in front, open on a screen.
    @Published var appRules: [AppRule] {
        didSet {
            if let data = try? JSONEncoder().encode(appRules) { save("appRules", data, .tiling) }
        }
    }

    /// Saved setups, in the order Open Setup 1…9 uses.
    @Published var setups: [Setup] {
        didSet {
            if let data = try? JSONEncoder().encode(setups) { save("setups", data, .other) }
        }
    }

    @Published var shortcuts: ShortcutSet {
        didSet {
            if let data = try? JSONEncoder().encode(shortcuts) { save("shortcuts", data, .shortcuts) }
        }
    }

    private init() {
        // Tessera 2 starts with clean settings; Tessera 1 saved different things under some of the same names.
        if store.integer(forKey: "settingsVersion") < 2, let id = Bundle.main.bundleIdentifier {
            for key in (store.persistentDomain(forName: id) ?? [:]).keys where key != "TesseraTestHooks" {
                store.removeObject(forKey: key)
            }
            store.set(2, forKey: "settingsVersion")
        }
        store.register(defaults: [
            "gap": 0,
            "outerGap": -1,
            "spacing": true,
            "accordionPadding": 30.0,
            "dim": false,
            "dimAmount": 0.25,
            "border": false,
            "borderWidth": 4.0,
            "borderColor": "#4c9aff",
            "showDesktopNumber": false,
            "focusFollowsMouse": false,
            "moveModifier": "fn",
            "preset": "tessera",
            "unhideHiddenApps": false,
            "dragToSnap": true,
            "restoreSizeOnDrag": true,
            "cycleSizes": true,
            "autoTile": false,
            "mainRatio": 0.5,
            "frontLimit": 0,
            "specifiedWidth": 1680.0,
            "specifiedHeight": 1050.0,
            "ignoredApps": ["com.apple.calculator", "com.apple.systempreferences"],
        ])
        gap = store.integer(forKey: "gap")
        outerGap = store.integer(forKey: "outerGap")
        spacing = store.bool(forKey: "spacing")
        accordionPadding = store.double(forKey: "accordionPadding")
        dim = store.bool(forKey: "dim")
        dimAmount = store.double(forKey: "dimAmount")
        border = store.bool(forKey: "border")
        borderWidth = store.double(forKey: "borderWidth")
        borderColor = store.string(forKey: "borderColor") ?? "#4c9aff"
        showDesktopNumber = store.bool(forKey: "showDesktopNumber")
        focusFollowsMouse = store.bool(forKey: "focusFollowsMouse")
        moveModifier = store.string(forKey: "moveModifier") ?? "fn"
        preset = store.string(forKey: "preset") ?? "tessera"
        unhideHiddenApps = store.bool(forKey: "unhideHiddenApps")
        dragToSnap = store.bool(forKey: "dragToSnap")
        restoreSizeOnDrag = store.bool(forKey: "restoreSizeOnDrag")
        cycleSizes = store.bool(forKey: "cycleSizes")
        autoTile = store.bool(forKey: "autoTile")
        mainRatio = store.double(forKey: "mainRatio")
        frontLimit = FrontLimit(raw: store.integer(forKey: "frontLimit"))
        ignoredApps = store.stringArray(forKey: "ignoredApps") ?? []
        specifiedWidth = store.double(forKey: "specifiedWidth")
        specifiedHeight = store.double(forKey: "specifiedHeight")
        let saved = store.dictionary(forKey: "layouts") as? [String: String] ?? [:]
        layouts = saved.compactMapValues(LayoutStyle.init(rawValue:))
        if let data = store.data(forKey: "appRules"), let rules = try? JSONDecoder().decode([AppRule].self, from: data) {
            appRules = rules
        } else {
            appRules = []
        }
        if let data = store.data(forKey: "setups"), let list = try? JSONDecoder().decode([Setup].self, from: data) {
            setups = list
        } else {
            setups = []
        }
        if let data = store.data(forKey: "shortcuts"), let set = try? JSONDecoder().decode(ShortcutSet.self, from: data) {
            shortcuts = set
        } else {
            shortcuts = ShortcutSet()
        }
    }

    private func save(_ key: String, _ value: Any, _ change: Change) {
        store.set(value, forKey: key)
        for listener in listeners { listener(change) }
    }

    /// Calls back after any setting changes.
    func observe(_ listener: @escaping @MainActor (Change) -> Void) {
        listeners.append(listener)
    }

    func layout(for screenID: String) -> LayoutStyle { layouts[screenID] ?? ConfigStore.shared.defaultLayout ?? .auto }

    /// The gaps on a screen: the config file's (which can differ per screen) or the sliders',
    /// and none while spacing is toggled off.
    func gaps(for display: DisplayInfo, in displays: [DisplayInfo]) -> Gaps {
        guard spacing else { return Gaps(inner: 0, outer: 0) }
        if let fromFile = ConfigStore.shared.config.gaps { return fromFile }
        return Gaps(inner: CGFloat(gap), outer: CGFloat(outerGap < 0 ? gap : outerGap))
    }

    /// The shortcut preset in use (the config file's wins).
    var shortcutPreset: ShortcutPreset { ConfigStore.shared.config.preset ?? ShortcutPreset(rawValue: preset) ?? .tessera }

    func isIgnored(_ bundleID: String) -> Bool { ignoredApps.contains(bundleID) }

    func rule(for bundleID: String) -> AppRule? { appRules.first { $0.bundleID == bundleID } }

    var rulesByApp: [String: AppRule] { Dictionary(appRules.map { ($0.bundleID, $0) }, uniquingKeysWith: { a, _ in a }) }

    /// Changes one app's rule; a rule that ends up changing nothing is removed.
    func updateRule(for bundleID: String, _ change: (inout AppRule) -> Void) {
        var rule = rule(for: bundleID) ?? AppRule(bundleID: bundleID)
        change(&rule)
        var rules = appRules.filter { $0.bundleID != bundleID }
        if !rule.isEmpty { rules.append(rule) }
        appRules = rules.sorted { $0.bundleID < $1.bundleID }
    }

    func toggleIgnored(_ bundleID: String) {
        if let index = ignoredApps.firstIndex(of: bundleID) {
            ignoredApps.remove(at: index)
        } else {
            ignoredApps.append(bundleID)
        }
    }

    // MARK: Settings file

    /// Everything worth moving to another Mac. Layouts are per screen, so they only matter on the same screens.
    var file: SettingsFile {
        var file = SettingsFile()
        file.gap = gap
        file.dragToSnap = dragToSnap
        file.restoreSizeOnDrag = restoreSizeOnDrag
        file.cycleSizes = cycleSizes
        file.autoTile = autoTile
        file.layouts = layouts.mapValues(\.rawValue)
        file.frontLimit = frontLimit.raw
        file.mainRatio = mainRatio
        file.ignoredApps = ignoredApps
        file.specifiedWidth = specifiedWidth
        file.specifiedHeight = specifiedHeight
        file.shortcuts = shortcuts
        file.appRules = appRules
        file.setups = setups
        return file
    }

    /// Takes every setting the file has; the rest stay as they are.
    func apply(_ file: SettingsFile) {
        let file = file.cleaned
        if let v = file.gap { gap = v }
        if let v = file.dragToSnap { dragToSnap = v }
        if let v = file.restoreSizeOnDrag { restoreSizeOnDrag = v }
        if let v = file.cycleSizes { cycleSizes = v }
        if let v = file.layouts { layouts = v.compactMapValues(LayoutStyle.init(rawValue:)) }
        if let v = file.frontLimit { frontLimit = FrontLimit(raw: v) }
        if let v = file.mainRatio { mainRatio = v }
        if let v = file.ignoredApps { ignoredApps = v }
        if let v = file.specifiedWidth { specifiedWidth = v }
        if let v = file.specifiedHeight { specifiedHeight = v }
        if let v = file.shortcuts { shortcuts = v }
        if let v = file.appRules { appRules = v }
        if let v = file.setups { setups = v }
        if let v = file.autoTile { autoTile = v }   // Last, so tiling starts with the new layouts.
    }

    func export(to url: URL) throws {
        try file.encoded().write(to: url, options: .atomic)
        Log.info("Settings exported")
    }

    func importFile(at url: URL) throws {
        apply(try SettingsFile.decode(Data(contentsOf: url)))
        Log.info("Settings imported")
    }

    /// Like Rectangle: a TesseraConfig.json left in Tessera's Application Support folder is read at launch,
    /// then renamed with the date, so it's read only once.
    func importDroppedFile() {
        guard let id = Bundle.main.bundleIdentifier,
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let folder = support.appendingPathComponent(id)
        let file = folder.appendingPathComponent("TesseraConfig.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try importFile(at: file)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try FileManager.default.moveItem(at: file, to: folder.appendingPathComponent("TesseraConfig-imported-\(stamp).json"))
        } catch {
            Log.error("TesseraConfig.json: \(error.localizedDescription)")
        }
    }

    // MARK: Open at login

    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.error("Open at login: \(error.localizedDescription)")
            }
        }
    }
}
