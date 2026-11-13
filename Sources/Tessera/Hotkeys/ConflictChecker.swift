import AppKit
import Carbon.HIToolbox
import TesseraCore

/// Something else that already uses a key combo.
enum ShortcutConflict: Hashable {
    case tessera(ShortcutAction)
    case macOS
    case menuItem(app: String, item: String)
    case typing(String)
    case heldByApp

    var message: String {
        switch self {
        case .tessera(let action): L("Also used by “%@”", action.title)
        case .macOS: L("Used by macOS")
        case .menuItem(let app, let item): L("Used by %@ › %@", app, item)
        case .typing(let character): L("Types “%@”", character)
        case .heldByApp: L("Held by another app")
        }
    }
}

/// Finds what else uses a key combo: other Tessera shortcuts, macOS, open apps' menus, typing.
/// It can't check apps that aren't open or keys used outside app menus.
@MainActor
enum ConflictChecker {
    private static var systemCache: (date: Date, value: Set<KeyCombo>)?

    /// Combos macOS reserves (from System Settings › Keyboard Shortcuts, plus fixed ones).
    static func systemShortcuts() -> Set<KeyCombo> {
        if let systemCache, Date().timeIntervalSince(systemCache.date) < 10 { return systemCache.value }
        let value = readSystemShortcuts()
        systemCache = (Date(), value)
        return value
    }

    private static func readSystemShortcuts() -> Set<KeyCombo> {
        var result: Set<KeyCombo> = [
            KeyCombo(KeyCode.tab, .command),
            KeyCombo(KeyCode.tab, [.command, .shift]),
            KeyCombo(KeyCode.grave, .command),
            KeyCombo(KeyCode.escape, [.option, .command]),
            KeyCombo(KeyCode.q, [.control, .command]),
            KeyCombo(KeyCode.f, [.control, .command]),
            KeyCombo(KeyCode.space, .command),
            KeyCombo(KeyCode.three, [.shift, .command]),
            KeyCombo(KeyCode.four, [.shift, .command]),
            KeyCombo(KeyCode.five, [.shift, .command]),
            KeyCombo(KeyCode.three, [.control, .shift, .command]),
            KeyCombo(KeyCode.four, [.control, .shift, .command]),
        ]
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let array = unmanaged?.takeRetainedValue() as? [[String: Any]] else {
            return result
        }
        for entry in array {
            guard (entry["kHISymbolicHotKeyEnabled"] as? Bool) ?? false,
                  let code = entry["kHISymbolicHotKeyCode"] as? Int, code != 0xFFFF,
                  let flags = entry["kHISymbolicHotKeyModifiers"] as? Int else { continue }
            result.insert(KeyCombo(UInt32(code), Modifiers(carbonFlags: UInt32(flags))))
        }
        return result
    }

    private static var menuCache: (date: Date, value: [KeyCombo: (String, String)])?

    /// Shortcuts in the menus of open apps, read through Accessibility. Cached briefly.
    static func menuShortcuts() -> [KeyCombo: (app: String, item: String)] {
        if let menuCache, Date().timeIntervalSince(menuCache.date) < 30 {
            return menuCache.value.mapValues { (app: $0.0, item: $0.1) }
        }
        var result: [KeyCombo: (String, String)] = [:]
        let deadline = Date().addingTimeInterval(0.8)
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .prefix(16)
        outer: for app in apps {
            let element = AXElement.application(app.processIdentifier)
            element.setMessagingTimeout(0.1)
            guard let bar = element.element(kAXMenuBarAttribute) else { continue }
            for top in bar.elements(kAXChildrenAttribute) {
                for menu in top.elements(kAXChildrenAttribute) {
                    for item in menu.elements(kAXChildrenAttribute) {
                        if Date() > deadline { break outer }
                        guard let combo = combo(of: item) else { continue }
                        result[combo] = (app.displayName, item.title ?? "")
                    }
                }
            }
        }
        menuCache = (Date(), result)
        return result.mapValues { (app: $0.0, item: $0.1) }
    }

    private static func combo(of item: AXElement) -> KeyCombo? {
        let virtualKey = item.int(kAXMenuItemCmdVirtualKeyAttribute)
        let character = item.string(kAXMenuItemCmdCharAttribute)
        let keyCode: UInt32?
        if let virtualKey { keyCode = UInt32(virtualKey) } else { keyCode = character.flatMap { KeyCode.code(forCharacter: $0) } }
        guard let keyCode else { return nil }
        let flags = item.int(kAXMenuItemCmdModifiersAttribute) ?? 0
        var modifiers: Modifiers = []
        if flags & 8 == 0 { modifiers.insert(.command) }
        if flags & 1 != 0 { modifiers.insert(.shift) }
        if flags & 2 != 0 { modifiers.insert(.option) }
        if flags & 4 != 0 { modifiers.insert(.control) }
        return KeyCombo(keyCode, modifiers)
    }

    /// Everything that conflicts with `combo` if assigned to `action`.
    static func conflicts(for combo: KeyCombo, action: ShortcutAction?, resolver: ShortcutResolver, includeMenus: Bool) -> [ShortcutConflict] {
        var result: [ShortcutConflict] = []
        for other in resolver.actions(using: combo) where other != action && !(other.isDerived && action == .tabView) {
            result.append(.tessera(other))
        }
        if systemShortcuts().contains(combo) { result.append(.macOS) }
        if includeMenus, let menu = menuShortcuts()[combo] { result.append(.menuItem(app: menu.app, item: menu.item)) }
        if !combo.modifiers.preventsTyping, !combo.isFunctionKey,
           let typed = KeyboardLayout.typedCharacter(keyCode: combo.keyCode, modifiers: combo.modifiers) {
            result.append(.typing(typed))
        }
        return result
    }

    /// Free keys to suggest: same key with other modifiers first, then F-keys.
    static func suggestions(for combo: KeyCombo, action: ShortcutAction?, resolver: ShortcutResolver) -> [KeyCombo] {
        let system = systemShortcuts()
        let menus = menuShortcuts()
        return ShortcutResolver.suggestions(for: combo, isFree: { candidate in
            resolver.actions(using: candidate).allSatisfy { $0 == action } &&
                !system.contains(candidate) && menus[candidate] == nil
        })
    }
}
