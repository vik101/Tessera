import AppKit
import SwiftUI
import TesseraCore

/// Entry point. Tessera is a menu bar app (no Dock icon unless a window is open).
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
    private var whatsNewWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let prefs = Preferences.shared
        AppAppearance.apply(prefs.appearance)
        AppIconStyle.apply(prefs.appIcon)
        buildMainMenu()

        LicenseManager.shared.start()
        let tiling = TilingController.shared
        tiling.onChange = { Overlays.refresh() }

        StatusItemController.shared.install()
        SystemMonitor.shared.start()
        tiling.start()
        DragController.shared.start()
        PointerTracker.shared.update()
        ShortcutCenter.shared.reload()
        UpdateController.shared.start()
        AppModel.shared.noPeekOn = prefs.noPeek

        if !prefs.onboardingComplete {
            OnboardingWindowController.shared.show()
        } else {
            if !AccessibilityPermission.isTrusted { AccessibilityPermission.prompt() }
            if prefs.lastSeenVersion != AppConfig.version {
                prefs.lastSeenVersion = AppConfig.version
                showWhatsNew()
            }
        }
        Log.info("\(AppConfig.appName) \(AppConfig.version) started")
    }

    /// Opening the app again (Finder, Spotlight) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Windows stay where they are; only our own overlays go away.
        CleanSpaceController.shared.turnOff()
        NoPeekController.shared.clear()
        HighlightController.shared.clear()
    }

    private func showWhatsNew() {
        let view = WhatsNewView(onDone: { [weak self] in self?.whatsNewWindow?.close() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = L("What's New")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        whatsNewWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Menu

    /// A small main menu so ⌘, ⌘Q and copy/paste work in Settings.
    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(item(L("Settings…"), #selector(openSettings), ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: L("Hide %@", AppConfig.appName), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: L("Quit %@", AppConfig.appName), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L("Edit"))
        editMenu.addItem(NSMenuItem(title: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: L("Redo"), action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: L("Window"))
        windowMenu.addItem(NSMenuItem(title: L("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(title: L("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }
}

/// Redraws every overlay after the arrangement or focus changes.
@MainActor
enum Overlays {
    private static let debouncer = Debouncer(delay: 0.03)

    static func refresh() {
        debouncer.schedule {
            HighlightController.shared.refresh()
            NoPeekController.shared.refresh()
            CleanSpaceController.shared.refresh()
            HoverBarController.shared.refresh()
            StatusItemController.shared.refreshIcon()
        }
    }
}
