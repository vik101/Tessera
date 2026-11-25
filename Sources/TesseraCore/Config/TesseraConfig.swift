import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A screen, as config patterns see it.
public struct DisplayContext: Equatable, Sendable {
    public var name: String
    /// 1 for the left-most screen.
    public var index: Int
    public var isMain: Bool
    public var count: Int
    public init(name: String, index: Int, isMain: Bool, count: Int) {
        self.name = name
        self.index = index
        self.isMain = isMain
        self.count = count
    }
}

public enum DisplayPattern {
    /// `main`, `secondary` (the other one, when there are two), a number counted from the left,
    /// or part of the screen's name (a regular expression, any case).
    public static func matches(_ pattern: String, _ display: DisplayContext) -> Bool {
        switch pattern.lowercased() {
        case "main": return display.isMain
        case "secondary": return !display.isMain && display.count == 2
        default:
            if let n = Int(pattern) { return display.index == n }
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(display.name.startIndex..., in: display.name)
                return regex.firstMatch(in: display.name, range: range) != nil
            }
            return display.name.localizedCaseInsensitiveContains(pattern)
        }
    }
}

/// A number that may differ per screen: `outer.top = [{ monitor.main = 40 }, 8]`.
public struct PerDisplay: Equatable, Sendable {
    public struct Case: Equatable, Sendable {
        public var pattern: String
        public var value: CGFloat
    }
    public var value: CGFloat
    public var cases: [Case]

    public init(_ value: CGFloat, cases: [Case] = []) {
        self.value = value
        self.cases = cases
    }

    public func value(for display: DisplayContext) -> CGFloat {
        cases.first { DisplayPattern.matches($0.pattern, display) }?.value ?? value
    }
}

/// Space between windows (inner) and at the screen's edges (outer), in points.
public struct Gaps: Equatable, Sendable {
    public var innerHorizontal: PerDisplay
    public var innerVertical: PerDisplay
    public var outerLeft: PerDisplay
    public var outerRight: PerDisplay
    public var outerTop: PerDisplay
    public var outerBottom: PerDisplay

    public init(inner: CGFloat, outer: CGFloat) {
        innerHorizontal = PerDisplay(inner)
        innerVertical = PerDisplay(inner)
        outerLeft = PerDisplay(outer)
        outerRight = PerDisplay(outer)
        outerTop = PerDisplay(outer)
        outerBottom = PerDisplay(outer)
    }

    /// For one screen: the gap between windows, and the area the layout plans in.
    ///
    /// Layouts put a full gap at the area's edges and half a gap on each side of an inner edge.
    /// Growing the area by (inner − outer) on each side makes the edges come out at the outer gap.
    public func resolve(visible: CGRect, display: DisplayContext) -> (gap: CGFloat, area: CGRect) {
        let inner = max(innerHorizontal.value(for: display), innerVertical.value(for: display))
        let left = outerLeft.value(for: display), right = outerRight.value(for: display)
        let top = outerTop.value(for: display), bottom = outerBottom.value(for: display)
        let area = CGRect(x: visible.minX + left - inner, y: visible.minY + top - inner,
                          width: visible.width - left - right + 2 * inner, height: visible.height - top - bottom + 2 * inner)
        return (inner, area)
    }
}

public struct KeyBinding: Equatable, Sendable {
    /// As written in the file: `alt-shift-h`.
    public var key: String
    public var combo: KeyCombo
    /// One or more command lines, run in order.
    public var commands: [String]
    public var line: Int
}

/// What to do with new windows that match (AeroSpace's `on-window-detected`).
public struct WindowRule: Equatable, Sendable {
    public var appID: String?
    /// A regular expression found anywhere in the app's name, any case.
    public var appName: String?
    /// A regular expression found anywhere in the window's title, any case.
    public var title: String?
    public var desktop: Int?
    /// Only for windows found when Tessera starts (true), or only for new ones (false).
    public var duringStartup: Bool?
    public var commands: [String]
    /// Keep looking at later rules after this one matches.
    public var checkFurther: Bool
    public var line: Int

    public init(appID: String? = nil, appName: String? = nil, title: String? = nil, desktop: Int? = nil,
                duringStartup: Bool? = nil, commands: [String], checkFurther: Bool = false, line: Int = 0) {
        self.appID = appID
        self.appName = appName
        self.title = title
        self.desktop = desktop
        self.duringStartup = duringStartup
        self.commands = commands
        self.checkFurther = checkFurther
        self.line = line
    }

