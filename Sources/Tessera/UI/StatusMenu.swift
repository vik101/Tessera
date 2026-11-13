import AppKit
import TesseraCore

/// The menu bar icon and its menu, laid out like Rectangle's.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    static let shared = StatusMenu()

    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuIcons.statusIcon
        item.button?.setAccessibilityLabel("Tessera")
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
    }

    /// Opens the menu (used by the test harness to take a screenshot).
    func open() { statusItem?.button?.performClick(nil) }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    private func rebuild() {
        menu.removeAllItems()
        let settings = Settings.shared
        let tiler = AutoTiler.shared
        let shortcuts = settings.shortcuts

        // Problems first, so they're hard to miss.
        var warnings = false
        if !AccessibilityPermission.isTrusted {
            menu.addItem(item("⚠︎ Allow Accessibility Access…", #selector(showPermission)))
            warnings = true
        }
        for app in ConflictingApps.running {
            let name = app.bundleIdentifier.flatMap { ConflictingApps.known[$0] } ?? app.displayName
            let quit = item("⚠︎ Quit \(name) (it uses the same shortcuts)", #selector(quitConflictingApp(_:)))
            quit.representedObject = app.processIdentifier
            menu.addItem(quit)
            warnings = true
        }
        if settings.dragToSnap, MacTiling.edgeDragIsOn {
            menu.addItem(item("⚠︎ Turn Off macOS Edge Tiling (it fights drag-to-snap)", #selector(turnOffMacTiling)))
            warnings = true
        }
        if !Shortcuts.shared.failed.isEmpty {
            menu.addItem(item("⚠︎ Some shortcuts are taken by another app…", #selector(showSettings)))
            warnings = true
        }
        if warnings { menu.addItem(.separator()) }

        // Snap actions.
        for group in SnapGroup.allCases where group.submenuTitle == nil {
            for action in SnapAction.allCases where action.group == group {
                menu.addItem(commandItem(.snap(action), shortcuts: shortcuts, icon: action.iconRegion))
            }
            menu.addItem(.separator())
        }
        for group in SnapGroup.allCases {
            guard let title = group.submenuTitle else { continue }
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for action in SnapAction.allCases where action.group == group {
                submenu.addItem(commandItem(.snap(action), shortcuts: shortcuts, icon: action.iconRegion))
            }
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.submenu = submenu
            menu.addItem(parent)
        }
        menu.addItem(.separator())

        // Auto-tile.
        let auto = commandItem(.tile(.toggleAutoTile), shortcuts: shortcuts, icon: nil)
        auto.state = settings.autoTile ? .on : .off
        menu.addItem(auto)

        let layoutMenu = NSMenu()
        layoutMenu.autoenablesItems = false
        let screen = tiler.currentLayoutScreen
        let current = screen.map { settings.layout(for: $0.stableID) } ?? .auto
        if let screen, Screens.all().count > 1 {
            let header = NSMenuItem(title: "For \(screen.name)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            layoutMenu.addItem(header)
        }
        for style in LayoutStyle.allCases {
            let styleItem = item(style.title, #selector(setLayout(_:)))
            styleItem.representedObject = style.rawValue
            styleItem.state = settings.autoTile && style == current ? .on : .off
            styleItem.image = MenuIcons.image(for: style)
            layoutMenu.addItem(styleItem)
        }
        layoutMenu.addItem(.separator())
        layoutMenu.addItem(commandItem(.tile(.nextLayout), shortcuts: shortcuts, icon: nil))
        let layoutParent = NSMenuItem(title: "Layout: \(current.title)", action: nil, keyEquivalent: "")
        layoutParent.submenu = layoutMenu
        menu.addItem(layoutParent)

        let swap = commandItem(.tile(.swapWithMain), shortcuts: shortcuts, icon: nil)
        swap.isEnabled = tiler.isOn
        menu.addItem(swap)
        let float = commandItem(.tile(.toggleFloat), shortcuts: shortcuts, icon: nil)
        let focused = WindowRegistry.shared.focusedWindow()
        float.title = focused.map { tiler.isTiled($0) } == false && tiler.isOn ? "Tile This Window" : "Float This Window"
        float.isEnabled = tiler.isOn
        menu.addItem(float)
        let retile = commandItem(.tile(.retile), shortcuts: shortcuts, icon: nil)
        retile.isEnabled = tiler.isOn
        menu.addItem(retile)
        menu.addItem(.separator())

        // The app you're in.
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(), let id = app.bundleIdentifier {
            let ignore = item("Ignore \(app.displayName)", #selector(toggleIgnore(_:)))
            ignore.representedObject = id
            ignore.state = settings.isIgnored(id) ? .on : .off
            menu.addItem(ignore)
            menu.addItem(.separator())
        }

        let settingsItem = item("Settings…", #selector(showSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(item("About Tessera", #selector(showAbout)))
        let quit = item("Quit Tessera", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    // MARK: Building items

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func commandItem(_ command: Command, shortcuts: ShortcutSet, icon: UnitRect?) -> NSMenuItem {
        let item = item(command.title, #selector(runCommand(_:)))
        item.representedObject = command.id
        if let combo = shortcuts.combo(for: command), let key = combo.menuKeyEquivalent {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = combo.modifiers.eventFlags
        }
        if let icon { item.image = MenuIcons.image(for: icon) }
        return item
    }

    // MARK: Actions

    @objc private func runCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let command = Command(id: id) else { return }
        Shortcuts.run(command)
    }

    @objc private func setLayout(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = LayoutStyle(rawValue: raw),
              let screen = AutoTiler.shared.currentLayoutScreen else { return }
        AutoTiler.shared.setLayout(style, for: screen)
    }

    @objc private func toggleIgnore(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.shared.toggleIgnored(id)
    }

    @objc private func quitConflictingApp(_ sender: NSMenuItem) {
        guard let pid = sender.representedObject as? pid_t else { return }
        NSRunningApplication(processIdentifier: pid)?.terminate()
        // Give it a moment to let go of its shortcuts, then take them.
        after(1.5) { Shortcuts.shared.reload() }
    }

    @objc private func showPermission() { PermissionWindow.shared.show() }

    @objc private func turnOffMacTiling() {
        MacTiling.turnOffEdgeDrag()
        Notice.shared.show("macOS edge tiling off")
    }
    @objc private func showSettings() { SettingsWindow.shared.show() }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - Icons

@MainActor
enum MenuIcons {
    /// A small screen with the part an action fills shaded in.
    static func image(for unit: UnitRect) -> NSImage {
        image { inner in
            NSBezierPath(roundedRect: part(unit, of: inner), xRadius: 1, yRadius: 1).fill()
        }
    }

    /// A small picture of a layout with three windows.
    static func image(for style: LayoutStyle) -> NSImage {
        let screen = CGRect(x: 0, y: 0, width: 16, height: 10)
        let frames = TilePlanner.frames(count: 3, in: screen, style: style, gap: 0)
        return image { inner in
            for frame in frames {
                let unit = UnitRect(x: frame.minX / 16, y: frame.minY / 10, width: frame.width / 16, height: frame.height / 10)
                NSBezierPath(roundedRect: part(unit, of: inner).insetBy(dx: 0.5, dy: 0.5), xRadius: 0.5, yRadius: 0.5).fill()
            }
        }
    }

    /// The menu bar icon: four tiles.
    static var statusIcon: NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            let tiles = [
                CGRect(x: 2, y: 3, width: 8, height: 12),
                CGRect(x: 11, y: 3, width: 5, height: 5.5),
                CGRect(x: 11, y: 9.5, width: 5, height: 5.5),
            ]
            for tile in tiles { NSBezierPath(roundedRect: tile, xRadius: 1.5, yRadius: 1.5).fill() }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func image(_ drawInside: @escaping @Sendable (CGRect) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 14), flipped: true) { rect in
            NSColor.black.set()
            let outer = rect.insetBy(dx: 1.5, dy: 1.5)
            let frame = NSBezierPath(roundedRect: outer, xRadius: 2, yRadius: 2)
            frame.lineWidth = 1
            frame.stroke()
            drawInside(outer.insetBy(dx: 2, dy: 2))
            return true
        }
        image.isTemplate = true
        return image
    }

    private nonisolated static func part(_ unit: UnitRect, of rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX + rect.width * unit.x,
            y: rect.minY + rect.height * unit.y,
            width: rect.width * unit.width,
            height: rect.height * unit.height
        )
    }
}

// MARK: - Key equivalents

extension KeyCombo {
    /// The character NSMenuItem needs to show this shortcut.
    var menuKeyEquivalent: String? {
        func function(_ value: Int) -> String { String(Character(Unicode.Scalar(UInt32(value))!)) }
        switch keyCode {
        case KeyCode.leftArrow: return function(NSLeftArrowFunctionKey)
        case KeyCode.rightArrow: return function(NSRightArrowFunctionKey)
        case KeyCode.upArrow: return function(NSUpArrowFunctionKey)
        case KeyCode.downArrow: return function(NSDownArrowFunctionKey)
        case KeyCode.returnKey: return "\r"
        case KeyCode.delete: return "\u{8}"
        case KeyCode.forwardDelete: return function(NSDeleteFunctionKey)
        case KeyCode.tab: return "\t"
        case KeyCode.space: return " "
        case KeyCode.escape: return "\u{1b}"
        case KeyCode.home: return function(NSHomeFunctionKey)
        case KeyCode.end: return function(NSEndFunctionKey)
        case KeyCode.pageUp: return function(NSPageUpFunctionKey)
        case KeyCode.pageDown: return function(NSPageDownFunctionKey)
        default:
            if let index = [KeyCode.f1, KeyCode.f2, KeyCode.f3, KeyCode.f4, KeyCode.f5, KeyCode.f6, KeyCode.f7, KeyCode.f8,
                            KeyCode.f9, KeyCode.f10, KeyCode.f11, KeyCode.f12, KeyCode.f13, KeyCode.f14, KeyCode.f15,
                            KeyCode.f16, KeyCode.f17, KeyCode.f18, KeyCode.f19, KeyCode.f20].firstIndex(of: keyCode) {
                return function(NSF1FunctionKey + index)
            }
            let label = KeyCode.label(for: keyCode)
            return label.count == 1 ? label.lowercased() : nil
        }
    }
}

extension Modifiers {
    var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.control) { flags.insert(.control) }
        if contains(.option) { flags.insert(.option) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.command) { flags.insert(.command) }
        return flags
    }

    init(eventFlags flags: NSEvent.ModifierFlags) {
        var value: Modifiers = []
        if flags.contains(.control) { value.insert(.control) }
        if flags.contains(.option) { value.insert(.option) }
        if flags.contains(.shift) { value.insert(.shift) }
        if flags.contains(.command) { value.insert(.command) }
        self = value
    }
}
