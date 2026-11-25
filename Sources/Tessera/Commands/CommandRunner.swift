import AppKit
import TesseraCore

/// Runs Tessera's command language, from a key binding, the config file, a tessera:// link or the
/// `tessera` command line tool. Commands act on the focused window unless they name another.
@MainActor
enum CommandRunner {
    struct Outcome {
        var ok = true
        var output: [String] = []
        var errors: [String] = []
    }

    /// Runs command lines one after another.
    @discardableResult
    static func run(_ lines: [String], window: CGWindowID? = nil, fromKey: Bool = false) -> Outcome {
        var all = Outcome()
        for line in lines {
            let outcome = run(line, window: window, fromKey: fromKey)
            all.ok = outcome.ok
            all.output += outcome.output
            all.errors += outcome.errors
        }
        return all
    }

    @discardableResult
    static func run(_ line: String, window: CGWindowID? = nil, fromKey: Bool = false) -> Outcome {
        do {
            return run(try CommandParser.parse(line), window: window, fromKey: fromKey)
        } catch {
            Log.error("Command “\(line)”: \(error)")
            return Outcome(ok: false, errors: ["\(error)"])
        }
    }

    static func run(_ script: Script, window: CGWindowID? = nil, fromKey: Bool = false) -> Outcome {
        var outcome = Outcome()
        outcome.ok = script.run { invocation in
            switch invocation {
            case .query(let query):
                let answer = QueryRunner.answer(query)
                if !answer.text.isEmpty {
                    if answer.ok { outcome.output.append(answer.text) } else { outcome.errors.append(answer.text) }
                }
                return answer.ok
            case .action(let action, let id):
                let result = perform(action, window: id ?? window, fromKey: fromKey)
                if let text = result.output { outcome.output.append(text) }
                if let text = result.error { outcome.errors.append(text) }
                return result.ok
            }
        }
        if TestHooks.shared.isOn { Log.info("Ran: \(script.invocations.count) command(s), ok \(outcome.ok)") }
        return outcome
    }

    struct Result {
        var ok: Bool
        var output: String?
        var error: String?
        static let done = Result(ok: true)
        static func failed(_ message: String) -> Result { Result(ok: false, error: message) }
    }

    // MARK: Actions