    public func matches(appID: String, appName: String, title: String, desktop: Int?, startup: Bool) -> Bool {
        if let want = self.appID, want != appID { return false }
        if let pattern = self.appName, !Self.search(pattern, in: appName) { return false }
        if let pattern = self.title, !Self.search(pattern, in: title) { return false }
        if let want = self.desktop, want != desktop { return false }
        if let want = duringStartup, want != startup { return false }
        return true
    }

    /// The commands to run for a window: every matching rule up to the first that doesn't say keep looking.
    public static func commands(for rules: [WindowRule], appID: String, appName: String, title: String,
                                desktop: Int?, startup: Bool) -> [String] {
        var out: [String] = []
        for rule in rules where rule.matches(appID: appID, appName: appName, title: title, desktop: desktop, startup: startup) {
            out += rule.commands
            if !rule.checkFurther { break }
        }
        return out
    }

    static func search(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text.localizedCaseInsensitiveContains(pattern)
        }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

/// Built-in key sets. Tessera's own keys (Rectangle's, plus ⌃⌥ for auto-tile) are always the base,
/// except with `none`; the others add their tool's keys on top.
public enum ShortcutPreset: String, Sendable, CaseIterable {
    case tessera, spectacle, aerospace, spacetile, none

    public var title: String {
        switch self {
        case .tessera: "Tessera (Rectangle's keys)"
        case .spectacle: "Spectacle"
        case .aerospace: "AeroSpace"
        case .spacetile: "Spacetile"
        case .none: "None (only the config file's)"
        }
    }

    /// The extra bindings this preset adds, by mode.
    public var bindings: [String: [(key: String, command: String)]] {
        switch self {
        case .tessera, .none:
            return [:]
        case .spectacle:
            return ["main": [
                ("cmd-alt-left", "place left-half"), ("cmd-alt-right", "place right-half"),
                ("cmd-alt-up", "place top-half"), ("cmd-alt-down", "place bottom-half"),
                ("cmd-alt-f", "place maximize"), ("cmd-alt-c", "place center"),
                ("cmd-ctrl-left", "place top-left"), ("cmd-ctrl-right", "place top-right"),
                ("cmd-ctrl-shift-left", "place bottom-left"), ("cmd-ctrl-shift-right", "place bottom-right"),
                ("cmd-ctrl-alt-right", "place next-display"), ("cmd-ctrl-alt-left", "place previous-display"),
                ("ctrl-alt-shift-right", "grow"), ("ctrl-alt-shift-left", "shrink"),
            ]]
        case .aerospace:
            var main: [(key: String, command: String)] = [
                ("alt-slash", "layout tiles horizontal vertical"), ("alt-comma", "layout accordion horizontal vertical"),
                ("alt-h", "focus left"), ("alt-j", "focus down"), ("alt-k", "focus up"), ("alt-l", "focus right"),
                ("alt-shift-h", "move left"), ("alt-shift-j", "move down"), ("alt-shift-k", "move up"), ("alt-shift-l", "move right"),
                ("alt-minus", "resize smart -50"), ("alt-equal", "resize smart +50"),
                ("alt-tab", "workspace-back-and-forth"), ("alt-shift-semicolon", "mode service"),
            ]
            for n in 1...9 {
                main.append(("alt-\(n)", "workspace \(n)"))
                main.append(("alt-shift-\(n)", "move-node-to-workspace \(n)"))
            }
            return [
                "main": main,
                "service": [
                    ("esc", "reload-config; mode main"), ("r", "flatten-workspace-tree; mode main"),
                    ("f", "layout floating tiling; mode main"), ("backspace", "close-all-windows-but-current; mode main"),
                    ("alt-shift-h", "join-with left; mode main"), ("alt-shift-j", "join-with down; mode main"),
                    ("alt-shift-k", "join-with up; mode main"), ("alt-shift-l", "join-with right; mode main"),
                ],
            ]
        case .spacetile:
            var main: [(key: String, command: String)] = [
                ("alt-left", "focus west"), ("alt-right", "focus east"), ("alt-up", "focus north"), ("alt-down", "focus south"),
                ("alt-s", "layout stack"), ("alt-d", "layout tree"), ("alt-n", "stack next"), ("alt-p", "stack prev"),
                ("alt-0", "space 10"),
            ]
            for n in 1...9 {
                main.append(("alt-\(n)", "space \(n)"))
                main.append(("alt-shift-\(n)", "send \(n)"))
            }
            return ["main": main]
        }
    }
}

/// Tessera's config file (~/.config/tessera/tessera.toml). Every key is optional: anything left
/// out keeps the value from Settings. AeroSpace's keys are read too, so an aerospace.toml works.
public struct TesseraConfig: Equatable, Sendable {
    public var autoTile: Bool?
    public var startAtLogin: Bool?
    public var autoReload: Bool?
    public var unhideHiddenApps: Bool?
    public var afterStartup: [String] = []
    /// The layout for every screen, and per-screen ones by pattern.
    public var layout: LayoutStyle?
    public var layouts: [(pattern: String, style: LayoutStyle)] = []
    public var frontLimit: FrontLimit?
    public var mainRatio: Double?
    public var gaps: Gaps?
    public var accordionPadding: CGFloat?
    public var defaultContainerLayout: ContainerLayout?
    /// nil: by the screen's shape.
    public var defaultOrientation: Orientation?
    public var preset: ShortcutPreset?
    public var keyMapping: KeyMapping = .qwerty
    /// Binding modes: `main` is the usual one.
    public var modes: [String: [KeyBinding]] = [:]
    public var rules: [WindowRule] = []
    public var onFocusChanged: [String] = []
    public var onDisplayFocusChanged: [String] = []
    public var onModeChanged: [String] = []
    /// A program and its arguments, run when the desktop changes.
    public var execOnDesktopChange: [String] = []
    public var inheritEnvironment: Bool = true
    public var environment: [String: String] = [:]
    public var dragToSnap: Bool?
    public var restoreSizeOnDrag: Bool?
    public var cycleSizes: Bool?
    public var ignoredApps: [String]?
    /// The modifier that lets you drag a window from anywhere in it: "fn", "ctrl-cmd", or "none".
    public var moveModifier: String?
    public var focusFollowsMouse: Bool?
    public var dim: Bool?
    public var dimAmount: Double?
    public var border: Bool?
    public var borderWidth: CGFloat?
    public var borderColor: String?
    public var showDesktopNumber: Bool?
    /// Problems found while reading: unknown keys, commands that don't parse. Each names its line.
    public var warnings: [String] = []

