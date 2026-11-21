import AppKit
import TesseraCore

/// Entry point. Tessera lives in the menu bar (no Dock icon).
@main
@MainActor
enum TesseraMain {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engineStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        takeOverFromOtherCopies()
        buildMainMenu()
        StatusMenu.shared.install()
        Shortcuts.shared.start()
        TestHooks.shared.start()

        // Window work needs Accessibility. Start as soon as it's allowed.
        PermissionWindow.shared.onGranted = { [weak self] in self?.startEngine() }
        PermissionWindow.shared.begin()

        if !TestHooks.shared.isOn {
            after(0.8) { [weak self] in
                self?.warnAboutConflicts()
                self?.offerToTurnOffMacTiling()
            }
        }
        Log.info("Tessera \(AppInfo.version) started")
    }

    /// Opening Tessera again (from Finder or Spotlight) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.shared.show()
        return false
    }

    private func startEngine() {
        guard !engineStarted else { return }
        engineStarted = true
        WindowRegistry.shared.start()
        DragSnapper.shared.start()
        AutoTiler.shared.start()
        Log.info("Window engine started")
        // Tessera has no window of its own, so say hello: otherwise opening it looks like nothing happened.
        if !TestHooks.shared.isOn {
            after(0.6) {
                Notice.shared.show(Settings.shared.autoTile
                    ? "Tessera is running · auto-tile is on"
                    : "Tessera is running · it lives in the menu bar")
            }
        }
    }

    /// If another copy of Tessera is running (say, the old version you just replaced),
    /// the copy you opened last takes over: the other one quits first, so they never fight
    /// over shortcuts. (Before, the new copy quit silently, which looked like a crash.)
    private func takeOverFromOtherCopies() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != getpid() }
        guard !others.isEmpty else { return }
        Log.info("Replacing \(others.count) other running copy of Tessera")
        for other in others { other.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while others.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        for other in others where !other.isTerminated { other.forceTerminate() }
    }

    /// Rectangle and friends grab the same shortcuts. Offer to quit them.
    private func warnAboutConflicts() {
        guard let app = ConflictingApps.running.first else { return }
        let name = app.bundleIdentifier.flatMap { ConflictingApps.known[$0] } ?? app.displayName
        let alert = NSAlert()
        alert.messageText = "\(name) is also running"
        alert.informativeText = "\(name) uses the same keyboard shortcuts as Tessera, so Tessera's shortcuts may not respond. Quit \(name) to use Tessera."
        alert.addButton(withTitle: "Quit \(name)")
        alert.addButton(withTitle: "Keep Both")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            app.terminate()
            after(1.5) { Shortcuts.shared.reload() }
        }
    }

    /// macOS's own drag-to-edge tiling grabs the same drags as Tessera. Ask once.
    private func offerToTurnOffMacTiling() {
        let asked = "askedAboutMacTiling"
        guard Settings.shared.dragToSnap, MacTiling.edgeDragIsOn, !UserDefaults.standard.bool(forKey: asked) else { return }
        UserDefaults.standard.set(true, forKey: asked)
        let alert = NSAlert()
        alert.messageText = "Turn off macOS's own edge tiling?"
        alert.informativeText = "macOS also snaps windows you drag to a screen edge. The two get in each other's way. Tessera can turn off the macOS version (System Settings › Desktop & Dock › Drag windows to screen edges to tile)."
        alert.addButton(withTitle: "Turn It Off")
        alert.addButton(withTitle: "Keep Both")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            MacTiling.turnOffEdgeDrag()
        }
    }

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Tessera", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Tessera", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    @objc private func showSettings() { SettingsWindow.shared.show() }
}
