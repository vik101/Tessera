import AppKit
import TesseraCore

/// Answers questions from the command line: which windows, desktops, screens, apps and modes there are.
@MainActor
enum QueryRunner {
    static func answer(_ query: Query) -> (ok: Bool, text: String) {
        switch query {
        case .version:
            return (true, "Tessera \(AppInfo.version)")
        case .help(let topic):
            if let topic {
                guard let text = CommandHelp.detail(topic) else { return (false, "No command “\(topic)”. Run `tessera help` for the list.") }
                return (true, text)
            }
            return (true, CommandHelp.overview)
        case .windows(let scope, let app, let pid, let output):
            return (true, render(windows(scope, app: app, pid: pid), output,
                                 defaultFormat: "%{window-id} | %{app-name} | %{window-title}"))
        case .desktops(let focused, let output):
            var rows = desktops()
            if focused { rows = rows.filter { $0["focused"] as? Bool == true } }
            return (true, render(rows, output, defaultFormat: "%{display-name} | %{desktop}%{current} | %{layout} | %{window-count} windows"))
        case .displays(let focused, let output):
            var rows = displays()
            if focused { rows = rows.filter { $0["focused"] as? Bool == true } }
            return (true, render(rows, output, defaultFormat: "%{display-number} | %{display-name} | desktop %{desktop} | %{layout}"))
        case .apps(let output):
            let rows: [[String: Any]] = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map { app in
                ["app-name": app.displayName, "app-bundle-id": app.bundleIdentifier ?? "", "app-pid": Int(app.processIdentifier),
                 "hidden": app.isHidden]
            }
            return (true, render(rows, output, defaultFormat: "%{app-pid} | %{app-bundle-id} | %{app-name}"))
        case .modes(let current, let output):
            let names = current ? [Shortcuts.shared.mode] : Shortcuts.shared.modes
            let rows: [[String: Any]] = names.map { ["mode": $0, "current": $0 == Shortcuts.shared.mode] }
            return (true, render(rows, output, defaultFormat: "%{mode}"))
        case .tree(let output):
            let displays = Screens.ordered(Screens.all())
            let rows: [[String: Any]] = displays.map { display in
                ["display-name": display.name, "display-id": display.stableID,
                 "layout": AutoTiler.shared.currentStyle(on: display).urlName,
                 "tree": AutoTiler.shared.treeText(on: display) ?? ""]
            }
            return (true, render(rows, output, defaultFormat: "%{display-name} | %{layout} | %{tree}"))
        case .config(let key, let path, let output):
            let store = ConfigStore.shared
            if path { return (true, store.fileURL.path) }
            if let key {
                guard let text = try? String(contentsOf: store.fileURL, encoding: .utf8), let table = try? TOML.parse(text) else {
                    return (false, "No config file at \(store.fileURL.path)")
                }
                guard let value = table.value(at: key.split(separator: ".").map(String.init)) else { return (false, "“\(key)” isn't set") }
                return (true, json(plain(value)))
            }
            let summary: [String: Any] = [
                "path": store.fileURL.path, "exists": store.fileExists, "error": store.lastError ?? "",
                "warnings": store.config.warnings, "modes": store.config.modeNames,
                "rules": store.config.rules.count, "preset": Settings.shared.shortcutPreset.rawValue,
            ]
            return (true, output.json ? json(summary) : summary.sorted { $0.key < $1.key }.map { "\($0.key): \(text($0.value))" }.joined(separator: "\n"))
        case .subscribe:
            return (false, "subscribe only works from the command line tool")
        }
    }

    // MARK: Gathering

