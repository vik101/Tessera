import CoreGraphics
import Foundation
import Testing
@testable import TesseraCore

@Suite("Config file")
struct ConfigTests {
    @Test func readsAeroSpacesDefaultConfig() throws {
        let c = try TesseraConfig.parse(AeroSpaceSamples.defaultConfig)
        let main = c.modes["main"] ?? []
        let service = c.modes["service"] ?? []
        // Lettered workspaces and moving a workspace between screens need AeroSpace's own workspaces.
        #expect(main.count == 22)
        #expect(service.count == 8)
        #expect(c.warnings.count == 5, "\(c.warnings)")
        #expect(c.warnings.contains { $0.contains("workspace A") && $0.hasPrefix("line ") })
        #expect(c.warnings.contains { $0.contains("move-workspace-to-monitor") })
        let h = main.first { $0.key == "alt-h" }
        #expect(h?.combo == KeyCombo(KeyCode.h, [.option]))
        #expect(h?.commands == ["focus left"])
        #expect(service.first { $0.key == "esc" }?.commands == ["reload-config", "mode main"])
        #expect(c.onDisplayFocusChanged == ["move-mouse monitor-lazy-center"])
        #expect(c.accordionPadding == 30)
        #expect(c.defaultOrientation == nil)
        #expect(c.defaultContainerLayout == .tiles)
        #expect(c.keyMapping == .qwerty)
        #expect(c.unhideHiddenApps == false)
        #expect(c.startAtLogin == false)
        #expect(c.gaps == Gaps(inner: 0, outer: 0))
        #expect(c.modeNames == ["main", "service"])
    }

    @Test func readsAPersonalAeroSpaceConfig() throws {
        let c = try TesseraConfig.parse(AeroSpaceSamples.personalConfig)
        #expect(c.afterStartup == ["exec-and-forget sketchybar"])
        #expect(c.execOnDesktopChange.count == 3)
        #expect(c.execOnDesktopChange.first == "/bin/bash")
        #expect(c.onFocusChanged == ["move-mouse window-lazy-center"])
        #expect(c.warnings.contains { $0.contains("persistent-workspaces") })
        #expect(c.warnings.contains { $0.contains("workspace-to-monitor-force-assignment") })
        #expect(c.warnings.contains { $0.contains("workspace T") })
        #expect(c.modes["resize"]?.count == 4)
        #expect(c.modes["resize"]?.first { $0.key == "h" }?.combo == KeyCombo(KeyCode.h, []))
        #expect(c.modes["main"]?.first { $0.key == "cmd-alt-ctrl-f" }?.combo == KeyCombo(KeyCode.f, [.command, .option, .control]))
        #expect(c.modeNames == ["main", "resize"])

        // Rules.
        #expect(c.rules.count == 4)
        #expect(c.rules[0].appID == "com.apple.systempreferences")
        #expect(c.rules[2].title == "Picture-in-Picture")
        #expect(c.rules[2].duringStartup == false)
        #expect(c.rules[2].checkFurther)
        #expect(c.rules[3].commands == ["layout tiling"])
        let slack = WindowRule.commands(for: c.rules, appID: "com.tinyspeck.slackmacgap", appName: "Slack", title: "general",
                                        desktop: 1, startup: false)
        #expect(slack == ["move-node-to-workspace 3"])
        let pip = WindowRule.commands(for: c.rules, appID: "com.apple.Safari", appName: "Safari", title: "Picture-in-Picture",
                                      desktop: 1, startup: false)
        #expect(pip == ["layout floating"])
        let atStart = WindowRule.commands(for: c.rules, appID: "com.apple.Safari", appName: "Safari", title: "Picture-in-Picture",
                                          desktop: 1, startup: true)
        #expect(atStart.isEmpty)

        // Gaps differ by screen.
        let gaps = try #require(c.gaps)
        let builtIn = DisplayContext(name: "Built-in Retina Display", index: 1, isMain: true, count: 2)
        let dell = DisplayContext(name: "DELL U2412M", index: 2, isMain: false, count: 2)
        let lgMain = DisplayContext(name: "LG ULTRAFINE", index: 1, isMain: true, count: 1)
        #expect(gaps.outerTop.value(for: builtIn) == 8)
        #expect(gaps.outerTop.value(for: lgMain) == 40)
        #expect(gaps.outerTop.value(for: dell) == 32)
        let visible = CGRect(x: 0, y: 25, width: 1512, height: 957)
        let resolved = gaps.resolve(visible: visible, display: lgMain)
        #expect(resolved.gap == 8)
        // A window at the top-left edge lands 8 points in from the side and 40 from the top.
        let corner = applyGap(CGRect(x: resolved.area.minX, y: resolved.area.minY, width: 400, height: 400), in: resolved.area, gap: resolved.gap)
        #expect(corner.minX == 8)
        #expect(corner.minY == 65)
    }

