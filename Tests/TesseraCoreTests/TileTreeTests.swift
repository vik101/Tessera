import CoreGraphics
import Foundation
import Testing
@testable import TesseraCore

private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1000)
private typealias Tree = TileTree<Int>

/// A tree from a compact description: H(1, V(2, 3)).
private func H(_ children: Tree.Node...) -> Tree.Node { .container(.init(orientation: .horizontal, children: children)) }
private func V(_ children: Tree.Node...) -> Tree.Node { .container(.init(orientation: .vertical, children: children)) }
private func w(_ id: Int) -> Tree.Node { .window(id) }
private func tree(_ node: Tree.Node) -> Tree {
    switch node {
    case .container(let c): return Tree(root: c)
    case .window(let id): return Tree(root: .init(orientation: .horizontal, children: [.window(id)]))
    }
}

/// Short text for a tree: H[1 V[2 3]].
private func shape(_ t: Tree) -> String {
    func text(_ node: Tree.Node) -> String {
        switch node {
        case .window(let id): return "\(id)"
        case .container(let c):
            let letter = c.layout == .accordion ? (c.orientation == .horizontal ? "HA" : "VA") : (c.orientation == .horizontal ? "H" : "V")
            return letter + "[" + c.children.map(text).joined(separator: " ") + "]"
        }
    }
    return text(.container(t.root))
}

private func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }

@Suite("Tree layout")
struct TileTreeTests {
    // MARK: Adding

    @Test func firstWindowFillsTheArea() {
        var t = Tree()
        t.insert(1, splitting: nil, direction: .right)
        #expect(t.frames(in: screen) == [1: screen])
        #expect(shape(t) == "H[1]")
    }

    @Test func secondWindowSplitsTheFirst() {
        var t = Tree()
        t.insert(1, splitting: nil, direction: .right)
        t.insert(2, splitting: 1, direction: .right)
        #expect(t.frames(in: screen) == [1: r(0, 0, 960, 1000), 2: r(960, 0, 960, 1000)])
        // Splitting down from 2 makes a column on the right.
        t.insert(3, splitting: 2, direction: .down)
        #expect(shape(t) == "H[1 V[2 3]]")
        #expect(t.frames(in: screen) == [1: r(0, 0, 960, 1000), 2: r(960, 0, 960, 500), 3: r(960, 500, 960, 500)])
    }

    @Test func splittingTheSameWayTakesHalfOfThatTileOnly() {
        var t = tree(H(w(1), w(2)))
        t.insert(3, splitting: 2, direction: .right)
        #expect(shape(t) == "H[1 2 3]")
        #expect(t.frames(in: screen) == [1: r(0, 0, 960, 1000), 2: r(960, 0, 480, 1000), 3: r(1440, 0, 480, 1000)])
    }

    @Test func splittingLeftOrUpPutsTheNewWindowFirst() {
        var t = tree(H(w(1), w(2)))
        t.insert(3, splitting: 1, direction: .left)
        #expect(shape(t) == "H[3 1 2]")
        t.insert(4, splitting: 2, direction: .up)
        #expect(shape(t) == "H[3 1 V[4 2]]")
    }

    @Test func aMissingTargetSplitsTheLastWindow() {
        var t = tree(H(w(1), w(2)))
        t.insert(3, splitting: 99, direction: .down)
        #expect(shape(t) == "H[1 V[2 3]]")
        t.insert(3, splitting: 1, direction: .down)     // Already in: nothing changes.
        #expect(shape(t) == "H[1 V[2 3]]")
    }

    @Test func theFirstWindowSetsTheRootWay() {
        var t = Tree()
        t.insert(1, splitting: nil, direction: .down, orientation: .vertical)
        t.insert(2, splitting: 1, direction: .down)
        #expect(shape(t) == "V[1 2]")
    }

    // MARK: Removing

    @Test func closingAWindowLetsItsNeighbourGrow() {
        var t = tree(H(w(1), w(2), w(3)))
        t.remove(2)
        // 1 was the neighbour before 2: it takes 2's share.
        #expect(t.frames(in: screen) == [1: r(0, 0, 1280, 1000), 3: r(1280, 0, 640, 1000)])
        var u = tree(H(w(1), w(2), w(3)))
        u.remove(1)
        #expect(u.frames(in: screen) == [2: r(0, 0, 1280, 1000), 3: r(1280, 0, 640, 1000)])
    }

    @Test func aContainerWithOneWindowLeftIsReplacedByIt() {
        var t = tree(H(w(1), V(w(2), w(3))))
        t.remove(3)
        #expect(shape(t) == "H[1 2]")
        #expect(t.frames(in: screen) == [1: r(0, 0, 960, 1000), 2: r(960, 0, 960, 1000)])
        t.remove(1)
        #expect(shape(t) == "H[2]")
        t.remove(2)
        #expect(t.isEmpty)
        #expect(t.frames(in: screen).isEmpty)
    }

