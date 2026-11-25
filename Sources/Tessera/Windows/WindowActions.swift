import AppKit
import TesseraCore

/// One-off things done to a window or a screen: close, minimise, full screen, focus a screen, move the pointer.
@MainActor
enum WindowActions {
    /// Presses the window's close button. With `quitIfLast`, an app with no other window quits.
    static func close(_ window: TrackedWindow, quitIfLast: Bool) -> Bool {
        let others = WindowRegistry.shared.windows(of: window.pid).filter { $0.id != window.id && $0.isStandard }
        guard let button = window.element.element(kAXCloseButtonAttribute) else { return false }
        button.perform(kAXPressAction)
        if quitIfLast, others.isEmpty, let app = NSRunningApplication(processIdentifier: window.pid) {
            after(0.3) { app.terminate() }
        }
        return true
    }

    /// Closes every other window on the desktop the window's screen shows.
    static func closeOthers(than window: TrackedWindow, quitIfLast: Bool) -> Bool {
        guard let frame = window.frame, let display = Screens.display(for: frame, in: Screens.all()) else { return false }
        for other in KeyboardMoves.visibleWindows(on: display) where other.id != window.id {
            _ = close(other, quitIfLast: quitIfLast)
        }
        return true
    }

    static func minimize(_ window: TrackedWindow) -> Bool {
        window.element.set(kAXMinimizedAttribute, bool: true)
        return true
    }

    static func nativeFullScreen(_ window: TrackedWindow, _ toggle: Toggle) -> Bool {
        let now = window.element.isFullScreen
        let want = toggle.apply(to: now)
        guard want != now else { return true }
        window.element.set("AXFullScreen", bool: want)
        return true
    }

    /// The screen a window is on, or the one with the pointer.
    static func display(of window: TrackedWindow?) -> DisplayInfo? {
        let displays = Screens.all()
        if let frame = window?.frame, let display = Screens.display(for: frame, in: displays) { return display }
        return Screens.display(containing: Screens.mouseLocation, in: displays) ?? displays.first
    }

    /// Finds a screen from a target, counting from `from`.
    static func display(_ target: DisplayTarget, from: DisplayInfo?, wrap: Bool) -> DisplayInfo? {
        let displays = Screens.ordered(Screens.all())
        guard !displays.isEmpty else { return nil }
        switch target {
        case .number(let n):
            return displays.indices.contains(n - 1) ? displays[n - 1] : nil
        case .pattern(let pattern):
            return displays.first { DisplayPattern.matches(pattern, Screens.context(of: $0, in: displays)) }
        case .next, .previous:
            guard let from, let index = displays.firstIndex(of: from) else { return displays.first }
            let i = index + (target == .next ? 1 : -1)
            if displays.indices.contains(i) { return displays[i] }
            return wrap && displays.count > 1 ? displays[(i + displays.count) % displays.count] : nil
        case .direction(let direction):
            guard let from else { return nil }
            let others = displays.filter { $0 != from }.map { (id: UInt32($0.displayID), frame: $0.frame) }
            if let id = Navigation.neighbour(of: from.frame, direction: direction, among: others) {
                return displays.first { $0.displayID == CGDirectDisplayID(id) }
            }
            guard wrap else { return nil }
            // Round to the screen furthest the other way.
            var furthest: DisplayInfo?
            var probe = from.frame
            while let id = Navigation.neighbour(of: probe, direction: direction.opposite, among: others),
                  let next = displays.first(where: { $0.displayID == CGDirectDisplayID(id) }), next != furthest {
                furthest = next
                probe = next.frame
            }
            return furthest
        }
    }

    /// Focuses the front window on a screen; an empty screen gets the pointer instead.
    static func focus(_ display: DisplayInfo) -> Bool {
        if let window = KeyboardMoves.visibleWindows(on: display).first {
            AutoTiler.shared.focus(window)
            return true
        }
        CGWarpMouseCursorPosition(CGPoint(x: display.frame.midX, y: display.frame.midY))
        return true
    }

    /// Sends a window to another screen: into its tiles when auto-tile is on, else to the same spot there.
    static func send(_ window: TrackedWindow, to display: DisplayInfo, follow: Bool) -> Bool {
        guard let frame = window.frame, let from = Screens.display(for: frame, in: Screens.all()), from != display else { return false }
        let tiler = AutoTiler.shared
        if tiler.isOn, tiler.isTiled(window) {
            tiler.move(window, to: display)
        } else {
            let moved = SnapCalculator.moveProportionally(frame, from: from.visibleFrame, to: display.visibleFrame)
            WindowMover.shared.move(window, to: moved, within: display.visibleFrame)
        }
        if !follow, let stay = KeyboardMoves.visibleWindows(on: from).first(where: { $0.id != window.id }) {
            after(0.2) { tiler.focus(stay) }
        }
        return true
    }

    /// Moves the pointer to the middle of the focused window or its screen. "Lazy" leaves it alone
    /// when it's already there.
    static func moveMouse(_ target: MouseTarget, window: TrackedWindow?) -> Bool {
        let point = Screens.mouseLocation
        switch target {
        case .windowLazyCenter, .windowForceCenter:
            guard let frame = window?.frame else { return false }
            if target == .windowLazyCenter, frame.contains(point) { return true }
            CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
        case .displayLazyCenter, .displayForceCenter:
            guard let display = display(of: window) else { return false }
            if target == .displayLazyCenter, display.frame.contains(point) { return true }
            CGWarpMouseCursorPosition(CGPoint(x: display.frame.midX, y: display.frame.midY))
        }
        return true
    }

    /// Changes the sound volume, like the keyboard's volume keys.
    static func volume(_ change: VolumeChange) -> Bool {
        let script: String
        switch change {
        case .up: script = "set volume output volume ((output volume of (get volume settings)) + 6)"
        case .down: script = "set volume output volume ((output volume of (get volume settings)) - 6)"
        case .muteToggle: script = "set volume output muted (not (output muted of (get volume settings)))"
        case .muteOn: script = "set volume with output muted"
        case .muteOff: script = "set volume without output muted"
        case .set(let n): script = "set volume output volume \(n)"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        do { try process.run() } catch { return false }
        return true
    }
}
