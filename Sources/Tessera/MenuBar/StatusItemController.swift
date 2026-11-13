import AppKit
import SwiftUI
import TesseraCore

/// The menu bar icon and the panel it opens.
@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {
    static let shared = StatusItemController()

    private var item: NSStatusItem?
    private var panel: FloatingPanel?
    private var monitors: [Any] = []
    /// The screen the panel acts on: the one under the pointer when it opened.
    private(set) var panelKey: String?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.setAccessibilityLabel(AppConfig.appName)
        self.item = item
        refreshIcon()
    }

    func refreshIcon() {
        let model = AppModel.shared
        let active = model.canArrange
        let warning = model.status == .needsAccessibility || model.status == .needsLicense
        item?.button?.image = MenuBarIcon.image(active: active, cleanSpace: model.cleanSpaceOn, warning: warning)
    }

    var isOpen: Bool { panel != nil }

    @objc func togglePanel() {
        isOpen ? close() : open()
    }

    func open() {
        guard let button = item?.button, let buttonWindow = button.window else { return }
        let model = AppModel.shared
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() {
            model.frontAppName = front.displayName
            model.frontAppBundleID = front.bundleIdentifier
        }
        panelKey = TilingController.shared.keyUnderPointer

        let controller = NSHostingController(rootView: MenuPanelView(onClose: { [weak self] in self?.close() }))
        controller.sizingOptions = [.preferredContentSize]
        let panel = FloatingPanel(level: .popUpMenu, ignoresMouse: false)
        panel.allowsKey = true
        panel.contentViewController = controller
        panel.delegate = self
        panel.hasShadow = true
        self.panel = panel
        anchor(to: buttonWindow.frame)

        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)

        if let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(outside) }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let keyCode = event.keyCode
            let command = event.modifierFlags.contains(.command)
            let characters = event.charactersIgnoringModifiers
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isOpen else { return false }
                if keyCode == UInt16(KeyCode.escape) {
                    self.close()
                    return true
                }
                if command, characters == "," {
                    self.close()
                    SettingsWindowController.shared.show()
                    return true
                }
                return false
            }
            return handled ? nil : event
        }) { monitors.append(keys) }
    }

    func close() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        panel?.orderOut(nil)
        panel = nil
    }

    private func anchor(to buttonFrame: NSRect) {
        guard let panel else { return }
        let size = panel.contentViewController?.preferredContentSize ?? panel.frame.size
        let width = max(size.width, 340)
        var x = buttonFrame.midX - width / 2
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(buttonFrame.origin) }) {
            x = min(max(x, screen.visibleFrame.minX + 6), screen.visibleFrame.maxX - width - 6)
        }
        let top = buttonFrame.minY - 4
        panel.setFrame(NSRect(x: x, y: top - size.height, width: width, height: size.height), display: true)
        panelTop = top
    }

    private var panelTop: CGFloat = 0

    func windowDidResize(_ notification: Notification) {
        // Keep the top edge pinned under the menu bar as content grows or shrinks.
        guard let panel, panelTop > 0 else { return }
        var frame = panel.frame
        if abs(frame.maxY - panelTop) > 0.5 {
            frame.origin.y = panelTop - frame.height
            panel.setFrame(frame, display: true)
        }
    }
}

/// The menu bar icon: three panes. Outlined when paused; a dot during Clean Space.
enum MenuBarIcon {
    static func image(active: Bool, cleanSpace: Bool, warning: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let left = NSRect(x: 2, y: 3, width: 6.5, height: 12)
            let topRight = NSRect(x: 10, y: 9.5, width: 6, height: 5.5)
            let bottomRight = NSRect(x: 10, y: 3, width: 6, height: 5.5)
            NSColor.black.set()
            for rect in [left, topRight, bottomRight] {
                let path = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
                if active {
                    path.fill()
                } else {
                    path.lineWidth = 1.2
                    path.stroke()
                }
            }
            if cleanSpace || warning {
                let dot = NSBezierPath(ovalIn: NSRect(x: 13, y: 0, width: 5, height: 5))
                NSColor.black.setFill()
                dot.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
