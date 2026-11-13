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

/// A short message near the bottom of the screen, like the volume HUD. Can show a picture
/// (for example, the layout you just picked).
@MainActor
final class Notice {
    static let shared = Notice()

    private let panel = OverlayPanel()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let imageView = NSImageView()
    private let stack: NSStackView
    private var hideTask: Task<Void, Never>?

    private init() {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.alignment = .center
        label.preferredMaxLayoutWidth = 300
        imageView.contentTintColor = .labelColor
        imageView.imageScaling = .scaleNone
        stack = NSStackView(views: [imageView, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 14, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
        panel.level = .statusBar
    }

    /// Shows `text` (and an optional picture) for a moment on the screen with the mouse.
    func show(_ text: String, picture: NSImage? = nil) {
        label.stringValue = text
        imageView.image = picture
        imageView.isHidden = picture == nil
        let size = stack.fittingSize
        let width = max(220, size.width)
        let height = size.height
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        panel.setFrame(CGRect(x: (area.midX - width / 2).rounded(), y: area.minY + 120, width: width, height: height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideTask?.cancel()
        hideTask = after(picture == nil ? 1.4 : 1.8) { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                self?.panel.animator().alphaValue = 0
            }
        }
    }
}
