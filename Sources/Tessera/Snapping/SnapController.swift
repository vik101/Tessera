import AppKit
import TesseraCore

/// Runs snap actions (Left Half, Maximise, Restore…) on the window you're working in.
@MainActor
final class SnapController {
    static let shared = SnapController()

    /// What Tessera remembers about a window it snapped.
    private struct Memory {
        /// Where the window was before Tessera first snapped it. Restore goes back here.
        var restore: CGRect
        var lastAction: SnapAction?
        var cycle = 0
        /// Where the last snap put it, so we can tell if you moved it since.
        var lastFrame: CGRect?
    }

    private var memory: [CGWindowID: Memory] = [:]
    private let registry = WindowRegistry.shared
    private let mover = WindowMover.shared
    private let settings = Settings.shared

    /// Snaps the focused window.
    func perform(_ action: SnapAction) {
        guard AccessibilityPermission.isTrusted else {
            PermissionWindow.shared.show()
            return
        }
        guard let window = registry.focusedWindow() else {
            NSSound.beep()
            return
        }
        perform(action, on: window)
    }

    func perform(_ action: SnapAction, on window: TrackedWindow) {
        guard !settings.isIgnored(window.bundleID), let frame = window.element.frame else {
            NSSound.beep()
            return
        }
        let displays = Screens.all()
        guard let display = Screens.display(for: frame, in: displays) else { return }
        let tiler = AutoTiler.shared

        // A fresh series of snaps starts when the window was moved since Tessera last touched it.
        var mem = memory[window.id] ?? Memory(restore: frame)
        if let last = mem.lastFrame, !frame.isClose(to: last, tolerance: 4) {
            mem = Memory(restore: frame)
        }

        // Make Larger / Smaller on a tile: it grows into its neighbours, and they shrink to make room.
        if action == .larger || action == .smaller, tiler.resizeTile(window, larger: action == .larger) { return }

        switch action {
        case .restore:
            if tiler.isOn, tiler.unpin(window) { return }   // Back into auto-tile.
            if tiler.evenOut(window) { return }             // A tile you made larger or smaller: back to even.
            guard let saved = memory[window.id] else {
                NSSound.beep()
                return
            }
            let target = Screens.display(for: saved.restore, in: displays) ?? display
            mover.move(window, to: saved.restore, within: target.visibleFrame)
            memory[window.id] = nil
            return

        case .nextDisplay, .previousDisplay:
            guard displays.count > 1 else {
                NSSound.beep()
                return
            }
            let ordered = displays.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
            let index = ordered.firstIndex(of: display) ?? 0
            let step = action == .nextDisplay ? 1 : -1
            let next = ordered[(index + step + ordered.count) % ordered.count]
            if tiler.isOn, tiler.isTiled(window) {
                tiler.move(window, to: next)
                return
            }
            var target = SnapCalculator.moveProportionally(frame, from: display.visibleFrame, to: next.visibleFrame)
            // A window snapped with Tessera keeps its snap (for example Left Half) on the new screen.
            if let last = mem.lastAction, last.region(shape: .standard) != nil,
               let snapped = SnapCalculator.frame(for: last, context(window: frame, on: next, cycle: mem.cycle)) {
                target = snapped
            }
            mem.lastFrame = mover.move(window, to: target, within: next.visibleFrame) ?? target
            memory[window.id] = mem
            if tiler.isOn { tiler.pin(window, at: mem.lastFrame!) }

        default:
            let repeated = settings.cycleSizes && action.cycles && mem.lastAction == action
            let cycle = repeated ? mem.cycle + 1 : 0
            guard let target = SnapCalculator.frame(for: action, context(window: frame, on: display, cycle: cycle)) else { return }
            if tiler.isOn { tiler.pin(window, at: target) }
            mem.lastAction = action
            mem.cycle = cycle
            mem.lastFrame = mover.move(window, to: target, within: display.visibleFrame) ?? target
            memory[window.id] = mem
        }
    }

    /// Snaps a window you dropped on a screen edge. `start` is where it was before the drag.
    func dropSnap(_ action: SnapAction, window: TrackedWindow, startFrame: CGRect, on display: DisplayInfo) {
        guard let frame = window.element.frame,
              let target = SnapCalculator.frame(for: action, context(window: frame, on: display, cycle: 0)) else { return }
        var mem = memory[window.id] ?? Memory(restore: startFrame)
        if mem.lastFrame == nil || !(mem.lastFrame!.isClose(to: startFrame, tolerance: 4)) {
            mem = Memory(restore: startFrame)
        }
        if AutoTiler.shared.isOn { AutoTiler.shared.pin(window, at: target) }
        mem.lastAction = action
        mem.cycle = 0
        mem.lastFrame = mover.move(window, to: target, within: display.visibleFrame) ?? target
        memory[window.id] = mem
    }

    /// The size to give back when you drag a snapped window away, or nil if it isn't snapped.
    func sizeBeforeSnap(_ window: TrackedWindow, currentFrame: CGRect) -> CGSize? {
        guard let mem = memory[window.id], let last = mem.lastFrame, last.isClose(to: currentFrame, tolerance: 4) else { return nil }
        return mem.restore.size
    }

    /// Forgets a window after you dragged it out of its snap.
    func forget(_ window: TrackedWindow) { memory[window.id] = nil }

    private func context(window: CGRect, on display: DisplayInfo, cycle: Int) -> SnapContext {
        SnapContext(window: window, visible: display.visibleFrame, gap: CGFloat(settings.gap), cycle: cycle)
    }
}
