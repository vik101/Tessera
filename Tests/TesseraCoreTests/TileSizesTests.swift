import CoreGraphics
import Testing
@testable import TesseraCore

private let screen = CGRect(x: 0, y: 25, width: 1920, height: 1055)
private let even = TileSizes.even

private func plan(_ count: Int, _ style: LayoutStyle, _ sizes: [CGSize], gap: CGFloat = 8,
                  minimums: [CGSize?] = [], area: CGRect = screen) -> [CGRect] {
    TilePlanner.frames(count: count, in: area, style: style, gap: gap, minimumSizes: minimums, sizes: sizes)
}

private func noOverlaps(_ frames: [CGRect], in area: CGRect) -> Bool {
    frames.allSatisfy { area.contains($0) } &&
        frames.indices.allSatisfy { i in frames.indices.allSatisfy { j in i == j || frames[i].intersectionArea(frames[j]) == 0 } }
}

@Suite("Making tiles larger and smaller")
struct TileSizesTests {
    /// Three columns; you make the middle one larger again and again. It grows into both sides:
    /// the left and right windows both shrink, evenly, and stay at the screen's edges.
    @Test func makingTheMiddleColumnLargerShrinksBothNeighbours() {
        var sizes = [even, even, even]
        var last = plan(3, .columns, sizes)
        for press in 1...6 {
            sizes[1] = TileSizes.resized(sizes[1], larger: true)!
            let frames = plan(3, .columns, sizes)
            #expect(frames[1].width > last[1].width, "press \(press): the middle grows")
            #expect(frames[0].width < last[0].width && frames[2].width < last[2].width, "press \(press): both neighbours shrink")
            #expect(abs(frames[0].width - frames[2].width) <= 1, "press \(press): evenly")
            #expect(frames[0].minX == screen.minX + 8 && frames[2].maxX == screen.maxX - 8, "press \(press): edges stay put")
            #expect(frames[1].minX - frames[0].maxX == 8 && frames[2].minX - frames[1].maxX == 8, "press \(press): no holes")
            #expect(noOverlaps(frames, in: screen))
            last = frames
        }
        // Six presses of Make Smaller go all the way back to even.
        for _ in 1...6 { sizes[1] = TileSizes.resized(sizes[1], larger: false)! }
        #expect(sizes[1] == even)
        #expect(plan(3, .columns, sizes) == plan(3, .columns, [even, even, even]))
    }

    @Test func makingAColumnSmallerGivesItsRoomToTheOthers() {
        let sizes = [even, TileSizes.resized(even, larger: false)!, even]
        let frames = plan(3, .columns, sizes)
        let before = plan(3, .columns, [even, even, even])
        #expect(frames[1].width < before[1].width)
        #expect(frames[0].width > before[0].width && frames[2].width > before[2].width)
    }

    @Test func rowsWorkTheSameWayUpAndDown() {
        let sizes = [even, TileSizes.resized(even, larger: true)!, even]
        let frames = plan(3, .rows, sizes)
        let before = plan(3, .rows, [even, even, even])
        #expect(frames[1].height > before[1].height)
        #expect(frames[0].height < before[0].height && frames[2].height < before[2].height)
        #expect(frames[0].minY == screen.minY + 8 && frames[2].maxY == screen.maxY - 8)
        #expect(frames.allSatisfy { $0.width == before[0].width })   // widths don't change
    }

    @Test func inAGridALargerWindowIsWiderAndItsRowTaller() {
        let sizes = [TileSizes.resized(even, larger: true)!, even, even, even]
        let frames = plan(4, .grid, sizes)
        // 2 × 2: windows 0 and 1 on top, 2 and 3 below.
        #expect(frames[0].width > frames[1].width)
        #expect(frames[0].height > frames[2].height)
        #expect(frames[0].height == frames[1].height)   // a row stays a row
        #expect(noOverlaps(frames, in: screen))
    }

    @Test func mainAndSideLargerMainIsWider() {
        let before = plan(3, .mainAndSide, [even, even, even])
        let main = plan(3, .mainAndSide, [TileSizes.resized(even, larger: true)!, even, even])
        #expect(main[0].width > before[0].width)
        #expect(main[1].width < before[1].width)
        let side = plan(3, .mainAndSide, [even, TileSizes.resized(even, larger: true)!, even])
        #expect(side[1].height > side[2].height)
    }