    @Test func keyNames() throws {
        #expect(try KeyNotation.parse("alt-shift-h") == KeyCombo(KeyCode.h, [.option, .shift]))
        #expect(try KeyNotation.parse("ctrl-opt-left") == KeyCombo(KeyCode.leftArrow, [.control, .option]))
        #expect(try KeyNotation.parse("esc") == KeyCombo(KeyCode.escape, []))
        #expect(try KeyNotation.parse("alt-minus") == KeyCombo(KeyCode.minus, [.option]))
        #expect(try KeyNotation.parse("alt-slash") == KeyCombo(KeyCode.slash, [.option]))
        #expect(try KeyNotation.parse("f13") == KeyCombo(KeyCode.f13, []))
        #expect(try KeyNotation.parse("alt-leftSquareBracket") == KeyCombo(KeyCode.leftBracket, [.option]))
        #expect(try KeyNotation.parse("cmd-keypad5") == KeyCombo(0x57, [.command]))
        // Dvorak's h is QWERTY's j; Colemak's n is QWERTY's j too.
        #expect(try KeyNotation.parse("alt-h", mapping: .dvorak) == KeyCombo(KeyCode.j, [.option]))
        #expect(try KeyNotation.parse("alt-n", mapping: .colemak) == KeyCombo(KeyCode.j, [.option]))
        #expect(try KeyNotation.parse("alt-1", mapping: .dvorak) == KeyCombo(KeyCode.one, [.option]))
        #expect(KeyNotation.text(for: KeyCombo(KeyCode.h, [.option, .shift])) == "alt-shift-h")
        #expect(KeyNotation.text(for: KeyCombo(KeyCode.leftArrow, [.control, .command])) == "cmd-ctrl-left")
        for bad in ["hyper-h", "alt-", "alt-foo", "", "-h"] {
            #expect(throws: CommandError.self) { try KeyNotation.parse(bad) }
        }
    }

    @Test func presetsAddKeysAndTheFileWins() throws {
        let c = try TesseraConfig.parse("""
        preset = 'aerospace'
        [mode.main.binding]
        alt-h = 'focus right'
        """)
        let main = c.bindings(for: "main")
        #expect(main.first { $0.combo == KeyCombo(KeyCode.h, [.option]) }?.commands == ["focus right"])
        #expect(main.filter { $0.combo == KeyCombo(KeyCode.h, [.option]) }.count == 1)
        #expect(main.contains { $0.key == "alt-3" && $0.commands == ["workspace 3"] })
        #expect(c.bindings(for: "service").contains { $0.key == "esc" })
        #expect(c.modeNames.contains("service"))
        // Every preset's commands parse.
        for preset in ShortcutPreset.allCases {
            for (mode, list) in preset.bindings {
                for (key, command) in list {
                    #expect((try? KeyNotation.parse(key)) != nil, "\(preset) \(mode) \(key)")
                    #expect((try? CommandParser.parse(command)) != nil, "\(preset) \(mode) \(command)")
                }
            }
        }
    }

    @Test func tesseraSettings() throws {
        let c = try TesseraConfig.parse("""
        auto-tile = true
        layout = 'tree'
        front-limit = 4
        main-ratio = 0.6
        preset = 'rectangle'
        ignored-apps = ['com.apple.calculator']
        dim = true
        dim-amount = 2.0
        [layouts]
        main = 'columns'
        DELL = 'stack'
        [mouse]
        move-modifier = 'ctrl-cmd'
        focus-follows-mouse = true
        [appearance]
        border = true
        border-color = '#4c9aff'
        border-width = 6
        show-desktop-number = true
        """)
        #expect(c.warnings.isEmpty, "\(c.warnings)")
        #expect(c.autoTile == true)
        #expect(c.layout == .tree)
        #expect(c.layouts.map(\.pattern) == ["main", "DELL"])
        #expect(c.layouts.map(\.style) == [.columns, .stack])
        #expect(c.frontLimit == .fixed(4))
        #expect(c.mainRatio == 0.6)
        #expect(c.preset == .tessera)
        #expect(c.ignoredApps == ["com.apple.calculator"])
        #expect(c.dim == true)
        #expect(c.dimAmount == 0.9)
        #expect(c.moveModifier == "ctrl-cmd")
        #expect(c.focusFollowsMouse == true)
        #expect(c.border == true)
        #expect(c.borderWidth == 6)
        #expect(c.showDesktopNumber == true)
        #expect(TesseraConfig.hexColor("#4c9aff")?.red == Double(0x4c) / 255)
        #expect(TesseraConfig.hexColor("blue") == nil)
    }