    @Test func aWindowPutBackReturnsToItsPlace() {
        var t = tree(H(w(1), V(w(2), w(3)), w(4)))
        let before = t.frames(in: screen)
        let hint = t.remove(3)
        #expect(hint == Tree.Hint(anchor: 2, direction: .down))
        t.insert(3, hint: hint, fallback: 1, direction: .right)
        #expect(t.frames(in: screen) == before)
        // The first child remembers the window after it.
        let first = t.remove(1)
        #expect(first == Tree.Hint(anchor: 2, direction: .left))
        t.insert(1, hint: first, fallback: nil, direction: .right)
        #expect(shape(t) == "H[1 V[2 3] 4]")
    }

    @Test func aHintWhoseAnchorIsGoneFallsBack() {
        var t = tree(H(w(1), w(2)))
        t.insert(3, hint: Tree.Hint(anchor: 42, direction: .left), fallback: 1, direction: .down)
        #expect(shape(t) == "H[V[1 3] 2]")
    }

    @Test func reconcileKeepsExactlyTheWindowsPresent() {
        var t = tree(H(w(1), w(2), w(3)))
        t.reconcile([1, 3, 4, 5], target: nil) { _ in .right }
        #expect(Set(t.windows) == [1, 3, 4, 5])
        #expect(!t.contains(2))
    }

    // MARK: Moving

    @Test func movingPastAWindowSwapsThemAndSpotsKeepTheirSizes() {
        var t = tree(H(w(1), w(2), w(3)))
        t.resize(1, along: .horizontal, by: 200, in: screen)
        let spots = t.frames(in: screen)
        let r1 = t.move(1, .right)
        #expect(r1)
        #expect(t.windows == [2, 1, 3])
        let after = t.frames(in: screen)
        #expect(after[2] == spots[1])
        #expect(after[1] == spots[2])
    }

    @Test func movingIntoAColumn() {
        var t = tree(H(w(1), V(w(2), w(3))))
        let r2 = t.move(1, .right)
        #expect(r2)
        #expect(shape(t) == "V[2 3 1]")
    }

    @Test func movingOutOfAColumnAtTheEnd() {
        var t = tree(H(w(1), V(w(2), w(3))))
        let r3 = t.move(3, .right)
        #expect(r3)
        #expect(shape(t) == "H[1 2 3]")
    }

    @Test func movingDownOutOfARow() {
        var t = tree(V(H(w(1), w(2)), w(3)))
        let r4 = t.move(1, .down)
        #expect(r4)
        #expect(shape(t) == "V[2 1 3]")
    }

    @Test func movingAcrossARootThatRunsTheOtherWaySplitsIt() {
        var t = tree(V(w(1), w(2), w(3)))
        let r5 = t.move(3, .right)
        #expect(r5)
        #expect(shape(t) == "H[V[1 2] 3]")
        var u = tree(V(w(1), w(2)))
        let r6 = u.move(2, .left)
        #expect(r6)
        #expect(shape(u) == "H[2 1]")
    }

    @Test func movingPastTheEdgeOfARowReturnsFalse() {
        var t = tree(H(w(1), w(2)))
        let r7 = t.move(1, .left)
        #expect(!r7)
        let r8 = t.move(2, .right)
        #expect(!r8)
        #expect(t.windows == [1, 2])
        var single = tree(w(1))
        let r9 = single.move(1, .up)
        #expect(!r9)
        let r10 = single.move(1, .right)
        #expect(!r10)
    }

    @Test func swappingKeepsEverySpot() {
        var t = tree(H(w(1), V(w(2), w(3)), w(4)))
        let before = t.frames(in: screen)
        t.swap(1, 3)
        let after = t.frames(in: screen)
        #expect(after[3] == before[1])
        #expect(after[1] == before[3])
        #expect(after[2] == before[2])
        t.swap(4, 4)
        #expect(t.frames(in: screen) == after)
    }

    @Test func replacingAWindowKeepsItsSpot() {
        var t = tree(H(w(1), V(w(2), w(3))))
        let before = t.frames(in: screen)
        t.replace(2, with: 9)
        #expect(shape(t) == "H[1 V[9 3]]")
        #expect(t.frames(in: screen)[9] == before[2])
        t.replace(1, with: 3)       // Already in the tree: nothing changes.
        #expect(shape(t) == "H[1 V[9 3]]")
    }

