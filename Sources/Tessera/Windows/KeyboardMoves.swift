import AppKit
import TesseraCore

/// Focus the window to the left, right, above or below; send a window to another desktop.
@MainActor
enum KeyboardMoves {
    private static var sending = false

    static func perform(_ action: MoveAction) {
        guard AccessibilityPermission.isTrusted else {
            PermissionWindow.shared.show()
            return
        }
        if let direction = action.direction {
            focus(direction)
        } else if let n = action.desktopNumber {
            send(desktop: n, forward: nil)
        } else {
            send(desktop: nil, forward: action == .nextDesktop)
        }
    }

    // MARK: Focus by direction

    /// Windows you can see, on every screen: not minimised, hidden, waiting off screen or ignored.
    private static func visibleWindows() -> [TrackedWindow] {
        let registry = WindowRegistry.shared
        return WindowServer.onScreen().filter { $0.layer == 0 }.compactMap { info in
            guard let window = registry.window(info.id), window.isStandard,
                  !Settings.shared.isIgnored(window.bundleID), !AutoTiler.shared.isWaiting(info.id) else { return nil }
            return window
        }
    }

    private static func focus(_ direction: Direction) {
        guard let focused = WindowRegistry.shared.focusedWindow(), let frame = focused.frame else {
            NSSound.beep()
            return
        }
        let candidates = visibleWindows().filter { $0.id != focused.id }
            .compactMap { w in w.frame.map { (id: UInt32(w.id), frame: $0) } }
        guard let next = Navigation.neighbour(of: frame, direction: direction, among: candidates),
              let window = WindowRegistry.shared.window(CGWindowID(next)) else {
            NSSound.beep()
            return
        }
        AutoTiler.shared.focus(window)
    }

    // MARK: Send to a desktop

    /// macOS can't move a window to another desktop from outside its app, except the way a person does it:
    /// hold the window by its title bar and press "Move right a space" (⌃→) or "Move left a space" (⌃←).
    /// Tessera does exactly that, then puts the pointer back. macOS shows the new desktop afterwards.
    private static func send(desktop number: Int?, forward: Bool?) {
        guard !sending, let window = WindowRegistry.shared.focusedWindow(), let frame = window.frame,
              let display = Screens.display(for: frame, in: Screens.all()),
              let layout = Spaces.ordered(for: display) else {
            NSSound.beep()
            return
        }
        let presses: Int?
        if let number {
            presses = DesktopSteps.presses(spaces: layout.spaces, current: layout.current, toDesktop: number)
        } else {
            presses = DesktopSteps.presses(spaces: layout.spaces, current: layout.current, forward: forward ?? true)
        }
        guard let presses, presses != 0 else {
            NSSound.beep()
            if let number, presses == nil { Notice.shared.show("No Desktop \(number) on this screen") }
            return
        }
        guard let key = SpaceKey(right: presses > 0), key.enabled else {
            Notice.shared.show("Turn on “Move \(presses > 0 ? "right" : "left") a space” in Keyboard Shortcuts")
            return
        }
        guard let grab = grabPoint(of: window, frame: frame) else {
            NSSound.beep()
            return
        }
        let target = Self.target(layout: layout, presses: presses)
        sending = true
        DragSnapper.shared.suspended = true
        let home = Screens.mouseLocation
        Task { @MainActor in
            defer {
                DragSnapper.shared.suspended = false
                sending = false
            }
            // Press, then drag a few points the way a hand does, so macOS starts moving the window.
            var point = grab
            mouse(.mouseMoved, point)
            try? await Task.sleep(for: .milliseconds(60))
            mouse(.leftMouseDown, point)
            try? await Task.sleep(for: .milliseconds(150))
            for _ in 0..<10 {
                point.x += 2
                mouse(.leftMouseDragged, point)
                try? await Task.sleep(for: .milliseconds(20))
            }
            try? await Task.sleep(for: .milliseconds(150))
            let held = window.frame.map { abs($0.minX - frame.minX) >= 4 } ?? false
            Log.info("Send: holding window \(window.id) at \(Int(grab.x)),\(Int(grab.y)): \(held ? "it follows the pointer" : "it didn't move")")
            if held {
                for _ in 0..<abs(presses) {
                    key.press()
                    try? await Task.sleep(for: .milliseconds(700))
                    mouse(.leftMouseDragged, point)   // Keep the drag alive while the desktop slides.
                    try? await Task.sleep(for: .milliseconds(60))
                }
            }
            mouse(.leftMouseUp, point)
            try? await Task.sleep(for: .milliseconds(300))
            CGWarpMouseCursorPosition(home)
            guard held else {
                Notice.shared.show("Couldn't hold the window to move it")
                return
            }
            let landed = target.map { Spaces.spaces(of: window.id).contains($0) } ?? true
            Log.info("Sent window \(window.id) \(presses) desktops along: \(landed ? "done" : "didn't land")")
            if !landed { Notice.shared.show("macOS didn't move the window") }
        }
    }

    private static func target(layout: (spaces: [(id: UInt64, isDesktop: Bool)], current: UInt64), presses: Int) -> UInt64? {
        guard let from = layout.spaces.firstIndex(where: { $0.id == layout.current }),
              layout.spaces.indices.contains(from + presses) else { return nil }
        return layout.spaces[from + presses].id
    }

    /// A spot in the window's title bar that drags the window: the bar itself, the toolbar or the title,
    /// never a button, tab or text field. Found by asking Accessibility what sits at each spot.
    private static func grabPoint(of window: TrackedWindow, frame: CGRect) -> CGPoint? {
        let rows: [CGFloat] = [6, 10, 16, 24, 32]
        let columns: [CGFloat] = [0.5, 0.35, 0.65, 0.2, 0.8]
        let draggable: Set<String> = [kAXWindowRole, kAXToolbarRole, kAXStaticTextRole, "AXUnknown"]
        for dy in rows {
            for share in columns {
                let point = CGPoint(x: (frame.minX + frame.width * share).rounded(), y: frame.minY + dy)
                guard let hit = AXElement.element(at: point), hit.pid == window.pid,
                      let role = hit.role, draggable.contains(role) else { continue }
                if role == kAXWindowRole, hit.windowID != window.id { continue }
                Log.info("Send: grab point on \(role)")
                return point
            }
        }
        return nil
    }

    private static func mouse(_ type: CGEventType, _ point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
}

/// macOS's "Move left a space" / "Move right a space" shortcut, as set in Keyboard Shortcuts › Mission Control.
private struct SpaceKey {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    let enabled: Bool

    init?(right: Bool) {
        // Entries 79 (left) and 81 (right) in com.apple.symbolichotkeys; missing means the default, ⌃← / ⌃→.
        let entry = (UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .dictionary(forKey: "AppleSymbolicHotKeys")?[right ? "81" : "79"]) as? [String: Any]
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

    func press() {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: keyCode, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}
