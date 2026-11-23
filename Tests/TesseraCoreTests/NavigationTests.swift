import CoreGraphics
import Testing
@testable import TesseraCore

private func near(_ source: CGRect, _ direction: Direction, _ windows: [UInt32: CGRect]) -> UInt32? {
    Navigation.neighbour(of: source, direction: direction, among: windows.map { (id: $0.key, frame: $0.value) })
}

@Suite("Focus by direction and desktops")
struct NavigationTests {
    // Main + Side: a big window on the left, two stacked on the right.
    let main = CGRect(x: 0, y: 0, width: 960, height: 1000)
    let top = CGRect(x: 960, y: 0, width: 960, height: 500)
    let bottom = CGRect(x: 960, y: 500, width: 960, height: 500)

    @Test func movesBetweenTiles() {
        let all: [UInt32: CGRect] = [1: main, 2: top, 3: bottom]
        #expect(near(main, .right, all) == 2)        // A tie goes to the top one.
        #expect(near(top, .down, all) == 3)
        #expect(near(bottom, .up, all) == 2)
        #expect(near(bottom, .left, all) == 1)
        #expect(near(main, .left, all) == nil)       // Nothing there.
        #expect(near(top, .right, all) == nil)
    }

    @Test func prefersWindowsInLineOverNearerOnes() {
        let source = CGRect(x: 0, y: 400, width: 400, height: 200)
        let inLine = CGRect(x: 1200, y: 400, width: 400, height: 200)
        let diagonal = CGRect(x: 500, y: 0, width: 300, height: 200)
        #expect(near(source, .right, [1: inLine, 2: diagonal]) == 1)
        // With nothing in line, the nearest wins.
        #expect(near(source, .right, [2: diagonal, 3: CGRect(x: 1500, y: 900, width: 300, height: 100)]) == 2)
    }

    @Test func worksWithOverlappingWindows() {
        let back = CGRect(x: 100, y: 100, width: 800, height: 600)
        let front = CGRect(x: 400, y: 150, width: 800, height: 600)
        #expect(near(back, .right, [2: front]) == 2)
        #expect(near(front, .left, [1: back]) == 1)
        #expect(near(front, .up, [1: back]) == nil)   // 50 points higher is beside it, not above it.
    }

    @Test func desktopStepsSkipFullScreenApps() {
        // Desktop 1, a full-screen app, desktop 2, desktop 3.
        let spaces: [(id: UInt64, isDesktop: Bool)] = [(id: 10, isDesktop: true), (id: 11, isDesktop: false),
                                                       (id: 12, isDesktop: true), (id: 13, isDesktop: true)]
        #expect(DesktopSteps.presses(spaces: spaces, current: 10, toDesktop: 2) == 2)
        #expect(DesktopSteps.presses(spaces: spaces, current: 13, toDesktop: 1) == -3)
        #expect(DesktopSteps.presses(spaces: spaces, current: 12, toDesktop: 2) == 0)
        #expect(DesktopSteps.presses(spaces: spaces, current: 10, toDesktop: 4) == nil)
        #expect(DesktopSteps.presses(spaces: spaces, current: 10, forward: true) == 2)
        #expect(DesktopSteps.presses(spaces: spaces, current: 12, forward: false) == -2)
        #expect(DesktopSteps.presses(spaces: spaces, current: 13, forward: true) == nil)
        #expect(DesktopSteps.presses(spaces: spaces, current: 99, toDesktop: 1) == nil)
    }

    @Test func moveActionsHaveKeysAndNames() {
        #expect(MoveAction.desktop3.desktopNumber == 3)
        #expect(MoveAction.desktop3.urlName == "send-to-desktop-3")
        #expect(MoveAction.nextDesktop.urlName == "send-to-next-desktop")
        #expect(MoveAction.focusLeft.urlName == "focus-left")
        #expect(MoveAction.desktop9.defaultShortcut == KeyCombo(KeyCode.nine, [.control, .option, .shift]))
        // No default key is used twice anywhere.
        let combos = Command.allCases.compactMap(\.defaultShortcut)
        #expect(Set(combos).count == combos.count)
    }
}
