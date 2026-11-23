import CoreGraphics
import Testing
@testable import TesseraCore

@Suite("Front windows")
struct FrontWindowsTests {
    // Recency: bigger means used more lately.
    private let recency = [1: 50, 2: 40, 3: 10, 4: 30, 5: 20, 6: 60]

    // Screens in points ("looks like" sizes), as macOS gives them, with room for the menu bar.
    private static let screens: [(name: String, area: CGRect, front: Int)] = [
        ("49-inch super ultrawide", CGRect(x: 0, y: 25, width: 5120, height: 1415), 6),
        ("49-inch, scaled", CGRect(x: 0, y: 25, width: 3840, height: 1055), 6),
        ("34-inch ultrawide", CGRect(x: 0, y: 25, width: 3440, height: 1415), 6),
        ("27-inch", CGRect(x: 0, y: 25, width: 2560, height: 1415), 4),
        ("16-inch MacBook Pro", CGRect(x: 0, y: 38, width: 1728, height: 1079), 3),
        ("14-inch MacBook Pro", CGRect(x: 0, y: 38, width: 1512, height: 944), 3),
        ("13-inch MacBook Air", CGRect(x: 0, y: 38, width: 1470, height: 918), 2),
        ("20-inch 4:3 Dell", CGRect(x: 0, y: 25, width: 1600, height: 1175), 3),
        ("19-inch 5:4 Dell", CGRect(x: 0, y: 25, width: 1280, height: 999), 2),
        ("1920×1080", CGRect(x: 0, y: 25, width: 1920, height: 1055), 3),
        ("Portrait 1080×1920", CGRect(x: 0, y: 25, width: 1080, height: 1895), 3),
    ]

    /// The promise: on every kind of screen, Auto's number of front windows, laid out by Auto,
    /// gives each window at least 500 × 400 points. Nothing gets stuffy.
    @Test func autoNeverGetsStuffy() {
        for screen in Self.screens {
            let count = FrontLimit.autoCount(for: screen.area.size)
            #expect(count == screen.front, "\(screen.name): \(count) in front")
            let frames = TilePlanner.frames(count: count, in: screen.area, style: .auto, gap: 8)
            for frame in frames {
                #expect(frame.width >= 500 && frame.height >= 400, "\(screen.name): a window is only \(frame.size)")
                #expect(screen.area.contains(frame))
            }
        }
    }

    /// The promise: a waiting window never shows on another screen, however the screens are
    /// arranged (at most a one-point sliver where two screens meet at a corner).
    @Test func waitingWindowsNeverShowOnAnotherScreen() {
        let book = CGRect(x: 0, y: 0, width: 1728, height: 1117)       // 16-inch MacBook Pro
        let wide = CGSize(width: 5120, height: 1440)                    // 49-inch
        let dell = CGSize(width: 1600, height: 1200)                    // 20-inch 4:3
        let setups: [(String, [CGRect])] = [
            ("49 above, MacBook centred below, Dell left", [
                book, CGRect(origin: CGPoint(x: -1696, y: -1440), size: wide), CGRect(origin: CGPoint(x: -1600, y: 0), size: dell)]),
            ("MacBook below the 49, right-aligned", [
                book, CGRect(origin: CGPoint(x: 1728 - 5120, y: -1440), size: wide)]),
            ("MacBook below the 49, left-aligned", [
                book, CGRect(origin: CGPoint(x: 0, y: -1440), size: wide)]),
            ("MacBook right of the 49, bottoms lined up", [
                book, CGRect(origin: CGPoint(x: -5120, y: 1117 - 1440), size: wide)]),
            ("MacBook left of the 49, Dell right of it", [
                book, CGRect(origin: CGPoint(x: 1728, y: -323), size: wide), CGRect(origin: CGPoint(x: 1728 + 5120, y: -323), size: dell)]),
            ("MacBook with screens left, right and below", [
                book, CGRect(x: -1600, y: 0, width: 1600, height: 1200), CGRect(x: 1728, y: 0, width: 1920, height: 1080),
                CGRect(x: 0, y: 1117, width: 1728, height: 1117)]),
        ]
        for (name, screens) in setups {
            for (index, screen) in screens.enumerated() {
                let others = screens.enumerated().filter { $0.offset != index }.map(\.element)
                for size in [CGSize(width: 800, height: 600), CGSize(width: 1900, height: 1300), CGSize(width: 400, height: 300)] {
                    let frame = FrontWindows.waitingFrame(size: size, screen: screen, otherScreens: others)
                    // One point on its own screen…
                    let own = screen.intersection(frame)
                    #expect(!own.isNull && (own.width <= 1 || own.height <= 1), "\(name): shows \(own.size) on its own screen")
                    #expect(FrontWindows.isWaiting(frame, screens: screens), "\(name): not hidden")
                    // …and at most a one-point sliver on any other.
                    for other in others {
                        let shared = other.intersection(frame)
                        #expect(shared.isNull || shared.width <= 1 || shared.height <= 1, "\(name): \(size) shows \(shared.size) on another screen")
                    }
                }
            }
        }
    }

