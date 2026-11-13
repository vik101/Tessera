import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import TesseraCore

@Suite("Screen model")
struct ScreenStateTests {
    @Test func newWindowsTakeTheNextFreeTile() {
        var s = ScreenState()
        let first = s.insert(1, capacity: 3, placement: .nextFreeTile, whenFull: .stack, activeTile: nil)
        let second = s.insert(2, capacity: 3, placement: .nextFreeTile, whenFull: .stack, activeTile: nil)
        #expect(first == .tiled(tile: 0))
        #expect(second == .tiled(tile: 1))
        #expect(s.showingWindows == [1, 2])
    }

    @Test func mainTilePlacementPushesOthersDown() {
        var s = ScreenState(tiles: [Tile(1), Tile(2)])
        s.insert(3, capacity: 3, placement: .mainTile, whenFull: .stack, activeTile: nil)
        #expect(s.showingWindows == [3, 1, 2])
    }

    @Test func fullScreenStacksInTheActiveTile() {
        var s = ScreenState(tiles: [Tile(1), Tile(2)])
        let result = s.insert(3, capacity: 2, placement: .nextFreeTile, whenFull: .stack, activeTile: 0)
        #expect(result == .stacked(tile: 0))
        #expect(s.tiles[0].windows == [1, 3])
        #expect(s.tiles[0].showing == 3)
    }

    @Test func fullScreenCanFloatInstead() {
        var s = ScreenState(tiles: [Tile(1)])
        let result = s.insert(2, capacity: 1, placement: .nextFreeTile, whenFull: .float, activeTile: 0)
        #expect(result == .floated)
        #expect(!s.contains(2))
    }

    @Test func closingReflowsAndKeepsOrder() {
        var s = ScreenState(tiles: [Tile(1), Tile(2), Tile(3)])
        s.remove(1, rebalanceTo: 3)
        #expect(s.showingWindows == [2, 3])
    }

    @Test func closingTheShowingWindowRevealsTheMostRecent() {
        var s = ScreenState(tiles: [Tile([1, 2, 3])])
        s.remove(3, rebalanceTo: 1)
        #expect(s.tiles[0].showing == 2)
    }

    @Test func roomGivesWaitingWindowsTheirOwnTile() {
        var s = ScreenState(tiles: [Tile([1, 4]), Tile(2), Tile(3)])
        s.remove(3, rebalanceTo: 3)
        #expect(s.tiles.count == 3)
        #expect(s.tiles[0].windows == [4])
        #expect(s.tiles[2].windows == [1])
    }

    @Test func loweringCountFoldsTheLastTile() {
        var s = ScreenState(tiles: [Tile(1), Tile(2), Tile(3)])
        s.rebalance(capacity: 2)
        #expect(s.tiles.count == 2)
        #expect(s.tiles[1].windows == [3, 2])
        #expect(s.tiles[1].showing == 2)
    }

    @Test func swappingMovesOnlyShowingWindows() {
        var s = ScreenState(tiles: [Tile([5, 1]), Tile(2)])
        s.swapShowing(0, 1)
        #expect(s.tiles[0].windows == [5, 2])
        #expect(s.tiles[1].windows == [1])
    }

    @Test func makePrimary() {
        var s = ScreenState(tiles: [Tile(1), Tile(2), Tile(3)])
        s.makePrimary(3)
        #expect(s.showingWindows == [3, 2, 1])
    }

    @Test func stackCyclesBothWays() {
        var t = Tile([1, 2, 3])
        t.cycleForward()
        #expect(t.showing == 1)
        t.cycleBackward()
        #expect(t.showing == 3)
    }

    @Test func stackOntoKeepsTargetWhenIndicesShift() {
        var s = ScreenState(tiles: [Tile(1), Tile(2), Tile(3)])
        s.stack(1, onto: 2)
        #expect(s.tiles.count == 2)
        #expect(s.tiles[1].windows == [3, 1])
    }

