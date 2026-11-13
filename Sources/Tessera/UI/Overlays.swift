import AppKit

/// A borderless panel that floats above windows and ignores the mouse.
@MainActor
final class OverlayPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The blue footprint shown while you drag a window to a screen edge.
@MainActor
final class SnapPreview {
    static let shared = SnapPreview()

    private let panel = OverlayPanel()
    private var shownFrame: CGRect?

    private init() {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.borderWidth = 2
        view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        panel.contentView = view
    }

    /// Shows the footprint at `frame` (Accessibility coordinates).
    func show(_ frame: CGRect) {
        guard frame != shownFrame else { return }
        shownFrame = frame
        panel.setFrame(Screens.toCocoa(frame).insetBy(dx: 2, dy: 2), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        guard shownFrame != nil else { return }
        shownFrame = nil
        panel.orderOut(nil)
    }
}

/// A short message near the bottom of the screen, like the volume HUD.
@MainActor
final class Notice {
    static let shared = Notice()

    private let panel = OverlayPanel()
    private let label = NSTextField(labelWithString: "")
    private var hideTask: Task<Void, Never>?

    private init() {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
        ])
        panel.contentView = effect
        panel.level = .statusBar
    }

    /// Shows `text` for a moment on the screen with the mouse.
    func show(_ text: String) {
        label.stringValue = text
        let width = max(220, label.intrinsicContentSize.width + 48)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        panel.setFrame(CGRect(x: area.midX - width / 2, y: area.minY + 120, width: width, height: 46), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideTask?.cancel()
        hideTask = after(1.4) { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                self?.panel.animator().alphaValue = 0
            }
        }
    }
}
