import Foundation

/// Auto-tile commands.
public enum TileCommand: String, CaseIterable, Codable, Sendable {
    case toggleAutoTile, nextLayout, previousLayout, swapWithMain, toggleFloat, retile
    /// The window picker: every window on this desktop; pick one to bring it to the front.
    case showWindows
    /// Keep the focused window in front: it never steps back to make room.
    case keepInFront

    public var title: String {
        switch self {
        case .toggleAutoTile: "Auto-Tile"
        case .nextLayout: "Next Layout"
        case .previousLayout: "Previous Layout"
        case .swapWithMain: "Swap with Main"
        case .toggleFloat: "Float or Tile Window"
        case .retile: "Retile"
        case .showWindows: "Bring a Window Forward…"
        case .keepInFront: "Keep Window in Front"
        }
    }

    /// These avoid every Rectangle default, so the two never fight over a key.
    public var defaultShortcut: KeyCombo? {
        let co: Modifiers = [.control, .option]
        switch self {
        case .toggleAutoTile: return KeyCombo(KeyCode.a, co)
        case .nextLayout: return KeyCombo(KeyCode.l, co)
        case .previousLayout: return KeyCombo(KeyCode.l, co.union(.shift))
        case .swapWithMain: return KeyCombo(KeyCode.m, co)
        case .toggleFloat: return KeyCombo(KeyCode.w, co)
        case .retile: return nil
        case .showWindows: return KeyCombo(KeyCode.space, co)
        case .keepInFront: return KeyCombo(KeyCode.p, co)
        }
    }
}

extension LayoutStyle {
    /// ⌃⌥1 to ⌃⌥5, in menu order.
    public var defaultShortcut: KeyCombo? {
        guard let index = Self.allCases.firstIndex(of: self), index < KeyCode.digits.count else { return nil }
        return KeyCombo(KeyCode.digits[index], [.control, .option])
    }
}

/// Anything a shortcut can trigger.
public enum Command: Hashable, Sendable {
    case snap(SnapAction)
    case tile(TileCommand)
    /// Switch this screen to one layout style.
    case layout(LayoutStyle)
    /// Move every window on the screen at once (Tile All, Cascade, Reverse All, stacks).
    case arrange(ArrangeAction)
    /// Focus by direction, send to a desktop.
    case move(MoveAction)
    /// Open saved setup number 1…9 (in the order Settings lists them).
    case setup(Int)

    public static var allCases: [Command] {
        SnapAction.allCases.map(Command.snap) + TileCommand.allCases.map(Command.tile)
            + LayoutStyle.allCases.map(Command.layout) + ArrangeAction.allCases.map(Command.arrange)
            + MoveAction.allCases.map(Command.move) + (1...9).map(Command.setup)
    }