    @Test func sharesStopAtTheLimits() {
        var size = even
        var presses = 0
        while let next = TileSizes.resized(size, larger: true) {
            size = next
            presses += 1
            #expect(presses < 20)
        }
        #expect(size.width == TileSizes.range.upperBound)
        size = even
        while let next = TileSizes.resized(size, larger: false) { size = next }
        #expect(size.width == TileSizes.range.lowerBound)
    }

    /// Neighbours that can't shrink (an app's minimum size) keep their minimum; the larger
    /// window gets what's left, and nothing overlaps.
    @Test func neighboursKeepTheirMinimumSize() {
        let big = CGSize(width: 4, height: 4)
        let minimums: [CGSize?] = [CGSize(width: 500, height: 200), nil, CGSize(width: 500, height: 200)]
        let frames = plan(3, .columns, [even, big, even], minimums: minimums)
        #expect(frames[0].width >= 500 - 1 && frames[2].width >= 500 - 1)
        #expect(noOverlaps(frames, in: screen))
    }

    /// Any mix of shares, any style, any screen: every window keeps its own space on the screen.
    @Test(arguments: LayoutStyle.allCases.filter(\.isAdaptive))
    func anySharesKeepEveryWindowOnScreenWithoutOverlaps(style: LayoutStyle) {
        var seed: UInt64 = 42
        func random() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return TileSizes.range.lowerBound + CGFloat(seed >> 33) / CGFloat(1 << 31) * (TileSizes.range.upperBound - TileSizes.range.lowerBound)
        }
        for area in [screen, CGRect(x: 0, y: 25, width: 5120, height: 1415), CGRect(x: 0, y: 0, width: 1080, height: 1895)] {
            for count in 1...6 {
                let sizes = (0..<count).map { _ in CGSize(width: random(), height: random()) }
                let frames = plan(count, style, sizes, area: area)
                #expect(frames.count == count)
                #expect(noOverlaps(frames, in: area), "\(style), \(count) windows")
            }
        }
    }

    /// Dragging the edge between the middle and right columns 150 points to the right: the
    /// middle one's right edge lands there, the right one gives way, the left one doesn't move.
    @Test func draggingTheEdgeBetweenTwoColumnsMovesOnlyThatEdge() {
        let frames = plan(3, .columns, [even, even, even])
        var dragged = frames[1]
        dragged.size.width += 150
        let shares = TileSizes.afterDrag(frames: frames, shares: [even, even, even], index: 1, to: dragged, area: screen, gap: 8)
        #expect(shares != nil)
        guard let shares else { return }
        let after = plan(3, .columns, shares)
        #expect(abs(after[1].maxX - dragged.maxX) <= 1)
        #expect(abs(after[1].minX - frames[1].minX) <= 1)
        #expect(abs(after[0].minX - frames[0].minX) <= 1 && abs(after[0].maxX - frames[0].maxX) <= 1)
        #expect(abs(after[2].minX - (frames[2].minX + 150)) <= 1 && after[2].maxX == frames[2].maxX)
        #expect(shares.allSatisfy { $0.height == 1 })   // only widths change
    }

    @Test func draggingTheScreenEdgeChangesNothing() {
        let frames = plan(3, .columns, [even, even, even])
        var dragged = frames[0]
        dragged.origin.x += 100
        dragged.size.width -= 100
        #expect(TileSizes.afterDrag(frames: frames, shares: [even, even, even], index: 0, to: dragged, area: screen, gap: 8) == nil)
    }

    /// In a 2 × 2 grid, dragging the edge between the rows moves it for the whole row.
    @Test func draggingARowEdgeInAGridMovesTheWholeRow() {
        let frames = plan(4, .grid, [even, even, even, even])
        var dragged = frames[0]
        dragged.size.height += 120
        guard let shares = TileSizes.afterDrag(frames: frames, shares: Array(repeating: even, count: 4), index: 0,
                                               to: dragged, area: screen, gap: 8) else {
            Issue.record("no shares")
            return
        }
        let after = plan(4, .grid, shares)
        #expect(abs(after[0].maxY - dragged.maxY) <= 1 && abs(after[1].maxY - dragged.maxY) <= 1)
        #expect(after[2].height < frames[2].height && after[3].height < frames[3].height)
        #expect(after[0].width == frames[0].width)
    }
}
