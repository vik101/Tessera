import AppKit
import TesseraCore

/// Moves and resizes windows. Remembers its own moves so they aren't mistaken for yours.
@MainActor
final class WindowMover {
    static let shared = WindowMover()

    private var ownMoves: [CGWindowID: Date] = [:]
    /// The last frame asked for each window, and where the window ended up.
    private var lastMove: [CGWindowID: (asked: CGRect, got: CGRect)] = [:]
    /// How many times Tessera has moved a window (the tests check nothing moves when it shouldn't).
    private(set) var moveCount = 0

    /// Puts a window at `frame` (Accessibility coordinates). Skips windows already there.
    ///
    /// If the app won't shrink the window that far, the window is nudged back inside
    /// `visible`, so it never hangs off the screen.
    ///
    /// - Parameter slack: a window this many points smaller than `frame` (at the right spot) counts
    ///   as already there. Apps like Terminal size themselves in whole characters.
    /// - Parameter force: ask again even if the window is still where the same request left it.
    @discardableResult
    func move(_ window: TrackedWindow, to frame: CGRect, within visible: CGRect? = nil, slack: CGFloat = 0,
              force: Bool = false) -> CGRect? {
        if let current = window.element.frame {
            let placed = abs(current.minX - frame.minX) <= 1 && abs(current.minY - frame.minY) <= 1
            let wide = current.width <= frame.width + 1 && current.width >= frame.width - max(slack, 1)
            let tall = current.height <= frame.height + 1 && current.height >= frame.height - max(slack, 1)
            if placed && wide && tall { return current }
            // Same request as last time, and the window hasn't moved since: asking again would only
            // make a window that can't get that small jump and come back.
            if !force, let last = lastMove[window.id], last.asked.isClose(to: frame, tolerance: 1),
               current.isClose(to: last.got, tolerance: 1) {
                return current
            }
        }
        ownMoves[window.id] = Date().addingTimeInterval(0.8)
        moveCount += 1
        defer { if let got = window.element.frame { lastMove[window.id] = (frame, got) } }

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

    func forget(_ id: CGWindowID) {
        ownMoves.removeValue(forKey: id)
        lastMove.removeValue(forKey: id)
    }
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
