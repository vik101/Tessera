import AppKit
import TesseraCore

/// Connects key combos to commands, and runs commands.
@MainActor
final class Shortcuts {
    static let shared = Shortcuts()

    private var tokens: [HotKeyCenter.Token] = []
    /// Commands whose shortcut macOS refused (another app already holds it).
    private(set) var failed: [Command] = []

    func start() {
        Settings.shared.observe { [weak self] change in
            if change == .shortcuts { self?.reload() }
        }
        reload()
    }

    func reload() {
        HotKeyCenter.shared.unregister(tokens)
        tokens = []
        failed = []
        for (command, combo) in Settings.shared.shortcuts.bindings {
            if let token = HotKeyCenter.shared.register(combo, handler: { Shortcuts.run(command) }) {
                tokens.append(token)
            } else {
                failed.append(command)
            }
        }
        if !failed.isEmpty {
            Log.error("Shortcuts held by another app: " + failed.map(\.title).joined(separator: ", "))
        }
    }

    /// Pauses all shortcuts while you record a new one in Settings.
    var paused: Bool {
        get { HotKeyCenter.shared.paused }
        set { HotKeyCenter.shared.paused = newValue }
    }

    static func run(_ command: Command) {
        if TestHooks.shared.isOn { Log.info("Shortcut: \(command.id)") }
        switch command {
        case .snap(let action):
            SnapController.shared.perform(action)
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
        }
    }
}
