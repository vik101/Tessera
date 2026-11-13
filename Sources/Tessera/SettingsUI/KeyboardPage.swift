import AppKit
import SwiftUI
import TesseraCore

extension ShortcutPrefix {
    var title: String { modifiers.symbols }
}

/// Click, then press the new keys. Esc cancels; Delete turns the shortcut off.
struct ShortcutRecorder: View {
    let combo: KeyCombo?
    var requiresHold = false
    var digitOnly = false
    let onChange: @MainActor (KeyCombo?) -> Void

    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? L("Press keys…") : (combo?.description ?? L("Off")))
                    .font(.system(size: 12).monospaced())
                    .frame(minWidth: 96)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
            if let hint {
                Text(hint).font(.system(size: 10)).foregroundStyle(.orange)
            }
        }
        .onDisappear { if recording { stop() } }
    }

    private func start() {
        hint = nil
        recording = true
        ShortcutRecording.begin()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(keyCode: event.keyCode, flags: event.modifierFlags) }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        ShortcutRecording.end()
    }

    private func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        var modifiers: Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        let code = UInt32(keyCode)
        if code == KeyCode.escape, modifiers.isEmpty {
            stop()
            return
        }
        if (code == KeyCode.delete || code == KeyCode.forwardDelete), modifiers.isEmpty {
            stop()
            onChange(nil)
            return
        }
        let combo = KeyCombo(code, modifiers)
        if digitOnly, !KeyCode.digits.contains(code) {
            hint = L("Press the keys with a number, like ⌃⌥⌘1.")
            return
        }
        if requiresHold, modifiers.subtracting(.shift).isEmpty {
            hint = L("Tab View needs a key to hold, such as ⌥.")
            return
        }
        guard combo.isAllowedAsShortcut else {
            hint = L("Keep ⌃, ⌥ or ⌘ in a shortcut so normal typing still works. F-keys can be used alone.")
            return
        }
        stop()
        onChange(combo)
    }
}

/// While recording, Tessera's own shortcuts step aside so their keys can be captured.
@MainActor
enum ShortcutRecording {
    private static var depth = 0

    static func begin() {
        depth += 1
        if depth == 1 {
            HotKeyCenter.shared.paused = true
            let saved = Preferences.shared.shortcutsEnabled
            Preferences.shared.shortcutsEnabled = false
            ShortcutCenter.shared.reload()
            Preferences.shared.shortcutsEnabled = saved
        }
    }

    static func end() {
        depth = max(0, depth - 1)
        if depth == 0 {
            HotKeyCenter.shared.paused = false
            ShortcutCenter.shared.reload()
        }
    }
}

struct KeyboardPage: View {
    private var prefs: Preferences { .shared }
    private var center: ShortcutCenter { .shared }
    @State private var pendingConflict: PendingConflict?
    @State private var menuScanned = false

    struct PendingConflict: Identifiable {
        let action: ShortcutAction
        let combo: KeyCombo
        let others: [ShortcutAction]
        var id: String { action.rawValue }
    }