    static func perform(_ action: Action, window id: CGWindowID?, fromKey: Bool = false) -> Result {
        let registry = WindowRegistry.shared
        let tiler = AutoTiler.shared
        // These don't need a window, or Accessibility.
        switch action {
        case .echo(let text): return Result(ok: true, output: text)
        case .succeed: return .done
        case .fail: return Result(ok: false)
        case .openSettings:
            SettingsWindow.shared.show()
            return .done
        case .reloadConfig:
            let result = ConfigStore.shared.load()
            return result.ok ? Result(ok: true, output: result.message) : .failed(result.message)
        case .mode(let name):
            return Shortcuts.shared.setMode(name) ? .done : .failed("There's no mode “\(name)”. Modes: " + Shortcuts.shared.modes.joined(separator: ", "))
        case .exec(let script):
            Events.shared.exec(script, window: id ?? registry.focusedWindow()?.id)
            return .done
        case .volume(let change):
            return WindowActions.volume(change) ? .done : .failed("Couldn't change the volume")
        case .appearance(let what, let toggle):
            let s = Settings.shared
            switch what {
            case .spacing: s.spacing = toggle.apply(to: s.spacing)
            case .border: s.border = toggle.apply(to: s.border)
            case .dim: s.dim = toggle.apply(to: s.dim)
            }
            return .done
        case .enable(let toggle):
            guard AccessibilityPermission.isTrusted else {
                PermissionWindow.shared.show()
                return .failed("Tessera needs Accessibility permission (System Settings › Privacy & Security › Accessibility)")
            }
            Settings.shared.autoTile = toggle.apply(to: Settings.shared.autoTile)
            return .done
        case .setup(let request):
            switch request {
            case .open(let name):
                guard Settings.shared.setups.contains(where: { $0.name == name }) else { return .failed("No setup named “\(name)”") }
                Setups.open(name: name)
            case .number(let n):
                guard Settings.shared.setups.indices.contains(n - 1) else { return .failed("There's no setup \(n)") }
                Setups.open(number: n)
            case .save(let name):
                return Setups.save(name: name) != nil ? .done : .failed("Nothing to save")
            case .delete(let name):
                guard Settings.shared.setups.contains(where: { $0.name == name }) else { return .failed("No setup named “\(name)”") }
                Settings.shared.setups.removeAll { $0.name == name }
            }
            return .done
        case .triggerBinding(let mode, let key):
            guard let commands = Shortcuts.shared.commands(forKey: key, mode: mode) else {
                return .failed("Nothing is bound to \(key) in mode \(mode)")
            }
            let outcome = run(commands, window: id)
            return Result(ok: outcome.ok, output: outcome.output.isEmpty ? nil : outcome.output.joined(separator: "\n"),
                          error: outcome.errors.isEmpty ? nil : outcome.errors.joined(separator: "\n"))
        default:
            break
        }

        guard AccessibilityPermission.isTrusted else {
            PermissionWindow.shared.show()
            return .failed("Tessera needs Accessibility permission (System Settings › Privacy & Security › Accessibility)")
        }
        if let id, registry.window(id) == nil {
            registry.rescan()
            if registry.window(id) == nil { return .failed("No window \(id) (see `tessera list-windows`)") }
        }
        let window = id.flatMap(registry.window) ?? registry.focusedWindow()
        func need(_ body: (TrackedWindow) -> Result) -> Result {
            guard let window else { return .failed("No window to act on: nothing is focused") }
            return body(window)
        }
        func tiled(_ body: (TrackedWindow) -> Bool, _ what: String) -> Result {
            need { window in
                guard tiler.isOn else { return .failed("Auto-tile is off (turn it on with `tessera enable on`)") }
                guard tiler.isTiled(window) else { return .failed("That window isn't tiled (it floats, or was snapped by hand)") }
                return body(window) ? .done : .failed(what)
            }
        }

        switch action {
        case .command(let command):
            if let id, let target = registry.window(id) {
                if case .snap(let snap) = command {
                    SnapController.shared.perform(snap, on: target, walking: false)
                    return .done
                }
                if target.id != registry.focusedWindow()?.id {
                    tiler.focus(target)
                    after(0.25) { Shortcuts.run(command) }
                    return .done
                }
            }
            Shortcuts.run(command, fromKey: fromKey)
            return .done

        case .layout(let choices):
            return layout(choices, window: window)

        case .focus(let target, let wrap):
            return focus(target, wrap: wrap, from: window)

        case .focusDisplay(let target, let wrap):
            guard let display = WindowActions.display(target, from: WindowActions.display(of: window), wrap: wrap) else {
                return .failed("No screen that way")
            }
            return WindowActions.focus(display) ? .done : .failed("Couldn't focus that screen")

        case .move(let direction):
            return need { window in
                if tiler.isOn, tiler.isTiled(window) {
                    return tiler.walk(window, direction) ? .done : .failed("Can't move that way")
                }
                let edges: [Direction: SnapAction] = [.left: .moveLeft, .right: .moveRight, .up: .moveUp, .down: .moveDown]
                SnapController.shared.perform(edges[direction]!, on: window)
                return .done
            }

        case .swap(let target, let wrap, let keepFocus):
            return tiled({ window in
                guard let other = tiler.swap(window, target, wrap: wrap) else { return false }
                if keepFocus, let w = registry.window(other) { tiler.focus(w) }
                return true
            }, "No window to swap with that way")

        case .join(let direction):
            return tiled({ window in tiler.changeTree(window) { tree, _ in tree.join(window.id, direction) } }, "Nothing to join with that way")

        case .split(let choice):
            return tiled({ window in
                tiler.changeTree(window) { tree, plan in
                    switch choice {
                    case .toggle:
                        tree.toggleOrientation(of: window.id)
                    case .horizontal:
                        tiler.preselect(window, .right)
                    case .vertical:
                        tiler.preselect(window, .down)
                    case .opposite:
                        let way = tree.parent(of: window.id)?.orientation ?? Orientation.along(plan.area.size)
                        tiler.preselect(window, way.opposite.forward)
                    }
                    return true
                }
            }, "Couldn't split")

        case .preselect(let direction):
            return tiled({ window in
                tiler.changeTree(window) { _, _ in
                    tiler.preselect(window, direction)
                    return true
                }
            }, "Couldn't preselect")

        case .mirror(let way):
            return tiled({ window in tiler.changeTree(window) { tree, _ in tree.mirror(way); return true } }, "Couldn't mirror")

        case .rotate(let turns):
            return tiled({ window in
                tiler.changeTree(window) { tree, _ in
                    for _ in 0..<(turns % 4) { tree.rotate(clockwise: true) }
                    return true
                }
            }, "Couldn't rotate")

        case .balance:
            return need { window in tiler.balance(window) ? .done : .failed("Nothing to even out") }

        case .flatten:
            return tiled({ window in tiler.changeTree(window) { tree, _ in tree.flatten(); return true } }, "Couldn't flatten")

        case .popOut:
            return tiled({ window in tiler.changeTree(window) { tree, _ in tree.popOut(window.id) } }, "Already at the top of the tree")

        case .popIn:
            return tiled({ window in tiler.changeTree(window) { tree, _ in tree.popIn(window.id) } }, "Nothing to join with")

        case .resize(let dimension, let amount):
            return need { window in resize(window, dimension, amount) }

        case .border(let way, let delta):
            return tiled({ window in tiler.moveBorder(window, along: way, by: delta) }, "That edge can't move")

        case .zoom(let toggle):
            return need { window in
                if tiler.zoom(window, toggle) { return .done }
                // Not tiled: maximise, or put back.
                let display = WindowActions.display(of: window)
                var maximised = false
                if let frame = window.frame, let display { maximised = frame.isClose(to: display.visibleFrame, tolerance: 4) }
                SnapController.shared.perform(toggle.apply(to: maximised) ? .maximise : .restore, on: window)
                return .done
            }

        case .nativeFullScreen(let toggle):
            return need { WindowActions.nativeFullScreen($0, toggle) ? .done : .failed("Couldn't change full screen") }

        case .minimize:
            return need { WindowActions.minimize($0) ? .done : .failed("Couldn't minimise") }

        case .close(let quitIfLast):
            return need { WindowActions.close($0, quitIfLast: quitIfLast) ? .done : .failed("That window has no close button") }

        case .closeOthers(let quitIfLast):
            return need { WindowActions.closeOthers(than: $0, quitIfLast: quitIfLast) ? .done : .failed("Couldn't close the others") }

        case .float(let toggle):
            return need { window in
                guard tiler.isOn else { return .failed("Auto-tile is off, so every window floats") }
                return tiler.setFloating(window, toggle) ? .done : .failed("Tessera doesn't tile that window")
            }

        case .keepInFront(let toggle):
            return need { tiler.setKept($0, toggle) ? .done : .failed("Couldn't keep that window in front") }

        case .stack(let forward):
            if let window, tiler.style(of: window) == .stack {
                return tiler.stackStep(window, forward: forward) ? .done : .failed("Only one window here")
            }
            Arranger.shared.perform(forward ? .nextInStack : .previousInStack)
            return .done

        case .desktop(let target):
            guard let display = WindowActions.display(of: window) else { return .failed("No screen") }
            return Desktops.go(target, on: display) ? .done : .failed("No such desktop on this screen")

        case .sendToDesktop(let target, let follow):
            return need { window in
                KeyboardMoves.send(window, to: target, follow: follow)
                return .done
            }

        case .sendToDisplay(let target, let follow, let wrap):
            return need { window in
                guard let display = WindowActions.display(target, from: WindowActions.display(of: window), wrap: wrap) else {
                    return .failed("No screen that way")
                }
                return WindowActions.send(window, to: display, follow: follow) ? .done : .failed("It's already on that screen")
            }

        case .retile:
            tiler.retileCommand()
            return .done

        case .moveMouse(let target):
            return WindowActions.moveMouse(target, window: window) ? .done : .failed("No window")

        default:
            return .failed("Not handled")
        }
    }

