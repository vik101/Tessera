import AppKit
import TesseraCore

/// Saved setups: the apps on your screens and where their windows go, opened again in one step.
@MainActor
enum Setups {
    private static var opening = false
    private static var knownScreens: Set<String> = Set(Screens.all().map(\.stableID))

    /// Screens changed: a setup that opens when its screens connect does so (once they've settled).
    static func screensChanged() {
        let now = Set(Screens.all().map(\.stableID))
        let added = now.subtracting(knownScreens)
        knownScreens = now
        guard !added.isEmpty,
              let setup = Settings.shared.setups.first(where: { $0.opens(whenAdded: added, connected: now) }) else { return }
        Log.info("Screens connected: opening setup “\(setup.name)”")
        after(2.5) { open(setup) }
    }

    /// Saves the windows on screen now (every screen, this desktop) as a setup, replacing one of the same name.
    @discardableResult
    static func save(name: String) -> Setup? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, AccessibilityPermission.isTrusted else {
            NSSound.beep()
            return nil
        }
        let displays = Screens.all()
        var entries: [Setup.Entry] = []
        for info in WindowServer.onScreen() where info.layer == 0 {
            guard let window = WindowRegistry.shared.window(info.id), window.isStandard,
                  !Settings.shared.isIgnored(window.bundleID), !AutoTiler.shared.isWaiting(info.id),
                  let frame = window.frame, let display = Screens.display(for: frame, in: displays) else { continue }
            entries.append(.init(bundleID: window.bundleID, screen: display.stableID, place: Setup.unit(of: frame, in: display.visibleFrame)))
        }
        guard !entries.isEmpty else {
            NSSound.beep()
            Notice.shared.show("No windows to save")
            return nil
        }
        var layouts: [String: String] = [:]
        if AutoTiler.shared.isOn {
            for display in displays { layouts[display.stableID] = AutoTiler.shared.layout(for: display).rawValue }
        }
        let old = Settings.shared.setups.first { $0.name == name }
        let setup = Setup(name: name, entries: entries, layouts: layouts, hideOthers: old?.hideOthers ?? true)
        var list = Settings.shared.setups.filter { $0.name != name }
        if let index = Settings.shared.setups.firstIndex(where: { $0.name == name }) {
            list.insert(setup, at: min(index, list.count))
        } else {
            list.append(setup)
        }
        Settings.shared.setups = list
        Notice.shared.show("Saved “\(name)”")
        Log.info("Setup saved: \(entries.count) windows")
        return setup
    }

    /// Asks for a name, then saves.
    static func saveWithPrompt() {
        let alert = NSAlert()
        alert.messageText = "Save Current Setup"
        alert.informativeText = "Saves the apps on your screens and where their windows are."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Name, such as Work"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        save(name: field.stringValue)
    }

    static func open(number: Int) {
        let list = Settings.shared.setups
        guard list.indices.contains(number - 1) else {
            NSSound.beep()
            return
        }
        open(list[number - 1])
    }

    static func open(name: String) {
        guard let setup = Settings.shared.setups.first(where: { $0.name == name }) else {
            NSSound.beep()
            Log.error("No setup named \(name)")
            return
        }
        open(setup)
    }

    /// Opens the setup's apps that aren't running, waits for their windows, hides other apps
    /// (if the setup says so), then puts each window back on its screen and in its place.
    static func open(_ setup: Setup) {
        guard AccessibilityPermission.isTrusted else {
            PermissionWindow.shared.show()
            return
        }
        guard !opening else { return }
        opening = true
        Task { @MainActor in
            defer { opening = false }
            let me = Bundle.main.bundleIdentifier
            for id in setup.apps where NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
            }
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                guard let id = app.bundleIdentifier, id != me else { continue }
                if setup.apps.contains(id) {
                    if app.isHidden { app.unhide() }
                } else if setup.hideOthers {
                    app.hide()
                }
            }
            // Wait (up to 8 seconds) until each app shows as many windows as the setup has for it.
            let wanted = Dictionary(setup.entries.map { ($0.bundleID, 1) }, uniquingKeysWith: +)
            for _ in 0..<32 {
                let have = Dictionary(windowsOnScreen().map { ($0.bundleID, 1) }, uniquingKeysWith: +)
                if wanted.allSatisfy({ have[$0.key, default: 0] >= $0.value }) { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            place(setup)
            Notice.shared.show("Opened “\(setup.name)”")
            Log.info("Setup opened: \(setup.entries.count) windows")
        }
    }

    private static func windowsOnScreen() -> [TrackedWindow] {
        WindowServer.onScreen().filter { $0.layer == 0 }.compactMap { info in
            guard let window = WindowRegistry.shared.window(info.id), window.isStandard else { return nil }
            return window
        }
    }

    private static func place(_ setup: Setup) {
        let displays = Screens.all()
        let main = displays.first(where: \.isMain) ?? displays.first
        let windows = windowsOnScreen()
        let assigned = setup.assign(windows.map { (id: $0.id, bundleID: $0.bundleID) })
        let tiler = AutoTiler.shared
        if tiler.isOn {
            for (screen, raw) in setup.layouts {
                if let display = displays.first(where: { $0.stableID == screen }), let style = LayoutStyle(rawValue: raw) {
                    tiler.setLayout(style, for: display, notify: false)
                }
            }
        }
        for (id, entry) in assigned {
            guard let window = WindowRegistry.shared.window(id),
                  let display = displays.first(where: { $0.stableID == entry.screen }) ?? main else { continue }
            if tiler.isOn, tiler.isTiled(window) {
                if let frame = window.frame, Screens.display(for: frame, in: displays) != display { tiler.move(window, to: display) }
            } else {
                WindowMover.shared.move(window, to: display.visibleFrame.part(entry.place), within: display.visibleFrame)
            }
        }
        // Stack them as saved: the first entry ends on top.
        for (id, _) in assigned.reversed() {
            WindowRegistry.shared.window(id)?.element.perform(kAXRaiseAction)
        }
        if let first = assigned.first.flatMap({ WindowRegistry.shared.window($0.id) }) { tiler.focus(first) }
    }
}
