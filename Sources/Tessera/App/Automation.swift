import AppKit
import TesseraCore

/// Runs tessera:// links. Window actions need Accessibility, like the shortcuts do.
@MainActor
enum Automation {
    static func open(_ url: URL) {
        guard let command = URLCommand(url: url) else {
            Log.error("Unknown link: \(url.absoluteString)")
            NSSound.beep()
            return
        }
        Log.info("Link: \(url.host ?? "")")
        let settings = Settings.shared
        switch command {
        case .run(let command):
            Shortcuts.run(command)
        case .ignore(let app, let ignored):
            guard let id = app ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
            if settings.isIgnored(id) != ignored { settings.toggleIgnored(id) }
        case .exportSettings(let path):
            do { try settings.export(to: URL(fileURLWithPath: path)) } catch { Log.error("Export: \(error.localizedDescription)") }
        case .importSettings(let path):
            do { try settings.importFile(at: URL(fileURLWithPath: path)) } catch { Log.error("Import: \(error.localizedDescription)") }
        case .saveSetup(let name):
            Setups.save(name: name)
        case .openSetup(let name):
            Setups.open(name: name)
        case .script(let line):
            CommandRunner.run(line)
        }
    }
}
