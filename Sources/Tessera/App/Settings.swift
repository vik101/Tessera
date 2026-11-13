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
    /// Share of the screen the main window takes in Main + Side (0.3–0.7).
    @Published var mainRatio: Double { didSet { save("mainRatio", mainRatio, .tiling) } }

    /// Apps Tessera leaves alone (bundle identifiers).
    @Published var ignoredApps: [String] { didSet { save("ignoredApps", ignoredApps, .tiling) } }

    @Published var shortcuts: ShortcutSet {
        didSet {
            if let data = try? JSONEncoder().encode(shortcuts) { save("shortcuts", data, .shortcuts) }
        }
    }

    private init() {
        store.register(defaults: [
            "gap": 0,
            "dragToSnap": true,
            "restoreSizeOnDrag": true,
            "cycleSizes": true,
            "autoTile": false,
            "mainRatio": 0.5,
            "ignoredApps": ["com.apple.calculator", "com.apple.systempreferences"],
        ])
        gap = store.integer(forKey: "gap")
        dragToSnap = store.bool(forKey: "dragToSnap")
        restoreSizeOnDrag = store.bool(forKey: "restoreSizeOnDrag")
        cycleSizes = store.bool(forKey: "cycleSizes")
        autoTile = store.bool(forKey: "autoTile")
        mainRatio = store.double(forKey: "mainRatio")
        ignoredApps = store.stringArray(forKey: "ignoredApps") ?? []
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
