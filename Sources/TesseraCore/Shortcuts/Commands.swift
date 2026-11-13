import Foundation

/// Auto-tile commands.
public enum TileCommand: String, CaseIterable, Codable, Sendable {
    case toggleAutoTile, nextLayout, swapWithMain, toggleFloat, retile

    public var title: String {
        switch self {
        case .toggleAutoTile: "Auto-Tile"
        case .nextLayout: "Next Layout"
        case .swapWithMain: "Swap with Main"
        case .toggleFloat: "Float or Tile Window"
        case .retile: "Retile"
        }
    }

    /// These avoid every Rectangle default, so the two never fight over a key.
    public var defaultShortcut: KeyCombo? {
        let co: Modifiers = [.control, .option]
        switch self {
        case .toggleAutoTile: return KeyCombo(KeyCode.a, co)
        case .nextLayout: return KeyCombo(KeyCode.l, co)
        case .swapWithMain: return KeyCombo(KeyCode.m, co)
        case .toggleFloat: return KeyCombo(KeyCode.w, co)
        case .retile: return nil
        }
    }
}

/// Anything a shortcut can trigger.
public enum Command: Hashable, Sendable {
    case snap(SnapAction)
    case tile(TileCommand)

    public static var allCases: [Command] {
        SnapAction.allCases.map(Command.snap) + TileCommand.allCases.map(Command.tile)
    }

    /// Stable name used in saved settings.
    public var id: String {
        switch self {
        case .snap(let action): "snap." + action.rawValue
        case .tile(let command): "tile." + command.rawValue
        }
    }

    public init?(id: String) {
        if id.hasPrefix("snap."), let action = SnapAction(rawValue: String(id.dropFirst(5))) {
            self = .snap(action)
        } else if id.hasPrefix("tile."), let command = TileCommand(rawValue: String(id.dropFirst(5))) {
            self = .tile(command)
        } else {
            return nil
        }
    }

    public var title: String {
        switch self {
        case .snap(let action): action.title
        case .tile(let command): command.title
        }
    }

    public var defaultShortcut: KeyCombo? {
        switch self {
        case .snap(let action): action.defaultShortcut
        case .tile(let command): command.defaultShortcut
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
