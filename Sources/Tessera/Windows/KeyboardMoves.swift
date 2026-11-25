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
        } else if let window = WindowRegistry.shared.focusedWindow() {
            let target: DesktopTarget = action.desktopNumber.map { .number($0) } ?? (action == .nextDesktop ? .next : .previous)
            send(window, to: target, follow: true)
        } else {
            NSSound.beep()
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
        guard let focused = WindowRegistry.shared.focusedWindow() else {
            NSSound.beep()
            return
        }
        if !focus(from: focused, direction, wrap: false) { NSSound.beep() }
    }

    /// Focuses the window that way from `window`, on any screen. With `wrap`, at the edge it goes round
    /// to the window furthest the other way in line. Returns false when there's nothing to go to.
    @discardableResult
    static func focus(from window: TrackedWindow, _ direction: Direction, wrap: Bool) -> Bool {
        guard let frame = window.frame else { return false }
        let candidates = visibleWindows().filter { $0.id != window.id }
            .compactMap { w in w.frame.map { (id: UInt32(w.id), frame: $0) } }
        var next = Navigation.neighbour(of: frame, direction: direction, among: candidates)
        if next == nil, wrap {
            // Round to the far side: the furthest window the other way, staying in line.
            var furthest: UInt32?
            var probe = frame
            while let back = Navigation.neighbour(of: probe, direction: direction.opposite, among: candidates),
                  back != furthest, let f = candidates.first(where: { $0.id == back })?.frame {
                furthest = back
                probe = f
            }
            next = furthest
        }
        guard let next, let target = WindowRegistry.shared.window(CGWindowID(next)) else { return false }
        AutoTiler.shared.focus(target)
        return true
    }

    /// The windows you can see on a screen, front to back.
    static func visibleWindows(on display: DisplayInfo) -> [TrackedWindow] {
        visibleWindows().filter { window in
            window.frame.map { Screens.display(for: $0, in: Screens.all()) == display } ?? false
        }
    }

    // MARK: Send to a desktop

    /// macOS can't move a window to another desktop from outside its app, except the way a person does it:
    /// hold the window by its title bar and press "Move right a space" (⌃→) or "Move left a space" (⌃←).
    /// Tessera does exactly that, then puts the pointer back. macOS shows the new desktop afterwards;
    /// without `follow`, Tessera then switches back to the desktop you were on.
    static func send(_ window: TrackedWindow, to destination: DesktopTarget, follow: Bool) {
        guard !sending, let frame = window.frame,
              let display = Screens.display(for: frame, in: Screens.all()),
              let layout = Spaces.ordered(for: display) else {
            NSSound.beep()
            return
        }
        let presses: Int?
        switch destination {
        case .number(let number):
            presses = DesktopSteps.presses(spaces: layout.spaces, current: layout.current, toDesktop: number)
            if presses == nil { Notice.shared.show("No Desktop \(number) on this screen") }
        case .next:
            presses = DesktopSteps.presses(spaces: layout.spaces, current: layout.current, forward: true)
        case .previous:
            presses = DesktopSteps.presses(spaces: layout.spaces, current: layout.current, forward: false)
        case .last:
            presses = Desktops.lastSpace(for: display).flatMap { last in
                guard let to = layout.spaces.firstIndex(where: { $0.id == last }),
                      let from = layout.spaces.firstIndex(where: { $0.id == layout.current }) else { return nil }
                return to - from
            }
        }
        guard let presses, presses != 0 else {
            NSSound.beep()
            return
        }
        guard let key = SpaceKey(right: presses > 0), key.enabled else {
            Notice.shared.show("Turn on “Move \(presses > 0 ? "right" : "left") a space” in Keyboard Shortcuts")
            return
        }
        // The window must be on top, so the press lands on it and not on a window over it.
        window.element.perform(kAXRaiseAction)
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
            // If macOS didn't pick the window up, let go and try once more.
            var point = grab
            var held = false
            for attempt in 1...2 where !held {
                if attempt == 2 {
                    mouse(.leftMouseUp, point)
                    try? await Task.sleep(for: .milliseconds(400))
                    window.element.perform(kAXRaiseAction)
                    point = grab
                }
                let start = window.frame ?? frame
                mouse(.mouseMoved, point)
                try? await Task.sleep(for: .milliseconds(80))
                mouse(.leftMouseDown, point)
                try? await Task.sleep(for: .milliseconds(150))
                for _ in 0..<10 {
                    point.x += 2
                    mouse(.leftMouseDragged, point)
                    try? await Task.sleep(for: .milliseconds(20))
                }
                try? await Task.sleep(for: .milliseconds(150))
                held = window.frame.map { abs($0.minX - start.minX) >= 4 } ?? false
                Log.info("Send: holding window \(window.id) at \(Int(grab.x)),\(Int(grab.y)), try \(attempt): \(held ? "it follows the pointer" : "it didn't move")")
            }
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
            if landed, !follow, let back = SpaceKey(right: presses < 0), back.enabled {
                try? await Task.sleep(for: .milliseconds(400))
                for _ in 0..<abs(presses) { back.press() }
            }
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
                // Only this window's own title bar: another window of the same app may sit on top.
                if role == kAXWindowRole, hit.windowID != window.id { continue }
                if role != kAXWindowRole, let owner = hit.window?.windowID, owner != window.id { continue }
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
