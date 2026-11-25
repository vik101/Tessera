import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Tessera's command language: one text form for key bindings, the config file, links and the
// `tessera` command line tool. It reads Tessera's own command names, AeroSpace's (focus, move,
// join-with, workspace, move-node-to-workspace…) and Spacetile's (place, space, send, preselect…),
// so configs and scripts written for those tools work here.

public enum Toggle: String, Equatable, Sendable {
    case on, off, toggle

    init?(_ word: String?) {
        guard let word else { self = .toggle; return }
        switch word.lowercased() {
        case "on", "true", "yes", "enable": self = .on
        case "off", "false", "no", "disable": self = .off
        case "toggle": self = .toggle
        default: return nil
        }
    }

    /// The new state, given the current one.
    public func apply(to current: Bool) -> Bool {
        switch self {
        case .on: true
        case .off: false
        case .toggle: !current
        }
    }
}

/// A desktop (macOS Space) on the screen you're working on.
public enum DesktopTarget: Equatable, Sendable {
    /// Desktop 1, 2, 3… in Mission Control order (full-screen apps don't count).
    case number(Int)
    case next, previous
    /// The desktop you were on before this one.
    case last
}

public enum DisplayTarget: Equatable, Sendable {
    case direction(Direction)
    case next, previous
    /// Screens counted left to right, from 1.
    case number(Int)
    /// `main`, `secondary`, or part of a screen's name.
    case pattern(String)
}

public enum FocusTarget: Equatable, Sendable {
    case direction(Direction)
    /// The next or previous window in the layout's order.
    case next, previous
    /// The window you used before this one.
    case back
    case window(UInt32)
    /// The nth window in the layout's order, from 0 (AeroSpace's --dfs-index).
    case index(Int)
}

public enum SwapTarget: Equatable, Sendable {
    case direction(Direction)
    case next, previous
}

public enum SplitChoice: String, Equatable, Sendable {
    case horizontal, vertical, opposite, toggle
}

public enum ResizeDimension: String, Equatable, Sendable {
    /// Along the way the window's container runs (AeroSpace's `smart`).
    case smart
    case smartOpposite = "smart-opposite"
    case width, height
}

public enum ResizeAmount: Equatable, Sendable {
    case by(CGFloat)
    case to(CGFloat)
}

public enum MouseTarget: String, Equatable, Sendable, CaseIterable {
    case windowLazyCenter = "window-lazy-center"
    case windowForceCenter = "window-force-center"
    case displayLazyCenter = "monitor-lazy-center"
    case displayForceCenter = "monitor-force-center"
}

/// What `layout` can switch to. Several can be given: the first that changes something wins,
/// so `layout floating tiling` toggles.
public enum LayoutChoice: Equatable, Sendable {
    /// A layout for the whole desktop: auto, columns, rows, grid, main-and-side, tree, stack, float.
    case style(LayoutStyle)
    /// The Tree layout's container around the focused window: tiles or accordion, horizontal or vertical.
    case container(ContainerLayout?, Orientation?)
    /// Just the focused window: floating or tiled.
    case floating
    case tiling
}

public enum SetupRequest: Equatable, Sendable {
    case open(String)
    case number(Int)
    case save(String)
    case delete(String)
}

public enum Appearance: String, Equatable, Sendable, CaseIterable {
    /// The gaps between windows.
    case spacing
    /// A border around the focused window.
    case border
    /// Dims every window except the focused one.
    case dim
}

public enum VolumeChange: Equatable, Sendable {
    case up, down, muteToggle, muteOn, muteOff
    case set(Int)
}

