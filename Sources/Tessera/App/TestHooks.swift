import AppKit
import TesseraCore

/// Lets the automatic tests on GitHub's Macs drive Tessera and read its state.
///
/// Off unless the hidden setting is on:  defaults write com.vikram.Tessera TesseraTestHooks -bool YES
/// Commands arrive as a distributed notification named com.vikram.Tessera.test, with the command as its object.
@MainActor
final class TestHooks: NSObject {
    static let shared = TestHooks()
    static let dumpPath = "/tmp/tessera-dump.json"

    private(set) var isOn = false

    func start() {
        guard UserDefaults.standard.bool(forKey: "TesseraTestHooks") else { return }
        isOn = true
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(received(_:)), name: Notification.Name("com.vikram.Tessera.test"), object: nil
        )
        Log.info("Test hooks on")
    }

    @objc private func received(_ note: Notification) {
        guard let command = note.object as? String else { return }
        Log.info("Test command: \(command)")
        run(command)
    }

    private func run(_ command: String) {
        let settings = Settings.shared
        switch command {
        case "dump": writeDump()
        case "menu": after(0.05) { StatusMenu.shared.open() }
        case "settings": SettingsWindow.shared.show()
        case "close-settings": SettingsWindow.shared.close()
        case "permission": PermissionWindow.shared.show()
        case "fix-mac-tiling": MacTiling.turnOffEdgeDrag()
        default:
            if command.hasPrefix("run:"), let target = Command(id: String(command.dropFirst(4))) {
                Shortcuts.run(target)
            } else if command.hasPrefix("set:") {
                let parts = command.dropFirst(4).split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return }
                switch parts[0] {
                case "autoTile": settings.autoTile = parts[1] == "1"
                case "gap": settings.gap = Int(parts[1]) ?? 0
                case "layout":
                    if let style = LayoutStyle(rawValue: parts[1]) {
                        for display in Screens.all() { settings.layouts[display.stableID] = style }
                    }
                default: break
                }
            }
        }
    }

    private func writeDump() {
        func rect(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map(Double.init) }
        let visible = WindowServer.onScreen().filter { $0.layer == 0 }
        var windows: [[String: Any]] = []
        for info in visible {
            guard let window = WindowRegistry.shared.window(info.id), let frame = window.frame else { continue }
            windows.append([
                "id": Int(info.id),
                "app": window.bundleID,
                "frame": rect(frame),
                "tiled": AutoTiler.shared.isTiled(window),
                "standard": window.isStandard,
            ])
        }
        let focused = WindowRegistry.shared.focusedWindow()
        let dump: [String: Any] = [
            "trusted": AccessibilityPermission.isTrusted,
            "version": AppInfo.version,
            "path": Bundle.main.bundlePath,
            "macEdgeTiling": MacTiling.edgeDragIsOn,
            "displays": Screens.all().map { ["id": $0.stableID, "name": $0.name, "frame": rect($0.frame), "visible": rect($0.visibleFrame)] },
            "focused": focused.map { Int($0.id) } ?? 0,
            "windows": windows,
            "autoTile": AutoTiler.shared.debugState(),
            "gap": Settings.shared.gap,
            "layouts": Settings.shared.layouts.mapValues(\.rawValue),
            "autoTileSetting": Settings.shared.autoTile,
            "failedShortcuts": Shortcuts.shared.failed.map(\.id),
            "log": Array(Log.recent.suffix(60)),
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: dump, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: Self.dumpPath))
        } catch {
            Log.error("Dump failed: \(error.localizedDescription)")
        }
    }
}
