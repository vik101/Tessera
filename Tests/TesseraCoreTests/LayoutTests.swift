import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import TesseraCore

private let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)

private func frames(_ layout: LayoutKind, _ shape: ScreenShape = .landscape, count: Int, main: MainSize = .half, gap: Double = 0, rect: CGRect = screen) -> [Int: CGRect] {
    let tree = LayoutEngine.tree(layout: layout, shape: shape, count: count, mainSize: main)
    let solver = LayoutSolver(gap: gap, defaultMinimum: CGSize(width: 10, height: 10))
    guard case .success(let result) = solver.solve(tree, in: rect) else {
        Issue.record("layout failed")
        return [:]
    }
    return result
}

@Suite("Layout shapes")
struct LayoutShapeTests {
    @Test func oneWindowFillsTheArea() {
        let f = frames(.grid, count: 1)
        #expect(f[0] == screen)
    }

    @Test func gridTwoIsSideBySidePrimaryLeft() {
        let f = frames(.grid, count: 2)
        #expect(f[0] == CGRect(x: 0, y: 0, width: 500, height: 600))
        #expect(f[1] == CGRect(x: 500, y: 0, width: 500, height: 600))
    }

    @Test func gridThreeSplitsTheRightHalf() {
        let f = frames(.grid, count: 3)
        #expect(f[0] == CGRect(x: 0, y: 0, width: 500, height: 600))
        #expect(f[1] == CGRect(x: 500, y: 0, width: 500, height: 300))
        #expect(f[2] == CGRect(x: 500, y: 300, width: 500, height: 300))
    }

    @Test func gridFourPrimaryKeepsTopOfItsColumn() {
        let f = frames(.grid, count: 4)
        #expect(f[0] == CGRect(x: 0, y: 0, width: 500, height: 300))
        #expect(f[3] == CGRect(x: 0, y: 300, width: 500, height: 300))
        #expect(f[1] == CGRect(x: 500, y: 0, width: 500, height: 300))
        #expect(f[2] == CGRect(x: 500, y: 300, width: 500, height: 300))
    }

    @Test func columnsHalfMeansEqualShares() {
        let f = frames(.columns, count: 4)
        #expect(f.values.allSatisfy { $0.width == 250 && $0.height == 600 })
    }

    @Test func columnsSixtyGivesFirstColumnSixty() {
        let f = frames(.columns, count: 3, main: .sixty)
        #expect(f[0]?.width == 600)
        #expect(f[1]?.width == 200)
    }

    @Test func rowsStackFullWidth() {
        let f = frames(.rows, count: 3)
        #expect(f[0] == CGRect(x: 0, y: 0, width: 1000, height: 200))
        #expect(f[2] == CGRect(x: 0, y: 400, width: 1000, height: 200))
    }

    @Test func sideStacksOthersOnTheRight() {
        let f = frames(.side, count: 4, main: .twoThirds)
        #expect(f[0]?.width == 667)
        #expect(f[1]?.minX == 667)
        #expect(f[3]?.maxY == 600)
    }

    @Test func gapsSeparateTiles() {
        let f = frames(.grid, count: 2, gap: 10)
        #expect(f[0] == CGRect(x: 0, y: 0, width: 495, height: 600))
        #expect(f[1] == CGRect(x: 505, y: 0, width: 495, height: 600))
    }

    @Test func ultrawideSideKeepsTwoLargeAndANarrowColumn() {
        let wide = CGRect(x: 0, y: 0, width: 3440, height: 1400)
        #expect(ScreenShape.of(width: 3440, height: 1440) == .ultrawide)
        let f = frames(.side, .ultrawide, count: 5, rect: wide)
        #expect(f.count == 5)
        #expect(f[0]?.width == 1290)
        #expect(f[1]?.width == 1290)
        #expect(f[2]?.width == 860)
        #expect(f[4]?.maxY == 1400)
    }

    @Test func verticalGridPutsMainOnTop() {
        let tall = CGRect(x: 0, y: 0, width: 600, height: 1000)
        let f = frames(.grid, .vertical, count: 3, rect: tall)
        #expect(f[0] == CGRect(x: 0, y: 0, width: 600, height: 500))
        #expect(f[1] == CGRect(x: 0, y: 500, width: 300, height: 500))
    }

