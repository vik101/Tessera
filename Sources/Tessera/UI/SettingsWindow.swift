import AppKit
import Combine
import SwiftUI
import TesseraCore
import UniformTypeIdentifiers

/// The one Settings window.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Tessera Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 560, height: 720))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func close() { window?.close() }
}

struct SettingsView: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var recorder = ShortcutRecorder.shared
    @State private var displays: [DisplayInfo] = Screens.all()

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open Tessera at login", isOn: Binding(
                    get: { settings.openAtLogin },
                    set: { settings.openAtLogin = $0 }
                ))
                LabeledContent("Gap between windows") {
                    HStack {
                        Slider(value: Binding(
                            get: { Double(settings.gap) },
                            set: { settings.gap = Int($0.rounded()) }
                        ), in: 0...30, step: 2)
                        Text("\(settings.gap) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }

            Section("Snapping") {
                Toggle("Snap windows by dragging them to a screen edge or corner", isOn: $settings.dragToSnap)
                Toggle("Give a window its old size when you drag it out of a snap", isOn: $settings.restoreSizeOnDrag)
                Toggle("Pressing Left or Right Half again cycles ½, ⅔ and ⅓", isOn: $settings.cycleSizes)
            }

            Section {
                Toggle("Auto-tile windows", isOn: $settings.autoTile)
                ForEach(displays) { display in
                    Picker(displays.count > 1 ? "Layout on \(display.name)" : "Layout", selection: layoutBinding(display)) {
                        ForEach(LayoutStyle.allCases, id: \.self) { style in
                            Text(style.title).tag(style)
                        }
                    }
                }
                Picker("Windows in front", selection: $settings.frontLimit) {
                    ForEach(FrontLimit.choices, id: \.self) { limit in
                        Text(limitTitle(limit)).tag(limit)
                    }
                }
                LabeledContent("Main window size (Main + Side)") {
                    HStack {
                        Slider(value: $settings.mainRatio, in: 0.3...0.7)
                        Text("\(Int((settings.mainRatio * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            } header: {
                Text("Auto-Tile")
            } footer: {
                Text("Auto-tile arranges every normal window on a screen so none overlap. Auto picks the best arrangement for the number of windows and the shape of the screen. Snap a window by hand to keep it in place; the others fill the rest. Restore (⌃⌥⌫) puts it back.\n\nOnly a few windows sit in front; the rest wait just off the screen's edge. Use a waiting window (click it in the Dock, ⌘Tab, or pick it with ⌃⌥Space) and it takes the place of the front window you used least lately. ⌃⌥P keeps a window in front.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("Apps Tessera leaves alone") {
                if settings.ignoredApps.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(settings.ignoredApps, id: \.self) { bundleID in
                    HStack {
                        Image(nsImage: AppInfo.icon(bundleID)).resizable().frame(width: 18, height: 18)
                        Text(AppInfo.name(bundleID))
                        Spacer()
                        Button("Remove") { settings.ignoredApps.removeAll { $0 == bundleID } }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add App…", action: addIgnoredApp)
            }

            Section {
                ForEach(Self.shortcutGroups, id: \.title) { group in
                    Text(group.title).font(.headline).padding(.top, 4)
                    ForEach(group.commands, id: \.id) { command in
                        ShortcutRow(command: command)
                    }
                }
                Button("Restore Default Shortcuts") { settings.shortcuts = ShortcutSet() }
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                Text("Click a shortcut, then press the new keys. Esc cancels. Delete removes it.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                Text("Tessera \(AppInfo.version)").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 500)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = Screens.all()
        }
        .onDisappear { recorder.stop() }
    }

    /// "Auto (3 here)" names what Auto means on this Mac's screens.
    private func limitTitle(_ limit: FrontLimit) -> String {
        guard limit == .auto else { return limit.title }
        let counts = Set(displays.map { FrontLimit.autoCount(for: $0.visibleFrame.size) }).sorted().map(String.init)
        return counts.isEmpty ? "Auto" : "Auto (\(counts.joined(separator: " or ")) here)"
    }

    private func layoutBinding(_ display: DisplayInfo) -> Binding<LayoutStyle> {
        Binding(
            get: { AutoTiler.shared.layout(for: display) },
            set: { AutoTiler.shared.setLayout($0, for: display, notify: false) }
        )
    }

    private func addIgnoredApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !settings.ignoredApps.contains(id) {
                settings.ignoredApps.append(id)
            }
        }
    }

    private struct ShortcutGroup {
        let title: String
        let commands: [Command]
    }

    private static let shortcutGroups: [ShortcutGroup] = {
        var groups = SnapGroup.allCases.map { group in
            ShortcutGroup(
                title: group.submenuTitle ?? group.rawValue.capitalized,
                commands: SnapAction.allCases.filter { $0.group == group }.map(Command.snap)
            )
        }
        groups.append(ShortcutGroup(title: "Auto-Tile", commands: TileCommand.allCases.map(Command.tile)))
        groups.append(ShortcutGroup(title: "Layouts", commands: LayoutStyle.allCases.map(Command.layout)))
        return groups
    }()
}

/// One command with its shortcut button.
private struct ShortcutRow: View {
    let command: Command
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var recorder = ShortcutRecorder.shared

    var body: some View {
        let combo = settings.shortcuts.combo(for: command)
        let recording = recorder.command == command
        HStack {
            Text(command.title)
            if Shortcuts.shared.failed.contains(command) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Another app holds this shortcut")
            }
            Spacer()
            if let note = recorder.notes[command.id] {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Button {
                recording ? recorder.stop() : recorder.start(command)
            } label: {
                Text(recording ? "Type shortcut…" : (combo?.description ?? "Record Shortcut"))
                    .frame(minWidth: 110)
                    .foregroundStyle(combo == nil && !recording ? .secondary : .primary)
            }
            .controlSize(.small)
        }
    }
}

/// Records a new shortcut from the keyboard. Only one command records at a time.
@MainActor
final class ShortcutRecorder: ObservableObject {
    static let shared = ShortcutRecorder()

    @Published private(set) var command: Command?
    /// Short notes like "Moved from Left Half", by command id.
    @Published private(set) var notes: [String: String] = [:]
    private var monitor: Any?

    func start(_ command: Command) {
        stop()
        self.command = command
        notes[command.id] = nil
        Shortcuts.shared.paused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = event.keyCode
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
            let used = MainActor.assumeIsolated { ShortcutRecorder.shared.handle(code: code, flags: flags) }
            return used ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        command = nil
        Shortcuts.shared.paused = false
    }

    private func handle(code: UInt16, flags: UInt) -> Bool {
        guard let command else { return false }
        let modifiers = Modifiers(eventFlags: NSEvent.ModifierFlags(rawValue: flags))
        let key = UInt32(code)
        if modifiers.isEmpty, key == KeyCode.escape {
            stop()
            return true
        }
        if modifiers.isEmpty, key == KeyCode.delete || key == KeyCode.forwardDelete {
            Settings.shared.shortcuts.set(nil, for: command)
            stop()
            return true
        }
        let combo = KeyCombo(key, modifiers)
        guard combo.isAllowedAsShortcut else {
            // Plain letters would stop you typing them. Ask for ⌃, ⌥ or ⌘.
            NSSound.beep()
            return true
        }
        if let moved = Settings.shared.shortcuts.set(combo, for: command) {
            notes[command.id] = "Moved from \(moved.title)"
        }
        stop()
        return true
    }
}

/// Names and icons of apps, by bundle identifier.
@MainActor
enum AppInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    static func name(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    static func icon(_ bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
    }
}