    @Test func joiningMakesAColumnFromTwoNeighbours() {
        var t = tree(H(w(1), w(2), w(3)))
        let r11 = t.join(2, .right)
        #expect(r11)
        #expect(shape(t) == "H[1 V[2 3]]")
        // The column keeps both shares: two thirds of the width.
        #expect(t.frames(in: screen)[2] == r(640, 0, 1280, 500))
        // Joining a column that already runs the other way adds to it.
        let r12 = t.join(1, .right)
        #expect(r12)
        #expect(shape(t) == "V[1 2 3]")
        let r13 = t.join(3, .down)
        #expect(!r13)
    }

    @Test func joiningFromInsideAContainerReachesItsNeighbour() {
        var t = tree(H(V(w(1), w(2)), w(3)))
        let r14 = t.join(2, .right)
        #expect(r14)
        #expect(shape(t) == "H[1 V[2 3]]")
    }

    @Test func popOutAndPopIn() {
        var t = tree(H(w(1), V(w(2), w(3))))
        let r15 = t.popOut(2)
        #expect(r15)
        #expect(shape(t) == "H[1 3 2]")
        let r16 = t.popOut(1)  // Already at the top.
        #expect(!r16)
        let r17 = t.popIn(3)
        #expect(r17)
        #expect(shape(t) == "H[1 V[3 2]]")
    }

    // MARK: Containers

    @Test func changingTheContainerWay() {
        var t = tree(H(w(1), V(w(2), w(3))))
        t.toggleOrientation(of: 2)
        // The column now runs side by side, like its parent, so it merges into it.
        #expect(shape(t) == "H[1 2 3]")
        t.setLayout(of: 1, layout: nil, orientation: .vertical)
        #expect(shape(t) == "V[1 2 3]")
    }

    @Test func accordionShowsAStripOfEachNeighbour() {
        var t = tree(H(w(1), w(2), w(3)))
        t.setLayout(of: 1, layout: .accordion, orientation: nil)
        #expect(shape(t) == "HA[1 2 3]")
        let f = t.frames(in: screen, padding: 30)
        #expect(f[1] == r(0, 0, 1890, 1000))
        #expect(f[2] == r(30, 0, 1860, 1000))
        #expect(f[3] == r(30, 0, 1890, 1000))
        // New windows join the accordion beside the one they split.
        t.insert(4, splitting: 3, direction: .down)
        #expect(shape(t) == "HA[1 2 3 4]")
    }

    @Test func anAccordionNeverSqueezesAWindowBelowHalf() {
        let t = tree(H(w(1), w(2)))
        var a = t
        a.setLayout(of: 1, layout: .accordion, orientation: nil)
        let f = a.frames(in: r(0, 0, 200, 100), padding: 100)
        #expect(f[1]!.width >= 100)
        #expect(f[2]!.width >= 100)
    }

    @Test func mirrorAndRotate() {
        var t = tree(H(w(1), V(w(2), w(3))))
        t.mirror(.horizontal)
        #expect(shape(t) == "H[V[2 3] 1]")
        t.mirror(.vertical)
        #expect(shape(t) == "H[V[3 2] 1]")

        var u = tree(H(w(1), w(2)))
        u.rotate(clockwise: true)
        #expect(shape(u) == "V[1 2]")
        u.rotate(clockwise: true)
        #expect(shape(u) == "H[2 1]")
        u.rotate(clockwise: false)
        #expect(shape(u) == "V[1 2]")

        var whole = tree(H(w(1), V(w(2), w(3)), w(4)))
        let start = whole
        for _ in 0..<4 { whole.rotate(clockwise: true) }
        #expect(shape(whole) == shape(start))
    }

    @Test func balanceAndFlatten() {
        var t = tree(H(w(1), V(w(2), w(3))))
        t.resize(1, along: .horizontal, by: 300, in: screen)
        t.balance()
        #expect(t.frames(in: screen)[1] == r(0, 0, 960, 1000))
        t.flatten()
        #expect(shape(t) == "H[1 2 3]")
        #expect(t.frames(in: screen)[3] == r(1280, 0, 640, 1000))
    }

    // MARK: Sizes

    @Test func resizeTakesFromTheSiblings() {
        var t = tree(H(w(1), w(2)))
        let r18 = t.resize(1, along: .horizontal, by: 100, in: screen)
        #expect(r18)
        #expect(t.frames(in: screen) == [1: r(0, 0, 1060, 1000), 2: r(1060, 0, 860, 1000)])
        // Height: no container runs that way, so nothing changes.
        let r19 = t.resize(1, along: .vertical, by: 100, in: screen)
        #expect(!r19)
        // Never below the minimum.
        let r20 = t.resize(2, along: .horizontal, by: -5000, in: screen, minimum: 40)
        #expect(r20)
        #expect(t.frames(in: screen)[2]!.width == 40)
    }

