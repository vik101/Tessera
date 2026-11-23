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

        // First, the windows on this desktop: in front, then waiting. Click one to bring it forward.
        let screen = tiler.currentLayoutScreen
        if tiler.isOn, let screen {
            let (front, waiting) = tiler.windows(on: screen)
            let limit = tiler.frontLimit(on: screen)
            if !front.isEmpty || !waiting.isEmpty {
                menu.addItem(.sectionHeader(title: limit.map { "In Front (\(front.count) of \($0))" } ?? "In Front"))
                for window in front { menu.addItem(windowItem(window, kept: tiler.isKept(window.id))) }
                if !waiting.isEmpty {
                    menu.addItem(.sectionHeader(title: "Waiting · Click to Bring Forward"))
                    for window in waiting { menu.addItem(windowItem(window, kept: false)) }
                }
                menu.addItem(commandItem(.tile(.showWindows), shortcuts: shortcuts, icon: nil))
                let keep = commandItem(.tile(.keepInFront), shortcuts: shortcuts, icon: nil)
                keep.state = WindowRegistry.shared.focusedWindow().map { tiler.isKept($0.id) } == true ? .on : .off
                menu.addItem(keep)
                menu.addItem(.separator())
            }
        }

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
        // Many windows at once: Tile All, Cascade, Reverse All, stacks.
        let all = NSMenu()
        all.autoenablesItems = false
        for action in ArrangeAction.allCases {
            all.addItem(commandItem(.arrange(action), shortcuts: shortcuts, icon: nil))
        }
        let allParent = NSMenuItem(title: "All Windows", action: nil, keyEquivalent: "")
        allParent.submenu = all
        menu.addItem(allParent)
        // Focus by direction and sending to another desktop.
        let moves = NSMenu()
        moves.autoenablesItems = false
        for action in MoveAction.allCases {
            if action == .desktop1 || action == .nextDesktop { moves.addItem(.separator()) }
            moves.addItem(commandItem(.move(action), shortcuts: shortcuts, icon: nil))
        }
        let movesParent = NSMenuItem(title: "Focus and Desktops", action: nil, keyEquivalent: "")
        movesParent.submenu = moves
        menu.addItem(movesParent)
        menu.addItem(.separator())

        // Auto-tile: the switch, then each layout with a picture of what it would do here.
        let auto = commandItem(.tile(.toggleAutoTile), shortcuts: shortcuts, icon: nil)
        auto.state = settings.autoTile ? .on : .off
        menu.addItem(auto)

        let current = screen.map { tiler.layout(for: $0) } ?? .auto
        if let screen, Screens.all().count > 1 {
            let header = NSMenuItem(title: "Layout for \(screen.name)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
        }
        // Pictures show the windows you have now (or three, as an example).
        let tiled = screen.map { tiler.tiledCount(on: $0) } ?? 0
        let count = tiled >= 2 ? min(tiled, 12) : 3
        for style in LayoutStyle.allCases {
            let styleItem = commandItem(.layout(style), shortcuts: shortcuts, icon: nil)
            styleItem.state = settings.autoTile && style == current ? .on : .off
            styleItem.image = MenuIcons.layoutIcon(style, on: screen, count: count, height: 16)
            styleItem.indentationLevel = 1
            menu.addItem(styleItem)
        }
        menu.addItem(commandItem(.tile(.nextLayout), shortcuts: shortcuts, icon: nil))
        menu.addItem(commandItem(.tile(.previousLayout), shortcuts: shortcuts, icon: nil))
        menu.addItem(.separator())

        let limits = NSMenu()
        limits.autoenablesItems = false
        let autoCount = screen.map { FrontLimit.autoCount(for: $0.visibleFrame.size) }
        for choice in FrontLimit.choices {
            let title = choice == .auto ? (autoCount.map { "Auto (\($0) here)" } ?? "Auto") : choice.title
            let limitItem = item(title, #selector(setFrontLimit(_:)))
            limitItem.representedObject = choice.raw
            limitItem.state = settings.frontLimit == choice ? .on : .off
            limits.addItem(limitItem)
        }
        let limitParent = NSMenuItem(title: "Windows in Front", action: nil, keyEquivalent: "")
        limitParent.submenu = limits
        menu.addItem(limitParent)
        menu.addItem(.separator())

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
        if Updater.shared.isConfigured {
            menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        }
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

    /// A window in the "In Front" or "Waiting" list: app icon, app name and window title.
    private func windowItem(_ window: TrackedWindow, kept: Bool) -> NSMenuItem {
        var title = window.title.isEmpty || window.title == window.appName ? window.appName : "\(window.appName) — \(window.title)"
        if title.count > 52 { title = String(title.prefix(51)) + "…" }
        if kept { title += " (kept)" }
        let item = item(title, #selector(bringWindowForward(_:)))
        item.representedObject = Int(window.id)
        item.indentationLevel = 1
        if let icon = NSRunningApplication(processIdentifier: window.pid)?.icon?.copy() as? NSImage {
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
        }
        return item
    }

    // MARK: Actions

    @objc private func bringWindowForward(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int else { return }
        AutoTiler.shared.bringForward(CGWindowID(id))
    }

    @objc private func setFrontLimit(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int else { return }
        Settings.shared.frontLimit = FrontLimit(raw: raw)
        let limit = Settings.shared.frontLimit
        Notice.shared.show(limit == .unlimited ? "Every window in front" : "Windows in front: \(limit.title)")
    }

    @objc private func runCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let command = Command(id: id) else { return }
        Shortcuts.run(command)
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

    @objc private func checkForUpdates() { Updater.shared.checkNow() }

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

    /// A picture of what a layout style does with `count` windows on a screen.
    static func layoutIcon(_ style: LayoutStyle, on screen: DisplayInfo?, count: Int, height: CGFloat) -> NSImage {
        let area = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let ratio = CGFloat(Settings.shared.mainRatio)
        let frames = TilePlanner.frames(count: count, in: area, style: style, mainRatio: style == .mainAndSide ? ratio : 0.5)
        return picture(of: frames, in: area, height: height)
    }

    /// Draws windows (`frames`) inside a screen (`area`) as a small template picture.
    static func picture(of frames: [CGRect], in area: CGRect, height: CGFloat) -> NSImage {
        let aspect = area.height > 0 ? area.width / area.height : 1.6
        let size = NSSize(width: (height * min(max(aspect, 0.6), 2.6)).rounded(), height: height)
        let big = height > 30
        let units = frames.map { frame in
            UnitRect(
                x: (frame.minX - area.minX) / area.width,
                y: (frame.minY - area.minY) / area.height,
                width: frame.width / area.width,
                height: frame.height / area.height
            )
        }
        return render(size) { rect in
            NSColor.black.set()
            let outer = rect.insetBy(dx: big ? 2 : 1, dy: big ? 2 : 1)
            let screen = NSBezierPath(roundedRect: outer, xRadius: big ? 6 : 2, yRadius: big ? 6 : 2)
            screen.lineWidth = big ? 2 : 1
            screen.stroke()
            let inner = outer.insetBy(dx: big ? 5 : 2, dy: big ? 5 : 2)
            for unit in units {
                let tile = part(unit, of: inner).insetBy(dx: big ? 2 : 0.6, dy: big ? 2 : 0.6)
                NSBezierPath(roundedRect: tile, xRadius: big ? 3 : 0.8, yRadius: big ? 3 : 0.8).fill()
            }
        }
    }

    /// The menu bar icon: four tiles.
    static var statusIcon: NSImage {
        render(NSSize(width: 18, height: 18)) { _ in
            NSColor.black.setFill()
            let tiles = [
                CGRect(x: 2, y: 3, width: 8, height: 12),
                CGRect(x: 11, y: 3, width: 5, height: 5.5),
                CGRect(x: 11, y: 9.5, width: 5, height: 5.5),
            ]
            for tile in tiles { NSBezierPath(roundedRect: tile, xRadius: 1.5, yRadius: 1.5).fill() }
        }
    }

    private static func image(_ drawInside: (CGRect) -> Void) -> NSImage {
        render(NSSize(width: 20, height: 14)) { rect in
            NSColor.black.set()
            let outer = rect.insetBy(dx: 1.5, dy: 1.5)
            let frame = NSBezierPath(roundedRect: outer, xRadius: 2, yRadius: 2)
            frame.lineWidth = 1
            frame.stroke()
            drawInside(outer.insetBy(dx: 2, dy: 2))
        }
    }

    /// Draws a template picture straight away, on this thread, at 1×, 2× and 3×.
    ///
    /// Not with an NSImage drawing handler: macOS may run that later on another thread
    /// (for example to draw the menu bar on a second screen), and a Swift 6 app stops
    /// with a crash when main-thread code runs anywhere else.
    private static func render(_ size: NSSize, _ draw: (CGRect) -> Void) -> NSImage {
        let image = NSImage(size: size)
        for scale in [1, 2, 3] as [CGFloat] {
            let width = Int((size.width * scale).rounded())
            let height = Int((size.height * scale).rounded())
            guard width > 0, height > 0, let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)   // Points, with y growing downward.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            draw(CGRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            if let picture = context.makeImage() {
                let rep = NSBitmapImageRep(cgImage: picture)
                rep.size = size
                image.addRepresentation(rep)
            }
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