    // MARK: Helpers

    /// `layout a b c`: the first that changes something wins, so `layout floating tiling` toggles.
    static func layout(_ choices: [LayoutChoice], window: TrackedWindow?) -> Result {
        let tiler = AutoTiler.shared
        guard let display = WindowActions.display(of: window) else { return .failed("No screen") }
        for (index, choice) in choices.enumerated() {
            let isLast = index == choices.count - 1
            switch choice {
            case .style(let style):
                // `layout tree stack` toggles; a single `layout tree` always applies (the latest command
                // wins: snapped windows join again and sizes even out, like picking it from the menu).
                if !isLast, tiler.isOn, tiler.currentStyle(on: display) == style { continue }
                tiler.setLayout(style, for: display)
                return .done
            case .floating, .tiling:
                guard let window else { return .failed("No window to act on") }
                guard tiler.isOn else { return .failed("Auto-tile is off, so every window floats") }
                let floating = tiler.isFloatingWindow(window.id)
                if (choice == .floating) == floating { continue }
                return tiler.setFloating(window, choice == .floating ? .on : .off) ? .done : .failed("Tessera doesn't tile that window")
            case .container(let layout, let orientation):
                guard let window else { return .failed("No window to act on") }
                guard tiler.isOn, tiler.isTiled(window) else { return .failed("That window isn't tiled") }
                var changed = false
                tiler.changeTree(window) { tree, _ in
                    guard let parent = tree.parent(of: window.id) else { return false }
                    let newLayout = layout ?? parent.layout
                    let newWay = orientation ?? parent.orientation
                    // A single window's root can only change when there's something to lay out.
                    guard newLayout != parent.layout || newWay != parent.orientation else { return true }
                    tree.setLayout(of: window.id, layout: layout, orientation: orientation)
                    changed = true
                    return true
                }
                if changed { return .done }
            }
        }
        return .done
    }