    @Test func resizeReachesTheNearestContainerThatRunsThatWay() {
        var t = tree(H(w(1), V(w(2), w(3))))
        let r21 = t.resize(2, along: .horizontal, by: -160, in: screen)
        #expect(r21)
        let f = t.frames(in: screen)
        #expect(f[1] == r(0, 0, 1120, 1000))
        #expect(f[2] == r(1120, 0, 800, 500))
        #expect(f[3] == r(1120, 500, 800, 500))
    }

    @Test func movingAnEdgeOnlyChangesTheNeighbourAcrossIt() {
        var t = tree(H(w(1), w(2), w(3)))
        let r22 = t.moveEdge(2, .right, by: 100, in: screen)
        #expect(r22)
        let f = t.frames(in: screen)
        #expect(f[1] == r(0, 0, 640, 1000))
        #expect(f[2] == r(640, 0, 740, 1000))
        #expect(f[3] == r(1380, 0, 540, 1000))
        // The screen's edge can't move.
        let r23 = t.moveEdge(3, .right, by: 50, in: screen)
        #expect(!r23)
        let r24 = t.moveEdge(1, .left, by: 50, in: screen)
        #expect(!r24)
        // The left edge of 2, dragged left by 40: 2 grows, 1 shrinks.
        let r25 = t.moveEdge(2, .left, by: 40, in: screen)
        #expect(r25)
        #expect(t.frames(in: screen)[1] == r(0, 0, 600, 1000))
    }

    // MARK: Frames

    @Test func gapsMatchTheOtherLayouts() {
        let t = tree(H(w(1), w(2)))
        let f = t.frames(in: screen, gap: 10)
        #expect(f[1] == applyGap(r(0, 0, 960, 1000), in: screen, gap: 10))
        #expect(f[2] == applyGap(r(960, 0, 960, 1000), in: screen, gap: 10))
        #expect(f[1] == r(10, 10, 945, 980))
    }

    @Test func aWindowThatWontShrinkGetsItsSizeAndTheRestShare() {
        let t = tree(H(w(1), w(2), w(3)))
        let f = t.frames(in: screen, minimums: [1: CGSize(width: 1200, height: 0)])
        #expect(f[1]!.width == 1200)
        #expect(f[2]!.width == 360)
        #expect(f[3]!.width == 360)
    }

    @Test func fromFramesRebuildsEveryLayoutExactly() {
        for style in [LayoutStyle.columns, .rows, .grid, .mainAndSide, .auto] {
            for count in 1...7 {
                for gap in [CGFloat(0), 10] {
                    let frames = TilePlanner.frames(count: count, in: screen, style: style, gap: gap)
                    let rebuilt = Tree.fromFrames(frames.enumerated().map { (id: $0.offset, frame: $0.element) }, in: screen)
                    let again = rebuilt.frames(in: screen, gap: gap)
                    #expect(rebuilt.count == count, "\(style) \(count)")
                    for (i, frame) in frames.enumerated() {
                        #expect(again[i].map { $0.isClose(to: frame, tolerance: 1) } == true,
                                "\(style) with \(count) windows, gap \(gap): window \(i) \(again[i].map(NSStringFromRectSafe) ?? "nil") ≠ \(NSStringFromRectSafe(frame))")
                    }
                }
            }
        }
    }

    @Test func fromFramesOfOverlappingWindowsPutsThemSideBySide() {
        let items: [(id: Int, frame: CGRect)] = [(1, r(0, 0, 800, 800)), (2, r(100, 100, 800, 800))]
        let t = Tree.fromFrames(items)
        #expect(Set(t.windows) == [1, 2])
        #expect(t.count == 2)
    }

    @Test func normalisingKeepsFrames() {
        // A row inside a row merges into it without moving anything.
        let nested = Tree.Container(orientation: .horizontal, children: [w(1), H(w(2), w(3))], weights: [1, 2])
        let t = Tree(root: nested)
        #expect(shape(t) == "H[1 2 3]")
        #expect(t.frames(in: r(0, 0, 1800, 900)) == [1: r(0, 0, 600, 900), 2: r(600, 0, 600, 900), 3: r(1200, 0, 600, 900)])
    }

    @Test func directionWords() {
        #expect(Direction(word: "west") == .left)
        #expect(Direction(word: "EAST") == .right)
        #expect(Direction(word: "north") == .up)
        #expect(Direction(word: "south") == .down)
        #expect(Direction(word: "sideways") == nil)
        #expect(Direction.left.opposite == .right)
        #expect(Orientation.of(.up) == .vertical)
        #expect(Orientation.along(CGSize(width: 10, height: 20)) == .vertical)
    }
}

private func NSStringFromRectSafe(_ r: CGRect) -> String {
    "(\(Int(r.minX)), \(Int(r.minY)), \(Int(r.width)), \(Int(r.height)))"
}
