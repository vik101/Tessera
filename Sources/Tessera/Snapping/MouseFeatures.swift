import AppKit
import TesseraCore

/// Hold a modifier (fn by default) and drag anywhere in a window to move it, like Spacetile's fn-drag
/// and macOS's ⌃⌘-drag. Tessera watches mouse presses with an event tap, and only takes the ones
/// made while that modifier is held; every other click goes to the app as usual.
@MainActor
final class ModifierDrag {
    static let shared = ModifierDrag()

    fileprivate var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var window: TrackedWindow?
    private var offset = CGPoint.zero
    private var lastMove = Date.distantPast
    /// True while a modifier drag is moving a window.
    var isDragging: Bool { window != nil }

    func start() {
        Settings.shared.observe { [weak self] change in
            if change == .other { self?.refresh() }
        }
        refresh()
    }

    /// The modifier flags the setting asks for, or nil when it's off.
    private var required: CGEventFlags? {
        switch Settings.shared.moveModifier {
        case "fn": [.maskSecondaryFn]
        case "ctrl-cmd": [.maskControl, .maskCommand]
        case "cmd-alt": [.maskCommand, .maskAlternate]
        case "ctrl-alt": [.maskControl, .maskAlternate]
        default: nil
        }
    }

    func refresh() {
        let wanted = required != nil && AccessibilityPermission.isTrusted
        if wanted && tap == nil {
            install()
        } else if !wanted, let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            self.tap = nil
            source = nil
        }
    }

    private func install() {
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: modifierDragCallback, userInfo: nil) else {
            Log.error("Couldn't watch the mouse for modifier-drag")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.source = source
    }

    /// Returns true when Tessera takes the event (the app never sees it).
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let point = event.location
        switch type {
        case .leftMouseDown:
            guard let required, event.flags.contains(required), !DragSnapper.shared.suspended,
                  let found = WindowRegistry.shared.window(at: point), !Settings.shared.isIgnored(found.bundleID),
                  let frame = found.frame else { return false }
            window = found
            offset = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
            DragSnapper.shared.externalDrag(true)
            return true
        case .leftMouseDragged:
            guard let window else { return false }
            guard Date().timeIntervalSince(lastMove) > 1.0 / 60 else { return true }
            lastMove = Date()
            window.element.setPosition(CGPoint(x: point.x - offset.x, y: point.y - offset.y))
            return true
        case .leftMouseUp:
            guard let window else { return false }
            window.element.setPosition(CGPoint(x: point.x - offset.x, y: point.y - offset.y))
            self.window = nil
            DragSnapper.shared.externalDrag(false)
            let tiler = AutoTiler.shared
            if tiler.isOn, tiler.isTiled(window) {
                tiler.userDropped(window, at: point)
            } else {
                tiler.mouseReleased()
            }
            return true
        default:
            return false
        }
    }
}

private func modifierDragCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                                  _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated {
            if let tap = ModifierDrag.shared.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        }
        return Unmanaged.passUnretained(event)
    }
    let taken = MainActor.assumeIsolated { ModifierDrag.shared.handle(type, event) }
    return taken ? nil : Unmanaged.passUnretained(event)
}

/// Focus follows the mouse (off by default): resting the pointer on a window for a moment focuses it.
@MainActor
final class FocusFollowsMouse {
    static let shared = FocusFollowsMouse()

    private var monitor: Any?
    private let debouncer = Debouncer(delay: 0.15)

    func start() {
        Settings.shared.observe { [weak self] change in
            if change == .other { self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        let wanted = Settings.shared.focusFollowsMouse
        if wanted, monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { _ in
                MainActor.assumeIsolated { FocusFollowsMouse.shared.moved() }
            }
        } else if !wanted, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func moved() {
        debouncer.schedule {
            guard NSEvent.pressedMouseButtons == 0, !ModifierDrag.shared.isDragging, AccessibilityPermission.isTrusted,
                  let window = WindowRegistry.shared.window(at: Screens.mouseLocation), window.isStandard,
                  !Settings.shared.isIgnored(window.bundleID),
                  WindowRegistry.shared.focusedWindow()?.id != window.id else { return }
            AutoTiler.shared.focus(window)
        }
    }
}