    static func windows(_ scope: WindowScope, app: String?, pid: Int?) -> [[String: Any]] {
        let registry = WindowRegistry.shared
        let tiler = AutoTiler.shared
        let displays = Screens.all()
        let ordered = Screens.ordered(displays)
        let focused = registry.focusedWindow()?.id
        var list: [TrackedWindow]
        switch scope {
        case .focused:
            list = registry.focusedWindow().map { [$0] } ?? []
        case .all:
            registry.rescan()
            list = registry.windows.values.filter { $0.element.subrole == kAXStandardWindowSubrole }
        default:
            list = WindowServer.onScreen().filter { $0.layer == 0 }.compactMap { info in
                guard let window = registry.window(info.id), window.isStandard else { return nil }
                return window
            }
        }
        var rows: [[String: Any]] = []
        for window in list {
            let frame = window.frame ?? .zero
            let display = Screens.display(for: frame, in: displays)
            let space = Spaces.spaces(of: window.id).first
            let desktop = space.flatMap(Desktops.number(of:))
            if case .desktop(let n) = scope, desktop != n { continue }
            if case .display(let target) = scope {
                guard let wanted = WindowActions.display(target, from: WindowActions.display(of: registry.focusedWindow()), wrap: false),
                      display == wanted else { continue }
            }
            if let app, window.bundleID != app { continue }
            if let pid, Int(window.pid) != pid { continue }
            let state: String
            if window.element.isMinimized { state = "minimized" }
            else if window.element.isFullScreen { state = "fullscreen" }
            else if tiler.isWaiting(window.id) { state = "waiting" }
            else if tiler.isZoomed(window.id) { state = "zoomed" }
            else if tiler.isTiled(window) { state = "tiled" }
            else { state = "floating" }
            rows.append([
                "window-id": Int(window.id),
                "window-title": window.title,
                "app-name": window.appName,
                "app-bundle-id": window.bundleID,
                "app-pid": Int(window.pid),
                "display-name": display?.name ?? "",
                "display-number": display.flatMap { ordered.firstIndex(of: $0) }.map { $0 + 1 } ?? 0,
                "desktop": desktop ?? 0,
                "state": state,
                "focused": window.id == focused,
                "frame": [frame.minX, frame.minY, frame.width, frame.height].map { Int($0.rounded()) },
            ])
        }
        return rows
    }

    static func desktops() -> [[String: Any]] {
        let displays = Screens.ordered(Screens.all())
        let focusedDisplay = WindowActions.display(of: WindowRegistry.shared.focusedWindow())
        var counts: [UInt64: Int] = [:]
        for info in WindowServer.onScreen() where info.layer == 0 {
            guard let window = WindowRegistry.shared.window(info.id), window.isStandard else { continue }
            for space in Spaces.spaces(of: info.id) { counts[space, default: 0] += 1 }
        }
        var rows: [[String: Any]] = []
        for (i, display) in displays.enumerated() {
            guard let layout = Desktops.layout(of: display) else { continue }
            for (n, id) in layout.desktops.enumerated() {
                let current = id == layout.current
                rows.append([
                    "display-name": display.name, "display-number": i + 1, "desktop": n + 1,
                    "current": current ? " (showing)" : "", "showing": current,
                    "focused": current && display == focusedDisplay,
                    "layout": current ? AutoTiler.shared.currentStyle(on: display).urlName : "",
                    "window-count": current ? (counts[id] ?? 0) : 0,
                ])
            }
        }
        return rows
    }

    static func displays() -> [[String: Any]] {
        let displays = Screens.ordered(Screens.all())
        let focusedDisplay = WindowActions.display(of: WindowRegistry.shared.focusedWindow())
        return displays.enumerated().map { i, display in
            [
                "display-number": i + 1, "display-name": display.name, "display-id": display.stableID,
                "main": display.isMain, "focused": display == focusedDisplay,
                "frame": [display.frame.minX, display.frame.minY, display.frame.width, display.frame.height].map { Int($0) },
                "visible-frame": [display.visibleFrame.minX, display.visibleFrame.minY, display.visibleFrame.width, display.visibleFrame.height].map { Int($0) },
                "desktop": Desktops.layout(of: display)?.currentNumber ?? 0,
                "layout": AutoTiler.shared.currentStyle(on: display).urlName,
                "front-limit": AutoTiler.shared.frontLimit(on: display) ?? 0,
            ]
        }
    }

    // MARK: Output

    static func render(_ rows: [[String: Any]], _ output: ListOutput, defaultFormat: String) -> String {
        if output.count { return String(rows.count) }
        if output.json { return json(rows) }
        let format = output.format ?? defaultFormat
        if output.format == nil {
            let columns = format.components(separatedBy: " | ")
            return ListFormat.table(rows.map { row in columns.map { ListFormat.render($0, strings(row)) } })
        }
        return rows.map { ListFormat.render(format, strings($0)) }.joined(separator: "\n")
    }

    static func strings(_ row: [String: Any]) -> [String: String] {
        row.mapValues(text)
    }

    static func text(_ value: Any) -> String {
        switch value {
        case let b as Bool: return b ? "true" : "false"
        case let list as [Any]: return list.map(text).joined(separator: ",")
        default: return "\(value)"
        }
    }

    static func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value) || value is String || value is NSNumber,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) else {
            return "\(value)"
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// A TOML value as plain JSON-ready values.
    static func plain(_ value: TOMLValue) -> Any {
        switch value {
        case .string(let s), .datetime(let s): return s
        case .integer(let i): return i
        case .float(let d): return d
        case .bool(let b): return b
        case .array(let a): return a.map(plain)
        case .table(let t): return Dictionary(uniqueKeysWithValues: t.keys.compactMap { key in t[key].map { (key, plain($0)) } })
        }
    }
}
