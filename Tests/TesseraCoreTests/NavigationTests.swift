import CoreGraphics
import Foundation
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

@Suite("App rules")
struct AppRuleTests {
    let rules = ["chat": AppRule(bundleID: "chat", keepInFront: true), "mail": AppRule(bundleID: "mail", keepInFront: true),
                 "notes": AppRule(bundleID: "notes", float: true)]
    let apps: [Int: String] = [1: "chat", 2: "mail", 3: "notes", 4: "web", 5: "chat"]

    @Test func keepsTheMostRecentlyUsedUpToTheRoom() {
        let recency = [1: 10, 2: 30, 5: 20]
        let kept = AppRules.kept([1, 2, 3, 4, 5], app: { apps[$0] }, rules: rules, room: 2, recency: recency)
        #expect(kept == [2, 5])
        #expect(AppRules.kept([1, 2, 3, 4, 5], app: { apps[$0] }, rules: rules, room: 0, recency: recency).isEmpty)
        #expect(AppRules.kept([3, 4], app: { apps[$0] }, rules: rules, room: 3, recency: recency).isEmpty)
    }

    @Test func emptyRulesAreDroppedFromFiles() throws {
        var file = SettingsFile()
        file.appRules = [AppRule(bundleID: "a", float: true), AppRule(bundleID: "b"), AppRule(bundleID: "", float: true)]
        let back = try SettingsFile.decode(file.encoded())
        #expect(back.appRules == [AppRule(bundleID: "a", float: true)])
        let json = try SettingsFile.decode(Data(#"{"appRules": [{"bundleID": "com.apple.Terminal", "float": true}]}"#.utf8))
        #expect(json.appRules?.first?.float == true && json.appRules?.first?.screen == nil)
    }
}

@Suite("Saved setups")
struct SetupTests {
    let screen = CGRect(x: 0, y: 25, width: 1920, height: 1055)

    @Test func eachAppsWindowsTakeItsEntriesInOrder() {
        let left = UnitRect(x: 0, y: 0, width: 0.5, height: 1), right = UnitRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let setup = Setup(name: "Work", entries: [
            .init(bundleID: "edit", screen: "a", place: left),
            .init(bundleID: "web", screen: "a", place: right),
            .init(bundleID: "edit", screen: "b", place: .full),
            .init(bundleID: "mail", screen: "b", place: .full),     // Mail has no window open: skipped.
        ])
        let windows: [(id: Int, bundleID: String)] = [(id: 1, bundleID: "web"), (id: 2, bundleID: "edit"),
                                                     (id: 3, bundleID: "edit"), (id: 4, bundleID: "edit")]
        let assigned = setup.assign(windows)
        #expect(assigned.map { $0.id } == [2, 1, 3])                   // Window 4 is left alone.
        #expect(assigned.map { $0.entry.screen } == ["a", "a", "b"])
        #expect(setup.apps == ["edit", "web", "mail"])
    }

    @Test func placesAreSharesOfTheScreen() {
        let half = CGRect(x: 0, y: 25, width: 960, height: 1055)
        let unit = Setup.unit(of: half, in: screen)
        #expect(unit == UnitRect(x: 0, y: 0, width: 0.5, height: 1))
        #expect(screen.part(unit) == half)
        // On a bigger screen the same share fills the same part.
        let big = CGRect(x: 0, y: 0, width: 5120, height: 1440)
        #expect(big.part(unit) == CGRect(x: 0, y: 0, width: 2560, height: 1440))
        // A window hanging off the screen counts only the part on it.
        #expect(Setup.unit(of: CGRect(x: -100, y: 25, width: 1060, height: 1055), in: screen).width == 0.5)
    }

    @Test func setupsSurviveASettingsFile() throws {
        var file = SettingsFile()
        file.setups = [Setup(name: "Calls", entries: [.init(bundleID: "zoom", screen: "a", place: .full)], hideOthers: false)]
        #expect(try SettingsFile.decode(file.encoded()).setups == file.setups)
        let link = URLCommand(url: URL(string: "tessera://open-setup?name=Calls")!)
        #expect(link == .openSetup(name: "Calls"))
        #expect(Command(urlName: "open-setup-3") == .setup(3))
        #expect(Command(id: "setup.3") == .setup(3))
    }
}