    /// After a screen is unplugged, the windows you used most lately get the front spots, and
    /// front windows that stay keep their spots.
    @Test func afterScreensChangeTheMostRecentlyUsedAreInFront() {
        // 6 (most recent) arrives from an unplugged screen; 3 (least recent) was in front.
        #expect(FrontWindows.refill([1, 2, 3, 4, 5, 6], limit: 3, kept: [], recency: recency) == [1, 2, 6, 4, 5, 3])
        // A kept window stays in front even if used long ago.
        let kept = FrontWindows.refill([1, 2, 3, 4, 5, 6], limit: 3, kept: [3], recency: recency)
        #expect(Set(kept.prefix(3)) == [6, 1, 3])
        // Room for all: nothing changes.
        #expect(FrontWindows.refill([3, 1, 2], limit: 3, kept: [], recency: recency) == [3, 1, 2])
    }

    @Test func autoFitsTheScreen() {
        #expect(FrontLimit.autoCount(for: CGSize(width: 1470, height: 920)) == 2)   // 13-inch MacBook Air
        #expect(FrontLimit.autoCount(for: CGSize(width: 1512, height: 945)) == 3)   // 14-inch MacBook Pro
        #expect(FrontLimit.autoCount(for: CGSize(width: 1728, height: 1080)) == 3)  // 16-inch MacBook Pro
        #expect(FrontLimit.autoCount(for: CGSize(width: 1920, height: 1050)) == 3)
        #expect(FrontLimit.autoCount(for: CGSize(width: 2560, height: 1410)) == 4)  // 27-inch
        #expect(FrontLimit.autoCount(for: CGSize(width: 3008, height: 1660)) == 5)  // 32-inch 6K
        #expect(FrontLimit.autoCount(for: CGSize(width: 3440, height: 1410)) == 6)  // ultrawide
        #expect(FrontLimit.autoCount(for: CGSize(width: 1080, height: 1895)) == 3)  // portrait: the long side counts
        #expect(FrontLimit.autoCount(for: CGSize(width: 800, height: 600)) == 2)
        #expect(FrontLimit.autoCount(for: CGSize(width: 8000, height: 2000)) == 6)
    }

    @Test func limitIsSavedAsANumber() {
        for limit in FrontLimit.choices {
            #expect(FrontLimit(raw: limit.raw) == limit)
        }
        #expect(FrontLimit(raw: -7) == FrontLimit.unlimited)
        #expect(FrontLimit(raw: 99) == .fixed(12))
        #expect(FrontLimit.unlimited.count(for: CGSize(width: 1920, height: 1080)) == nil)
        #expect(FrontLimit.fixed(4).count(for: CGSize(width: 1470, height: 920)) == 4)
    }

    @Test func splitTakesTheFirstFew() {
        let (front, waiting) = FrontWindows.split([1, 2, 3, 4, 5], limit: 3)
        #expect(front == [1, 2, 3])
        #expect(waiting == [4, 5])
        #expect(FrontWindows.split([1, 2], limit: 3).waiting.isEmpty)
        #expect(FrontWindows.split([1, 2, 3], limit: nil).front == [1, 2, 3])
        #expect(FrontWindows.split([1, 2, 3], limit: 0).front == [1])
    }

    /// The promise: a window you use takes the spot of the one used least lately, and the
    /// other front windows don't move.
    @Test func bringingForwardReplacesTheLeastRecentlyUsed() {
        // Front 1, 2, 3; 3 was used least lately, so 5 takes its spot.
        let result = FrontWindows.bringForward(5, in: [1, 2, 3, 4, 5], limit: 3, kept: [], recency: recency)
        #expect(result == [1, 2, 5, 4, 3])
        // Spots of 1 and 2 are untouched.
        #expect(Array(result.prefix(2)) == [1, 2])
    }

    @Test func keptWindowsNeverLeave() {
        // 3 is used least lately but kept, so 2 (next least) goes.
        let result = FrontWindows.bringForward(5, in: [1, 2, 3, 4, 5], limit: 3, kept: [3], recency: recency)
        #expect(result == [1, 5, 3, 4, 2])
        // If every front window is kept, the least used one still makes room (the window you
        // asked for must come on screen).
        let full = FrontWindows.bringForward(5, in: [1, 2, 3, 4, 5], limit: 3, kept: [1, 2, 3], recency: recency)
        #expect(full == [1, 2, 5, 4, 3])
    }

    @Test func bringingForwardAFrontWindowChangesNothing() {
        #expect(FrontWindows.bringForward(2, in: [1, 2, 3, 4], limit: 3, kept: [], recency: recency) == [1, 2, 3, 4])
        #expect(FrontWindows.bringForward(9, in: [1, 2, 3, 4], limit: 3, kept: [], recency: recency) == [1, 2, 3, 4])
    }