    public init() {}

    public static func == (a: TesseraConfig, b: TesseraConfig) -> Bool {
        a.autoTile == b.autoTile && a.layout == b.layout && a.layouts.map(\.pattern) == b.layouts.map(\.pattern)
            && a.layouts.map(\.style) == b.layouts.map(\.style) && a.frontLimit == b.frontLimit && a.gaps == b.gaps
            && a.modes == b.modes && a.rules == b.rules && a.preset == b.preset && a.warnings == b.warnings
            && a.afterStartup == b.afterStartup && a.onFocusChanged == b.onFocusChanged && a.dim == b.dim && a.border == b.border
    }

    /// The default file, written when you choose Open Config File and there isn't one yet.
    public static let template = """
    # Tessera's config file. Every setting is optional: anything left out keeps its value from Settings.
    # Reload with `tessera reload-config`, or turn on auto-reload-config below.
    # AeroSpace's settings and commands work here too.

    auto-reload-config = true
    # auto-tile = true
    # layout = 'auto'                 # auto, columns, rows, grid, main-and-side, tree, stack, float
    # front-limit = 'auto'            # or a number, or 'none'
    # preset = 'tessera'              # also: spectacle, aerospace, spacetile, none

    # [gaps]
    # inner.horizontal = 8
    # inner.vertical = 8
    # outer.left = 8
    # outer.right = 8
    # outer.top = 8
    # outer.bottom = 8

    # [mode.main.binding]
    # alt-h = 'focus left'
    # alt-shift-h = 'move left'
    # alt-1 = 'desktop 1'
    # alt-shift-1 = 'send-to-desktop 1'
    # alt-r = 'mode resize'

    # [mode.resize.binding]
    # h = 'resize width -50'
    # l = 'resize width +50'
    # esc = 'mode main'

    # [[on-window-detected]]
    # if.app-id = 'com.apple.systempreferences'
    # run = 'layout floating'
    """

    // MARK: Reading

