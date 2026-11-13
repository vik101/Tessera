import CoreGraphics
import Testing
@testable import TesseraCore

/// A 1920×1080 screen with a 25-point menu bar.
private let screen = CGRect(x: 0, y: 25, width: 1920, height: 1055)
private let window = CGRect(x: 300, y: 200, width: 800, height: 600)

private func snap(_ action: SnapAction, window: CGRect = window, on visible: CGRect = screen, gap: CGFloat = 0, cycle: Int = 0) -> CGRect? {
    SnapCalculator.frame(for: action, SnapContext(window: window, visible: visible, gap: gap, cycle: cycle))
}

@Suite("Snapping")
struct SnapTests {
    @Test func halves() {
        #expect(snap(.leftHalf) == CGRect(x: 0, y: 25, width: 960, height: 1055))
        #expect(snap(.rightHalf) == CGRect(x: 960, y: 25, width: 960, height: 1055))
        #expect(snap(.topHalf) == CGRect(x: 0, y: 25, width: 1920, height: 528))
        #expect(snap(.bottomHalf) == CGRect(x: 0, y: 553, width: 1920, height: 527))
        #expect(snap(.centreHalf) == CGRect(x: 480, y: 25, width: 960, height: 1055))
    }

    @Test func halvesCycleThroughTwoThirdsAndOneThird() {
        #expect(snap(.leftHalf, cycle: 1) == CGRect(x: 0, y: 25, width: 1280, height: 1055))
        #expect(snap(.leftHalf, cycle: 2) == CGRect(x: 0, y: 25, width: 640, height: 1055))
        #expect(snap(.leftHalf, cycle: 3) == snap(.leftHalf))
        #expect(snap(.rightHalf, cycle: 1) == CGRect(x: 640, y: 25, width: 1280, height: 1055))
        #expect(snap(.topRight, cycle: 2) == CGRect(x: 1280, y: 25, width: 640, height: 528))
    }

