import CoreGraphics
import Testing
@testable import TesseraCore

private let standard = CGRect(x: 0, y: 25, width: 1920, height: 1055)
private let ultrawide = CGRect(x: 0, y: 25, width: 3440, height: 1415)
private let portrait = CGRect(x: 0, y: 0, width: 1080, height: 1895)
private let laptop = CGRect(x: 0, y: 25, width: 1440, height: 875)

private func plan(_ n: Int, _ area: CGRect = standard, _ style: LayoutStyle = .auto, gap: CGFloat = 0, minimums: [CGSize?] = []) -> [CGRect] {
    TilePlanner.frames(count: n, in: area, style: style, gap: gap, minimumSizes: minimums)
}

@Suite("Auto-tile layouts")
struct TileTests {
    /// The promise to the user: every window gets its own space, inside the screen, with nothing hidden.
    @Test(arguments: LayoutStyle.allCases)
    func everyWindowGetsItsOwnSpace(style: LayoutStyle) {
        for area in [standard, ultrawide, portrait, laptop] {
            for n in 1...12 {
                let frames = plan(n, area, style, gap: 8)
                #expect(frames.count == n)
                for (i, a) in frames.enumerated() {
                    #expect(area.contains(a), "\(style) n=\(n): window \(i) leaves the screen")
                    #expect(a.width >= 20 && a.height >= 20)
                    for b in frames[(i + 1)...] {
                        #expect(a.intersectionArea(b) == 0, "\(style) n=\(n): windows overlap")
                    }
                }
            }
        }
    }

    @Test(arguments: [LayoutStyle.auto, .columns, .rows, .grid, .mainAndSide])
    func noGapsWithoutAGapSetting(style: LayoutStyle) {
        for n in 1...9 {
            let frames = plan(n, laptop, style)
            let covered = frames.map { $0.width * $0.height }.reduce(0, +)
            if style == .auto && n == 1 { continue }
            #expect(covered == laptop.width * laptop.height, "\(style) n=\(n) leaves holes")
        }
    }

    @Test func autoPicksSensibleArrangements() {
        // 1 window fills a normal screen.
        #expect(plan(1) == [standard])
        // 2 windows side by side.
        #expect(plan(2) == [CGRect(x: 0, y: 25, width: 960, height: 1055), CGRect(x: 960, y: 25, width: 960, height: 1055)])
        // 3 windows: a main window plus two stacked beside it.
        #expect(plan(3) == plan(3, standard, .mainAndSide))
        // 4 windows: a 2×2 grid.
        let four = plan(4)
        #expect(Set(four.map(\.width)) == [960])
        #expect(Set(four.map(\.minY)).count == 2)
        // 6 windows: 3 across, 2 down.
        #expect(Set(plan(6).map(\.width)) == [640])
    }

    @Test func autoAdaptsToTheScreenShape() {
        // Portrait: windows stack top to bottom.
        let tall = plan(2, portrait)
        #expect(tall[0].width == portrait.width && tall[1].minY == tall[0].maxY)
        // Ultrawide: a single window is centred, not stretched.
        let single = plan(1, ultrawide)[0]
        #expect(single.midX == ultrawide.midX && single.width < ultrawide.width)
        // Ultrawide with 5: 3 on top and 2 below, never a thin full-width strip.
        #expect(plan(5, ultrawide).allSatisfy { $0.width < ultrawide.width / 1.5 })
    }

    @Test func styles() {
        #expect(Set(plan(3, standard, .columns).map(\.width)) == [640])
        #expect(Set(plan(3, standard, .rows).map(\.width)) == [1920])
        let main = plan(4, standard, .mainAndSide)
        #expect(main[0] == CGRect(x: 0, y: 25, width: 960, height: 1055))
        #expect(main[1...].allSatisfy { $0.minX == 960 && $0.width == 960 })
        let mainTall = plan(3, portrait, .mainAndSide)
        #expect(mainTall[0].width == portrait.width)
        #expect(LayoutStyle.auto.next == .columns && LayoutStyle.mainAndSide.next == .auto)
    }

    @Test func mainRatioChangesTheMainWindow() {
        let frames = TilePlanner.frames(count: 3, in: standard, style: .mainAndSide, mainRatio: 0.6)
        #expect(frames[0].width == 1152)
    }

    @Test func windowsThatCannotShrinkGetAnArrangementTheyFit() {
        // Two windows that need 1000 points of width can't sit side by side on 1920.
        let wide = CGSize(width: 1000, height: 300)
        let frames = plan(2, standard, .auto, minimums: [wide, wide])
        #expect(frames.allSatisfy { $0.width >= 1000 })
        #expect(frames[0].intersectionArea(frames[1]) == 0)
    }

    @Test func gapsAreEven() {
        let frames = plan(2, standard, .columns, gap: 10)
        #expect(frames[0].minX == 10)
        #expect(frames[1].minX - frames[0].maxX == 10)
        #expect(standard.maxX - frames[1].maxX == 10)
    }
}

@Suite("Space left by snapped windows")
struct FreeAreaTests {
    @Test func leftHalfLeavesTheRightHalf() {
        let left = CGRect(x: 0, y: 25, width: 960, height: 1055)
        #expect(TilePlanner.freeArea(standard, excluding: [left]) == CGRect(x: 960, y: 25, width: 960, height: 1055))
    }

    @Test func topHalfLeavesTheBottom() {
        let top = CGRect(x: 0, y: 25, width: 1920, height: 528)
        #expect(TilePlanner.freeArea(standard, excluding: [top]) == CGRect(x: 0, y: 553, width: 1920, height: 527))
    }

    @Test func twoThirdsLeavesOneThird() {
        let big = CGRect(x: 640, y: 25, width: 1280, height: 1055)
        #expect(TilePlanner.freeArea(standard, excluding: [big]) == CGRect(x: 0, y: 25, width: 640, height: 1055))
    }

    @Test func cornersAndMaximisedWindowsFloatAbove() {
        let corner = CGRect(x: 0, y: 25, width: 960, height: 528)
        #expect(TilePlanner.freeArea(standard, excluding: [corner]) == standard)
        #expect(TilePlanner.freeArea(standard, excluding: [standard]) == standard)
    }

    @Test func gapsCountAsTouchingTheEdge() {
        let left = CGRect(x: 10, y: 35, width: 945, height: 1035)
        #expect(TilePlanner.freeArea(standard, excluding: [left], tolerance: 12) == CGRect(x: 955, y: 25, width: 965, height: 1055))
    }
}

@Suite("Window order")
struct OrderTests {
    @Test func reconcileKeepsOrderAndAppendsNewWindows() {
        #expect(TileOrder.reconcile([3, 1, 2], present: [1, 2, 4]) == [1, 2, 4])
        #expect(TileOrder.reconcile([5, 6], present: [7, 6, 5]) == [5, 6, 7])
    }

    @Test func promoteAndSwap() {
        #expect(TileOrder.promote(3, in: [1, 2, 3]) == [3, 2, 1])
        #expect(TileOrder.promote(1, in: [1, 2, 3]) == [2, 1, 3])
        #expect(TileOrder.swap(1, 3, in: [1, 2, 3]) == [3, 2, 1])
    }
}