    public static func parse(_ text: String) throws -> TesseraConfig {
        try TesseraConfig(table: TOML.parse(text))
    }

    public init(table t: TOMLTable) {
        var c = TesseraConfig()
        func warn(_ key: String, _ message: String, line: Int? = nil) {
            let at = line ?? t.lines[key]
            c.warnings.append((at.map { "line \($0): " } ?? "") + message)
        }
        func bool(_ key: String) -> Bool? {
            guard let value = t[key] else { return nil }
            guard let b = value.bool else { warn(key, "\(key) should be true or false"); return nil }
            return b
        }
        func valid(_ list: [String], key: String, line: Int?) -> [String] {
            list.filter { text in
                do {
                    _ = try CommandParser.parse(text)
                    return true
                } catch {
                    c.warnings.append((line.map { "line \($0): " } ?? "") + "\(key): “\(text)” — \(error)")
                    return false
                }
            }
        }
        func commands(_ key: String) -> [String] {
            guard let value = t[key] else { return [] }
            guard let list = value.strings else { warn(key, "\(key) should be a command or a list of commands"); return [] }
            return valid(list, key: key, line: t.lines[key])
        }

        let known: Set<String> = [
            "config-version", "auto-tile", "start-at-login", "auto-reload-config", "automatically-unhide-macos-hidden-apps",
            "unhide-hidden-apps", "after-startup-command", "after-startup-commands", "layout", "layouts", "front-limit",
            "main-ratio", "gaps", "accordion-padding", "default-root-container-layout", "default-root-container-orientation",
            "preset", "builtin-shortcuts", "key-mapping", "mode", "on-window-detected", "on-focus-changed",
            "on-focused-monitor-changed", "on-display-focus-changed", "on-mode-changed", "exec-on-workspace-change",
            "exec-on-desktop-change", "exec", "drag-to-snap", "restore-size-on-drag", "cycle-sizes", "ignored-apps",
            "mouse", "focus-follows-mouse", "appearance", "dim", "dim-amount", "border", "border-width", "border-color",
            "show-desktop-number", "enable-normalization-flatten-containers",
            "enable-normalization-opposite-orientation-for-nested-containers",
            "persistent-workspaces", "workspace-to-monitor-force-assignment",
        ]
        for key in t.keys where !known.contains(key) { warn(key, "“\(key)” isn't a Tessera setting; it's ignored") }

        c.autoTile = bool("auto-tile")
        c.startAtLogin = bool("start-at-login")
        c.autoReload = bool("auto-reload-config")
        c.unhideHiddenApps = bool("automatically-unhide-macos-hidden-apps") ?? bool("unhide-hidden-apps")
        c.afterStartup = commands("after-startup-command") + commands("after-startup-commands")
        c.onFocusChanged = commands("on-focus-changed")
        c.onDisplayFocusChanged = commands("on-focused-monitor-changed") + commands("on-display-focus-changed")
        c.onModeChanged = commands("on-mode-changed")
        c.dragToSnap = bool("drag-to-snap")
        c.restoreSizeOnDrag = bool("restore-size-on-drag")
        c.cycleSizes = bool("cycle-sizes")

        for key in ["exec-on-workspace-change", "exec-on-desktop-change"] {
            guard let value = t[key] else { continue }
            if let argv = value.strings, !argv.isEmpty { c.execOnDesktopChange = argv } else { warn(key, "\(key) should be a list: a program, then its arguments") }
        }

        for key in ["enable-normalization-flatten-containers", "enable-normalization-opposite-orientation-for-nested-containers"] {
            if bool(key) == false { warn(key, "\(key): Tessera always keeps its tree tidy, so this can't be turned off") }
        }
        for key in ["persistent-workspaces", "workspace-to-monitor-force-assignment"] where t[key] != nil {
            warn(key, "\(key) needs AeroSpace's own workspaces; Tessera uses macOS desktops, so it's ignored")
        }

        if let value = t["layout"] {
            if let raw = value.string, let style = Self.style(raw) { c.layout = style } else { warn("layout", "layout should be one of " + LayoutStyle.allCases.map(\.urlName).joined(separator: ", ")) }
        }
        if let table = t["layouts"]?.table {
            for key in table.keys {
                if let raw = table[key]?.string, let style = Self.style(raw) {
                    c.layouts.append((key, style))
                } else {
                    warn("layouts", "layouts.\(key) should be a layout name", line: table.lines[key])
                }
            }
        }
        if let value = t["front-limit"] {
            switch value {
            case .string(let s) where s.lowercased() == "auto": c.frontLimit = .auto
            case .string(let s) where ["none", "off", "unlimited"].contains(s.lowercased()): c.frontLimit = .unlimited
            case .integer(let n) where (1...12).contains(n): c.frontLimit = .fixed(n)
            default: warn("front-limit", "front-limit should be 'auto', 'none' or a number from 1 to 12")
            }
        }
        if let value = t["main-ratio"] {
            if let n = value.number, (0.2...0.8).contains(n) { c.mainRatio = n } else { warn("main-ratio", "main-ratio should be between 0.2 and 0.8") }
        }
        if let value = t["accordion-padding"] {
            if let n = value.number, n >= 0 { c.accordionPadding = CGFloat(n) } else { warn("accordion-padding", "accordion-padding should be a number of points") }
        }
        if let raw = t["default-root-container-layout"]?.string {
            if let layout = ContainerLayout(rawValue: raw) { c.defaultContainerLayout = layout } else { warn("default-root-container-layout", "default-root-container-layout should be tiles or accordion") }
        }
        if let raw = t["default-root-container-orientation"]?.string {
            switch raw {
            case "auto": c.defaultOrientation = nil
            case "horizontal": c.defaultOrientation = .horizontal
            case "vertical": c.defaultOrientation = .vertical
            default: warn("default-root-container-orientation", "default-root-container-orientation should be horizontal, vertical or auto")
            }
        }
        if let raw = t["preset"]?.string {
            if let preset = ShortcutPreset(rawValue: raw.lowercased() == "rectangle" ? "tessera" : raw.lowercased()) { c.preset = preset } else {
                warn("preset", "preset should be one of " + ShortcutPreset.allCases.map(\.rawValue).joined(separator: ", "))
            }
        }
        if bool("builtin-shortcuts") == false { c.preset = ShortcutPreset.none }
        if let apps = t["ignored-apps"] {
            if let list = apps.strings { c.ignoredApps = list } else { warn("ignored-apps", "ignored-apps should be a list of app ids") }
        }

        // Key mapping.
        var aliases: [String: String] = [:]
        if let mapping = t["key-mapping"]?.table {
            if let raw = mapping["preset"]?.string {
                if let m = KeyMapping(rawValue: raw.lowercased()) { c.keyMapping = m } else { warn("key-mapping", "key-mapping.preset should be qwerty, dvorak or colemak", line: mapping.lines["preset"]) }
            }
            if let custom = mapping["key-notation-to-key-code"]?.table {
                for key in custom.keys { if let to = custom[key]?.string { aliases[key] = to } }
            }
        }

        // Gaps.
        if let g = t["gaps"]?.table {
            var gaps = Gaps(inner: 0, outer: 0)
            func read(_ path: [String], _ set: (PerDisplay) -> Void) {
                guard let value = g.value(at: path) else { return }
                let name = "gaps." + path.joined(separator: ".")
                if let n = value.number {
                    set(PerDisplay(CGFloat(max(n, 0))))
                } else if let list = value.array {
                    var cases: [PerDisplay.Case] = []
                    var fallback: CGFloat = 0
                    for item in list {
                        if let n = item.number {
                            fallback = CGFloat(max(n, 0))
                        } else if let monitor = item.table?["monitor"]?.table {
                            for pattern in monitor.keys {
                                if let n = monitor[pattern]?.number { cases.append(.init(pattern: pattern, value: CGFloat(max(n, 0)))) }
                            }
                        } else {
                            warn("gaps", "\(name): each item is a number or { monitor.<pattern> = number }")
                        }
                    }
                    set(PerDisplay(fallback, cases: cases))
                } else {
                    warn("gaps", "\(name) should be a number of points")
                }
            }
            if let n = g["inner"]?.number { gaps.innerHorizontal = PerDisplay(CGFloat(n)); gaps.innerVertical = PerDisplay(CGFloat(n)) }
            if let n = g["outer"]?.number {
                gaps.outerLeft = PerDisplay(CGFloat(n)); gaps.outerRight = PerDisplay(CGFloat(n))
                gaps.outerTop = PerDisplay(CGFloat(n)); gaps.outerBottom = PerDisplay(CGFloat(n))
            }
            read(["inner", "horizontal"]) { gaps.innerHorizontal = $0 }
            read(["inner", "vertical"]) { gaps.innerVertical = $0 }
            read(["outer", "left"]) { gaps.outerLeft = $0 }
            read(["outer", "right"]) { gaps.outerRight = $0 }
            read(["outer", "top"]) { gaps.outerTop = $0 }
            read(["outer", "bottom"]) { gaps.outerBottom = $0 }
            if gaps.innerHorizontal != gaps.innerVertical {
                warn("gaps", "gaps: inner.horizontal and inner.vertical differ; Tessera uses the larger for both")
            }
            c.gaps = gaps
        }

        // Binding modes.
        if let modes = t["mode"]?.table {
            for name in modes.keys {
                guard let bindings = modes[name]?.table?["binding"]?.table else {
                    warn("mode", "mode.\(name) needs a binding table: [mode.\(name).binding]", line: modes.lines[name])
                    continue
                }
                var list: [KeyBinding] = []
                var seen: [KeyCombo: String] = [:]
                for key in bindings.keys {
                    let line = bindings.lines[key] ?? 0
                    guard let commands = bindings[key]?.strings else {
                        c.warnings.append("line \(line): mode.\(name).binding.\(key) should be a command or a list of commands")
                        continue
                    }
                    let combo: KeyCombo
                    do {
                        combo = try KeyNotation.parse(key, mapping: c.keyMapping, aliases: aliases)
                    } catch {
                        c.warnings.append("line \(line): \(error)")
                        continue
                    }
                    if let other = seen[combo] {
                        c.warnings.append("line \(line): \(key) is the same key as \(other) in mode \(name); the first wins")
                        continue
                    }
                    let good = valid(commands, key: "mode.\(name).binding.\(key)", line: line)
                    guard good.count == commands.count else { continue }
                    seen[combo] = key
                    list.append(KeyBinding(key: key, combo: combo, commands: commands, line: line))
                }
                c.modes[name] = list
            }
        }

        // Window rules.
        if let list = t["on-window-detected"]?.array {
            for item in list {
                guard let rule = item.table else { continue }
                let line = rule.lines["run"] ?? rule.lines["if"] ?? 0
                guard let run = rule["run"]?.strings, !run.isEmpty else {
                    c.warnings.append("line \(line): on-window-detected needs run = 'command'")
                    continue
                }
                let commands = valid(run, key: "on-window-detected", line: line)
                guard !commands.isEmpty else { continue }
                var r = WindowRule(commands: commands, checkFurther: rule["check-further-callbacks"]?.bool ?? false, line: line)
                if let condition = rule["if"] {
                    if let table = condition.table {
                        r.appID = table["app-id"]?.string
                        r.appName = table["app-name-regex-substring"]?.string
                        r.title = table["window-title-regex-substring"]?.string
                        r.duringStartup = table["during-aerospace-startup"]?.bool ?? table["during-startup"]?.bool
                        if let d = table["workspace"] ?? table["desktop"] {
                            if let n = d.int ?? d.string.flatMap({ Int($0) }) {
                                r.desktop = n
                            } else {
                                c.warnings.append("line \(line): if.workspace “\(d.string ?? "")” isn't a desktop number; this rule is skipped")
                                continue
                            }
                        }
                        for key in table.keys where !["app-id", "app-name-regex-substring", "window-title-regex-substring",
                                                     "during-aerospace-startup", "during-startup", "workspace", "desktop"].contains(key) {
                            c.warnings.append("line \(line): if.\(key) isn't supported; it's ignored")
                        }
                    } else if let test = condition.string {
                        guard let parsed = Self.testCondition(test, into: &r) else {
                            c.warnings.append("line \(line): if = “\(test)” isn't supported (use if.app-id = '…'); this rule is skipped")
                            continue
                        }
                        _ = parsed
                    }
                }
                c.rules.append(r)
            }
        }

        // Exec.
        if let exec = t["exec"]?.table {
            c.inheritEnvironment = exec["inherit-env-vars"]?.bool ?? true
            if let env = exec["env-vars"]?.table {
                for key in env.keys { if let v = env[key]?.string { c.environment[key] = v } }
            }
        }

        // Mouse and appearance (top level or in their own tables).
        let mouse = t["mouse"]?.table
        if let ffm = t["focus-follows-mouse"] { c.focusFollowsMouse = ffm.bool ?? ffm.table?["enabled"]?.bool }
        if let v = mouse?["focus-follows-mouse"]?.bool { c.focusFollowsMouse = v }
        if let v = mouse?["move-modifier"]?.string {
            if Self.moveModifiers.contains(v.lowercased()) { c.moveModifier = v.lowercased() } else {
                c.warnings.append("mouse.move-modifier should be one of " + Self.moveModifiers.joined(separator: ", "))
            }
        }
        if let v = mouse?["drag-to-snap"]?.bool { c.dragToSnap = v }
        let look = t["appearance"]?.table
        func lookValue(_ key: String) -> TOMLValue? { t[key] ?? look?[key] }
        c.dim = lookValue("dim")?.bool
        c.dimAmount = lookValue("dim-amount")?.number.map { min(max($0, 0), 0.9) }
        c.border = lookValue("border")?.bool
        c.borderWidth = lookValue("border-width")?.number.map { CGFloat(min(max($0, 1), 20)) }
        if let color = lookValue("border-color")?.string {
            if Self.hexColor(color) != nil { c.borderColor = color } else { c.warnings.append("border-color should look like '#4c9aff'") }
        }
        c.showDesktopNumber = lookValue("show-desktop-number")?.bool
        self = c
    }