    @Test func mistakesBecomeWarningsNotFailures() throws {
        let c = try TesseraConfig.parse("""
        front-limit = 'lots'
        layout = 'spiral'
        typo-setting = 1
        auto-tile = 'yes'
        [mode.main.binding]
        alt-h = 'focus nowhere'
        alt-j = 'focus down'
        hyper-k = 'focus up'
        opt-j = 'focus up'
        [[on-window-detected]]
        if.app-id = 'com.example'
        """)
        #expect(c.frontLimit == nil)
        #expect(c.layout == nil)
        #expect(c.autoTile == nil)
        #expect(c.modes["main"]?.map(\.key) == ["alt-j"])
        #expect(c.rules.isEmpty)
        #expect(c.warnings.count >= 6, "\(c.warnings)")
        #expect(c.warnings.contains { $0.contains("typo-setting") })
        #expect(c.warnings.allSatisfy { $0.hasPrefix("line ") }, "\(c.warnings)")
    }

    @Test func aDuplicateKeyInAModeIsReported() throws {
        // Two names for the same key: the first wins.
        let c = try TesseraConfig.parse("""
        [mode.main.binding]
        alt-enter = 'focus left'
        alt-return = 'focus right'
        """)
        #expect(c.modes["main"]?.count == 1)
        #expect(c.warnings.contains { $0.contains("same key") })
    }

    @Test func brokenFilesSayWhere() {
        do {
            _ = try TesseraConfig.parse("auto-tile = true\n[mode.main.binding\n")
            Issue.record("expected an error")
        } catch let error as TOMLError {
            #expect(error.line == 2)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func testConditions() throws {
        let c = try TesseraConfig.parse("""
        [[on-window-detected]]
        if = 'test %{app-bundle-id} = com.apple.finder'
        run = 'layout floating'
        [[on-window-detected]]
        if = 'test %{app-name} ~= term'
        run = 'move-node-to-workspace 2'
        [[on-window-detected]]
        if = 'true && false'
        run = 'layout floating'
        """)
        #expect(c.rules.count == 2)
        #expect(c.rules[0].appID == "com.apple.finder")
        #expect(c.rules[1].matches(appID: "x", appName: "Terminal", title: "", desktop: nil, startup: false))
        #expect(c.warnings.count == 1)
    }

    @Test func theTemplateIsClean() throws {
        let c = try TesseraConfig.parse(TesseraConfig.template)
        #expect(c.warnings.isEmpty, "\(c.warnings)")
        #expect(c.autoReload == true)
    }

    @Test func importingAnAeroSpaceConfigListsWhatWontWork() throws {
        let result = try TesseraConfig.importAeroSpace(AeroSpaceSamples.defaultConfig)
        #expect(result.warnings.count == 5)
        #expect(result.text.hasPrefix("# Imported from AeroSpace"))
        #expect(result.text.contains("workspace A"))
        #expect(result.text.contains(AeroSpaceSamples.defaultConfig))
        // The imported file reads the same.
        let again = try TesseraConfig.parse(result.text)
        #expect(again.modes["main"]?.count == 22)
    }

    @Test func displayPatterns() {
        let laptop = DisplayContext(name: "Built-in Retina Display", index: 2, isMain: false, count: 2)
        #expect(DisplayPattern.matches("secondary", laptop))
        #expect(!DisplayPattern.matches("main", laptop))
        #expect(DisplayPattern.matches("2", laptop))
        #expect(DisplayPattern.matches("built-in", laptop))
        #expect(DisplayPattern.matches("^built", laptop))
        #expect(!DisplayPattern.matches("dell", laptop))
        let three = DisplayContext(name: "X", index: 3, isMain: false, count: 3)
        #expect(!DisplayPattern.matches("secondary", three))
    }
}
