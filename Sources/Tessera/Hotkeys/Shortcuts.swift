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
        switch command {
        case .snap(let action):
            SnapController.shared.perform(action)
        case .tile(.toggleAutoTile):
            AutoTiler.shared.toggle()
        case .tile(.nextLayout):
            AutoTiler.shared.nextLayout()
        case .tile(.swapWithMain):
            AutoTiler.shared.swapWithMain()
        case .tile(.toggleFloat):
            AutoTiler.shared.toggleFloat()
        case .tile(.retile):
            if AutoTiler.shared.isOn {
                AutoTiler.shared.retile()
            } else {
                AutoTiler.shared.toggle()
            }
        }
    }
}
