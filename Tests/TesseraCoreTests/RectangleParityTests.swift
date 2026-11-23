import CoreGraphics
import Foundation
import Testing
@testable import TesseraCore

/// A 1920×1080 screen with a 25-point menu bar, and a portrait one.
private let screen = CGRect(x: 0, y: 25, width: 1920, height: 1055)
private let portrait = CGRect(x: 0, y: 25, width: 1080, height: 1895)
private let window = CGRect(x: 300, y: 200, width: 800, height: 600)

private func snap(_ action: SnapAction, on visible: CGRect = screen, window: CGRect = window,
                  specified: CGSize = CGSize(width: 1680, height: 1050)) -> CGRect? {
    SnapCalculator.frame(for: action, SnapContext(window: window, visible: visible, specified: specified))
}

/// The parts tile the screen exactly: no gaps, no overlaps.
private func coversExactly(_ parts: [CGRect], _ area: CGRect) -> Bool {
    let total = parts.map { $0.width * $0.height }.reduce(0, +)
    for (i, a) in parts.enumerated() {
        for b in parts[(i + 1)...] where a.intersectionArea(b) > 0 { return false }
    }
    return total == area.width * area.height && parts.allSatisfy { area.contains($0) }
}

@Suite("Rectangle's other actions")
struct RectangleParityTests {
    @Test func ninthsMakeAThreeByThreeGrid() {
        let ninths = SnapAction.allCases.filter { $0.group == .ninths }
        #expect(ninths.count == 9)
        for area in [screen, portrait] {
            #expect(coversExactly(ninths.compactMap { snap($0, on: area) }, area))
        }
        #expect(snap(.middleCentreNinth) == CGRect(x: 640, y: 377, width: 640, height: 351))
    }

    @Test func eighthsAreFourAcrossTwoDownOrTwoAcrossFourDown() {
        let eighths = SnapAction.allCases.filter { $0.group == .eighths }
        #expect(eighths.count == 8)
        #expect(coversExactly(eighths.compactMap { snap($0) }, screen))
        #expect(coversExactly(eighths.compactMap { snap($0, on: portrait) }, portrait))
        #expect(snap(.topCentreRightEighth) == CGRect(x: 960, y: 25, width: 480, height: 528))
        #expect(snap(.topLeftEighth, on: portrait)?.width == 540)
        #expect(snap(.topLeftEighth, on: portrait)?.height == 474)
    }

    @Test func cornerThirdsAreTwoThirdsWideAndHalfHigh() {
        #expect(snap(.topLeftThird) == CGRect(x: 0, y: 25, width: 1280, height: 528))
        #expect(snap(.bottomRightThird) == CGRect(x: 640, y: 553, width: 1280, height: 527))
        // On a portrait screen: half wide, two thirds high.
        #expect(snap(.topRightThird, on: portrait) == CGRect(x: 540, y: 25, width: 540, height: 1263))
        #expect(snap(.bottomLeftThird, on: portrait) == CGRect(x: 0, y: 657, width: 540, height: 1263))
    }

    @Test func centreProminentlySitsHigherThanCentre() {
        let centre = snap(.centre)!, high = snap(.centreProminently)!
        #expect(high.size == window.size)
        #expect(high.midX == centre.midX)
        // A quarter of the spare height above, three quarters below.
        #expect(high.minY - screen.minY == ((screen.height - window.height) / 4).rounded())
    }

    @Test func specifiedSizeIsCentredAndFitsTheScreen() {
        #expect(snap(.specified) == CGRect(x: 120, y: 28, width: 1680, height: 1050))
        // Bigger than the screen: it fills that side.
        #expect(snap(.specified, specified: CGSize(width: 5000, height: 500))?.width == 1920)
        // 1 or less is a share of the screen.
        #expect(snap(.specified, specified: CGSize(width: 0.5, height: 0.5)) == CGRect(x: 480, y: 289, width: 960, height: 528))
    }

