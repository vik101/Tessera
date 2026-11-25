import AppKit
import TesseraCore

/// Watches the mouse. Dragging a window to a screen edge or corner snaps it (like Rectangle).
/// With auto-tile on, dropping a window on another one swaps them.
@MainActor
final class DragSnapper {
    static let shared = DragSnapper()

    /// True while the left mouse button is down. Auto-tile waits until you let go.
    private(set) var isMouseDown = false

    private var monitors: [Any] = []
    private var window: TrackedWindow?
    private var startFrame: CGRect?
    private var isMoving = false
    private var lastSample: CGRect?
    private var lastCheck = Date.distantPast
    private var zone: (action: SnapAction, display: DisplayInfo)?
    private let settings = Settings.shared

    func start() {
        guard monitors.isEmpty else { return }
        let events: [(NSEvent.EventTypeMask, @MainActor () -> Void)] = [
            (.leftMouseDown, { [weak self] in self?.mouseDown() }),
            (.leftMouseDragged, { [weak self] in self?.mouseDragged() }),
            (.leftMouseUp, { [weak self] in self?.mouseUp() }),
        ]
        for (mask, handler) in events {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in
                MainActor.assumeIsolated { handler() }
            }) {
                monitors.append(monitor)
            }
        }
    }

    /// True while Tessera itself drives the mouse (sending a window to another desktop).
    var suspended = false

    /// A modifier drag is moving a window: auto-tile waits for it, as for any drag.
    func externalDrag(_ active: Bool) { isMouseDown = active }

    private func mouseDown() {
        isMouseDown = true
        if suspended { return }
        isMoving = false
        lastSample = nil
        zone = nil
        window = nil
        startFrame = nil
        guard AccessibilityPermission.isTrusted else { return }
        let point = Screens.mouseLocation
        guard let found = WindowRegistry.shared.window(at: point), !settings.isIgnored(found.bundleID) else { return }
        window = found
        startFrame = found.element.frame
    }

    private func mouseDragged() {
        guard !suspended, let window, let startFrame else { return }
        // Reading a window's frame is slow-ish; 30 times a second is plenty.
        guard Date().timeIntervalSince(lastCheck) > 0.033 else { return }
        lastCheck = Date()

        if !isMoving {
            // A move changes the position but not the size between two looks.
            // (macOS may resize a window once as a drag starts, so compare with the last look, not the start.)
            guard let frame = window.element.frame else { return }
            let previous = lastSample ?? startFrame
            lastSample = frame
            let moved = abs(frame.minX - previous.minX) > 2 || abs(frame.minY - previous.minY) > 2
            let resized = abs(frame.width - previous.width) > 2 || abs(frame.height - previous.height) > 2
            guard moved, !resized else { return }
            isMoving = true
            restoreSizeIfSnapped(window, frame: frame)
        }

        guard settings.dragToSnap else { return }
        zone = snapZone(at: Screens.mouseLocation)
        if let zone,
           let frame = window.element.frame,
           let target = SnapCalculator.frame(for: zone.action, SnapContext(
               window: frame, visible: zone.display.visibleFrame, gap: CGFloat(settings.gap))) {
            SnapPreview.shared.show(target)
        } else {
            SnapPreview.shared.hide()
        }
    }

    private func mouseUp() {
        isMouseDown = false
        SnapPreview.shared.hide()
        if suspended {
            window = nil
            startFrame = nil
            AutoTiler.shared.mouseReleased()
            return
        }
        defer {
            window = nil
            startFrame = nil
            zone = nil
            isMoving = false
        }
        let tiler = AutoTiler.shared
        guard let window, let startFrame, let frame = window.element.frame else {
            tiler.mouseReleased()
            return
        }
        let resized = abs(frame.width - startFrame.width) > 2 || abs(frame.height - startFrame.height) > 2
        let moved = abs(frame.minX - startFrame.minX) > 2 || abs(frame.minY - startFrame.minY) > 2
        if isMoving, let zone {
            SnapController.shared.dropSnap(zone.action, window: window, startFrame: startFrame, on: zone.display)
        } else if tiler.isOn, resized, !isMoving {
            tiler.userResized(window, from: startFrame, to: frame)
        } else if tiler.isOn, isMoving || moved {
            tiler.userDropped(window, at: Screens.mouseLocation)
        } else {
            tiler.mouseReleased()
        }
    }

    /// Rectangle-style: a snapped window you drag away gets its old size back, under the pointer.
    private func restoreSizeIfSnapped(_ window: TrackedWindow, frame: CGRect) {
        guard settings.restoreSizeOnDrag, let dragStart = startFrame,
              let size = SnapController.shared.sizeBeforeSnap(window, currentFrame: dragStart) else { return }
        SnapController.shared.forget(window)
        guard !AutoTiler.shared.isTiled(window) else { return }
        let mouse = Screens.mouseLocation
        let share = frame.width > 0 ? (mouse.x - frame.minX) / frame.width : 0.5
        let x = (mouse.x - size.width * share).rounded()
        window.element.setSize(size)
        window.element.setPosition(CGPoint(x: x, y: frame.minY))
        // Restore should now return to this size, not to the snapped frame the drag began from.
        startFrame = window.element.frame ?? dragStart
    }

    /// Which snap a drop at `point` means: edges give halves, corners give quarters,
    /// the top edge maximises, and the bottom edge gives thirds.
    private func snapZone(at point: CGPoint) -> (action: SnapAction, display: DisplayInfo)? {
        let displays = Screens.all()
        guard let display = Screens.display(containing: point, in: displays) else { return nil }
        let f = display.frame
        let edge: CGFloat = 6
        let corner: CGFloat = 28
        let left = point.x <= f.minX + edge
        let right = point.x >= f.maxX - edge - 1
        let top = point.y <= f.minY + edge
        let bottom = point.y >= f.maxY - edge - 1
        let nearTop = point.y <= f.minY + corner
        let nearBottom = point.y >= f.maxY - corner - 1
        let nearLeft = point.x <= f.minX + corner
        let nearRight = point.x >= f.maxX - corner - 1

        let action: SnapAction?
        if (left && nearTop) || (top && nearLeft) {
            action = .topLeft
        } else if (right && nearTop) || (top && nearRight) {
            action = .topRight
        } else if (left && nearBottom) || (bottom && nearLeft) {
            action = .bottomLeft
        } else if (right && nearBottom) || (bottom && nearRight) {
            action = .bottomRight
        } else if left {
            action = .leftHalf
        } else if right {
            action = .rightHalf
        } else if top {
            action = .maximise
        } else if bottom {
            let share = (point.x - f.minX) / f.width
            action = share < 1.0 / 3 ? .firstThird : share < 2.0 / 3 ? .centreThird : .lastThird
        } else {
            action = nil
        }
        guard let action else { return nil }
        // A screen edge shared with another screen isn't a snap edge: the pointer just crosses it.
        let west = CGPoint(x: f.minX - 2, y: point.y)
        let east = CGPoint(x: f.maxX + 2, y: point.y)
        let north = CGPoint(x: point.x, y: f.minY - 2)
        let south = CGPoint(x: point.x, y: f.maxY + 2)
        let probes: [CGPoint] = switch action {
        case .leftHalf: [west]
        case .rightHalf: [east]
        case .maximise: [north]
        case .topLeft: [west, north]
        case .topRight: [east, north]
        case .bottomLeft: [west, south]
        case .bottomRight: [east, south]
        default: [south]
        }
        if probes.contains(where: { Screens.display(containing: $0, in: displays) != nil }) { return nil }
        return (action, display)
    }
}