    public static let moveModifiers = ["fn", "ctrl-cmd", "cmd-alt", "ctrl-alt", "none"]

    static func style(_ raw: String) -> LayoutStyle? {
        if let choice = try? CommandParser.layoutChoice(raw), case .style(let style) = choice { return style }
        return nil
    }

    /// `test %{app-bundle-id} = com.example` and `test %{app-name} ~= regex`.
    static func testCondition(_ text: String, into rule: inout WindowRule) -> Bool? {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count == 4, words[0] == "test" else { return nil }
        let value = words[3].trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        switch (words[1], words[2]) {
        case ("%{app-bundle-id}", "="): rule.appID = value
        case ("%{app-name}", "~="), ("%{app-name}", "="): rule.appName = words[2] == "=" ? "^" + NSRegularExpression.escapedPattern(for: value) + "$" : value
        case ("%{window-title}", "~="), ("%{window-title}", "="): rule.title = words[2] == "=" ? "^" + NSRegularExpression.escapedPattern(for: value) + "$" : value
        case ("%{workspace}", "="): guard let n = Int(value) else { return nil }; rule.desktop = n
        default: return nil
        }
        return true
    }

    /// `#4c9aff` → red, green, blue (0…1).
    public static func hexColor(_ text: String) -> (red: Double, green: Double, blue: Double)? {
        var hex = text.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    /// The bindings for a mode: the preset's (or none), then the file's, which win on the same key.
    public func bindings(for mode: String) -> [KeyBinding] {
        var result: [KeyBinding] = []
        var used = Set<KeyCombo>()
        for binding in modes[mode] ?? [] where used.insert(binding.combo).inserted { result.append(binding) }
        for (key, command) in (preset ?? .tessera).bindings[mode] ?? [] {
            guard let combo = try? KeyNotation.parse(key), used.insert(combo).inserted else { continue }
            result.append(KeyBinding(key: key, combo: combo, commands: [command], line: 0))
        }
        return result
    }

    /// An aerospace.toml made ready for Tessera: the same file (Tessera reads AeroSpace's keys and
    /// commands), with a note at the top of what won't work here.
    public static func importAeroSpace(_ text: String) throws -> (text: String, warnings: [String]) {
        let config = try parse(text)
        var header = "# Imported from AeroSpace on \(ISO8601DateFormatter().string(from: Date()).prefix(10)).\n"
        header += "# Tessera reads AeroSpace's settings and commands. Workspaces are your macOS desktops, numbered 1, 2, 3…\n"
        if config.warnings.isEmpty {
            header += "# Everything here works in Tessera.\n"
        } else {
            header += "# These parts don't work in Tessera and are skipped:\n"
            for warning in config.warnings { header += "#   - \(warning)\n" }
        }
        return (header + "\n" + text, config.warnings)
    }

    /// Every mode named in the file or the preset.
    public var modeNames: [String] {
        var names = Set(modes.keys).union((preset ?? .tessera).bindings.keys)
        names.insert("main")
        return names.sorted { $0 == "main" ? true : $1 == "main" ? false : $0 < $1 }
    }
}
