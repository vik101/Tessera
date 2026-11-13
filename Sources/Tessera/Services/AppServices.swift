import AppKit
import TesseraCore

// MARK: - App icon styles

/// Seven icon styles, drawn in code so they stay crisp at any size.
enum AppIconStyle: String, CaseIterable, Identifiable {
    case paper, ink, ocean, ember, moss, glass, mono

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paper: L("Paper")
        case .ink: L("Ink")
        case .ocean: L("Ocean")
        case .ember: L("Ember")
        case .moss: L("Moss")
        case .glass: L("Glass")
        case .mono: L("Mono")
        }
    }

    private var palette: (top: NSColor, bottom: NSColor, tiles: [NSColor]) {
        switch self {
        case .paper:
            (NSColor(hex: "#FBF7EF")!, NSColor(hex: "#EDE4D3")!, [NSColor(hex: "#C8553D")!, NSColor(hex: "#2E4057")!, NSColor(hex: "#D9B26F")!])
        case .ink:
            (NSColor(hex: "#2B2D42")!, NSColor(hex: "#14151F")!, [NSColor(hex: "#EDF2F4")!, NSColor(hex: "#8D99AE")!, NSColor(hex: "#EF233C")!])
        case .ocean:
            (NSColor(hex: "#4CC9F0")!, NSColor(hex: "#3A0CA3")!, [NSColor(white: 1, alpha: 0.95), NSColor(white: 1, alpha: 0.7), NSColor(white: 1, alpha: 0.5)])
        case .ember:
            (NSColor(hex: "#FFB703")!, NSColor(hex: "#FB5607")!, [NSColor(hex: "#FFFFFF")!, NSColor(hex: "#FFE8D6")!, NSColor(hex: "#3D0C02")!])
        case .moss:
            (NSColor(hex: "#A7C957")!, NSColor(hex: "#386641")!, [NSColor(hex: "#F2E8CF")!, NSColor(hex: "#F2E8CF")!.withAlphaComponent(0.75), NSColor(hex: "#BC4749")!])
        case .glass:
            (NSColor(hex: "#A0C4FF")!, NSColor(hex: "#BDB2FF")!, [NSColor(white: 1, alpha: 0.55), NSColor(white: 1, alpha: 0.4), NSColor(white: 1, alpha: 0.3)])
        case .mono:
            (NSColor(hex: "#FFFFFF")!, NSColor(hex: "#E5E5E5")!, [NSColor(hex: "#111111")!, NSColor(hex: "#555555")!, NSColor(hex: "#999999")!])
        }
    }

    /// The icon: a rounded square holding three tiles, like the Grid layout.
    func image(size: CGFloat = 512) -> NSImage {
        let palette = self.palette
        let isGlass = self == .glass
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let inset = rect.width * 0.1
            let body = rect.insetBy(dx: inset, dy: inset)
            let radius = body.width * 0.225
            let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
            shadow.shadowBlurRadius = rect.width * 0.03
            shadow.shadowOffset = NSSize(width: 0, height: -rect.width * 0.012)
            shadow.set()
            NSGradient(starting: palette.top, ending: palette.bottom)?.draw(in: shape, angle: -90)
            NSGraphicsContext.restoreGraphicsState()

            let pad = body.width * 0.17
            let gap = body.width * 0.05
            let area = body.insetBy(dx: pad, dy: pad)
            let tileRadius = body.width * 0.06
            let left = NSRect(x: area.minX, y: area.minY, width: (area.width - gap) * 0.55, height: area.height)
            let rightX = left.maxX + gap
            let rightW = area.maxX - rightX
            let top = NSRect(x: rightX, y: area.minY + (area.height + gap) / 2, width: rightW, height: (area.height - gap) / 2)
            let bottom = NSRect(x: rightX, y: area.minY, width: rightW, height: (area.height - gap) / 2)
            for (index, tile) in [left, top, bottom].enumerated() {
                let path = NSBezierPath(roundedRect: tile, xRadius: tileRadius, yRadius: tileRadius)
                palette.tiles[index].setFill()
                path.fill()
                if isGlass {
                    NSColor.white.withAlphaComponent(0.8).setStroke()
                    path.lineWidth = body.width * 0.008
                    path.stroke()
                }
            }
            return true
        }
    }

    @MainActor
    static func apply(_ name: String) {
        let style = AppIconStyle(rawValue: name) ?? .paper
        NSApp.applicationIconImage = style.image()
    }
}

// MARK: - System monitors

/// Polls things macOS doesn't announce: Accessibility trust, Stage Manager, Secure Input.
@MainActor
final class SystemMonitor {
    static let shared = SystemMonitor()
    private let timer = RepeatingTimer()

    func start() {
        poll()
        timer.start(every: 1.5) { [weak self] in self?.poll() }
    }

    private func poll() {
        let model = AppModel.shared
        var changed = false

        let trusted = AccessibilityPermission.isTrusted
        if trusted != model.accessibilityTrusted {
            model.accessibilityTrusted = trusted
            changed = true
            if trusted { TilingController.shared.registry.rescan() }
        }

        CFPreferencesAppSynchronize("com.apple.WindowManager" as CFString)
        let stage = (CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString) as? Bool) ?? false
        if stage != model.stageManagerOn {
            model.stageManagerOn = stage
            changed = true
        }

