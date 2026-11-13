import AppKit
import TesseraCore

/// Moves and resizes windows. Remembers its own moves so they aren't mistaken for yours.
@MainActor
final class WindowMover {
    static let shared = WindowMover()

    private var ownMoves: [CGWindowID: Date] = [:]

    /// Puts a window at `frame` (Accessibility coordinates). Skips windows already there.
    ///
    /// If the app won't shrink the window that far, the window is nudged back inside
    /// `visible`, so it never hangs off the screen.
    @discardableResult
    func move(_ window: TrackedWindow, to frame: CGRect, within visible: CGRect? = nil) -> CGRect? {
        if let current = window.element.frame, current.isClose(to: frame, tolerance: 1) { return current }
        ownMoves[window.id] = Date().addingTimeInterval(0.8)

        // Apps with "enhanced user interface" on (set by some assistive tools) animate every move. Pause it.
        let app = AXElement.application(window.pid)
        let enhanced = app.bool("AXEnhancedUserInterface") == true
        if enhanced { app.set("AXEnhancedUserInterface", bool: false) }
        defer { if enhanced { app.set("AXEnhancedUserInterface", bool: true) } }

        // Size, then position, then size again: this order works when moving between screens of different sizes.
        window.element.setSize(frame.size)
        window.element.setPosition(frame.origin)
        window.element.setSize(frame.size)

        guard var actual = window.element.frame else { return nil }
        if let visible, !visible.contains(actual), actual.width > frame.width + 1 || actual.height > frame.height + 1 {
            // The window is bigger than asked (it has a minimum size). Keep it on screen.
            let fixed = actual.clamped(to: visible)
            if fixed.origin != actual.origin {
                window.element.setPosition(fixed.origin)
                actual = window.element.frame ?? fixed
            }
        }
        return actual
    }

    /// True for a short while after Tessera moved this window.
    func isOwnMove(_ id: CGWindowID) -> Bool {
        guard let until = ownMoves[id] else { return false }
        if until < Date() {
            ownMoves.removeValue(forKey: id)
            return false
        }
        return true
    }

    func forget(_ id: CGWindowID) { ownMoves.removeValue(forKey: id) }
}

extension TrackedWindow {
    /// A normal, resizable document window: the kind Tessera tiles.
    var isStandard: Bool {
        element.subrole == kAXStandardWindowSubrole
            && !element.isMinimized
            && !element.isFullScreen
            && element.isSettable(kAXPositionAttribute)
            && element.isSettable(kAXSizeAttribute)
    }

    /// False for windows with a fixed size, such as Calculator.
    var isResizable: Bool {
        guard element.isSettable(kAXSizeAttribute) else { return false }
        if let zoom = element.element(kAXZoomButtonAttribute), zoom.bool(kAXEnabledAttribute) == false { return false }
        return true
    }
}