    /// Finds a command by its URL name: Rectangle's names (`left-half`, `tile-all`), Tessera's ids
    /// (`snap.leftHalf`, `tile.retile`), or a bare Tessera name (`leftHalf`, `retile`, `columns`).
    public init?(urlName raw: String) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if let command = Command(id: name) {
            self = command
        } else if let action = SnapAction(urlName: name) {
            self = .snap(action)
        } else if let action = ArrangeAction(urlName: name) {
            self = .arrange(action)
        } else if let action = MoveAction(rawValue: name) ?? MoveAction.allCases.first(where: { $0.urlName == name.lowercased() }) {
            self = .move(action)
        } else if name.lowercased().hasPrefix("open-setup-"), let n = Int(name.dropFirst(11)), (1...9).contains(n) {
            self = .setup(n)
        } else if let command = TileCommand(rawValue: name) ?? TileCommand.allCases.first(where: { $0.urlName == name.lowercased() }) {
            self = .tile(command)
        } else if let style = LayoutStyle(rawValue: name) ?? LayoutStyle.allCases.first(where: { $0.urlName == name.lowercased() }) {
            self = .layout(style)
        } else {
            return nil
        }
    }

    /// The command's name in URLs.
    public var urlName: String {
        switch self {
        case .snap(let action): action.rectangleName
        case .tile(let command): command.urlName
        case .layout(let style): style.urlName
        case .arrange(let action): action.urlName
        case .move(let action): action.urlName
        case .setup(let n): "open-setup-\(n)"
        }
    }

    /// Stable name used in saved settings.
    public var id: String {
        switch self {
        case .snap(let action): "snap." + action.rawValue
        case .tile(let command): "tile." + command.rawValue
        case .layout(let style): "layout." + style.rawValue
        case .arrange(let action): "arrange." + action.rawValue
        case .move(let action): "move." + action.rawValue
        case .setup(let n): "setup.\(n)"
        }
    }

    public init?(id: String) {
        if id.hasPrefix("snap."), let action = SnapAction(rawValue: String(id.dropFirst(5))) {
            self = .snap(action)
        } else if id.hasPrefix("tile."), let command = TileCommand(rawValue: String(id.dropFirst(5))) {
            self = .tile(command)
        } else if id.hasPrefix("layout."), let style = LayoutStyle(rawValue: String(id.dropFirst(7))) {
            self = .layout(style)
        } else if id.hasPrefix("arrange."), let action = ArrangeAction(rawValue: String(id.dropFirst(8))) {
            self = .arrange(action)
        } else if id.hasPrefix("move."), let action = MoveAction(rawValue: String(id.dropFirst(5))) {
            self = .move(action)
        } else if id.hasPrefix("setup."), let n = Int(id.dropFirst(6)), (1...9).contains(n) {
            self = .setup(n)
        } else {
            return nil
        }
    }

    public var title: String {
        switch self {
        case .snap(let action): action.title
        case .tile(let command): command.title
        case .layout(let style): style.title
        case .arrange(let action): action.title
        case .move(let action): action.title
        case .setup(let n): "Open Setup \(n)"
        }
    }

    public var defaultShortcut: KeyCombo? {
        switch self {
        case .snap(let action): action.defaultShortcut
        case .tile(let command): command.defaultShortcut
        case .layout(let style): style.defaultShortcut
        case .arrange: nil
        case .move(let action): action.defaultShortcut
        case .setup(let n): n - 1 < KeyCode.digits.count ? KeyCombo(KeyCode.digits[n - 1], [.control, .option, .command]) : nil
        }
    }
}

/// The user's shortcuts: the defaults plus their changes.
public struct ShortcutSet: Codable, Equatable, Sendable {
    /// Changed shortcuts, by command id.
    public var custom: [String: KeyCombo] = [:]
    /// Commands whose shortcut the user removed.
    public var cleared: Set<String> = []

    public init() {}

    public func combo(for command: Command) -> KeyCombo? {
        if cleared.contains(command.id) { return nil }
        return custom[command.id] ?? command.defaultShortcut
    }

    /// All active bindings.
    public var bindings: [(command: Command, combo: KeyCombo)] {
        Command.allCases.compactMap { command in combo(for: command).map { (command: command, combo: $0) } }
    }

    public func command(for combo: KeyCombo) -> Command? {
        bindings.first { $0.combo == combo }?.command
    }

    /// Sets (or with nil, removes) a shortcut. A command that already used the combo loses it.
    /// Returns that command, so the caller can say what changed.
    @discardableResult
    public mutating func set(_ combo: KeyCombo?, for command: Command) -> Command? {
        var displaced: Command?
        if let combo, let other = self.command(for: combo), other != command {
            clear(other)
            displaced = other
        }
        if let combo {
            cleared.remove(command.id)
            if combo == command.defaultShortcut {
                custom.removeValue(forKey: command.id)
            } else {
                custom[command.id] = combo
            }
        } else {
            clear(command)
        }
        return displaced
    }

    private mutating func clear(_ command: Command) {
        custom.removeValue(forKey: command.id)
        if command.defaultShortcut != nil { cleared.insert(command.id) } else { cleared.remove(command.id) }
    }
}

/// camelCase → kebab-case, for URL names.
func kebab(_ name: String) -> String {
    var out = ""
    for character in name {
        if character.isUppercase { out += "-" }
        out += character.lowercased()
    }
    return out
}

extension TileCommand {
    /// The command's name in Tessera's URLs, such as `next-layout`.
    public var urlName: String { kebab(rawValue) }
}

extension LayoutStyle {
    /// The layout's name in Tessera's URLs, such as `main-and-side`.
    public var urlName: String { kebab(rawValue) }
}
