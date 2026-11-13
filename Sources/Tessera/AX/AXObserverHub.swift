import AppKit
import ApplicationServices

/// One Accessibility observer per app, delivering notifications on the main actor.
@MainActor
final class AXObserverHub {
    typealias Handler = @MainActor (_ pid: pid_t, _ element: AXElement, _ notification: String) -> Void

    static let shared = AXObserverHub()

    private var observers: [pid_t: AXObserver] = [:]
    var handler: Handler?

    /// Creates the observer for an app. Returns false if the app can't be observed (yet).
    func start(pid: pid_t) -> Bool {
        if observers[pid] != nil { return true }
        var observer: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &observer) == .success, let observer else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
        return true
    }

    func stop(pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    @discardableResult
    func add(_ notification: String, to element: AXElement, pid: pid_t) -> AXError {
        guard let observer = observers[pid] else { return .invalidUIElementObserver }
        let refcon = UnsafeMutableRawPointer(bitPattern: Int(pid))
        return AXObserverAddNotification(observer, element.ref, notification as CFString, refcon)
    }

    func remove(_ notification: String, from element: AXElement, pid: pid_t) {
        guard let observer = observers[pid] else { return }
        AXObserverRemoveNotification(observer, element.ref, notification as CFString)
    }

    fileprivate func deliver(pid: pid_t, element: AXElement, notification: String) {
        handler?(pid, element, notification)
    }
}

/// C callback. The observer's run loop source lives on the main run loop,
/// so this always runs on the main thread.
private func axObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    let pid = pid_t(Int(bitPattern: refcon))
    let name = notification as String
    let wrapped = AXElement(element)
    MainActor.assumeIsolated {
        AXObserverHub.shared.deliver(pid: pid, element: wrapped, notification: name)
    }
}
