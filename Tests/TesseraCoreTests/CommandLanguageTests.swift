import CoreGraphics
import Foundation
import Testing
@testable import TesseraCore

private func one(_ text: String) throws -> Invocation {
    let script = try CommandParser.parse(text)
    #expect(script.invocations.count == 1, "\(text)")
    return script.invocations[0]
}

private func act(_ text: String) throws -> Action {
    guard case .action(let action, _) = try one(text) else {
        Issue.record("\(text) is not an action")
        return .fail
    }
    return action
}

private func ask(_ text: String) throws -> Query? {
    guard case .query(let query) = try one(text) else { return nil }
    return query
}

private func fails(_ text: String, _ containing: String? = nil) {
    do {
        _ = try CommandParser.parse(text)
        Issue.record("expected “\(text)” to be refused")
    } catch let error as CommandError {
        if let containing { #expect(error.message.contains(containing), "\(text): \(error.message)") }
    } catch {
        Issue.record("unexpected \(error)")
    }
}

@Suite("Command language")
struct CommandLanguageTests {
    @Test func focus() throws {
        #expect(try act("focus left") == .focus(.direction(.left), wrap: false))
        #expect(try act("focus west") == .focus(.direction(.left), wrap: false))
        #expect(try act("focus --wrap-around right") == .focus(.direction(.right), wrap: true))
        #expect(try act("focus --boundaries-action wrap-around-the-workspace up") == .focus(.direction(.up), wrap: true))
        #expect(try act("focus dfs-next") == .focus(.next, wrap: false))
        #expect(try act("focus prev") == .focus(.previous, wrap: false))
        #expect(try act("focus --window-id 42") == .focus(.window(42), wrap: false))
        #expect(try act("focus --dfs-index 2") == .focus(.index(2), wrap: false))
        #expect(try act("focus-back-and-forth") == .focus(.back, wrap: false))
        #expect(try act("focus-monitor main") == .focusDisplay(.pattern("main"), wrap: false))
        #expect(try act("focus-monitor --wrap-around next") == .focusDisplay(.next, wrap: true))
        #expect(try act("display prev") == .focusDisplay(.previous, wrap: true))
        fails("focus", "direction")
        fails("focus sideways", "isn't a direction")
    }

    @Test func treeCommands() throws {
        #expect(try act("move left") == .move(.left))
        #expect(try one("move --window-id 7 up") == .action(.move(.up), window: 7))
        #expect(try act("swap east --swap-focus") == .swap(.direction(.right), wrap: false, keepFocus: true))
        #expect(try act("swap dfs-next") == .swap(.next, wrap: false, keepFocus: false))
        #expect(try act("join-with down") == .join(.down))
        #expect(try act("join west") == .join(.left))
        #expect(try act("split") == .split(.toggle))
        #expect(try act("split opposite") == .split(.opposite))
        #expect(try act("preselect south") == .preselect(.down))
        #expect(try act("preselect cancel") == .preselect(nil))
        #expect(try act("mirror horizontal") == .mirror(.horizontal))
        #expect(try act("rotate 270") == .rotate(quarterTurns: 3))
        #expect(try act("rotate") == .rotate(quarterTurns: 1))
        #expect(try act("balance-sizes") == .balance)
        #expect(try act("flatten-workspace-tree") == .flatten)
        #expect(try act("pop out") == .popOut)
        #expect(try act("resize smart -50") == .resize(.smart, .by(-50)))
        #expect(try act("resize width +100") == .resize(.width, .by(100)))
        #expect(try act("resize height 600") == .resize(.height, .to(600)))
        #expect(try act("border horizontal -100") == .border(.horizontal, -100))
        #expect(try act("grow") == .command(.snap(.larger)))
        fails("split sideways")
        fails("resize smart lots", "number")
        fails("rotate 45")
    }

    @Test func layouts() throws {
        #expect(try act("layout tiles horizontal vertical") == .layout([.container(.tiles, nil), .container(nil, .horizontal), .container(nil, .vertical)]))
        #expect(try act("layout h_accordion") == .layout([.container(.accordion, .horizontal)]))
        #expect(try act("layout floating tiling") == .layout([.floating, .tiling]))
        #expect(try act("layout bsp") == .layout([.style(.tree)]))
        #expect(try act("layout tree") == .layout([.style(.tree)]))
        #expect(try act("layout stack") == .layout([.style(.stack)]))
        #expect(try act("layout float") == .layout([.style(.float)]))
        #expect(try act("layout main-and-side") == .layout([.style(.mainAndSide)]))
        #expect(try act("columns") == .command(.layout(.columns)))
        fails("layout spiral", "isn't a layout")
        fails("layout", "needs a layout")
    }

    @Test func desktopsAndScreens() throws {
        #expect(try act("workspace 3") == .desktop(.number(3)))
        #expect(try act("workspace next") == .desktop(.next))
        #expect(try act("workspace --wrap-around prev") == .desktop(.previous))
        #expect(try act("workspace-back-and-forth") == .desktop(.last))
        #expect(try act("space 2") == .desktop(.number(2)))
        #expect(try act("space last") == .desktop(.last))
        #expect(try act("space fullscreen next") == .desktop(.next))
        #expect(try act("desktop 4") == .desktop(.number(4)))
        #expect(try act("move-node-to-workspace 2") == .sendToDesktop(.number(2), follow: false))
        #expect(try act("move-node-to-workspace --focus-follows-window 2") == .sendToDesktop(.number(2), follow: true))
        #expect(try act("send 3") == .sendToDesktop(.number(3), follow: true))
        #expect(try act("send-to-desktop next") == .sendToDesktop(.next, follow: true))
        #expect(try act("send display next") == .sendToDisplay(.next, follow: true, wrap: true))
        #expect(try act("move-node-to-monitor --wrap-around next") == .sendToDisplay(.next, follow: false, wrap: true))
        #expect(try act("move-node-to-monitor left") == .sendToDisplay(.direction(.left), follow: false, wrap: false))
        #expect(try act("send-to-display 2") == .sendToDisplay(.number(2), follow: true, wrap: false))
        #expect(try act("send-to-desktop-3") == .command(.move(.desktop3)))
        fails("workspace A", "named workspaces")
        fails("workspace 0")
        fails("move-workspace-to-monitor next", "macOS desktops")
        fails("summon-workspace 2")
    }

    @Test func windowState() throws {
        #expect(try act("fullscreen") == .zoom(.toggle))
        #expect(try act("fullscreen on") == .zoom(.on))
        #expect(try act("fullscreen --no-outer-gaps off") == .zoom(.off))
        #expect(try act("zoom") == .zoom(.toggle))
        #expect(try act("macos-native-fullscreen") == .nativeFullScreen(.toggle))
        #expect(try act("native-fullscreen off") == .nativeFullScreen(.off))
        #expect(try act("macos-native-minimize") == .minimize)
        #expect(try act("close --quit-if-last-window") == .close(quitIfLast: true))
        #expect(try act("close") == .close(quitIfLast: false))
        #expect(try act("close-all-windows-but-current") == .closeOthers(quitIfLast: false))
        #expect(try act("float") == .float(.toggle))
        #expect(try act("float on") == .float(.on))
        #expect(try act("keep off") == .keepInFront(.off))
        #expect(try act("stack next") == .stack(forward: true))
        #expect(try act("restore") == .command(.snap(.restore)))
        fails("fullscreen pair", "isn't supported")
        fails("float sometimes", "on, off or toggle")
    }

    @Test func placing() throws {
        #expect(try act("place left") == .command(.snap(.leftHalf)))
        #expect(try act("place left 2/3") == .command(.snap(.firstTwoThirds)))
        #expect(try act("place right 3/4") == .command(.snap(.lastThreeQuarters)))
        #expect(try act("place top-right") == .command(.snap(.topRight)))
        #expect(try act("place top-right-sixth") == .command(.snap(.topRightSixth)))
        #expect(try act("place bottom-center-sixth") == .command(.snap(.bottomCentreSixth)))
        #expect(try act("place center") == .command(.snap(.centre)))
        #expect(try act("place left-half") == .command(.snap(.leftHalf)))
        #expect(try act("place maximize") == .command(.snap(.maximise)))
        #expect(try act("snap next-display") == .command(.snap(.nextDisplay)))
        #expect(try act("left-half") == .command(.snap(.leftHalf)))
        #expect(try act("tile-all") == .command(.arrange(.tileAll)))
        #expect(try act("run snap.topHalf") == .command(.snap(.topHalf)))
        fails("place sideways", "doesn't know")
    }

    @Test func tesseraAndToolCommands() throws {
        #expect(try act("enable off") == .enable(.off))
        #expect(try act("pause") == .enable(.toggle))
        #expect(try act("mode service") == .mode("service"))
        #expect(try act("reload-config --no-gui") == .reloadConfig)
        #expect(try act("move-mouse window-lazy-center") == .moveMouse(.windowLazyCenter))
        #expect(try act("move-mouse monitor-lazy-center") == .moveMouse(.displayLazyCenter))
        #expect(try act("setup open \"Deep Work\"") == .setup(.open("Deep Work")))
        #expect(try act("setup open 2") == .setup(.number(2)))
        #expect(try act("setup save Work") == .setup(.save("Work")))
        #expect(try act("load Writing") == .setup(.open("Writing")))
        #expect(try act("toggle dim") == .appearance(.dim, .toggle))
        #expect(try act("border on") == .appearance(.border, .on))
        #expect(try act("toggle spacing") == .appearance(.spacing, .toggle))
        #expect(try act("volume set 40") == .volume(.set(40)))
        #expect(try act("volume mute-toggle") == .volume(.muteToggle))
        #expect(try act("trigger-binding --mode main alt-h") == .triggerBinding(mode: "main", key: "alt-h"))
        #expect(try act("echo \"hello world\"") == .echo("hello world"))
        #expect(try act("settings") == .openSettings)
        fails("volume set 150", "0 to 100")
        fails("mode", "needs a name")
        fails("move-mouse somewhere")
    }

    @Test func execTakesTheRestOfTheLineAsWritten() throws {
        let script = try CommandParser.parse("exec-and-forget open -a 'Safari' && say \"hi\"; echo done")
        #expect(script.invocations == [.action(.exec("open -a 'Safari' && say \"hi\"; echo done"), window: nil)])
        #expect(try act("exec-and-forget   sketchybar --reload  ") == .exec("sketchybar --reload"))
        // Inside a chain, after other commands.
        let chained = try CommandParser.parse("mode main; exec-and-forget echo a; b")
        #expect(chained.invocations.count == 2)
        #expect(chained.invocations[1] == .action(.exec("echo a; b"), window: nil))
        fails("exec-and-forget", "needs a shell command")
    }

    @Test func chains() throws {
        let script = try CommandParser.parse("focus left; focus right")
        #expect(script.statements.count == 2)
        let choice = try CommandParser.parse("true && focus left || focus right")
        #expect(choice.statements.count == 1)
        #expect(choice.statements[0].count == 2)
        #expect(choice.statements[0][0].count == 2)
        #expect(try CommandParser.parse("focus left;").statements.count == 1)

        // a && b || c: c runs only if a or b failed.
        var ran: [String] = []
        func runner(_ invocation: Invocation) -> Bool {
            guard case .action(let action, _) = invocation else { return false }
            switch action {
            case .succeed: ran.append("true"); return true
            case .fail: ran.append("false"); return false
            case .echo(let text): ran.append(text); return true
            default: return true
            }
        }
        _ = try CommandParser.parse("false && echo a || echo b; echo c").run(runner)
        #expect(ran == ["false", "b", "c"])
        ran = []
        let ok = try CommandParser.parse("true && echo a || echo b").run(runner)
        #expect(ok)
        #expect(ran == ["true", "a"])
        ran = []
        let failed = try CommandParser.parse("echo x; false").run(runner)
        #expect(!failed)

        fails("focus left &&", "missing")
        fails("&& focus left", "missing")
        fails("; ;", "no command")
        fails("", "no command")
        fails("focus left | grep", "pipes")
        fails("echo \"open", "quote")
    }

    @Test func mistakesAreExplained() {
        fails("nonsense", "unknown command")
        fails("focus left extra", "doesn't understand")
        fails("move", "direction")
        fails("move --window-id abc left", "window number")
    }

    @Test func queries() throws {
        #expect(try ask("list-windows --all --json") == .windows(.all, app: nil, pid: nil, ListOutput(json: true)))
        #expect(try ask("list-windows --focused") == .windows(.focused, app: nil, pid: nil, ListOutput()))
        #expect(try ask("list-windows --desktop 2 --format '%{window-id} %{app-name}'")
            == .windows(.desktop(2), app: nil, pid: nil, ListOutput(format: "%{window-id} %{app-name}")))
        #expect(try ask("list-windows --monitor main --count") == .windows(.display(.pattern("main")), app: nil, pid: nil, ListOutput(count: true)))
        #expect(try ask("list-windows --app-bundle-id com.apple.Safari") == .windows(.visible, app: "com.apple.Safari", pid: nil, ListOutput()))
        #expect(try ask("list-monitors --json") == .displays(focused: false, ListOutput(json: true)))
        #expect(try ask("list-workspaces --focused") == .desktops(focused: true, ListOutput()))
        #expect(try ask("list-modes --current") == .modes(current: true, ListOutput()))
        #expect(try ask("list-apps") == .apps(ListOutput()))
        #expect(try ask("tree --json") == .tree(ListOutput(json: true)))
        #expect(try ask("version") == .version)
        #expect(try ask("--version") == .version)
        #expect(try ask("help focus") == .help("focus"))
        #expect(try ask("help") == .help(nil))
        #expect(try ask("config --get gaps") == .config(key: "gaps", path: false, ListOutput()))
        #expect(try ask("config --config-path") == .config(key: nil, path: true, ListOutput()))
        #expect(try ask("subscribe focus-changed desktop-changed") == .subscribe(["focus-changed", "desktop-changed"]))
        fails("list-windows --desktop A", "numbered")
        fails("list-windows --pid abc", "number")
    }

    @Test func toggles() {
        #expect(Toggle(nil) == .toggle)
        #expect(Toggle("ON") == .on)
        #expect(Toggle("off") == .off)
        #expect(Toggle("maybe") == nil)
        #expect(Toggle.toggle.apply(to: true) == false)
        #expect(Toggle.on.apply(to: false) == true)
    }
}
