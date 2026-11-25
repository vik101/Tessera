import AppKit
import TesseraCore

/// Two optional looks, both off by default: a border round the focused window, and dimming every
/// other window. Each is a see-through window of Tessera's that clicks pass through: the border sits
/// just above the focused window, and the dimming just below it (and over every other screen).
@MainActor
final class Decorations {
    static let shared = Decorations()

    private var border: NSPanel?
    private var dims: [CGDirectDisplayID: NSPanel] = [:]
    private let follow = RepeatingTimer()
    private let debouncer = Debouncer(delay: 0.03)
    private(set) var showing: (border: Bool, dim: Bool) = (false, false)

    func start() {
        Settings.shared.observe { [weak self] change in
            if change == .appearance { self?.update() }
        }
        WindowRegistry.shared.listen { [weak self] event in
            switch event {
            case .focused, .appActivated, .moved, .resized, .destroyed, .minimized, .deminimized, .appHidden, .appShown:
                self?.debouncer.schedule { self?.update() }
            default:
                break
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { Decorations.shared.update() } }
        update()
    }

    func update() {
        let settings = Settings.shared
        guard settings.border || settings.dim, AccessibilityPermission.isTrusted else {
            hideAll()
            follow.stop()
            return
        }
        // Windows move without telling us when apps animate: look again a few times a second.
        follow.start(every: 0.25) { [weak self] in self?.place() }
        place()
    }

    private func place() {
        let settings = Settings.shared
        guard let window = WindowRegistry.shared.focusedWindow(), let frame = window.frame,
              !window.element.isFullScreen, !window.element.isMinimized else {
            hideAll()
            return
        }
        let number = Int(window.id)
        let cocoa = Screens.toCocoa(frame)
        if settings.border {
            let width = CGFloat(settings.borderWidth)
            let panel = border ?? makePanel()
            border = panel
            panel.setFrame(cocoa.insetBy(dx: -width / 2, dy: -width / 2), display: false)
            if let view = panel.contentView {
                view.wantsLayer = true
                view.layer?.borderWidth = width
                view.layer?.borderColor = Self.color(settings.borderColor).cgColor
                view.layer?.cornerRadius = 10
                view.layer?.backgroundColor = NSColor.clear.cgColor
            }
            panel.order(.above, relativeTo: number)
        } else {
            border?.orderOut(nil)
        }
        if settings.dim {
            let displays = Screens.all()
            let focusedDisplay = Screens.display(for: frame, in: displays)
            for display in displays {
                let panel = dims[display.displayID] ?? makePanel()
                dims[display.displayID] = panel
                panel.backgroundColor = NSColor.black.withAlphaComponent(CGFloat(min(max(settings.dimAmount, 0.05), 0.9)))
                panel.setFrame(display.cocoaFrame, display: false)
                if display == focusedDisplay {
                    panel.order(.below, relativeTo: number)
                } else {
                    panel.orderFrontRegardless()
                }
            }
            for (id, panel) in dims where !displays.contains(where: { $0.displayID == id }) {
                panel.orderOut(nil)
                dims[id] = nil
            }
        } else {
            for panel in dims.values { panel.orderOut(nil) }
        }
        showing = (settings.border, settings.dim)
    }

    private func hideAll() {
        border?.orderOut(nil)
        for panel in dims.values { panel.orderOut(nil) }
        showing = (false, false)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .normal
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.contentView = NSView()
        return panel
    }

    /// `#4c9aff` as a colour (blue if it can't be read).
    static func color(_ hex: String) -> NSColor {
        guard let rgb = TesseraConfig.hexColor(hex) else { return .systemBlue }
        return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