    static func focus(_ target: FocusTarget, wrap: Bool, from window: TrackedWindow?) -> Result {
        let registry = WindowRegistry.shared
        let tiler = AutoTiler.shared
        switch target {
        case .direction(let direction):
            guard let window else { return .failed("Nothing is focused") }
            return KeyboardMoves.focus(from: window, direction, wrap: wrap) ? .done : .failed("No window that way")
        case .next, .previous:
            guard let window else { return .failed("Nothing is focused") }
            var order = tiler.layoutOrder(of: window)
            if !order.contains(window.id), let display = WindowActions.display(of: window) {
                order = KeyboardMoves.visibleWindows(on: display).map(\.id)
            }
            guard let index = order.firstIndex(of: window.id), order.count > 1 else { return .failed("No other window") }
            let i = index + (target == .next ? 1 : -1)
            guard order.indices.contains(i) || wrap else { return .failed("No window that way") }
            guard let next = registry.window(order[(i + order.count) % order.count]) else { return .failed("No window") }
            tiler.focus(next)
            return .done
        case .back:
            guard let id = Events.shared.previousFocus(excluding: window?.id), let previous = registry.window(id) else {
                return .failed("No window to go back to")
            }
            tiler.bringForward(previous.id)
            return .done
        case .window(let id):
            if registry.window(id) == nil { registry.rescan() }
            guard registry.window(id) != nil else { return .failed("No window \(id)") }
            tiler.bringForward(id)
            return .done
        case .index(let n):
            guard let display = WindowActions.display(of: window) else { return .failed("No screen") }
            let order = tiler.layoutOrder(on: display)
            guard order.indices.contains(n), let next = registry.window(order[n]) else { return .failed("No window number \(n)") }
            tiler.focus(next)
            return .done
        }
    }

    static func resize(_ window: TrackedWindow, _ dimension: ResizeDimension, _ amount: ResizeAmount) -> Result {
        let tiler = AutoTiler.shared
        let way: Orientation
        switch dimension {
        case .width: way = .horizontal
        case .height: way = .vertical
        case .smart: way = tiler.containerWay(of: window)
        case .smartOpposite: way = tiler.containerWay(of: window).opposite
        }
        if tiler.isOn, tiler.isTiled(window) {
            let delta: CGFloat
            switch amount {
            case .by(let n): delta = n
            case .to(let n):
                guard let now = tiler.tileLength(window, along: way) else { return .failed("Not tiled") }
                delta = n - now
            }
            return tiler.resize(window, along: way, by: delta) ? .done : .failed("It can't get any \(delta > 0 ? "bigger" : "smaller") that way")
        }
        // A floating window: change its size, keeping its top-left corner.
        guard var frame = window.frame, let display = WindowActions.display(of: window) else { return .failed("No frame") }
        let now = way == .horizontal ? frame.width : frame.height
        let wanted: CGFloat
        switch amount {
        case .by(let n): wanted = now + n
        case .to(let n): wanted = n
        }
        if way == .horizontal { frame.size.width = max(wanted, 100) } else { frame.size.height = max(wanted, 60) }
        WindowMover.shared.move(window, to: frame, within: display.visibleFrame)
        return .done
    }
}