    @Test func columnsBecomeRowsOnVerticalScreens() {
        #expect(!ScreenShape.vertical.availableLayouts.contains(.columns))
        let tall = CGRect(x: 0, y: 0, width: 600, height: 900)
        let f = frames(.columns, .vertical, count: 3, rect: tall)
        #expect(f[0]?.width == 600)
    }
}

@Suite("Solver")
struct SolverTests {
    @Test func waterFillRespectsMinimums() {
        let lengths = LayoutSolver.waterFill(total: 1000, weights: [1, 1], minimums: [700, 100])
        #expect(lengths == [700, 300])
    }

    @Test func waterFillFailsWhenMinimumsExceedSpace() {
        #expect(LayoutSolver.waterFill(total: 500, weights: [1, 1], minimums: [400, 400]) == nil)
    }

    @Test func splitLinesMoveToMakeRoom() {
        let tree = LayoutEngine.tree(layout: .grid, shape: .landscape, count: 2, mainSize: .half)
        let solver = LayoutSolver(gap: 0, minimumSizes: [1: CGSize(width: 700, height: 100)])
        guard case .success(let f) = solver.solve(tree, in: screen) else { Issue.record("failed"); return }
        #expect(f[1]?.width == 700)
        #expect(f[0]?.width == 300)
    }

    @Test func reportsTilesThatCannotFit() {
        let tree = LayoutEngine.tree(layout: .columns, shape: .landscape, count: 3, mainSize: .half)
        let solver = LayoutSolver(gap: 0, minimumSizes: [0: CGSize(width: 1000, height: 100), 1: CGSize(width: 300, height: 100)])
        let result = solver.solve(tree, in: CGRect(x: 0, y: 0, width: 1200, height: 900))
        #expect(result == .failure(.doesNotFit(tiles: [0, 1])))
    }

    @Test func capacityShrinksOnSmallScreens() {
        let small = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let n = LayoutEngine.effectiveCapacity(layout: .columns, shape: .landscape, requested: 4, area: small, gap: 8, mainSize: .half)
        #expect(n == 3)
    }

    @Test func draggingAnEdgeMovesTheSplit() {
        let tree = LayoutEngine.tree(layout: .grid, shape: .landscape, count: 2, mainSize: .half)
        let solver = LayoutSolver(gap: 0)
        let overrides = solver.overridesAfterDrag(tile: 0, to: CGRect(x: 0, y: 0, width: 600, height: 600), tree: tree, in: screen)
        let resized = LayoutSolver(gap: 0, overrides: overrides)
        guard case .success(let f) = resized.solve(tree, in: screen) else { Issue.record("failed"); return }
        #expect(f[0]?.width == 600)
        #expect(f[1]?.width == 400)
    }

    @Test func outerEdgesDoNotMove() {
        let tree = LayoutEngine.tree(layout: .grid, shape: .landscape, count: 2, mainSize: .half)
        let solver = LayoutSolver(gap: 0)
        let overrides = solver.overridesAfterDrag(tile: 0, to: CGRect(x: 50, y: 0, width: 450, height: 600), tree: tree, in: screen)
        #expect(overrides.isEmpty)
    }

    @Test func growAndShrinkStepAlongEverySplit() {
        let tree = LayoutEngine.tree(layout: .grid, shape: .landscape, count: 3, mainSize: .half)
        let solver = LayoutSolver(gap: 0)
        let grown = solver.overridesAfterStep(tile: 1, step: 100, tree: tree, in: screen)
        #expect(grown.changed)
        let after = LayoutSolver(gap: 0, overrides: grown.overrides)
        guard case .success(let f) = after.solve(tree, in: screen) else { Issue.record("failed"); return }
        #expect(f[1]!.width > 500)
        #expect(f[1]!.height > 300)
    }

    @Test func shrinkStopsAtMinimum() {
        let tree = LayoutEngine.tree(layout: .grid, shape: .landscape, count: 2, mainSize: .half)
        let solver = LayoutSolver(gap: 0, defaultMinimum: CGSize(width: 500, height: 10))
        let result = solver.overridesAfterStep(tile: 0, step: -50, tree: tree, in: screen)
        #expect(!result.changed)
    }
}
