import AppKit
import ServiceManagement
import TesseraCore

/// Everything you can change, saved in UserDefaults (domain com.vikram.Tessera).
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    enum Change { case shortcuts, tiling, other }

    private let store = UserDefaults.standard
    private var listeners: [@MainActor (Change) -> Void] = []

    /// Points between snapped or tiled windows (0–30).
    @Published var gap: Int { didSet { save("gap", gap, .tiling) } }
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

    func layout(for screenID: String) -> LayoutStyle { layouts[screenID] ?? .auto }

    func isIgnored(_ bundleID: String) -> Bool { ignoredApps.contains(bundleID) }

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