/// Something a command does.
public enum Action: Equatable, Sendable {
    /// Anything a shortcut can run: a snap, a layout, Tile All, Send to Desktop 3, Open Setup 2…
    case command(Command)
    case layout([LayoutChoice])
    case focus(FocusTarget, wrap: Bool)
    case focusDisplay(DisplayTarget, wrap: Bool)
    /// Move the window one step through the layout (or snap it, when it isn't tiled).
    case move(Direction)
    case swap(SwapTarget, wrap: Bool, keepFocus: Bool)
    case join(Direction)
    case split(SplitChoice)
    /// Where the next window opens beside the focused one; nil cancels.
    case preselect(Direction?)
    case mirror(Orientation)
    case rotate(quarterTurns: Int)
    case balance
    case flatten
    case popOut
    case popIn
    case resize(ResizeDimension, ResizeAmount)
    /// Moves one edge of the focused tile (Spacetile's `border horizontal 100`).
    case border(Orientation, CGFloat)
    /// The window fills the desktop until you do it again (AeroSpace's `fullscreen`).
    case zoom(Toggle)
    case nativeFullScreen(Toggle)
    case minimize
    case close(quitIfLast: Bool)
    case closeOthers(quitIfLast: Bool)
    case float(Toggle)
    case keepInFront(Toggle)
    /// In the Stack layout: show the next (or previous) window.
    case stack(forward: Bool)
    case desktop(DesktopTarget)
    case sendToDesktop(DesktopTarget, follow: Bool)
    case sendToDisplay(DisplayTarget, follow: Bool, wrap: Bool)
    case retile
    /// Turns auto-tile on or off (AeroSpace's `enable`, Spacetile's `pause`).
    case enable(Toggle)
    case mode(String)
    case reloadConfig
    /// Runs a shell command without waiting for it.
    case exec(String)
    case moveMouse(MouseTarget)
    case setup(SetupRequest)
    case appearance(Appearance, Toggle)
    case volume(VolumeChange)
    case openSettings
    case triggerBinding(mode: String, key: String)
    case echo(String)
    case succeed
    case fail
}

/// How a list is printed.
public struct ListOutput: Equatable, Sendable {
    public var json = false
    public var count = false
    public var format: String?
    public init(json: Bool = false, count: Bool = false, format: String? = nil) {
        self.json = json
        self.count = count
        self.format = format
    }
}

public enum WindowScope: Equatable, Sendable {
    /// Windows on the desktops your screens show now.
    case visible
    case all
    case focused
    case desktop(Int)
    case display(DisplayTarget)
}

/// Things you can ask Tessera (from the command line).
public enum Query: Equatable, Sendable {
    case windows(WindowScope, app: String?, pid: Int?, ListOutput)
    case desktops(focused: Bool, ListOutput)
    case displays(focused: Bool, ListOutput)
    case apps(ListOutput)
    case modes(current: Bool, ListOutput)
    case tree(ListOutput)
    case config(key: String?, path: Bool, ListOutput)
    case version
    case help(String?)
    case subscribe([String])
}

public enum Invocation: Equatable, Sendable {
    /// An action, on the focused window unless a window id is given.
    case action(Action, window: UInt32?)
    case query(Query)
}

/// A line of commands: `a; b` runs both, `a && b` runs b if a worked, `a || b` runs b if a failed.
public struct Script: Equatable, Sendable {
    /// Statements (split by `;`), each a choice (split by `||`) of runs (split by `&&`).
    public var statements: [[[Invocation]]]

    public init(statements: [[[Invocation]]]) { self.statements = statements }

    /// Every invocation in order.
    public var invocations: [Invocation] { statements.flatMap { $0.flatMap { $0 } } }

    /// Runs the script. `run` does one invocation and says whether it worked.
    /// Returns whether the last statement worked.
    @discardableResult
    public func run(_ run: (Invocation) -> Bool) -> Bool {
        var ok = true
        for statement in statements {
            ok = false
            for chain in statement {
                ok = chain.allSatisfy(run)
                if ok { break }
            }
        }
        return ok
    }
}

public struct CommandError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public enum CommandParser {
    /// Reads a line of commands.
    public static func parse(_ text: String) throws -> Script {
        let tokens = try tokenize(text)
        var statements: [[[Invocation]]] = []
        var statement: [[Invocation]] = []
        var chain: [Invocation] = []
        var words: [String] = []
        func endCommand() throws {
            guard !words.isEmpty else { throw CommandError("a command is missing next to “;”, “&&” or “||”") }
            chain.append(try invocation(words))
            words = []
        }
        for token in tokens {
            switch token {
            case .word(let w): words.append(w)
            case .and: try endCommand()
            case .or:
                try endCommand()
                statement.append(chain)
                chain = []
            case .semicolon:
                if words.isEmpty && chain.isEmpty && statement.isEmpty { continue }
                try endCommand()
                statement.append(chain)
                statements.append(statement)
                chain = []
                statement = []
            }
        }
        if !words.isEmpty || !chain.isEmpty || !statement.isEmpty {
            try endCommand()
            statement.append(chain)
            statements.append(statement)
        }
        guard !statements.isEmpty else { throw CommandError("no command") }
        return Script(statements: statements)
    }

