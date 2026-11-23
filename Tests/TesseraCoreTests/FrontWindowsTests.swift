import CoreGraphics
import Testing
@testable import TesseraCore

@Suite("Front windows")
struct FrontWindowsTests {
    // Recency: bigger means used more lately.
    private let recency = [1: 50, 2: 40, 3: 10, 4: 30, 5: 20, 6: 60]

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
}
