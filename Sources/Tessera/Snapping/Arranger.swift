import AppKit
import TesseraCore

/// Rectangle's many-window actions: Tile All, Tile in Rows or Columns, Cascade, Reverse All,
/// and stepping through windows stacked on one spot.
///
/// With auto-tile on, the tiling ones choose the matching layout instead (Grid, Rows, Columns),
/// so the two never fight. Cascading needs auto-tile off.
@MainActor
final class Arranger {
    static let shared = Arranger()

    private let registry = WindowRegistry.shared
    private let mover = WindowMover.shared
    private let settings = Settings.shared

    func perform(_ action: ArrangeAction) {
        guard AccessibilityPermission.isTrusted else {
            PermissionWindow.shared.show()
            return
        }
        let tiler = AutoTiler.shared
        switch action {
        case .nextInStack, .previousInStack:
            cycleStack(forward: action == .nextInStack)
            return
        case .tileAll where tiler.isOn: tiler.chooseLayout(.grid); return
        case .tileRows where tiler.isOn: tiler.chooseLayout(.rows); return
        case .tileColumns where tiler.isOn: tiler.chooseLayout(.columns); return
        case .reverseAll where tiler.isOn: tiler.reverseOrder(); return
        case .cascadeAll where tiler.isOn, .cascadeApp where tiler.isOn:
            NSSound.beep()
            Notice.shared.show("Turn off auto-tile to cascade")
            return
        default: break
        }

        guard let (display, windows) = windowsOnFocusedScreen(), !windows.isEmpty else {
            NSSound.beep()
            return
        }
        let area = display.visibleFrame
        let gap = CGFloat(settings.gap)
        switch action {
        case .tileAll:
            place(windows, Arrange.tileAll(windows.count, in: area, gap: gap), on: display)
        case .tileRows:
            place(windows, Arrange.rows(windows.count, in: area, gap: gap), on: display)
        case .tileColumns:
            place(windows, Arrange.columns(windows.count, in: area, gap: gap), on: display)
        case .cascadeAll, .cascadeApp:
            var list = windows
            if action == .cascadeApp, let focused = registry.focusedWindow() {
                list = windows.filter { $0.pid == focused.pid }
            }
            // Back to front, so the window you're in ends on top, at the bottom right of the cascade.
            list.reverse()
            let frames = Arrange.cascade(list.map { $0.frame?.size ?? area.size }, in: area.insetBy(dx: gap, dy: gap))
            place(list, frames, on: display)
            list.forEach { $0.element.perform(kAXRaiseAction) }
        case .reverseAll:
            for window in windows {
                if let frame = window.frame { mover.move(window, to: Arrange.reversed(frame, in: area), within: area) }
            }
        case .nextInStack, .previousInStack:
            break
        }
    }

    /// Ordinary windows on the screen with the focused window, front to back, on the desktop you can see.
    private func windowsOnFocusedScreen() -> (DisplayInfo, [TrackedWindow])? {
        let displays = Screens.all()
        guard let focused = registry.focusedWindow(), let frame = focused.frame,
              let display = Screens.display(for: frame, in: displays) else { return nil }
        let windows = WindowServer.onScreen().filter { $0.layer == 0 }.compactMap { info -> TrackedWindow? in
            guard let window = registry.window(info.id), window.isStandard, !settings.isIgnored(window.bundleID),
                  let frame = window.frame, Screens.display(for: frame, in: displays) == display else { return nil }
            return window
        }
        return (display, windows)
    }

    private func place(_ windows: [TrackedWindow], _ frames: [CGRect], on display: DisplayInfo) {
        for (window, frame) in zip(windows, frames) {
            mover.move(window, to: frame, within: display.visibleFrame)
        }
    }

    /// Brings forward the next window sitting on the same spot as the focused one.
    private func cycleStack(forward: Bool) {
        guard let focused = registry.focusedWindow(), let frame = focused.frame,
              let (_, windows) = windowsOnFocusedScreen() else {
            NSSound.beep()
            return
        }
        let candidates = windows.compactMap { w in w.frame.map { (id: UInt32(w.id), frame: $0) } }
        let stack = Arrange.stack(of: (id: UInt32(focused.id), frame: frame), among: candidates)
        guard let next = Arrange.step(stack, from: UInt32(focused.id), forward: forward),
              let window = registry.window(CGWindowID(next)) else {
            NSSound.beep()
            return
        }
        AutoTiler.shared.focus(window)
    }
}