        let secure = SecureInput.isOn
        if secure != model.secureInputOn { model.secureInputOn = secure }

        if changed {
            TilingController.shared.statusChanged()
            StatusItemController.shared.refreshIcon()
        }
        LicenseManager.shared.recompute()
        answerDumpRequest()
    }

    /// Developer aid: `scripts/dev-loop.sh state` asks for a diagnostics dump through a file.
    private func answerDumpRequest() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Tessera", isDirectory: true)
        let request = base.appendingPathComponent("dump-request")
        guard FileManager.default.fileExists(atPath: request.path) else { return }
        try? FileManager.default.removeItem(at: request)
        var text = Diagnostics.report(kind: .problem, message: "State dump", includeDiagnostics: true)
        let tiling = TilingController.shared
        text += "\n\n— Tiles —\n"
        for key in tiling.visibleKeys {
            guard let state = tiling.state(forKey: key) else { continue }
            text += "\(key): \(state.layout.rawValue) cap \(state.capacity)\n"
            for (index, tile) in state.tiles.enumerated() {
                let apps = tile.windows.map { id in tiling.registry.window(id)?.bundleID ?? "?" }
                let frame = tiling.frames[key]?[index].map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "-"
                text += "  [\(index)] \(frame) \(apps)\n"
            }
        }
        text += "Focused: \(tiling.focusedID.map(String.init) ?? "none"), floating: \(tiling.floating.count), auto-floating: \(tiling.autoFloating.count)\n"
        try? text.write(to: base.appendingPathComponent("dump.txt"), atomically: true, encoding: .utf8)
    }
}

// MARK: - Problem reports

@MainActor
enum Diagnostics {
    enum Kind { case problem, feature }

    static func report(kind: Kind, message: String, includeDiagnostics: Bool) -> String {
        var lines: [String] = []
        lines.append(kind == .problem ? L("What happened:") : L("Idea:"))
        lines.append(message.isEmpty ? "…" : message)
        guard includeDiagnostics else { return lines.joined(separator: "\n") }
        let prefs = Preferences.shared
        let model = AppModel.shared
        let tiling = TilingController.shared
        lines.append("")
        lines.append("— Diagnostics (no window titles or document names) —")
        lines.append("\(AppConfig.appName) \(AppConfig.version) (\(AppConfig.build))")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Model: \(hardwareModel())")
        lines.append("Status: \(model.status.message)")
        lines.append("Accessibility: \(model.accessibilityTrusted), Stage Manager: \(model.stageManagerOn), Secure Input: \(model.secureInputOn)")
        lines.append("License: \(model.licenseState)")
        for display in tiling.displays {
            let key = tiling.key(for: display)
            let state = tiling.state(forKey: key)
            lines.append("Screen \(Int(display.frame.width))×\(Int(display.frame.height)) \(display.shape.rawValue): layout \(state?.layout.rawValue ?? "-"), count \(state?.capacity ?? 0), tiles \(state?.tiles.count ?? 0)")
        }
        lines.append("Settings: main \(prefs.mainSize.rawValue), gap \(Int(prefs.gap)), new \(prefs.newWindowPlacement.rawValue), full \(prefs.whenFull.rawValue), move \(prefs.moveIntoFull.rawValue), highlight \(prefs.highlight.rawValue), hover \(prefs.hoverFocus), quick \(prefs.quickActions), prefix \(prefs.shortcutPrefix.rawValue)")
        lines.append("Windows tracked: \(tiling.registry.windows.count)")
        lines.append("Recent events:")
        lines.append(contentsOf: Log.recent.suffix(60))
        return lines.joined(separator: "\n")
    }

    static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    enum Mailer { case appleMail, gmail, outlook }

    static func send(_ body: String, subject: String, via mailer: Mailer) {
        let to = AppConfig.supportEmail
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?"))
        let s = subject.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let b = body.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let urlString: String
        switch mailer {
        case .appleMail: urlString = "mailto:\(to)?subject=\(s)&body=\(b)"
        case .gmail: urlString = "https://mail.google.com/mail/?view=cm&to=\(to)&su=\(s)&body=\(b)"
        case .outlook: urlString = "https://outlook.live.com/mail/0/deeplink/compose?to=\(to)&subject=\(s)&body=\(b)"
        }
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - What's new

struct ReleaseNote: Identifiable {
    let version: String
    let items: [String]
    var id: String { version }
}

enum WhatsNew {
    static var notes: [ReleaseNote] {
        [
            ReleaseNote(version: "1.0", items: [
                L("Windows tile themselves as they open, in Grid, Columns, Rows or Side."),
                L("Stacks: when a screen is full, new windows wait in the tile you're using."),
                L("Focus mode, No peek mode, Clean Space and Tab View."),
                L("Setups: open your work apps, arranged, in one click."),
                L("Every shortcut can be changed, with conflict checks and free suggestions."),
            ]),
        ]
    }
}
