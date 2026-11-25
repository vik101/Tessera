import AppKit
import TesseraCore

/// Connects key combos to commands, and runs commands.
@MainActor
final class Shortcuts {
    static let shared = Shortcuts()

    private var tokens: [HotKeyCenter.Token] = []
    /// Commands whose shortcut macOS refused (another app already holds it).
    private(set) var failed: [Command] = []
    /// Config-file keys macOS refused.
    private(set) var failedKeys: [String] = []
    /// The binding mode: "main" normally; config files can add others (like AeroSpace's).
    private(set) var mode = "main"

    func start() {
        Settings.shared.observe { [weak self] change in
            if change == .shortcuts { self?.reload() }
        }
        reload()
    }

    /// The config with the preset chosen in Settings (the file's own choice wins).
    private var config: TesseraConfig {
        var config = ConfigStore.shared.config
        if config.preset == nil { config.preset = Settings.shared.shortcutPreset }
        return config
    }

    /// Every mode there is: main, plus the config file's and the preset's.
    var modes: [String] { config.modeNames }

    /// Registers the keys of the current mode: in main, Tessera's own shortcuts (unless the preset is
    /// None) and the config file's; in other modes, only the config file's.
    func reload() {
        HotKeyCenter.shared.unregister(tokens)
        tokens = []
        failed = []
        failedKeys = []
        let config = self.config
        if mode != "main", !config.modeNames.contains(mode) { mode = "main" }
        let extra = config.bindings(for: mode)
        let taken = Set(extra.map(\.combo))
        if mode == "main", config.preset != .blank {
            for (command, combo) in Settings.shared.shortcuts.bindings where !taken.contains(combo) {
                if let token = HotKeyCenter.shared.register(combo, handler: { Shortcuts.run(command, fromKey: true) }) {
                    tokens.append(token)
                } else {
                    failed.append(command)
                }
            }
        }
        for binding in extra {
            let commands = binding.commands
            if let token = HotKeyCenter.shared.register(binding.combo, handler: { CommandRunner.run(commands, fromKey: true) }) {
                tokens.append(token)
            } else {
                failedKeys.append(binding.key)
            }
        }
        if !failed.isEmpty {
            Log.error("Shortcuts held by another app: " + failed.map(\.title).joined(separator: ", "))
        }
        if !failedKeys.isEmpty {
            Log.error("Config keys held by another app: " + failedKeys.joined(separator: ", "))
        }
    }

    /// Switches binding mode. Returns false for a mode no config or preset defines.
    @discardableResult
    func setMode(_ name: String) -> Bool {
        guard name == "main" || config.modeNames.contains(name) else { return false }
        guard name != mode else { return true }
        mode = name
        reload()
        Log.info("Mode: \(name)")
        Events.shared.modeChanged(name)
        return true
    }

    /// The commands bound to a key in a mode (for `trigger-binding`).
    func commands(forKey key: String, mode: String) -> [String]? {
        let config = self.config
        guard let combo = try? KeyNotation.parse(key, mapping: config.keyMapping) else { return nil }
        return config.bindings(for: mode).first { $0.combo == combo }?.commands
    }

    /// Pauses all shortcuts while you record a new one in Settings.
    var paused: Bool {
        get { HotKeyCenter.shared.paused }
        set { HotKeyCenter.shared.paused = newValue }
    }

    /// Runs a command. `fromKey` is true for a keyboard shortcut: then ⌃⌥ + arrow walks a tiled window
    /// through the layout, while Left Half from the menu or a link still snaps it there.
    static func run(_ command: Command, fromKey: Bool = false) {
        if TestHooks.shared.isOn { Log.info("Shortcut: \(command.id)") }
        switch command {
        case .snap(let action):
            SnapController.shared.perform(action, walking: fromKey)
        case .tile(.toggleAutoTile):
            AutoTiler.shared.toggle()
        case .tile(.nextLayout):
            AutoTiler.shared.nextLayout()
        case .tile(.previousLayout):
            AutoTiler.shared.previousLayout()
        case .layout(let style):
            AutoTiler.shared.chooseLayout(style)
        case .tile(.swapWithMain):
            AutoTiler.shared.swapWithMain()
        case .tile(.toggleFloat):
            AutoTiler.shared.toggleFloat()
        case .tile(.retile):
            AutoTiler.shared.retileCommand()
        case .tile(.showWindows):
            WindowPicker.shared.toggle()
        case .tile(.keepInFront):
            AutoTiler.shared.toggleKeep()
        case .arrange(let action):
            Arranger.shared.perform(action)
        case .move(let action):
            KeyboardMoves.perform(action)
        case .setup(let n):
            Setups.open(number: n)
        }
    }
}