    @Test func everyActionHasRectanglesURLName() {
        let names = SnapAction.allCases.map(\.rectangleName)
        #expect(Set(names).count == names.count)
        #expect(SnapAction.centreProminently.rectangleName == "center-prominently")
        #expect(SnapAction.firstThreeQuarters.rectangleName == "first-three-fourths")
        #expect(SnapAction.topCentreLeftEighth.rectangleName == "top-center-left-eighth")
        #expect(SnapAction.maximiseHeight.rectangleName == "maximize-height")
        for action in SnapAction.allCases { #expect(SnapAction(urlName: action.rectangleName) == action) }
        #expect(SnapAction(urlName: "leftHalf") == .leftHalf)
        #expect(SnapAction(urlName: "LEFT-HALF") == .leftHalf)
        #expect(SnapAction(urlName: "nope") == nil)
    }
}

@Suite("Arranging many windows")
struct ArrangeTests {
    @Test func tileAllMakesAGridWithNoEmptyCells() {
        for count in 1...12 {
            let frames = Arrange.tileAll(count, in: screen, gap: 0)
            #expect(frames.count == count)
            #expect(coversExactly(frames, screen), "count \(count)")
        }
        #expect(Arrange.tileAll(4, in: screen, gap: 0).first == CGRect(x: 0, y: 25, width: 960, height: 528))
    }

    @Test func rowsAndColumnsUseUpToThreeLines() {
        for count in 1...10 {
            let rows = Arrange.rows(count, in: screen, gap: 0)
            let columns = Arrange.columns(count, in: screen, gap: 0)
            #expect(rows.count == count && columns.count == count)
            #expect(coversExactly(rows, screen) && coversExactly(columns, screen), "count \(count)")
            #expect(Set(rows.map(\.minY)).count == min(count, 3))
            #expect(Set(columns.map(\.minX)).count == min(count, 3))
        }
        // Three windows in columns: three full-height columns, left to right.
        let three = Arrange.columns(3, in: screen, gap: 0)
        #expect(three.map(\.minX) == [0, 640, 1280])
        #expect(three.allSatisfy { $0.height == screen.height })
    }

    @Test func gapsSitBetweenAndAround() {
        let frames = Arrange.tileAll(2, in: screen, gap: 10)
        #expect(frames[0].minX == 10 && frames[1].maxX == 1910)
        #expect(frames[1].minX - frames[0].maxX == 10)
    }

    @Test func cascadeStepsDownAndRight() {
        let sizes = Array(repeating: CGSize(width: 800, height: 600), count: 4)
        let frames = Arrange.cascade(sizes, in: screen, step: 30)
        #expect(frames.map(\.minX) == [0, 30, 60, 90])
        #expect(frames.map(\.minY) == [25, 55, 85, 115])
        #expect(frames.allSatisfy { screen.contains($0) })
        // Too big for the cascade: shrunk to fit.
        let big = Arrange.cascade(Array(repeating: screen.size, count: 3), in: screen, step: 30)
        #expect(big.allSatisfy { screen.contains($0) })
    }

    @Test func reverseMirrorsLeftToRight() {
        let left = CGRect(x: 0, y: 25, width: 640, height: 1055)
        #expect(Arrange.reversed(left, in: screen) == CGRect(x: 1280, y: 25, width: 640, height: 1055))
        #expect(Arrange.reversed(Arrange.reversed(window, in: screen), in: screen) == window)
    }

