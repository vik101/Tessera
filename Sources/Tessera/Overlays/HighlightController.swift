import AppKit
import TesseraCore

/// Draws borders or a glow in the gaps around windows. Never covers window contents.
@MainActor
final class HighlightController {
    static let shared = HighlightController()

    private var panels: [CGWindowID: FloatingPanel] = [:]
    private var glowPanel: FloatingPanel?
    private let prefs = Preferences.shared
    private var tiling: TilingController { .shared }

    func refresh() {
        let style = prefs.highlight
        guard tiling.isActive, style != .none, !CleanSpaceController.shared.isOn else {
            clear()
            return
        }
        let color = prefs.highlightColor.nsColor
        let thickness = CGFloat(prefs.borderThickness)

        var wanted: [CGWindowID: CGRect] = [:]
        switch style {
        case .borderOnAll:
            for key in tiling.visibleKeys {
                guard let state = tiling.state(forKey: key) else { continue }
                for id in state.showingWindows {
                    if let frame = tiling.tileFrame(of: id) { wanted[id] = frame }
                }
            }
            if let focus = tiling.focusMode, let frame = tiling.tileFrame(of: focus.window) {
                // In focus mode only the zoomed window shows its border.
                wanted = [focus.window: frame]
            }
        case .borderOnActive, .glowOnActive:
            if let id = tiling.focusedTiledWindow, let frame = tiling.tileFrame(of: id) { wanted[id] = frame }
        case .none:
            break
        }

        if style == .glowOnActive {
            for (_, panel) in panels { panel.orderOut(nil) }
            panels.removeAll()
            if let first = wanted.first { showGlow(above: first.value, color: color) } else { glowPanel?.orderOut(nil) }
            return
        }
        glowPanel?.orderOut(nil)

        for (id, panel) in panels where wanted[id] == nil {
            panel.orderOut(nil)
            panels.removeValue(forKey: id)
        }
        for (id, frame) in wanted {
            let panel = panels[id] ?? makeBorderPanel()
            panels[id] = panel
            let outer = frame.insetBy(dx: -thickness - 1, dy: -thickness - 1)
            panel.setAXFrame(outer)
            if let view = panel.contentView as? BorderView {
                view.color = color
                view.thickness = thickness
                view.isActive = id == tiling.focusedID
                view.needsDisplay = true
            }
            panel.orderFrontRegardless()
        }
    }

    func clear() {
        for (_, panel) in panels { panel.orderOut(nil) }
        panels.removeAll()
        glowPanel?.orderOut(nil)
    }

    private func makeBorderPanel() -> FloatingPanel {
        let panel = FloatingPanel(level: .overlayLow, ignoresMouse: true)
        panel.contentView = BorderView()
        return panel
    }

    private func showGlow(above frame: CGRect, color: NSColor) {
        let panel = glowPanel ?? {
            let p = FloatingPanel(level: .overlayLow, ignoresMouse: true)
            p.contentView = GlowView()
            return p
        }()
        glowPanel = panel
        let height: CGFloat = 14
        panel.setAXFrame(CGRect(x: frame.minX + 12, y: frame.minY - height + 3, width: frame.width - 24, height: height))
        (panel.contentView as? GlowView)?.color = color
        panel.contentView?.needsDisplay = true
        panel.orderFrontRegardless()
    }
}

/// A hollow rounded rectangle drawn just outside a window's edges.
final class BorderView: NSView {
    var color: NSColor = .controlAccentColor
    var thickness: CGFloat = 3
    var isActive = true

    override func draw(_ dirtyRect: NSRect) {
        let inset = thickness / 2 + 1
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(roundedRect: rect, xRadius: WindowShape.cornerRadius + thickness / 2, yRadius: WindowShape.cornerRadius + thickness / 2)
        path.lineWidth = thickness
        (isActive ? color : color.withAlphaComponent(0.45)).setStroke()
        path.stroke()
    }
}

/// A soft line of color along the top edge of the active window.
final class GlowView: NSView {
    var color: NSColor = .controlAccentColor

    override func draw(_ dirtyRect: NSRect) {
        let line = NSRect(x: 8, y: 3, width: bounds.width - 16, height: 2.5)
        let shadow = NSShadow()
        shadow.shadowColor = color
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = .zero
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        color.setFill()
        NSBezierPath(roundedRect: line, xRadius: 1.25, yRadius: 1.25).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// The target spot while ⌘-dragging, with a label like "Swap" or "Move here".
@MainActor
final class DropHighlight {
    static let shared = DropHighlight()
    private var panel: FloatingPanel?

    func show(frame: CGRect, label: String) {
        let panel = self.panel ?? {
            let p = FloatingPanel(level: .overlayHigh, ignoresMouse: true)
            p.contentView = DropView()
            return p
        }()
        self.panel = panel
        panel.setAXFrame(frame)
        if let view = panel.contentView as? DropView {
            view.label = label
            view.needsDisplay = true
        }
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}

final class DropView: NSView {
    var label = ""

    override func draw(_ dirtyRect: NSRect) {
        let color = NSColor.controlAccentColor
        let rect = bounds.insetBy(dx: 3, dy: 3)
        let path = NSBezierPath(roundedRect: rect, xRadius: WindowShape.cornerRadius, yRadius: WindowShape.cornerRadius)
        color.withAlphaComponent(0.18).setFill()
        path.fill()
        path.lineWidth = 3
        color.setStroke()
        path.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: label, attributes: attributes)
        let size = text.size()
        let pill = NSRect(x: bounds.midX - size.width / 2 - 16, y: bounds.midY - size.height / 2 - 8, width: size.width + 32, height: size.height + 16)
        color.setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        text.draw(at: NSPoint(x: pill.minX + 16, y: pill.minY + 8))
    }
}
