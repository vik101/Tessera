import AppKit
import TesseraCore

/// Watches the mouse for ⌘-drag swaps, drags to other screens and edge resizes.
///
/// Uses global mouse monitors only — never keystrokes.
@MainActor
final class DragController {
    static let shared = DragController()

    private enum Mode { case none, moving, resizing }

    private struct Candidate {
        let id: CGWindowID
        let startFrame: CGRect
    }

    private var monitors: [Any] = []
    private var candidate: Candidate?
    private var mode: Mode = .none
    private var lastCheck = Date.distantPast
    private var tiling: TilingController { .shared }

    func start() {
        guard monitors.isEmpty else { return }
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }
        let dragged = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDragged() }
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseUp() }
        }
        let flags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] _ in
            MainActor.assumeIsolated { self?.flagsChanged() }
        }
        monitors = [down, dragged, up, flags].compactMap { $0 }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func mouseDown() {
        candidate = nil
        mode = .none
        guard tiling.isActive else { return }
        let point = Screens.mouseLocation
        // Ask the window server which window is really under the pointer (floating windows sit on top).
        var id = AXElement.element(at: point)?.window?.windowID
        if id == nil { id = tiling.tileHit(at: point)?.window }
        guard let id, tiling.isTiled(id), let frame = tiling.tileFrame(of: id) else { return }
        candidate = Candidate(id: id, startFrame: frame)
    }

    private func mouseDragged() {
        guard let candidate, Date().timeIntervalSince(lastCheck) > 0.05 else { return }
        lastCheck = Date()
        if mode == .none {
            guard let window = tiling.registry.window(candidate.id), let frame = window.frame else { return }
            let start = candidate.startFrame
            let resized = abs(frame.width - start.width) > 2 || abs(frame.height - start.height) > 2
            let moved = abs(frame.minX - start.minX) > 3 || abs(frame.minY - start.minY) > 3
            if resized {
                mode = .resizing
            } else if moved {
                mode = .moving
            }
            if mode != .none { tiling.dragInProgress = candidate.id }
        }
        if mode == .moving { updateHighlight() }
    }

    private func flagsChanged() {
        if mode == .moving { updateHighlight() }
    }

    private func updateHighlight() {
        guard let candidate else { return }
        let point = Screens.mouseLocation
        let flags = NSEvent.modifierFlags
        let sourceKey = tiling.keyOf(candidate.id)
        if flags.contains(.command), let hit = tiling.tileHit(at: point), hit.window != candidate.id, !tiling.isFloating(hit.window) {
            let label: String
            if flags.contains(.option) {
                label = L("Add to stack")
            } else if hit.tile == 0 {
                label = L("Make primary")
            } else {
                label = L("Swap")
            }
            DropHighlight.shared.show(frame: hit.frame, label: label)
            return
        }
        if let display = Screens.display(containing: point, in: tiling.displays), tiling.key(for: display) != sourceKey {
            DropHighlight.shared.show(frame: tiling.usableArea(display), label: L("Move here"))
            return
        }
        DropHighlight.shared.hide()
    }

    private func mouseUp() {
        defer {
            candidate = nil
            mode = .none
            DropHighlight.shared.hide()
        }
        guard let candidate, mode != .none else {
            tiling.dragInProgress = nil
            return
        }
        let flags = NSEvent.modifierFlags
        let point = Screens.mouseLocation
        let resized = mode == .resizing
        // Give the window a moment to settle at its final spot.
        after(0.06) { [weak self] in
            guard self != nil else { return }
            TilingController.shared.finishDrag(
                candidate.id,
                resized: resized,
                command: flags.contains(.command),
                option: flags.contains(.option),
                at: point
            )
        }
    }
}

/// Watches pointer movement for hover focus and the hover bar.
@MainActor
final class PointerTracker {
    static let shared = PointerTracker()

    private var monitor: Any?
    private var hoverTarget: CGWindowID?
    private var hoverTask: Task<Void, Never>?
    private var lastMove = Date()
    private var tiling: TilingController { .shared }
    private let prefs = Preferences.shared

    /// Installs or removes the mouse-move monitor based on settings.
    func update() {
        let needed = prefs.hoverFocus || prefs.quickActions
        if needed, monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
                MainActor.assumeIsolated { self?.moved() }
            }
        } else if !needed, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func moved() {
        lastMove = Date()
        let point = Screens.mouseLocation
        if prefs.quickActions { HoverBarController.shared.pointerMoved(to: point) }
        guard prefs.hoverFocus, tiling.isActive, NSEvent.pressedMouseButtons == 0 else { return }
        guard let hit = tiling.tileHit(at: point), hit.window != tiling.focusedID else {
            hoverTarget = nil
            hoverTask?.cancel()
            return
        }
        if hoverTarget == hit.window { return }
        hoverTarget = hit.window
        hoverTask?.cancel()
        let target = hit.window
        // Wait briefly so passing over windows doesn't activate each one.
        hoverTask = after(0.28) { [weak self] in self?.activate(target) }
    }

    private func activate(_ id: CGWindowID) {
        guard id == hoverTarget, NSEvent.pressedMouseButtons == 0, tiling.focusMode == nil else { return }
        // After a key press, the pointer must move again before hovering works.
        let sinceKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        if sinceKey < Date().timeIntervalSince(lastMove) { return }
        let point = Screens.mouseLocation
        guard tiling.tileHit(at: point)?.window == id else { return }
        // Make sure nothing (a floating window) is on top at that spot.
        if let top = WindowServer.onScreen().first(where: { $0.layer == 0 && $0.bounds.contains(point) }), top.id != id { return }
        guard let window = tiling.registry.window(id) else { return }
        tiling.applier.focus(window)
    }
}