    @Test func reconcileDropsMissingAndAddsNew() {
        var s = ScreenState(tiles: [Tile(1), Tile(2)])
        let floated = s.reconcile(present: [2, 7], capacity: 3, whenFull: .stack)
        #expect(floated.isEmpty)
        #expect(s.showingWindows == [2, 7])
    }
}

@Suite("Navigation")
struct NavigationTests {
    let tiles: [Int: CGRect] = [
        0: CGRect(x: 0, y: 0, width: 500, height: 600),
        1: CGRect(x: 500, y: 0, width: 500, height: 300),
        2: CGRect(x: 500, y: 300, width: 500, height: 300),
    ]

    @Test func rightFromPrimaryPicksTopOfColumn() {
        #expect(Navigation.neighbor(of: tiles[0]!, direction: .right, among: tiles) == 1)
    }

    @Test func downWithinAColumn() {
        #expect(Navigation.neighbor(of: tiles[1]!, direction: .down, among: tiles) == 2)
    }

    @Test func nothingBeyondTheEdge() {
        #expect(Navigation.neighbor(of: tiles[0]!, direction: .left, among: tiles) == nil)
    }

    @Test func leftFromBottomRightIsPrimary() {
        #expect(Navigation.neighbor(of: tiles[2]!, direction: .left, among: tiles) == 0)
    }
}

@Suite("Shortcuts")
struct ShortcutTests {
    @Test func defaultsUseControlOption() {
        let r = ShortcutResolver()
        #expect(r.combo(for: .toggleTiling)?.description == "⌃⌥T")
        #expect(r.combo(for: .layoutGrid)?.description == "⌃⌥⇧1")
        #expect(r.combo(for: .count4)?.description == "⌃⌥⌘4")
        #expect(r.combo(for: .tabView)?.description == "⌥⇥")
        #expect(r.combo(for: .tabViewBackward)?.description == "⌥⇧⇥")
        #expect(r.combo(for: .stackPrevious)?.description == "⌃⌥⇧`")
    }

    @Test func prefixChangeUpdatesUncustomisedShortcuts() {
        var r = ShortcutResolver(prefix: .optionCommand)
        r.bindings[.retile] = .custom(KeyCombo(KeyCode.f13, []))
        #expect(r.combo(for: .toggleTiling)?.description == "⌥⌘T")
        #expect(r.combo(for: .count1)?.description == "⌃⌥⌘1")
        #expect(r.combo(for: .retile)?.description == "F13")
    }

    @Test func controlShiftPrefixCollidesWithScreenshotKeys() {
        let r = ShortcutResolver(prefix: .controlShift)
        #expect(r.combo(for: .count3)?.description == "⌃⇧⌘3")
        #expect(r.combo(for: .layoutGrid)?.description == "⌃⌥⇧1")
    }

    @Test func offRemovesTheShortcut() {
        var r = ShortcutResolver()
        r.bindings[.noPeek] = .off
        #expect(r.combo(for: .noPeek) == nil)
    }

    @Test func windowCountKeysChangeTogether() {
        var r = ShortcutResolver()
        r.countModifiers = [.option, .shift]
        #expect(r.combo(for: .count2)?.description == "⌥⇧2")
        #expect(r.combo(for: .count5)?.description == "⌥⇧5")
    }

    @Test func suggestionsPreferSameKeyThenFKeys() {
        let taken = KeyCombo(KeyCode.t, [.control, .option])
        let all = ShortcutResolver.suggestions(for: taken, isFree: { $0.modifiers != [.option, .command] })
        #expect(all.first == KeyCombo(KeyCode.t, [.control, .shift]))
        let fkeys = ShortcutResolver.suggestions(for: taken, isFree: { $0.modifiers.isEmpty })
        #expect(fkeys.first == KeyCombo(KeyCode.f13, []))
    }

    @Test func typingKeysAreNotAllowedAlone() {
        #expect(!KeyCombo(KeyCode.r, [.shift]).isAllowedAsShortcut)
        #expect(KeyCombo(KeyCode.f5, []).isAllowedAsShortcut)
    }
}

