import AppKit
import TesseraCore

/// Tessera's config file, ~/.config/tessera/tessera.toml (or ~/.tessera.toml). Optional: without it
/// Tessera runs from Settings alone. With it, every setting the file names wins over Settings, and the
/// file adds key bindings, binding modes, window rules and callbacks. A file with a mistake never
/// stops Tessera: the last good config stays, and Tessera says what's wrong and where.
@MainActor
final class ConfigStore {
    static let shared = ConfigStore()

    /// The config in use (empty when there's no file).
    private(set) var config = TesseraConfig()
    /// Why the last read failed, if it did.
    private(set) var lastError: String?
    private var loadedDate: Date?
    private let watchdog = RepeatingTimer()
    private var listeners: [@MainActor () -> Void] = []

    var defaultLayout: LayoutStyle? { config.layout }

    /// Places Tessera looks, in order.
    static var candidates: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var list: [URL] = []
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            list.append(URL(fileURLWithPath: xdg).appendingPathComponent("tessera/tessera.toml"))
        }
        list.append(home.appendingPathComponent(".config/tessera/tessera.toml"))
        list.append(home.appendingPathComponent(".tessera.toml"))
        return list
    }

    /// The file in use, or where a new one goes.
    var fileURL: URL {
        Self.candidates.first { FileManager.default.fileExists(atPath: $0.path) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/tessera/tessera.toml")
    }

    var fileExists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    /// Calls back after each load.
    func observe(_ listener: @escaping @MainActor () -> Void) { listeners.append(listener) }

    /// Reads the file. On a mistake the old config stays. Returns a message to show.
    @discardableResult
    func load(quiet: Bool = false) -> (ok: Bool, message: String) {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            config = TesseraConfig()
            lastError = nil
            loadedDate = nil
            notify()
            return (true, "No config file at \(Self.tilde(url)); using Settings")
        }
        loadedDate = modified(url)
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            config = try TesseraConfig.parse(text)
            lastError = nil
            apply()
            notify()
            let message = config.warnings.isEmpty
                ? "Config loaded"
                : "Config loaded with \(config.warnings.count) problem\(config.warnings.count == 1 ? "" : "s"): " + config.warnings[0]
            for warning in config.warnings { Log.error("Config: \(warning)") }
            if !quiet, !config.warnings.isEmpty { Notice.shared.show(message) }
            Log.info(message)
            return (config.warnings.isEmpty, config.warnings.isEmpty ? message : ([message] + config.warnings.dropFirst()).joined(separator: "\n"))
        } catch let error as TOMLError {
            lastError = "\(Self.tilde(url)) \(error)"
        } catch {
            lastError = "\(Self.tilde(url)): \(error.localizedDescription)"
        }
        let message = "Config not loaded — \(lastError ?? "unknown problem"). The last good config stays."
        Log.error(message)
        if !quiet { Notice.shared.show(message) }
        return (false, message)
    }

    /// Settings the file names win over Settings.
    private func apply() {
        let s = Settings.shared
        let c = config
        if let v = c.frontLimit, v != s.frontLimit { s.frontLimit = v }
        if let v = c.mainRatio, v != s.mainRatio { s.mainRatio = v }
        if let v = c.dragToSnap, v != s.dragToSnap { s.dragToSnap = v }
        if let v = c.restoreSizeOnDrag, v != s.restoreSizeOnDrag { s.restoreSizeOnDrag = v }
        if let v = c.cycleSizes, v != s.cycleSizes { s.cycleSizes = v }
        if let v = c.ignoredApps, v != s.ignoredApps { s.ignoredApps = v }
        if let v = c.accordionPadding, Double(v) != s.accordionPadding { s.accordionPadding = Double(v) }
        if let v = c.dim, v != s.dim { s.dim = v }
        if let v = c.dimAmount, v != s.dimAmount { s.dimAmount = v }
        if let v = c.border, v != s.border { s.border = v }
        if let v = c.borderWidth, Double(v) != s.borderWidth { s.borderWidth = Double(v) }
        if let v = c.borderColor, v != s.borderColor { s.borderColor = v }
        if let v = c.showDesktopNumber, v != s.showDesktopNumber { s.showDesktopNumber = v }
        if let v = c.focusFollowsMouse, v != s.focusFollowsMouse { s.focusFollowsMouse = v }
        if let v = c.moveModifier, v != s.moveModifier { s.moveModifier = v }
        if let v = c.unhideHiddenApps, v != s.unhideHiddenApps { s.unhideHiddenApps = v }
        if let v = c.startAtLogin, v != s.openAtLogin { s.openAtLogin = v }
        // Layouts by screen pattern: the screens connected now.
        let displays = Screens.all()
        var layouts = s.layouts
        for display in displays {
            let context = Screens.context(of: display, in: displays)
            if let match = c.layouts.first(where: { DisplayPattern.matches($0.pattern, context) }) {
                layouts[display.stableID] = match.style
            } else if let style = c.layout {
                layouts[display.stableID] = style
            }
        }
        if layouts != s.layouts { s.layouts = layouts }
        if let v = c.autoTile, v != s.autoTile { s.autoTile = v }   // Last, so tiling starts with the new layouts.
        Shortcuts.shared.reload()
    }

    private func notify() {
        for listener in listeners { listener() }
        watch()
    }

    /// With auto-reload-config on, the file is read again whenever it changes (checked every second).
    private func watch() {
        guard config.autoReload == true else {
            watchdog.stop()
            return
        }
        watchdog.start(every: 1) { [weak self] in
            guard let self else { return }
            let url = self.fileURL
            let now = self.modified(url)
            if now != self.loadedDate {
                Log.info("Config file changed: reloading")
                self.load()
            }
        }
    }

    private func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Opens the file in your text editor, making it from the template first if there isn't one.
    func openInEditor() {
        let url = fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try TesseraConfig.template.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Notice.shared.show("Couldn't make \(Self.tilde(url)): \(error.localizedDescription)")
                return
            }
            load(quiet: true)
        }
        let config = NSWorkspace.OpenConfiguration()
        if let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit"),
           NSWorkspace.shared.urlForApplication(toOpen: url) == nil {
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Where AeroSpace keeps its config.
    static var aeroSpaceFiles: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var list = [home.appendingPathComponent(".aerospace.toml")]
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            list.append(URL(fileURLWithPath: xdg).appendingPathComponent("aerospace/aerospace.toml"))
        }
        list.append(home.appendingPathComponent(".config/aerospace/aerospace.toml"))
        return list
    }

    /// Copies an AeroSpace config into Tessera's file (keeping any old file as .bak) and loads it.
    /// Returns what happened, to show.
    @discardableResult
    func importAeroSpace(from source: URL? = nil) -> (ok: Bool, message: String) {
        guard let from = source ?? Self.aeroSpaceFiles.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return (false, "No AeroSpace config found (looked for ~/.aerospace.toml and ~/.config/aerospace/aerospace.toml)")
        }
        do {
            let text = try String(contentsOf: from, encoding: .utf8)
            let result = try TesseraConfig.importAeroSpace(text)
            let url = fileURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let backup = url.appendingPathExtension("bak")
                try? FileManager.default.removeItem(at: backup)
                try FileManager.default.copyItem(at: url, to: backup)
            }
            try result.text.write(to: url, atomically: true, encoding: .utf8)
            load(quiet: true)
            let skipped = result.warnings.isEmpty ? "everything carried over" : "\(result.warnings.count) parts skipped (listed at the top of the file)"
            return (true, "Imported \(Self.tilde(from)) into \(Self.tilde(url)): \(skipped)")
        } catch {
            return (false, "Couldn't import \(Self.tilde(from)): \(error)")
        }
    }

    static func tilde(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