    @Test func quartersMeetWithoutGapsOrOverlap() {
        let parts = [SnapAction.topLeft, .topRight, .bottomLeft, .bottomRight].compactMap { snap($0) }
        #expect(parts.count == 4)
        #expect(parts.map { $0.width * $0.height }.reduce(0, +) == screen.width * screen.height)
        for (i, a) in parts.enumerated() {
            for b in parts[(i + 1)...] { #expect(a.intersectionArea(b) == 0) }
        }
    }

    @Test func thirdsOnLandscapeAndPortrait() {
        #expect(snap(.firstThird) == CGRect(x: 0, y: 25, width: 640, height: 1055))
        #expect(snap(.centreThird) == CGRect(x: 640, y: 25, width: 640, height: 1055))
        #expect(snap(.lastTwoThirds) == CGRect(x: 640, y: 25, width: 1280, height: 1055))
        #expect(snap(.centreTwoThirds) == CGRect(x: 320, y: 25, width: 1280, height: 1055))
        let portrait = CGRect(x: 1920, y: 0, width: 1080, height: 1920)
        #expect(snap(.firstThird, on: portrait) == CGRect(x: 1920, y: 0, width: 1080, height: 640))
        #expect(snap(.lastThird, on: portrait) == CGRect(x: 1920, y: 1280, width: 1080, height: 640))
        // Halves keep their meaning on a portrait screen.
        #expect(snap(.leftHalf, on: portrait) == CGRect(x: 1920, y: 0, width: 540, height: 1920))
    }

    @Test func quartersAndSixths() {
        #expect(snap(.secondQuarter) == CGRect(x: 480, y: 25, width: 480, height: 1055))
        #expect(snap(.lastThreeQuarters) == CGRect(x: 480, y: 25, width: 1440, height: 1055))
        #expect(snap(.bottomCentreSixth) == CGRect(x: 640, y: 553, width: 640, height: 527))
    }

    @Test func gapsLeaveEqualSpaceEverywhere() {
        let left = snap(.leftHalf, gap: 10)!
        let right = snap(.rightHalf, gap: 10)!
        #expect(left == CGRect(x: 10, y: 35, width: 945, height: 1035))
        #expect(right.minX - left.maxX == 10)
        #expect(screen.maxX - right.maxX == 10)
        #expect(snap(.maximise, gap: 10) == screen.insetBy(dx: 10, dy: 10))
    }

    @Test func sizeActions() {
        #expect(snap(.maximise) == screen)
        #expect(snap(.almostMaximise) == CGRect(x: 96, y: 78, width: 1728, height: 949))
        #expect(snap(.maximiseHeight) == CGRect(x: 300, y: 25, width: 800, height: 1055))
        #expect(snap(.centre) == CGRect(x: 560, y: 253, width: 800, height: 600))
        // A window bigger than the screen is shrunk to fit when centred.
        #expect(snap(.centre, window: CGRect(x: 0, y: 0, width: 3000, height: 500)) == CGRect(x: 0, y: 303, width: 1920, height: 500))
    }

    @Test func largerAndSmaller() {
        #expect(snap(.larger) == CGRect(x: 270, y: 170, width: 860, height: 660))
        #expect(snap(.smaller) == CGRect(x: 330, y: 230, width: 740, height: 540))
        // A left-half window stays on the left edge.
        let left = snap(.leftHalf)!
        #expect(snap(.smaller, window: left) == CGRect(x: 0, y: 25, width: 930, height: 1055))
        #expect(snap(.larger, window: left) == CGRect(x: 0, y: 25, width: 990, height: 1055))
        // A maximised window shrinks on every side.
        #expect(snap(.smaller, window: screen) == CGRect(x: 30, y: 55, width: 1860, height: 995))
        // Never past the screen, never below a quarter of it.
        #expect(snap(.larger, window: screen) == screen)
        let tiny = CGRect(x: 800, y: 400, width: 480, height: 264)
        #expect(snap(.smaller, window: tiny) == tiny)
    }

    @Test func moveToEdgeKeepsSize() {
        #expect(snap(.moveLeft) == CGRect(x: 0, y: 200, width: 800, height: 600))
        #expect(snap(.moveRight) == CGRect(x: 1120, y: 200, width: 800, height: 600))
        #expect(snap(.moveUp) == CGRect(x: 300, y: 25, width: 800, height: 600))
        #expect(snap(.moveDown) == CGRect(x: 300, y: 480, width: 800, height: 600))
    }

    @Test func callerHandlesRestoreAndDisplays() {
        #expect(snap(.restore) == nil)
        #expect(snap(.nextDisplay) == nil)
        #expect(snap(.previousDisplay) == nil)
    }

    @Test func movingToAnotherDisplayKeepsTheSpot() {
        let small = CGRect(x: 1920, y: 0, width: 1280, height: 800)
        let moved = SnapCalculator.moveProportionally(snap(.leftHalf)!, from: screen, to: small)
        #expect(moved == CGRect(x: 1920, y: 0, width: 640, height: 800))
    }

    @Test func everyRegionActionStaysOnScreen() {
        for shape in [screen, CGRect(x: 0, y: 0, width: 1080, height: 1920), CGRect(x: 0, y: 25, width: 3440, height: 1415)] {
            for action in SnapAction.allCases {
                guard let frame = snap(action, on: shape) else { continue }
                #expect(shape.contains(frame), "\(action) left the screen")
                #expect(frame.width > 0 && frame.height > 0)
            }
        }
    }
}

@Suite("Shortcuts")
struct ShortcutTests {
    @Test func defaultsMatchRectangleAndNeverClash() {
        let set = ShortcutSet()
        let combos = set.bindings.map(\.combo)
        #expect(Set(combos).count == combos.count)
        #expect(set.combo(for: .snap(.leftHalf)) == KeyCombo(KeyCode.leftArrow, [.control, .option]))
        #expect(set.combo(for: .snap(.restore)) == KeyCombo(KeyCode.delete, [.control, .option]))
        #expect(set.combo(for: .snap(.maximise))?.description == "⌃⌥↩")
        #expect(set.combo(for: .layout(.auto))?.description == "⌃⌥1")
        #expect(set.combo(for: .layout(.mainAndSide))?.description == "⌃⌥5")
        #expect(set.combo(for: .tile(.previousLayout))?.description == "⌃⌥⇧L")
    }

    @Test func assigningATakenComboMovesIt() {
        var set = ShortcutSet()
        let combo = KeyCombo(KeyCode.leftArrow, [.control, .option])
        let displaced = set.set(combo, for: .snap(.centreHalf))
        #expect(displaced == .snap(.leftHalf))
        #expect(set.combo(for: .snap(.leftHalf)) == nil)
        #expect(set.command(for: combo) == .snap(.centreHalf))
        // Putting the default back restores the original state.
        set.set(combo, for: .snap(.leftHalf))
        set.set(nil, for: .snap(.centreHalf))
        #expect(set == ShortcutSet())
    }

    @Test func idsRoundTrip() {
        for command in Command.allCases {
            #expect(Command(id: command.id) == command)
        }
        #expect(Command(id: "nonsense") == nil)
    }
}