@Suite("Setups, learning and licensing")
struct MiscTests {
    @Test func missingScreenMovesToAFreeScreen() {
        let a = SetupScreen(screenID: "A", screenName: "A", layout: .grid, capacity: 2, sizes: [:], tiles: [SetupTile(apps: [SetupApp(bundleID: "x", name: "X")])])
        let b = SetupScreen(screenID: "B", screenName: "B", layout: .side, capacity: 3, sizes: [:], tiles: [SetupTile(apps: [SetupApp(bundleID: "y", name: "Y")])])
        let setup = Setup(name: "Work", screens: [a, b])
        let plan = SetupPlanner.plan(setup: setup, connected: ["A", "C"], main: "A")
        #expect(plan.screens["C"]?.layout == .side)
        #expect(plan.placements.contains { $0.bundleID == "y" && $0.screenID == "C" })
    }

    @Test func missingScreenStacksOnMainWhenNoneFree() {
        let a = SetupScreen(screenID: "A", screenName: "A", layout: .grid, capacity: 2, sizes: [:], tiles: [SetupTile(apps: [SetupApp(bundleID: "x", name: "X")])])
        let b = SetupScreen(screenID: "B", screenName: "B", layout: .side, capacity: 3, sizes: [:], tiles: [SetupTile(apps: [SetupApp(bundleID: "y", name: "Y")])])
        let plan = SetupPlanner.plan(setup: Setup(name: "Work", screens: [a, b]), connected: ["A"], main: "A")
        #expect(plan.placements.contains { $0.bundleID == "y" && $0.screenID == "A" && $0.stacked })
    }

    @Test func learnsOnlyRepeatedRefusals() {
        let ask = CGSize(width: 400, height: 600)
        let first = MinimumSizeLearner.Observation(requested: ask, actual: CGSize(width: 952, height: 600))
        let same = MinimumSizeLearner.Observation(requested: ask, actual: CGSize(width: 952, height: 600))
        let different = MinimumSizeLearner.Observation(requested: ask, actual: CGSize(width: 700, height: 600))
        let screen = CGSize(width: 1470, height: 900)
        #expect(MinimumSizeLearner.learn(first: first, second: same, screen: screen) == LearnedMinimum(width: 952, height: nil))
        #expect(MinimumSizeLearner.learn(first: first, second: different, screen: screen) == nil)
    }

    @Test func neverLearnsNearFullScreenMinimums() {
        let ask = CGSize(width: 400, height: 600)
        let refusal = MinimumSizeLearner.Observation(requested: ask, actual: CGSize(width: 1450, height: 600))
        #expect(MinimumSizeLearner.learn(first: refusal, second: refusal, screen: CGSize(width: 1470, height: 900)) == nil)
    }

    @Test func floatRuleMatchesFirstTwoWords() {
        let rule = FloatRule(bundleID: "com.jetbrains.pycharm", appName: "PyCharm", titleWords: FloatRule.words(from: "Commit Changes to main")!)
        #expect(rule.titleWords == "Commit Changes")
        #expect(rule.matches(bundleID: "com.jetbrains.pycharm", title: "Commit  Changes"))
        #expect(!rule.matches(bundleID: "com.jetbrains.pycharm", title: "project – main.py"))
    }

    @Test func trialRunsForTwoDays() {
        let start = Date(timeIntervalSince1970: 0)
        let day: TimeInterval = 86_400
        let during = LicenseState.compute(licensingEnabled: true, firstLaunch: start, now: start.addingTimeInterval(day), trialLength: 2 * day, hasActiveKey: false, keyRevoked: false)
        #expect(during == .trial(remaining: day))
        #expect(during.canTile && !during.hasFullVersion)
        let after = LicenseState.compute(licensingEnabled: true, firstLaunch: start, now: start.addingTimeInterval(3 * day), trialLength: 2 * day, hasActiveKey: false, keyRevoked: false)
        #expect(after == .trialEnded)
        #expect(LicenseState.compute(licensingEnabled: false, firstLaunch: start, now: start, trialLength: 0, hasActiveKey: false, keyRevoked: false) == .unlicensedBuild)
    }
}
