import AppKit
import SwiftUI

/// A borderless panel that never steals focus. Used for every overlay.
final class FloatingPanel: NSPanel {
    var allowsKey = false

    init(level: NSWindow.Level = .floating, ignoresMouse: Bool = true) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        self.level = level
        ignoresMouseEvents = ignoresMouse
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        isMovable = false
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// Positions the panel using a frame in Accessibility coordinates.
    func setAXFrame(_ rect: CGRect) {
        let cocoa = Screens.toCocoa(rect)
        if frame != cocoa { setFrame(cocoa, display: true) }
    }
}

/// Hosting view that reacts to the first click even though its panel isn't key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension NSWindow.Level {
    /// Above floating overlays, below the menu bar.
    static let overlayHigh = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
    /// Just above normal windows.
    static let overlayLow = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
}

/// Makes a panel hosting SwiftUI content.
@MainActor
func makeHostingPanel<Content: View>(_ content: Content, level: NSWindow.Level = .overlayHigh, interactive: Bool) -> (FloatingPanel, FirstMouseHostingView<Content>) {
    let panel = FloatingPanel(level: level, ignoresMouse: !interactive)
    let host = FirstMouseHostingView(rootView: content)
    host.translatesAutoresizingMaskIntoConstraints = true
    panel.contentView = host
    return (panel, host)
}

/// The rounded rectangle macOS uses for window corners.
enum WindowShape {
    static let cornerRadius: CGFloat = 10
}