    @Test func arrangeKeepsKeptAndWantedInFrontAndLinesUpTheRest() {
        // 6 is kept but waiting: it takes the spot of 3 (used least lately). Then 4, just opened,
        // takes the spot of 2 (the least lately used of the others; 6 is kept).
        let result = FrontWindows.arrange([1, 2, 3, 4, 5, 6], limit: 3, kept: [6], wanted: [4], recency: recency)
        #expect(result == [1, 4, 6, 2, 5, 3])
        let (front, waiting) = FrontWindows.split(result, limit: 3)
        #expect(front.contains(6))
        #expect(front.contains(4))
        #expect(Set(result) == Set([1, 2, 3, 4, 5, 6]))
        // Waiting windows: most lately used first.
        let order = waiting.map { recency[$0] ?? Int.min }
        #expect(order == order.sorted(by: >))
    }

    @Test func twoNewWindowsDontPushEachOtherBack() {
        // 3 and 5 both asked for the front (5 is the less recent of the two): both get there.
        let result = FrontWindows.arrange([1, 2, 4, 3, 5], limit: 3, kept: [], wanted: [3, 5], recency: recency)
        #expect(Set(result.prefix(3)).isSuperset(of: [3, 5]))
    }

    @Test func arrangeWithRoomForEveryoneChangesNothing() {
        #expect(FrontWindows.arrange([3, 1, 2], limit: 3, kept: [], wanted: [2], recency: recency) == [3, 1, 2])
        #expect(FrontWindows.arrange([3, 1, 2, 5], limit: nil, kept: [], wanted: [5], recency: recency) == [3, 1, 2, 5])
    }

    @Test func aFreeSpotGoesToTheMostRecentlyUsedWaitingWindow() {
        // 2 (a front window) closes; 4 and 5 wait; 4 was used more lately, so it takes 2's spot.
        let order = FrontWindows.fillSpots(left: [2], in: [1, 2, 3, 4, 5], waiting: [4, 5], recency: recency)
        #expect(order == [1, 4, 3, 2, 5])
        // Two leave at once: each spot gets a different window, most lately used first.
        let two = FrontWindows.fillSpots(left: [1, 3], in: [1, 2, 3, 4, 5], waiting: [4, 5], recency: recency)
        #expect(two == [4, 2, 5, 1, 3])
        // Nothing waiting, or the window already gone from the list: nothing changes.
        #expect(FrontWindows.fillSpots(left: [2], in: [1, 2, 3], waiting: [], recency: recency) == [1, 2, 3])
        #expect(FrontWindows.fillSpots(left: [9], in: [1, 2, 3, 4], waiting: [4], recency: recency) == [1, 2, 3, 4])
    }

    @Test func mergeKeepsOtherWindowsInPlace() {
        // 7 and 8 are on another desktop; only 1, 2, 3 take part.
        #expect(FrontWindows.merge([3, 1, 2], into: [1, 7, 2, 8, 3]) == [3, 7, 1, 8, 2])
    }

    @Test func waitingWindowsStayOffOtherScreens() {
        let main = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let size = CGSize(width: 800, height: 600)
        // Alone: bottom right, one point showing.
        let alone = FrontWindows.waitingFrame(size: size, screen: main, otherScreens: [])
        #expect(alone.minX == main.maxX - 1 && alone.minY == main.maxY - 1)
        #expect(FrontWindows.isWaiting(alone, screens: [main]))
        // A screen to the right: wait bottom left instead.
        let right = CGRect(x: 1728, y: 0, width: 2560, height: 1440)
        let beside = FrontWindows.waitingFrame(size: size, screen: main, otherScreens: [right])
        #expect(beside.maxX == main.minX + 1)
        #expect(right.intersectionArea(beside) == 0)
        // A window on screen is not waiting.
        #expect(!FrontWindows.isWaiting(CGRect(x: 100, y: 100, width: 800, height: 600), screens: [main]))
    }

    @Test func screensOnBothSidesStillLeaveAHidingPlace() {
        // The office: a Dell to the left, a 49-inch to the right with bottoms lined up.
        let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let dell = CGRect(x: -1600, y: 0, width: 1600, height: 1200)
        let wide = CGRect(x: 1920, y: -360, width: 5120, height: 1440)
        let size = CGSize(width: 601, height: 491)
        let spots = FrontWindows.waitingFrames(size: size, screen: main, otherScreens: [dell, wide])
        // Off the bottom right corner: only a one-point strip touches the 49-inch's bottom row.
        #expect(spots.first == CGRect(x: 1919, y: 1079, width: 601, height: 491))
        #expect(FrontWindows.isOutOfSight(spots[0], on: main, screens: [main, dell, wide]))
        // Every spot is tried in turn if macOS refuses one, and none is left out.
        #expect(spots.count == 25)
        // Where macOS put one when it refused: 101 points showing above the Dock. Not out of sight.
        #expect(!FrontWindows.isOutOfSight(CGRect(x: 29, y: 979, width: 601, height: 491), on: main, screens: [main, dell, wide]))
    }
}
