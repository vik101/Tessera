import AppKit
import TesseraCore

/// Switching between your macOS desktops (Spaces): to desktop 3, the next one, or the one you were
/// on before. macOS has no way for another app to switch desktops directly, so Tessera presses the
/// keys macOS offers for it: "Switch to Desktop N" when that key is on, otherwise "Move left/right
/// a space" (⌃← / ⌃→) as many times as it takes.
@MainActor
enum Desktops {
    /// The desktop each screen showed before the one it shows now, by display UUID.
    private static var previous: [String: Spaces.SpaceID] = [:]
    private static var current: [String: Spaces.SpaceID] = [:]

    /// Call when the desktop changes: remembers where you came from, for `desktop last`.
    static func noteChange() {
        guard let now = Spaces.currentByDisplay() else { return }
        for (display, space) in now where current[display] != space {
            if let old = current[display] { previous[display] = old }
            current[display] = space
        }
    }

    /// The desktop a screen showed before this one.
    static func lastSpace(for display: DisplayInfo) -> Spaces.SpaceID? {
        Spaces.displayUUID(display).flatMap { previous[$0] }
    }

    /// The desktops of a screen, in Mission Control order, with numbers counting only real desktops.
    struct Layout {
        var spaces: [(id: UInt64, isDesktop: Bool)]
        var current: UInt64
        var desktops: [UInt64] { spaces.filter(\.isDesktop).map(\.id) }
        var currentNumber: Int? { desktops.firstIndex(of: current).map { $0 + 1 } }
    }

    static func layout(of display: DisplayInfo) -> Layout? {
        guard let found = Spaces.ordered(for: display) else { return nil }
        return Layout(spaces: found.spaces, current: found.current)
    }

    /// The number of the desktop a space is (1 is the first in Mission Control), on whichever screen has it.
    static func number(of space: Spaces.SpaceID) -> Int? {
        for display in Screens.all() {
            if let layout = layout(of: display), let index = layout.desktops.firstIndex(of: space) { return index + 1 }
        }
        return nil
    }

    /// Switches the screen you're working on to a desktop. Returns false (and says why) if it can't.
    @discardableResult
    static func go(_ target: DesktopTarget, on display: DisplayInfo) -> Bool {
        guard let layout = layout(of: display), let from = layout.spaces.firstIndex(where: { $0.id == layout.current }) else {
            Notice.shared.show("macOS didn't say which desktops this screen has")
            return false
        }
        let destination: Int?
        switch target {
        case .number(let n):
            let desktops = layout.spaces.indices.filter { layout.spaces[$0].isDesktop }
            guard n >= 1, n <= desktops.count else {
                Notice.shared.show("No Desktop \(n) on this screen")
                return false
            }
            destination = desktops[n - 1]
            if let key = SpaceKey.desktop(n), key.enabled, destination != from {
                key.press()
                return true
            }
        case .next:
            destination = from + 1 < layout.spaces.count ? from + 1 : nil
        case .previous:
            destination = from > 0 ? from - 1 : nil
        case .last:
            let uuid = Spaces.displayUUID(display) ?? ""
            destination = previous[uuid].flatMap { id in layout.spaces.firstIndex { $0.id == id } }
        }
        guard let destination else {
            NSSound.beep()
            return false
        }
        let steps = destination - from
        guard steps != 0 else { return true }
        guard let key = SpaceKey(right: steps > 0), key.enabled else {
            Notice.shared.show("Turn on “Move \(steps > 0 ? "right" : "left") a space” in Keyboard Shortcuts › Mission Control")
            return false
        }
        // Keys switch the desktop of the screen with the pointer; put it there for a moment if needed.
        let home = Screens.mouseLocation
        let away = !display.frame.contains(home)
        if away { CGWarpMouseCursorPosition(CGPoint(x: display.frame.midX, y: display.frame.midY)) }
        for _ in 0..<abs(steps) { key.press() }
        if away { after(0.15) { CGWarpMouseCursorPosition(home) } }
        return true
    }
}

/// A macOS shortcut from Keyboard Shortcuts › Mission Control, as the user has it set.
struct SpaceKey {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    let enabled: Bool

    private static func entry(_ id: Int) -> [String: Any]? {
        (UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")?[String(id)]) as? [String: Any]
    }

    private init(keyCode: CGKeyCode, flags: CGEventFlags, enabled: Bool) {
        self.keyCode = keyCode
        self.flags = flags
        self.enabled = enabled
    }

    /// "Move left a space" / "Move right a space": entries 79 and 81; missing means the default, ⌃← / ⌃→.
    init?(right: Bool) {
        let entry = Self.entry(right ? 81 : 79)
        let parameters = ((entry?["value"] as? [String: Any])?["parameters"] as? [NSNumber]) ?? []
        enabled = (entry?["enabled"] as? NSNumber)?.boolValue ?? true
        if parameters.count >= 3 {
            keyCode = CGKeyCode(parameters[1].intValue)
            flags = CGEventFlags(rawValue: parameters[2].uint64Value)
        } else {
            keyCode = right ? 0x7C : 0x7B
            flags = [.maskControl, .maskSecondaryFn]
        }
    }

    /// "Switch to Desktop N": entries 118 (Desktop 1) to 133 (Desktop 16). Off unless you turned it on.
    static func desktop(_ n: Int) -> SpaceKey? {
        guard (1...16).contains(n), let entry = entry(117 + n),
              let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [NSNumber], parameters.count >= 3,
              parameters[1].intValue != 65535 else { return nil }
        return SpaceKey(keyCode: CGKeyCode(parameters[1].intValue), flags: CGEventFlags(rawValue: parameters[2].uint64Value),
                        enabled: (entry["enabled"] as? NSNumber)?.boolValue ?? false)
    }

    /// Presses the shortcut the way a keyboard does: modifier keys down, the key, modifier keys up.
    /// Without the "up" for each modifier, macOS can go on thinking ⌃ is held, and the next click
    /// becomes a ⌃-click (a right-click).
    func press() {
        let source = CGEventSource(stateID: .hidSystemState)
        let modifiers: [(CGEventFlags, CGKeyCode)] = [(.maskControl, 0x3B), (.maskAlternate, 0x3A), (.maskShift, 0x38), (.maskCommand, 0x37)]
        let used = modifiers.filter { flags.contains($0.0) }
        var held: CGEventFlags = []
        for (flag, code) in used {
            held.insert(flag)
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
            event?.flags = held
            event?.post(tap: .cghidEventTap)
        }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        for (flag, code) in used.reversed() {
            held.remove(flag)
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
            event?.flags = held
            event?.post(tap: .cghidEventTap)
        }
    }
}