    /// Reads one command already split into words, as the command line passes them.
    public static func invocation(_ words: [String]) throws -> Invocation {
        guard let first = words.first else { throw CommandError("no command") }
        var args = Args(Array(words.dropFirst()))
        let verb = first.lowercased()
        if let query = try query(verb, &args) {
            try args.finish(verb)
            return .query(query)
        }
        // `focus --window-id 42` focuses that window; for other commands it says which window to act on.
        var window: UInt32?
        if verb != "focus", let raw = try args.option("--window-id") {
            guard let id = UInt32(raw) else { throw CommandError("--window-id needs a window number, not “\(raw)”") }
            window = id
        }
        let action = try self.action(verb, &args)
        try args.finish(verb)
        return .action(action, window: window)
    }

    // MARK: Words

    enum Token: Equatable { case word(String), and, or, semicolon }

    static func tokenize(_ text: String) throws -> [Token] {
        var tokens: [Token] = []
        var word = ""
        var hasWord = false
        var quote: Character?
        let chars = Array(text)
        var i = 0
        func flush() {
            if hasWord { tokens.append(.word(word)) }
            word = ""
            hasWord = false
        }
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == q {
                    quote = nil
                } else if c == "\\", q == "\"", i + 1 < chars.count {
                    i += 1
                    word.append(chars[i])
                } else {
                    word.append(c)
                }
                i += 1
                continue
            }
            switch c {
            case "\"", "'":
                quote = c
                hasWord = true
            case " ", "\t", "\n", "\r\n":
                let ended = word.lowercased()
                let statementStart = tokens.isEmpty || { if case .word = tokens.last! { return false } else { return true } }()
                flush()
                // exec-and-forget takes the rest of the line as a shell command, as written.
                if statementStart && (ended == "exec-and-forget" || ended == "exec") {
                    let rest = String(chars[(i + 1)...]).trimmingCharacters(in: .whitespaces)
                    guard !rest.isEmpty else { throw CommandError("\(ended) needs a shell command") }
                    tokens.append(.word(rest))
                    return tokens
                }
            case ";":
                flush()
                tokens.append(.semicolon)
            case "&" where i + 1 < chars.count && chars[i + 1] == "&":
                flush()
                tokens.append(.and)
                i += 1
            case "|" where i + 1 < chars.count && chars[i + 1] == "|":
                flush()
                tokens.append(.or)
                i += 1
            case "|":
                throw CommandError("pipes (|) aren't supported; use exec-and-forget for shell commands")
            default:
                word.append(c)
                hasWord = true
            }
            i += 1
        }
        if quote != nil { throw CommandError("a quote isn't closed") }
        flush()
        return tokens
    }

    /// The words after the command name, with helpers to read flags.
    struct Args {
        var words: [String]
        init(_ words: [String]) { self.words = words }

        /// Takes a flag (like --wrap-around) if it's there.
        mutating func flag(_ names: String...) -> Bool {
            guard let index = words.firstIndex(where: { names.contains($0.lowercased()) }) else { return false }
            words.remove(at: index)
            return true
        }

        /// Takes an option and its value (like --window-id 42).
        mutating func option(_ names: String...) throws -> String? {
            guard let index = words.firstIndex(where: { names.contains($0.lowercased()) }) else { return nil }
            guard index + 1 < words.count else { throw CommandError("\(words[index]) needs a value") }
            let value = words[index + 1]
            words.removeSubrange(index...index + 1)
            return value
        }

        /// The next word that isn't a flag.
        mutating func next() -> String? {
            guard let index = words.firstIndex(where: { !$0.hasPrefix("--") || $0 == "--" }) else { return nil }
            if words[index] == "--" {
                words.remove(at: index)
                return next()
            }
            return words.remove(at: index)
        }

        mutating func rest() -> [String] {
            let out = words.filter { $0 != "--" }
            words = []
            return out
        }

        func finish(_ verb: String) throws {
            guard words.isEmpty else {
                throw CommandError("\(verb) doesn't understand “\(words.joined(separator: " "))”")
            }
        }
    }

    // MARK: Queries

    static func output(_ args: inout Args) throws -> ListOutput {
        ListOutput(json: args.flag("--json"), count: args.flag("--count"), format: try args.option("--format"))
    }

    static func query(_ verb: String, _ args: inout Args) throws -> Query? {
        switch verb {
        case "list-windows", "windows":
            var scope = WindowScope.visible
            if args.flag("--all") { scope = .all }
            if args.flag("--focused") { scope = .focused }
            if let d = try args.option("--desktop", "--workspace", "--space") {
                if d.lowercased() == "focused" || d.lowercased() == "visible" {
                    scope = .visible
                } else {
                    guard let n = Int(d) else { throw CommandError("Tessera's desktops are numbered: --desktop 1, 2, 3…") }
                    scope = .desktop(n)
                }
            }
            if let m = try args.option("--display", "--monitor") {
                scope = .display(try display(m, wrapAllowed: false))
            }
            let app = try args.option("--app-bundle-id", "--app")
            let pid = try args.option("--pid").map { raw -> Int in
                guard let p = Int(raw) else { throw CommandError("--pid needs a number") }
                return p
            }
            return .windows(scope, app: app, pid: pid, try output(&args))
        case "list-desktops", "list-workspaces", "list-spaces", "desktops":
            let focused = args.flag("--focused")
            _ = args.flag("--all")
            _ = try args.option("--monitor", "--display")
            return .desktops(focused: focused, try output(&args))
        case "list-displays", "list-monitors", "displays":
            let focused = args.flag("--focused")
            return .displays(focused: focused, try output(&args))
        case "list-apps", "apps":
            _ = args.flag("--macos-native-hidden")
            return .apps(try output(&args))
        case "list-modes", "modes":
            let current = args.flag("--current")
            return .modes(current: current, try output(&args))
        case "tree":
            return .tree(try output(&args))
        case "config":
            let path = args.flag("--config-path")
            let key = try args.option("--get")
            _ = args.flag("--keys", "--major-keys", "--all-keys")
            return .config(key: key, path: path, try output(&args))
        case "version", "--version", "-v":
            return .version
        case "help", "--help", "-h":
            let topic = args.next()
            _ = args.rest()
            return .help(topic)
        case "subscribe":
            _ = args.flag("--all", "--no-send-initial")
            return .subscribe(args.rest())
        case "debug-windows":
            _ = try args.option("--window-id")
            return .windows(.all, app: nil, pid: nil, ListOutput(json: true))
        default:
            return nil
        }
    }

    // MARK: Actions

    static func direction(_ word: String?, _ verb: String) throws -> Direction {
        guard let word else { throw CommandError("\(verb) needs a direction: left, right, up or down") }
        guard let direction = Direction(word: word) else {
            throw CommandError("“\(word)” isn't a direction: use left, right, up or down (or west, east, north, south)")
        }
        return direction
    }

    static func display(_ word: String, wrapAllowed: Bool) throws -> DisplayTarget {
        let lower = word.lowercased()
        if let d = Direction(word: lower) { return .direction(d) }
        switch lower {
        case "next": return .next
        case "prev", "previous": return .previous
        default:
            if let n = Int(lower) { return .number(n) }
            return .pattern(word)
        }
    }

    static func desktop(_ word: String?, _ verb: String) throws -> DesktopTarget {
        guard let word else { throw CommandError("\(verb) needs a desktop: a number, next, prev or last") }
        switch word.lowercased() {
        case "next": return .next
        case "prev", "previous": return .previous
        case "last", "back", "back-and-forth": return .last
        default:
            guard let n = Int(word), n >= 1 else {
                throw CommandError("“\(word)” isn't a desktop. Tessera uses your macOS desktops, numbered 1, 2, 3… (named workspaces aren't supported)")
            }
            return .number(n)
        }
    }

    static func toggle(_ args: inout Args, _ verb: String) throws -> Toggle {
        let word = args.next()
        guard let toggle = Toggle(word) else { throw CommandError("\(verb) takes on, off or toggle, not “\(word ?? "")”") }
        return toggle
    }

    static func action(_ verb: String, _ args: inout Args) throws -> Action {
        switch verb {
        // Focus
        case "focus":
            if let id = try args.option("--window-id") {
                guard let n = UInt32(id) else { throw CommandError("--window-id needs a window number") }
                return .focus(.window(n), wrap: false)
            }
            if let index = try args.option("--dfs-index") {
                guard let n = Int(index) else { throw CommandError("--dfs-index needs a number") }
                return .focus(.index(n), wrap: false)
            }
            var wrap = args.flag("--wrap-around")
            _ = args.flag("--ignore-floating", "--fail-if-fullscreen", "--fail-if-macos-native-fullscreen")
            _ = try args.option("--boundaries")
            if let action = try args.option("--boundaries-action"), action.lowercased().hasPrefix("wrap") { wrap = true }
            let word = args.next()
            switch word?.lowercased() {
            case "next", "dfs-next": return .focus(.next, wrap: wrap)
            case "prev", "previous", "dfs-prev": return .focus(.previous, wrap: wrap)
            case "back", "back-and-forth", "last": return .focus(.back, wrap: false)
            default: return .focus(.direction(try direction(word, verb)), wrap: wrap)
            }
        case "focus-back-and-forth":
            return .focus(.back, wrap: false)
        case "focus-monitor", "focus-display":
            let wrap = args.flag("--wrap-around")
            guard let word = args.next() else { throw CommandError("\(verb) needs a screen: left, right, next, prev, a number or a name") }
            return .focusDisplay(try display(word, wrapAllowed: true), wrap: wrap)
        case "display":
            // Spacetile: display next / display prev
            guard let word = args.next() else { throw CommandError("display needs next or prev") }
            return .focusDisplay(try display(word, wrapAllowed: true), wrap: true)

        // Moving windows
        case "move":
            _ = args.flag("--fail-if-fullscreen", "--fail-if-macos-native-fullscreen")
            _ = try args.option("--boundaries")
            _ = try args.option("--boundaries-action")
            return .move(try direction(args.next(), verb))
        case "swap":
            let keep = args.flag("--swap-focus")
            let wrap = args.flag("--wrap-around")
            let word = args.next()
            switch word?.lowercased() {
            case "next", "dfs-next": return .swap(.next, wrap: wrap, keepFocus: keep)
            case "prev", "previous", "dfs-prev": return .swap(.previous, wrap: wrap, keepFocus: keep)
            case "main": return .command(.tile(.swapWithMain))
            default: return .swap(.direction(try direction(word, verb)), wrap: wrap, keepFocus: keep)
            }
        case "join-with", "join":
            return .join(try direction(args.next(), verb))
        case "split":
            guard let word = args.next() else { return .split(.toggle) }
            guard let choice = SplitChoice(rawValue: word.lowercased()) else {
                throw CommandError("split takes horizontal, vertical, opposite or toggle")
            }
            return .split(choice)
        case "preselect":
            guard let word = args.next() else { throw CommandError("preselect needs a direction, or cancel") }
            if ["cancel", "none", "off"].contains(word.lowercased()) { return .preselect(nil) }
            return .preselect(try direction(word, verb))
        case "mirror":
            switch args.next()?.lowercased() {
            case "horizontal", "x", "h": return .mirror(.horizontal)
            case "vertical", "y", "v": return .mirror(.vertical)
            default: throw CommandError("mirror takes horizontal or vertical")
            }
        case "rotate":
            switch args.next()?.lowercased() {
            case nil, "90", "clockwise", "cw": return .rotate(quarterTurns: 1)
            case "180": return .rotate(quarterTurns: 2)
            case "270", "-90", "counterclockwise", "anticlockwise", "ccw": return .rotate(quarterTurns: 3)
            case let other?: throw CommandError("rotate takes 90, 180 or 270, not “\(other)”")
            }
        case "balance", "balance-sizes", "even-out":
            _ = try args.option("--workspace")
            return .balance
        case "flatten", "flatten-workspace-tree":
            _ = try args.option("--workspace")
            return .flatten
        case "pop":
            switch args.next()?.lowercased() {
            case "out": return .popOut
            case "in": return .popIn
            default: throw CommandError("pop takes out or in")
            }
        case "pop-out": return .popOut
        case "pop-in": return .popIn
        case "resize":
            guard let dimension = args.next().flatMap({ ResizeDimension(rawValue: $0.lowercased()) }) else {
                throw CommandError("resize takes smart, smart-opposite, width or height, then a number like +50 or -50")
            }
            guard let amount = args.next() else { throw CommandError("resize needs a number of points, like +50") }
            let relative = amount.hasPrefix("+") || amount.hasPrefix("-")
            guard let value = Double(amount) else { throw CommandError("“\(amount)” isn't a number of points") }
            return .resize(dimension, relative ? .by(CGFloat(value)) : .to(CGFloat(value)))
        case "border":
            // `border on|off|toggle` draws a border round the focused window; `border horizontal 100` moves an edge.
            if let first = args.words.first?.lowercased(), ["on", "off", "toggle"].contains(first) {
                return .appearance(.border, try toggle(&args, verb))
            }
            if args.words.isEmpty { return .appearance(.border, .toggle) }
            let axisWord = args.next()?.lowercased()
            let orientation: Orientation
            switch axisWord {
            case "horizontal", "width", "x": orientation = .horizontal
            case "vertical", "height", "y": orientation = .vertical
            default: throw CommandError("border takes horizontal or vertical, then points: border horizontal 100")
            }
            guard let raw = args.next(), let value = Double(raw) else { throw CommandError("border needs a number of points") }
            return .border(orientation, CGFloat(value))
        case "grow", "larger": return .command(.snap(.larger))
        case "shrink", "smaller": return .command(.snap(.smaller))

        // Window state
        case "zoom":
            return .zoom(try toggle(&args, verb))
        case "fullscreen":
            _ = args.flag("--no-outer-gaps", "--fail-if-noop")
            if args.words.first?.lowercased() == "pair" {
                throw CommandError("fullscreen pair (two windows in macOS Split View) isn't supported")
            }
            return .zoom(try toggle(&args, verb))
        case "macos-native-fullscreen", "native-fullscreen", "native-full-screen":
            _ = args.flag("--fail-if-noop")
            return .nativeFullScreen(try toggle(&args, verb))
        case "macos-native-minimize", "minimize", "minimise":
            return .minimize
        case "close":
            return .close(quitIfLast: args.flag("--quit-if-last-window"))
        case "close-all-windows-but-current", "close-others":
            return .closeOthers(quitIfLast: args.flag("--quit-if-last-window"))
        case "float":
            return .float(try toggle(&args, verb))
        case "keep", "keep-in-front":
            return .keepInFront(try toggle(&args, verb))
        case "restore":
            return .command(.snap(.restore))
        case "stack":
            switch args.next()?.lowercased() {
            case "next": return .stack(forward: true)
            case "prev", "previous": return .stack(forward: false)
            default: throw CommandError("stack takes next or prev")
            }
        case "layout":
            _ = try args.option("--workspace")
            _ = args.flag("--fail-if-noop", "--root")
            let words = args.rest()
            guard !words.isEmpty else { throw CommandError("layout needs a layout, such as tree, columns, stack, accordion or floating") }
            return .layout(try words.map(layoutChoice))
        case "retile": return .retile

        // Desktops and screens
        case "workspace", "space", "desktop":
            _ = args.flag("--auto-back-and-forth", "--fail-if-noop", "--wrap-around", "--stdin", "--no-stdin")
            let word = args.next()
            if verb == "space", word?.lowercased() == "fullscreen" {
                // Spacetile: step through full-screen apps too. macOS's own keys do that.
                switch args.next()?.lowercased() {
                case "next": return .desktop(.next)
                case "prev", "previous": return .desktop(.previous)
                default: throw CommandError("space fullscreen takes next or prev")
                }
            }
            return .desktop(try desktop(word, verb))
        case "workspace-back-and-forth":
            return .desktop(.last)
        case "move-node-to-workspace", "send-to-desktop", "send-desktop":
            let follow = args.flag("--focus-follows-window") || verb != "move-node-to-workspace"
            _ = args.flag("--wrap-around", "--fail-if-noop", "--stdin", "--no-stdin")
            return .sendToDesktop(try desktop(args.next(), verb), follow: follow)
        case "send":
            // Spacetile: send 3, send next, send display next
            if args.words.first?.lowercased() == "display" {
                _ = args.next()
                guard let word = args.next() else { throw CommandError("send display needs next or prev") }
                return .sendToDisplay(try display(word, wrapAllowed: true), follow: true, wrap: true)
            }
            return .sendToDesktop(try desktop(args.next(), verb), follow: true)
        case "move-node-to-monitor", "send-to-display", "send-display":
            let follow = args.flag("--focus-follows-window") || verb != "move-node-to-monitor"
            let wrap = args.flag("--wrap-around")
            _ = args.flag("--fail-if-noop")
            guard let word = args.next() else { throw CommandError("\(verb) needs a screen: left, right, next, prev, a number or a name") }
            return .sendToDisplay(try display(word, wrapAllowed: true), follow: follow, wrap: wrap)
        case "move-workspace-to-monitor", "summon-workspace":
            throw CommandError("\(verb) needs AeroSpace's own workspaces; Tessera uses macOS desktops, which can't move between screens")

        // Tessera
        case "enable", "auto-tile", "autotile":
            return .enable(try toggle(&args, verb))
        case "pause":
            return .enable(.toggle)
        case "mode":
            guard let name = args.next() else { throw CommandError("mode needs a name, such as main") }
            return .mode(name)
        case "reload-config", "reload":
            _ = args.flag("--no-gui", "--dry-run", "--warnings-as-errors")
            return .reloadConfig
        case "exec-and-forget", "exec":
            let script = args.rest().joined(separator: " ")
            guard !script.isEmpty else { throw CommandError("\(verb) needs a shell command") }
            return .exec(script)
        case "move-mouse":
            _ = args.flag("--fail-if-noop")
            guard let word = args.next()?.lowercased() else { throw CommandError("move-mouse needs a target, such as window-lazy-center") }
            let aliases: [String: MouseTarget] = ["display-lazy-center": .displayLazyCenter, "display-force-center": .displayForceCenter]
            guard let target = MouseTarget(rawValue: word) ?? aliases[word] else {
                throw CommandError("move-mouse takes " + MouseTarget.allCases.map(\.rawValue).joined(separator: ", "))
            }
            return .moveMouse(target)
        case "setup":
            let sub = args.next()?.lowercased()
            let name = args.rest().joined(separator: " ")
            switch sub {
            case "open", "load", "apply":
                guard !name.isEmpty else { throw CommandError("setup open needs a name") }
                if let n = Int(name) { return .setup(.number(n)) }
                return .setup(.open(name))
            case "save":
                guard !name.isEmpty else { throw CommandError("setup save needs a name") }
                return .setup(.save(name))
            case "delete", "remove":
                guard !name.isEmpty else { throw CommandError("setup delete needs a name") }
                return .setup(.delete(name))
            case let n? where Int(n) != nil:
                return .setup(.number(Int(n)!))
            default:
                throw CommandError("setup takes open, save or delete and a name")
            }
        case "load":
            let name = args.rest().joined(separator: " ")
            guard !name.isEmpty else { throw CommandError("load needs a setup name") }
            return .setup(.open(name))
        case "toggle":
            guard let word = args.next()?.lowercased(), let what = Appearance(rawValue: word) else {
                throw CommandError("toggle takes spacing, border or dim")
            }
            return .appearance(what, .toggle)
        case "spacing", "gaps", "dim":
            let what: Appearance = verb == "gaps" ? .spacing : Appearance(rawValue: verb)!
            return .appearance(what, try toggle(&args, verb))
        case "volume":
            let word = args.next()?.lowercased()
            switch word {
            case "up": return .volume(.up)
            case "down": return .volume(.down)
            case "mute-toggle", "mute": return .volume(.muteToggle)
            case "mute-on": return .volume(.muteOn)
            case "mute-off", "unmute": return .volume(.muteOff)
            case "set":
                guard let raw = args.next(), let n = Int(raw), (0...100).contains(n) else {
                    throw CommandError("volume set needs a number from 0 to 100")
                }
                return .volume(.set(n))
            default: throw CommandError("volume takes up, down, mute-toggle, mute-on, mute-off or set N")
            }
        case "settings", "preferences": return .openSettings
        case "trigger-binding":
            guard let mode = try args.option("--mode") else { throw CommandError("trigger-binding needs --mode") }
            guard let key = args.next() else { throw CommandError("trigger-binding needs a key, like alt-h") }
            return .triggerBinding(mode: mode, key: key)
        case "echo":
            _ = args.flag("--stderr")
            return .echo(args.rest().joined(separator: " "))
        case "true": return .succeed
        case "false": return .fail
        case "place", "snap":
            let words = args.rest()
            guard let action = place(words) else {
                throw CommandError("\(verb) doesn't know “\(words.joined(separator: " "))”: try left, right, top, bottom, top-left, center, left 2/3, or any Rectangle name like left-half")
            }
            return .command(.snap(action))
        case "run":
            guard let id = args.next(), let command = Command(id: id) ?? Command(urlName: id) else {
                throw CommandError("run needs a command id, such as snap.leftHalf or tile.retile")
            }
            return .command(command)
        default:
            if let command = Command(urlName: verb) { return .command(command) }
            throw CommandError("unknown command “\(verb)”. Run `tessera help` for the list")
        }
    }

    static func layoutChoice(_ word: String) throws -> LayoutChoice {
        let w = word.lowercased().replacingOccurrences(of: "_", with: "-")
        switch w {
        case "tiles": return .container(.tiles, nil)
        case "accordion": return .container(.accordion, nil)
        case "horizontal": return .container(nil, .horizontal)
        case "vertical": return .container(nil, .vertical)
        case "h-tiles": return .container(.tiles, .horizontal)
        case "v-tiles": return .container(.tiles, .vertical)
        case "h-accordion": return .container(.accordion, .horizontal)
        case "v-accordion": return .container(.accordion, .vertical)
        case "floating": return .floating
        case "tiling": return .tiling
        case "bsp", "tile", "dwindle": return .style(.tree)
        case "monocle", "fill": return .style(.stack)
        case "main", "master", "main-stack": return .style(.mainAndSide)
        default:
            if let style = LayoutStyle(rawValue: word) ?? LayoutStyle.allCases.first(where: { $0.urlName == w }) {
                return .style(style)
            }
            throw CommandError("“\(word)” isn't a layout: use " + LayoutStyle.allCases.map(\.urlName).joined(separator: ", ")
                + ", tiles, accordion, horizontal, vertical, floating or tiling")
        }
    }

    /// Spacetile and Rectangle place names: `left`, `top-right`, `left 2/3`, `top-left-sixth`, `left-half`.
    static func place(_ words: [String]) -> SnapAction? {
        let text = words.joined(separator: " ").lowercased()
            .replacingOccurrences(of: "center", with: "centre")
            .replacingOccurrences(of: "maximize", with: "maximise")
        let named: [String: SnapAction] = [
            "left": .leftHalf, "right": .rightHalf, "top": .topHalf, "bottom": .bottomHalf,
            "top-left": .topLeft, "top-right": .topRight, "bottom-left": .bottomLeft, "bottom-right": .bottomRight,
            "centre": .centre, "column": .centreThird, "maximise": .maximise, "fill": .maximise, "full": .maximise,
            "left 1/2": .leftHalf, "right 1/2": .rightHalf, "centre 1/2": .centreHalf,
            "top 1/2": .topHalf, "bottom 1/2": .bottomHalf,
            "left 1/3": .firstThird, "centre 1/3": .centreThird, "right 1/3": .lastThird,
            "left 2/3": .firstTwoThirds, "centre 2/3": .centreTwoThirds, "right 2/3": .lastTwoThirds,
            "left 1/4": .firstQuarter, "right 1/4": .lastQuarter,
            "left 3/4": .firstThreeQuarters, "centre 3/4": .centreThreeQuarters, "right 3/4": .lastThreeQuarters,
            "top-left-sixth": .topLeftSixth, "top-centre-sixth": .topCentreSixth, "top-right-sixth": .topRightSixth,
            "bottom-left-sixth": .bottomLeftSixth, "bottom-centre-sixth": .bottomCentreSixth, "bottom-right-sixth": .bottomRightSixth,
        ]
        if let action = named[text] { return action }
        if words.count == 1 {
            let name = words[0]
            if let action = SnapAction(rawValue: name) ?? SnapAction(urlName: name) { return action }
            if let action = SnapAction(urlName: text) { return action }
        }
        return nil
    }
}