    @Test func stacksAreWindowsOnTheSameSpot() {
        let spot = CGRect(x: 100, y: 100, width: 800, height: 600)
        let windows: [(id: UInt32, frame: CGRect)] = [
            (id: 7, frame: spot),
            (id: 3, frame: spot.offsetBy(dx: 4, dy: 4)),        // on the same spot
            (id: 9, frame: spot.offsetBy(dx: 900, dy: 0)),      // elsewhere
            (id: 5, frame: spot.offsetBy(dx: 30, dy: 30)),      // cascaded from it
        ]
        let stack = Arrange.stack(of: (id: 7, frame: spot), among: windows)
        #expect(stack == [3, 5, 7])
        #expect(Arrange.step(stack, from: 7, forward: true) == 3)
        #expect(Arrange.step(stack, from: 3, forward: false) == 7)
        #expect(Arrange.step([7], from: 7, forward: true) == nil)
    }
}

@Suite("Links and settings files")
struct AutomationTests {
    private func command(_ link: String) -> URLCommand? { URLCommand(url: URL(string: link)!) }

    @Test func linksRunActions() {
        #expect(command("tessera://execute-action?name=left-half") == .run(.snap(.leftHalf)))
        #expect(command("tessera://execute-action?name=center-prominently") == .run(.snap(.centreProminently)))
        #expect(command("tessera://execute-action?name=tile-all") == .run(.arrange(.tileAll)))
        #expect(command("tessera://execute-action?name=reverse-all") == .run(.arrange(.reverseAll)))
        #expect(command("tessera://execute-action?name=next-layout") == .run(.tile(.nextLayout)))
        #expect(command("tessera://execute-action?name=snap.topLeftNinth") == .run(.snap(.topLeftNinth)))
        #expect(command("tessera://execute-layout?name=columns") == .run(.layout(.columns)))
        #expect(command("tessera://execute-layout?name=main-and-side") == .run(.layout(.mainAndSide)))
        // Rectangle's links work too.
        #expect(command("rectangle://execute-action?name=maximize") == .run(.snap(.maximise)))
    }

    @Test func linksForAppsAndFiles() {
        #expect(command("tessera://execute-task?name=ignore-app&app-bundle-id=com.apple.Safari")
                == .ignore(app: "com.apple.Safari", ignored: true))
        #expect(command("tessera://execute-task?name=unignore-app") == .ignore(app: nil, ignored: false))
        #expect(command("tessera://export-settings?path=/tmp/t.json") == .exportSettings(path: "/tmp/t.json"))
        #expect(command("tessera://import-settings?path=/tmp/t.json") == .importSettings(path: "/tmp/t.json"))
    }

    @Test func badLinksDoNothing() {
        #expect(command("tessera://execute-action?name=fly") == nil)
        #expect(command("tessera://execute-action") == nil)
        #expect(command("tessera://launch-rockets") == nil)
        #expect(command("https://execute-action?name=left-half") == nil)
    }

    @Test func everyCommandHasAUniqueURLName() {
        let names = Command.allCases.map(\.urlName)
        #expect(Set(names).count == names.count)
        for command in Command.allCases {
            #expect(Command(urlName: command.urlName) == command, "\(command.urlName)")
            #expect(Command(id: command.id) == command)
        }
    }

    @Test func settingsFilesRoundTripAndStayInRange() throws {
        var file = SettingsFile()
        file.gap = 99
        file.mainRatio = 0.1
        file.frontLimit = 12
        file.layouts = ["screen-a": "columns", "screen-b": "spiral"]
        var shortcuts = ShortcutSet()
        shortcuts.set(nil, for: .snap(.leftHalf))
        file.shortcuts = shortcuts
        let back = try SettingsFile.decode(file.encoded())
        #expect(back.gap == 30)
        #expect(back.mainRatio == 0.3)
        #expect(back.frontLimit == 6)
        #expect(back.layouts == ["screen-a": "columns"])
        #expect(back.shortcuts?.combo(for: .snap(.leftHalf)) == nil)
        #expect(back.autoTile == nil)   // Missing fields stay missing, so importing leaves them alone.
        // A partial file written by hand.
        let partial = try SettingsFile.decode(Data(#"{"gap": 8, "autoTile": true}"#.utf8))
        #expect(partial.gap == 8 && partial.autoTile == true && partial.shortcuts == nil)
    }
}
