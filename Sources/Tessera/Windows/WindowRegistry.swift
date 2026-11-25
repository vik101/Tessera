import AppKit
import ApplicationServices

/// A window Tessera knows about.
@MainActor
final class TrackedWindow {
    let id: CGWindowID
    let pid: pid_t
    let element: AXElement
    let bundleID: String
    let appName: String
    let discoveredAt = Date()

    init(id: CGWindowID, pid: pid_t, element: AXElement, bundleID: String, appName: String) {
        self.id = id
        self.pid = pid
        self.element = element
        self.bundleID = bundleID
        self.appName = appName
    }

    var frame: CGRect? { element.frame }
    var title: String { element.title ?? "" }
}

/// Things that happen to apps and windows.
enum WindowEvent {
    case created(CGWindowID)
    case destroyed(CGWindowID)
    case minimized(CGWindowID)
    case deminimized(CGWindowID)
    case moved(CGWindowID)
    case resized(CGWindowID)
    case titleChanged(CGWindowID)
    case focused(CGWindowID?)
    case appHidden(pid_t)
    case appShown(pid_t)
    case appActivated(pid_t)
    case appTerminated(pid_t, [CGWindowID])
    case appLaunched(pid_t)
}

/// Watches every regular app's windows through Accessibility.
@MainActor
final class WindowRegistry: NSObject {
    static let shared = WindowRegistry()

    private struct TrackedApp {
        let app: NSRunningApplication
        let element: AXElement
    }

    private var apps: [pid_t: TrackedApp] = [:]
    private(set) var windows: [CGWindowID: TrackedWindow] = [:]
    private var idByElement: [AXElement: CGWindowID] = [:]
    private let hub = AXObserverHub.shared

    var onEvent: ((WindowEvent) -> Void)?
    /// Others who want every event too (callbacks, the command line's `subscribe`).
    private var listeners: [(WindowEvent) -> Void] = []

    func listen(_ listener: @escaping (WindowEvent) -> Void) { listeners.append(listener) }

    private func emit(_ event: WindowEvent) {
        onEvent?(event)
        for listener in listeners { listener(event) }
    }

    private static let appNotifications = [
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXApplicationHiddenNotification,
        kAXApplicationShownNotification,
    ]

    private static let windowNotifications = [
        kAXUIElementDestroyedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXTitleChangedNotification,
    ]

    // MARK: Lifecycle

    func start() {
        hub.handler = { [weak self] pid, element, name in
            self?.handle(pid: pid, element: element, notification: name)
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(appLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appHidden(_:)), name: NSWorkspace.didHideApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appUnhidden(_:)), name: NSWorkspace.didUnhideApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        for app in NSWorkspace.shared.runningApplications {
            track(app, attempt: 0)
        }
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        for pid in apps.keys { hub.stop(pid: pid) }
        apps.removeAll()
        windows.removeAll()
        idByElement.removeAll()
    }

    // MARK: Queries

    func window(_ id: CGWindowID) -> TrackedWindow? { windows[id] }

    func windows(of pid: pid_t) -> [TrackedWindow] { windows.values.filter { $0.pid == pid } }

    func app(_ pid: pid_t) -> NSRunningApplication? { apps[pid]?.app }

    var trackedPIDs: [pid_t] { Array(apps.keys) }

    /// The window you're working in: the focused window of the frontmost app.
    func focusedWindow() -> TrackedWindow? {
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() else { return nil }
        let pid = front.processIdentifier
        let app = apps[pid]?.element ?? AXElement.application(pid)
        let candidates = [app.element(kAXFocusedWindowAttribute), app.element(kAXMainWindowAttribute)]
            + app.elements(kAXWindowsAttribute).map(Optional.some)
        for case let element? in candidates {
            guard element.role == kAXWindowRole, !element.isMinimized else { continue }
            if let window = register(element, pid: pid) { return window }
        }
        return nil
    }

    /// The window under a point on screen (Accessibility coordinates).
    func window(at point: CGPoint) -> TrackedWindow? {
        guard let element = AXElement.element(at: point)?.window, let pid = element.pid, pid != getpid() else { return nil }
        return register(element, pid: pid)
    }

    /// Re-reads every app's window list. Picks up windows we missed.
    @discardableResult
    func rescan() -> [CGWindowID] {
        var found: [CGWindowID] = []
        for (pid, tracked) in apps {
            for element in tracked.element.elements(kAXWindowsAttribute) {
                if let window = register(element, pid: pid) { found.append(window.id) }
            }
        }
        // Forget windows that no app lists any more and that no longer answer.
        let listed = Set(found)
        for (id, window) in windows where !listed.contains(id) && window.element.role == nil {
            forget(id)
        }
        return found
    }

    // MARK: Tracking apps