    var body: some View {
        Form {
            Section {
                Toggle(L("Keyboard shortcuts"), isOn: Binding(get: { prefs.shortcutsEnabled }, set: {
                    prefs.shortcutsEnabled = $0
                    center.reload()
                }))
                HStack {
                    Text(L("Shortcut cheat sheet"))
                    Spacer()
                    Text(center.label(for: .cheatSheet)).font(.system(size: 12).monospaced()).foregroundStyle(.secondary)
                    Button(L("Show")) { CheatSheetController.shared.show() }
                }
                Picker(L("Shortcut prefix"), selection: Binding(get: { prefs.shortcutPrefix }, set: {
                    prefs.shortcutPrefix = $0
                    center.reload()
                })) {
                    ForEach(ShortcutPrefix.allCases) { prefix in Text(prefix.title).tag(prefix) }
                }
                .pickerStyle(.segmented)
                Text(L("Changing the prefix updates every shortcut you haven't changed. Shortcuts pause while a password field is active."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(ShortcutGroup.allCases) { group in
                Section(group.title) {
                    ForEach(rows(in: group)) { action in
                        row(action)
                    }
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button(L("Reset All")) {
                        prefs.shortcutBindings = [:]
                        prefs.countModifiers = nil
                        prefs.shortcutPrefix = .controlOption
                        center.reload()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // Read open apps' menus once, so menu conflicts can be shown.
            _ = ConflictChecker.menuShortcuts()
            menuScanned = true
        }
        .alert(
            L("These keys are already used"),
            isPresented: Binding(get: { pendingConflict != nil }, set: { if !$0 { pendingConflict = nil } }),
            presenting: pendingConflict
        ) { conflict in
            Button(L("Turn Off the Other")) {
                for other in conflict.others { prefs.setBinding(.off, for: other) }
                prefs.setBinding(.custom(conflict.combo), for: conflict.action)
                center.reload()
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: { conflict in
            Text(L("“%@” uses %@. Turn it off and use the keys here?", conflict.others.map(\.title).joined(separator: ", "), conflict.combo.description))
        }
    }

    /// Window-count keys change together, so they share one row.
    private func rows(in group: ShortcutGroup) -> [ShortcutAction] {
        ShortcutAction.allCases.filter { $0.group == group && !$0.isDerived && ($0.countValue == nil || $0 == .count1) }
    }

    @ViewBuilder private func row(_ action: ShortcutAction) -> some View {
        let resolver = center.resolver
        let combo = resolver.combo(for: action)
        let conflicts = combo.map { ConflictChecker.conflicts(for: $0, action: action, resolver: resolver, includeMenus: menuScanned) } ?? []
        let leftToMacOS = center.leftToMacOS.contains(action)
        let failed = center.failed.contains(action)
        let dimmed = !conflicts.isEmpty || leftToMacOS || failed
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(action.isWindowCount ? L("Window count (1–5)") : action.title)
                    .foregroundStyle(dimmed ? .secondary : .primary)
                Spacer()
                if resolver.isCustomized(action) {
                    Button {
                        if action.isWindowCount {
                            prefs.countModifiers = nil
                        } else {
                            prefs.setBinding(.standard, for: action)
                        }
                        center.reload()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help(L("Restore the default keys"))
                }
                ShortcutRecorder(combo: combo, requiresHold: action == .tabView, digitOnly: action.isWindowCount) { newCombo in
                    save(newCombo, for: action)
                }
            }
            if leftToMacOS {
                Text(L("Left to macOS. Use the menu bar panel, assign other keys, or pick another prefix."))
                    .font(.caption).foregroundStyle(.orange)
            } else if failed {
                Text(L("macOS couldn't set up this shortcut. Another app may be using it."))
                    .font(.caption).foregroundStyle(.orange)
            }
            if let combo, !conflicts.isEmpty {
                Text(conflicts.map(\.message).joined(separator: " · ")).font(.caption).foregroundStyle(.orange)
                let suggestions = ConflictChecker.suggestions(for: combo, action: action, resolver: resolver)
                if !suggestions.isEmpty {
                    HStack(spacing: 6) {
                        Text(L("Free keys:")).font(.caption).foregroundStyle(.secondary)
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion.description) { save(suggestion, for: action) }
                                .controlSize(.mini)
                        }
                    }
                }
            }
        }
    }

    private func save(_ combo: KeyCombo?, for action: ShortcutAction) {
        guard let combo else {
            if action.isWindowCount {
                for value in 1...5 { if let count = ShortcutAction.count(value) { prefs.setBinding(.off, for: count) } }
            } else {
                prefs.setBinding(.off, for: action)
            }
            center.reload()
            return
        }
        if action.isWindowCount {
            for value in 1...5 { if let count = ShortcutAction.count(value) { prefs.setBinding(.standard, for: count) } }
            prefs.countModifiers = combo.modifiers
            center.reload()
            return
        }
        let others = center.resolver.actions(using: combo).filter { $0 != action && !$0.isDerived }
        if !others.isEmpty {
            pendingConflict = PendingConflict(action: action, combo: combo, others: others)
            return
        }
        prefs.setBinding(.custom(combo), for: action)
        center.reload()
    }
}
