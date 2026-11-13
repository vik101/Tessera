import AppKit
import TesseraCore

/// Moves and resizes windows, and remembers what it asked for so our own
/// moves aren't mistaken for the user's.
@MainActor
final class FrameApplier {
    private struct Expectation {
        let frame: CGRect
        let until: Date
    }

    private var expected: [CGWindowID: Expectation] = [:]
    /// The frame we last asked each window to take.
    private(set) var requested: [CGWindowID: CGRect] = [:]
    /// Counts real moves, so Retile can say whether anything changed.
    private(set) var moveCount = 0

    /// Puts a window at a frame (Accessibility coordinates). Skips windows already there.
    @discardableResult
    func set(_ window: TrackedWindow, to frame: CGRect, force: Bool = false) -> Bool {
        requested[window.id] = frame
        if !force, let current = window.element.frame, current.isClose(to: frame, tolerance: 1) {
            return false
        }
        expected[window.id] = Expectation(frame: frame, until: Date().addingTimeInterval(0.8))
        moveCount += 1

        // Apps using "enhanced user interface" animate every AX move; switch it off briefly.
        let app = AXElement.application(window.pid)
        let enhanced = app.bool("AXEnhancedUserInterface") == true
        if enhanced { app.set("AXEnhancedUserInterface", bool: false) }

        // Size, position, size: the second size fixes moves across screens of different sizes.
        window.element.setSize(frame.size)
        window.element.setPosition(frame.origin)
        window.element.setSize(frame.size)

        if enhanced { app.set("AXEnhancedUserInterface", bool: true) }
        return true
    }

    /// True if a move or resize of this window was probably caused by us.
    func isOurs(_ id: CGWindowID) -> Bool {
        guard let expectation = expected[id] else { return false }
        if expectation.until < Date() {
            expected.removeValue(forKey: id)
            return false
        }
        return true
    }

    func forget(_ id: CGWindowID) {
        expected.removeValue(forKey: id)
        requested.removeValue(forKey: id)
    }

    /// Raises a window and makes its app frontmost.
    func focus(_ window: TrackedWindow) {
        let app = AXElement.application(window.pid)
        window.element.perform(kAXRaiseAction)
        window.element.set(kAXMainAttribute, bool: true)
        app.set(kAXFrontmostAttribute, bool: true)
        _ = NSRunningApplication(processIdentifier: window.pid)?.activate()
    }

    /// Raises a window inside its app without stealing focus from the user.
    func raise(_ window: TrackedWindow) {
        window.element.perform(kAXRaiseAction)
    }
}