    private func shouldTrack(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular && app.processIdentifier != getpid() && !app.isTerminated
    }

    private func track(_ app: NSRunningApplication, attempt: Int) {
        guard shouldTrack(app) else { return }
        let pid = app.processIdentifier
        guard apps[pid] == nil else { return }
        let element = AXElement.application(pid)
        element.setMessagingTimeout(0.4)
        guard hub.start(pid: pid) else {
            retryTrack(app, attempt: attempt)
            return
        }
        var ok = true
        for name in Self.appNotifications {
            let error = hub.add(name, to: element, pid: pid)
            if error == .cannotComplete || error == .notImplemented && name == kAXWindowCreatedNotification {
                ok = false
            }
        }
        guard ok else {
            hub.stop(pid: pid)
            retryTrack(app, attempt: attempt)
            return
        }
        apps[pid] = TrackedApp(app: app, element: element)
        for windowElement in element.elements(kAXWindowsAttribute) {
            register(windowElement, pid: pid)
        }
    }

    private func retryTrack(_ app: NSRunningApplication, attempt: Int) {
        guard attempt < 12 else { return }
        after(0.25 * Double(attempt + 1)) { [weak self] in
            self?.track(app, attempt: attempt + 1)
        }
    }

    private func untrack(_ pid: pid_t) -> [CGWindowID] {
        hub.stop(pid: pid)
        apps.removeValue(forKey: pid)
        let ids = windows.values.filter { $0.pid == pid }.map(\.id)
        for id in ids { forget(id) }
        return ids
    }

    // MARK: Tracking windows

    @discardableResult
    func register(_ element: AXElement, pid: pid_t) -> TrackedWindow? {
        if let known = idByElement[element], let window = windows[known] { return window }
        guard element.role == kAXWindowRole, let id = element.windowID else { return nil }
        if let existing = windows[id] { return existing }
        let app = apps[pid]?.app ?? NSRunningApplication(processIdentifier: pid)
        let window = TrackedWindow(
            id: id,
            pid: pid,
            element: element,
            bundleID: app?.bundleIdentifier ?? "pid.\(pid)",
            appName: app?.displayName ?? "App"
        )
        windows[id] = window
        idByElement[element] = id
        for name in Self.windowNotifications {
            hub.add(name, to: element, pid: pid)
        }
        return window
    }

    private func forget(_ id: CGWindowID) {
        guard let window = windows.removeValue(forKey: id) else { return }
        idByElement.removeValue(forKey: window.element)
        for name in Self.windowNotifications {
            hub.remove(name, from: window.element, pid: window.pid)
        }
    }

    // MARK: Accessibility notifications

    private func handle(pid: pid_t, element: AXElement, notification: String) {
        switch notification {
        case kAXWindowCreatedNotification:
            if let window = register(element, pid: pid) {
                emit(.created(window.id))
            }
        case kAXUIElementDestroyedNotification:
            if let id = idByElement[element] {
                forget(id)
                emit(.destroyed(id))
            }
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                let window = element.role == kAXWindowRole ? register(element, pid: pid) : nil
                emit(.focused(window?.id))
            }
        case kAXWindowMovedNotification:
            if let id = idByElement[element] { emit(.moved(id)) }
        case kAXWindowResizedNotification:
            if let id = idByElement[element] { emit(.resized(id)) }
        case kAXWindowMiniaturizedNotification:
            if let id = idByElement[element] { emit(.minimized(id)) }
        case kAXWindowDeminiaturizedNotification:
            if let id = idByElement[element] { emit(.deminimized(id)) }
        case kAXTitleChangedNotification:
            if let id = idByElement[element] { emit(.titleChanged(id)) }
        case kAXApplicationHiddenNotification:
            emit(.appHidden(pid))
        case kAXApplicationShownNotification:
            emit(.appShown(pid))
        default:
            break
        }
    }

    // MARK: Workspace notifications

    private static func runningApp(_ note: Notification) -> NSRunningApplication? {
        note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }

    @objc private func appLaunched(_ note: Notification) {
        guard let app = Self.runningApp(note) else { return }
        track(app, attempt: 0)
        emit(.appLaunched(app.processIdentifier))
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = Self.runningApp(note) else { return }
        let ids = untrack(app.processIdentifier)
        emit(.appTerminated(app.processIdentifier, ids))
    }

    @objc private func appHidden(_ note: Notification) {
        guard let app = Self.runningApp(note) else { return }
        emit(.appHidden(app.processIdentifier))
    }

    @objc private func appUnhidden(_ note: Notification) {
        guard let app = Self.runningApp(note) else { return }
        emit(.appShown(app.processIdentifier))
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = Self.runningApp(note) else { return }
        if apps[app.processIdentifier] == nil { track(app, attempt: 0) }
        emit(.appActivated(app.processIdentifier))
    }
}
