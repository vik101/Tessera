import Foundation

/// The modifier keys most shortcuts start with.
public enum ShortcutPrefix: String, Codable, CaseIterable, Sendable, Identifiable {
    case controlOption
    case optionCommand
    case controlShift

    public var id: String { rawValue }

    public var modifiers: Modifiers {
        switch self {
        case .controlOption: [.control, .option]
        case .optionCommand: [.option, .command]
        case .controlShift: [.control, .shift]
        }
    }

    /// Extra key for the layout shortcuts (⌃⌥⇧1–4 by default).
    public var layoutExtra: Modifiers { modifiers.contains(.shift) ? .option : .shift }

    /// Extra key for the window-count shortcuts (⌃⌥⌘1–5 by default).
    public var countExtra: Modifiers { modifiers.contains(.command) ? .control : .command }
}

public enum ShortcutGroup: String, CaseIterable, Sendable, Identifiable {
    case general, move, activate, size, layout, more
    public var id: String { rawValue }
}

/// Every action that can have a keyboard shortcut.
public enum ShortcutAction: String, Codable, CaseIterable, Sendable, Identifiable {
    case toggleTiling
    case cheatSheet

    case swapLeft, swapRight, swapUp, swapDown

    case makePrimary
    case nextWindow, previousWindow
    case stackNext, stackPrevious
    case tabView, tabViewBackward

    case grow, shrink, resetSizes

    case layoutGrid, layoutColumns, layoutRows, layoutSide
    case count1, count2, count3, count4, count5

    case float, alwaysFloat
    case focusMode, noPeek, cleanSpace
    case retile

    public var id: String { rawValue }

    public var group: ShortcutGroup {
        switch self {
        case .toggleTiling, .cheatSheet: .general
        case .swapLeft, .swapRight, .swapUp, .swapDown: .move
        case .makePrimary, .nextWindow, .previousWindow, .stackNext, .stackPrevious, .tabView, .tabViewBackward: .activate
        case .grow, .shrink, .resetSizes: .size
        case .layoutGrid, .layoutColumns, .layoutRows, .layoutSide, .count1, .count2, .count3, .count4, .count5: .layout
        case .float, .alwaysFloat, .focusMode, .noPeek, .cleanSpace, .retile: .more
        }
    }

    /// Window-count shortcuts change together.
    public var isWindowCount: Bool { countValue != nil }

    public var countValue: Int? {
        switch self {
        case .count1: 1
        case .count2: 2
        case .count3: 3
        case .count4: 4
        case .count5: 5
        default: nil
        }
    }

    public static func count(_ value: Int) -> ShortcutAction? {
        switch value {
        case 1: .count1
        case 2: .count2
        case 3: .count3
        case 4: .count4
        case 5: .count5
        default: nil
        }
    }

    public var layout: LayoutKind? {
        switch self {
        case .layoutGrid: .grid
        case .layoutColumns: .columns
        case .layoutRows: .rows
        case .layoutSide: .side
        default: nil
        }
    }

    public static func layout(_ kind: LayoutKind) -> ShortcutAction {
        switch kind {
        case .grid: .layoutGrid
        case .columns: .layoutColumns
        case .rows: .layoutRows
        case .side: .layoutSide
        }
    }

    public var direction: Direction? {
        switch self {
        case .swapLeft: .left
        case .swapRight: .right
        case .swapUp: .up
        case .swapDown: .down
        default: nil
        }
    }

    /// Tab View's backward shortcut is always derived: same keys plus ⇧.
    public var isDerived: Bool { self == .tabViewBackward }

    /// Tab View needs a key held down (like ⌥) rather than the prefix.
    public var usesPrefix: Bool { !(self == .tabView || self == .tabViewBackward) }

