import AppKit
import TesseraCore

/// Things that happen, and what the config file says to do about them: window rules for new windows,
/// commands when focus, the screen or the desktop changes, and shell commands. Also keeps the focus
/// history (for `focus back`) and tells `tessera subscribe` listeners.
@MainActor
final class Events {
    static let shared = Events()

    /// Windows focused lately, most recent last.
    private var history: [CGWindowID] = []
    private var lastDisplay: String?
    private var lastDesktop: Int?
    /// Windows the rules have looked at already.
    private var ruled: Set<CGWindowID> = []
    /// True while callbacks run: focus changes they cause don't start more callbacks.
    private var inCallback = false
    private let focusDebounce = Debouncer(delay: 0.08)
    private var subscribers: [(events: Set<String>, send: @Sendable (String) -> Bool)] = []

    func start() {
        WindowRegistry.shared.listen { [weak self] event in self?.handle(event) }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { Events.shared.desktopChanged() } }
        Desktops.noteChange()
        lastDesktop = currentDesktopNumber()
        if let window = WindowRegistry.shared.focusedWindow() { remember(window.id) }
        // Rules for windows already open when Tessera starts (rules can ask for these, or only new ones).
        after(1.0) { [weak self] in
            guard let self else { return }
            for id in WindowServer.onScreenIDs() {
                guard let window = WindowRegistry.shared.window(id), window.isStandard else { continue }
                self.applyRules(to: window, startup: true)
            }
            let startup = ConfigStore.shared.config.afterStartup
            if !startup.isEmpty { CommandRunner.run(startup) }
        }
    }

    // MARK: Focus history

    private func remember(_ id: CGWindowID) {
        history.removeAll { $0 == id }
        history.append(id)
        if history.count > 30 { history.removeFirst(history.count - 30) }
    }

    /// The window focused before this one that's still open.
    func previousFocus(excluding current: CGWindowID?) -> CGWindowID? {
        history.reversed().first { $0 != current && WindowRegistry.shared.window($0) != nil }
    }

    // MARK: Events

    private func handle(_ event: WindowEvent) {
        switch event {
        case .focused, .appActivated:
            focusDebounce.schedule { [weak self] in self?.focusChanged() }
        case .created(let id):
            // Give the app a moment to set the window's title.
            after(0.35) { [weak self] in
                guard let self, let window = WindowRegistry.shared.window(id) else { return }
                self.applyRules(to: window, startup: false)
                self.publish("window-detected", ["window-id": Int(id), "app-bundle-id": window.bundleID, "app-name": window.appName])
            }
        case .destroyed(let id):
            ruled.remove(id)
            history.removeAll { $0 == id }
            publish("window-closed", ["window-id": Int(id)])
        case .appHidden(let pid):
            if Settings.shared.unhideHiddenApps || ConfigStore.shared.config.unhideHiddenApps == true {
                after(0.1) { NSRunningApplication(processIdentifier: pid)?.unhide() }
            }
        default:
            break
        }
    }

    private func focusChanged() {
        guard let window = WindowRegistry.shared.focusedWindow() else { return }
        let changed = history.last != window.id
        remember(window.id)
        let config = ConfigStore.shared.config
        if changed {
            publish("focus-changed", ["window-id": Int(window.id), "app-bundle-id": window.bundleID, "app-name": window.appName])
            if !inCallback, !config.onFocusChanged.isEmpty { runCallback(config.onFocusChanged, window: window.id) }
        }
        let display = window.frame.flatMap { Screens.display(for: $0, in: Screens.all()) }?.stableID
        if let display, display != lastDisplay {
            let first = lastDisplay == nil
            lastDisplay = display
            if !first {
                publish("display-focus-changed", ["display": display])
                if !inCallback, !config.onDisplayFocusChanged.isEmpty { runCallback(config.onDisplayFocusChanged, window: window.id) }
            }
        }
    }

    private func desktopChanged() {
        Desktops.noteChange()
        let now = currentDesktopNumber()
        let previous = lastDesktop
        lastDesktop = now
        StatusMenu.shared.refreshTitle()
        publish("desktop-changed", ["desktop": now ?? 0, "previous": previous ?? 0])
        let argv = ConfigStore.shared.config.execOnDesktopChange
        if !argv.isEmpty {
            let focused: String = now.map { String($0) } ?? ""
            let before: String = previous.map { String($0) } ?? ""
            var extra: [String: String] = [:]
            extra["TESSERA_FOCUSED_DESKTOP"] = focused
            extra["TESSERA_PREV_DESKTOP"] = before
            extra["AEROSPACE_FOCUSED_WORKSPACE"] = focused
            extra["AEROSPACE_PREV_WORKSPACE"] = before
            launch(argv, extra: extra)
        }
    }

    func modeChanged(_ mode: String) {
        StatusMenu.shared.refreshTitle()
        publish("mode-changed", ["mode": mode])
        let commands = ConfigStore.shared.config.onModeChanged
        if !inCallback, !commands.isEmpty { runCallback(commands, window: nil) }
    }

    /// The number of the desktop the screen you're working on shows.
    func currentDesktopNumber() -> Int? {
        guard let display = WindowActions.display(of: WindowRegistry.shared.focusedWindow()),
              let layout = Desktops.layout(of: display) else { return nil }
        return layout.currentNumber
    }

    private func runCallback(_ commands: [String], window: CGWindowID?) {
        inCallback = true
        CommandRunner.run(commands, window: window)
        // Focus changes the commands cause arrive a moment later: keep ignoring them till then.
        after(0.3) { [weak self] in self?.inCallback = false }
    }

    // MARK: Window rules

    /// Runs the config's rules for a window, once per window.
    func applyRules(to window: TrackedWindow, startup: Bool) {
        let rules = ConfigStore.shared.config.rules
        guard !rules.isEmpty, ruled.insert(window.id).inserted else { return }
        let desktop = Spaces.spaces(of: window.id).first.flatMap(Desktops.number(of:))
        let commands = WindowRule.commands(for: rules, appID: window.bundleID, appName: window.appName,
                                           title: window.title, desktop: desktop, startup: startup)
        guard !commands.isEmpty else { return }
        Log.info("Rules for window \(window.id) (\(window.bundleID)): \(commands.joined(separator: "; "))")
        CommandRunner.run(commands, window: window.id)
    }

    // MARK: Shell commands

    /// Runs a shell command without waiting for it, with Homebrew on the PATH and the window's id in
    /// TESSERA_WINDOW_ID (and AEROSPACE_WINDOW_ID, for scripts written for AeroSpace).
    func exec(_ script: String, window: CGWindowID?) {
        var extra: [String: String] = [:]
        if let window {
            extra["TESSERA_WINDOW_ID"] = String(window)
            extra["AEROSPACE_WINDOW_ID"] = String(window)
        }
        launch(["/bin/bash", "-c", script], extra: extra)
    }

    private func launch(_ argv: [String], extra: [String: String]) {
        guard let program = argv.first else { return }
        let config = ConfigStore.shared.config
        var env = config.inheritEnvironment ? ProcessInfo.processInfo.environment : [:]
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:" + path
        for (key, value) in config.environment {
            var expanded = value
            for (name, current) in env { expanded = expanded.replacingOccurrences(of: "${\(name)}", with: current) }
            env[key] = expanded
        }
        for (key, value) in extra { env[key] = value }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program.hasPrefix("/") ? program : "/usr/bin/env")
        process.arguments = program.hasPrefix("/") ? Array(argv.dropFirst()) : argv
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Log.error("Couldn't run \(program): \(error.localizedDescription)")
        }
    }

    // MARK: Subscribers (`tessera subscribe`)

    /// Adds a listener. `send` returns false once the listener is gone.
    func subscribe(_ events: Set<String>, send: @escaping @Sendable (String) -> Bool) {
        subscribers.append((events, send))
    }

    private func publish(_ name: String, _ fields: [String: Any]) {
        guard !subscribers.isEmpty else { return }
        var payload = fields
        payload["event"] = name
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        subscribers = subscribers.filter { subscriber in
            subscriber.events.isEmpty || subscriber.events.contains(name) ? subscriber.send(line) : true
        }
    }
}