    /// The default keys for this action under a prefix.
    public func defaultCombo(prefix: ShortcutPrefix) -> KeyCombo {
        let p = prefix.modifiers
        switch self {
        case .toggleTiling: return KeyCombo(KeyCode.t, p)
        case .cheatSheet: return KeyCombo(KeyCode.slash, p)
        case .swapLeft: return KeyCombo(KeyCode.leftArrow, p)
        case .swapRight: return KeyCombo(KeyCode.rightArrow, p)
        case .swapUp: return KeyCombo(KeyCode.upArrow, p)
        case .swapDown: return KeyCombo(KeyCode.downArrow, p)
        case .makePrimary: return KeyCombo(KeyCode.returnKey, p)
        case .nextWindow: return KeyCombo(KeyCode.rightBracket, p)
        case .previousWindow: return KeyCombo(KeyCode.leftBracket, p)
        case .stackNext: return KeyCombo(KeyCode.grave, p)
        case .stackPrevious: return KeyCombo(KeyCode.grave, p.union(.shift))
        case .tabView: return KeyCombo(KeyCode.tab, .option)
        case .tabViewBackward: return KeyCombo(KeyCode.tab, [.option, .shift])
        case .grow: return KeyCombo(KeyCode.equal, p)
        case .shrink: return KeyCombo(KeyCode.minus, p)
        case .resetSizes: return KeyCombo(KeyCode.zero, p)
        case .layoutGrid: return KeyCombo(KeyCode.one, p.union(prefix.layoutExtra))
        case .layoutColumns: return KeyCombo(KeyCode.two, p.union(prefix.layoutExtra))
        case .layoutRows: return KeyCombo(KeyCode.three, p.union(prefix.layoutExtra))
        case .layoutSide: return KeyCombo(KeyCode.four, p.union(prefix.layoutExtra))
        case .count1: return KeyCombo(KeyCode.one, p.union(prefix.countExtra))
        case .count2: return KeyCombo(KeyCode.two, p.union(prefix.countExtra))
        case .count3: return KeyCombo(KeyCode.three, p.union(prefix.countExtra))
        case .count4: return KeyCombo(KeyCode.four, p.union(prefix.countExtra))
        case .count5: return KeyCombo(KeyCode.five, p.union(prefix.countExtra))
        case .float: return KeyCombo(KeyCode.f, p)
        case .alwaysFloat: return KeyCombo(KeyCode.f, p.union(.shift))
        case .focusMode: return KeyCombo(KeyCode.z, p)
        case .noPeek: return KeyCombo(KeyCode.d, p)
        case .cleanSpace: return KeyCombo(KeyCode.p, p)
        case .retile: return KeyCombo(KeyCode.r, p)
        }
    }
}

/// What the user chose for one action.
public enum ShortcutBinding: Codable, Hashable, Sendable {
    /// Follow the prefix default.
    case standard
    /// Keys the user recorded.
    case custom(KeyCombo)
    /// Turned off. The action stays in the menu bar panel and hover bar.
    case off
}

/// Resolves bindings into concrete key combos.
public struct ShortcutResolver: Sendable {
    public var prefix: ShortcutPrefix
    public var bindings: [ShortcutAction: ShortcutBinding]
    /// Modifiers shared by all window-count keys when customised.
    public var countModifiers: Modifiers?

    public init(prefix: ShortcutPrefix = .controlOption, bindings: [ShortcutAction: ShortcutBinding] = [:], countModifiers: Modifiers? = nil) {
        self.prefix = prefix
        self.bindings = bindings
        self.countModifiers = countModifiers
    }

    public func combo(for action: ShortcutAction) -> KeyCombo? {
        if action.isDerived {
            guard let base = combo(for: .tabView) else { return nil }
            return base.adding(.shift)
        }
        if let count = action.countValue {
            if case .off = bindings[action] ?? .standard { return nil }
            if let countModifiers {
                return KeyCombo(KeyCode.digits[count - 1], countModifiers)
            }
            return action.defaultCombo(prefix: prefix)
        }
        switch bindings[action] ?? .standard {
        case .standard: return action.defaultCombo(prefix: prefix)
        case .custom(let combo): return combo
        case .off: return nil
        }
    }

    public func isCustomized(_ action: ShortcutAction) -> Bool {
        if action.isWindowCount { return countModifiers != nil }
        if case .standard = bindings[action] ?? .standard { return false }
        return true
    }

    /// Every action currently bound to `combo`.
    public func actions(using combo: KeyCombo) -> [ShortcutAction] {
        ShortcutAction.allCases.filter { self.combo(for: $0) == combo }
    }

    /// Free alternatives: the same key with other modifiers first, then F-keys.
    public static func suggestions(
        for combo: KeyCombo,
        isFree: (KeyCombo) -> Bool,
        limit: Int = 3
    ) -> [KeyCombo] {
        let modifierSets: [Modifiers] = [
            [.control, .option], [.option, .command], [.control, .shift], [.control, .command],
            [.control, .option, .shift], [.control, .option, .command], [.option, .shift, .command],
            [.control, .shift, .command],
        ]
        var result: [KeyCombo] = []
        for set in modifierSets where set != combo.modifiers {
            let candidate = KeyCombo(combo.keyCode, set)
            if isFree(candidate) { result.append(candidate) }
            if result.count >= limit { return result }
        }
        for key in KeyCode.suggestedFunctionKeys {
            let candidate = KeyCombo(key, [])
            if isFree(candidate) { result.append(candidate) }
            if result.count >= limit { return result }
        }
        return result
    }
}
