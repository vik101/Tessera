import AppKit
import SwiftUI
import TesseraCore

/// The welcome tour. Tessera moves nothing until you press "Tidy My Workspace".
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil {
            let controller = NSHostingController(rootView: OnboardingView(onFinish: { [weak self] in self?.finish() }))
            let window = NSWindow(contentViewController: controller)
            window.title = L("Welcome to %@", AppConfig.appName)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 600, height: 470))
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        AppIconStyle.apply(Preferences.shared.appIcon)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        let prefs = Preferences.shared
        prefs.onboardingComplete = true
        prefs.lastSeenVersion = AppConfig.version
        LaunchAtLogin.set(prefs.openAtLogin)
        window?.close()
        TilingController.shared.statusChanged()
        StatusItemController.shared.refreshIcon()
        Notices.shared.toast(L("All tidy. New windows will place themselves."))
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct OnboardingView: View {
    let onFinish: @MainActor () -> Void
    @State private var step = 0
    private var model: AppModel { .shared }
    private var prefs: Preferences { .shared }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: access
                case 2: layout
                default: shortcuts
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<4, id: \.self) { index in
                        Circle().fill(index == step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if step > 0 { Button(L("Back")) { step -= 1 } }
                if step < 3 {
                    Button(L("Continue")) { step += 1 }
                        .keyboardShortcut(.defaultAction)
                        .disabled(step == 1 && !model.accessibilityTrusted)
                } else {
                    Button(L("Tidy My Workspace")) { onFinish() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.accessibilityTrusted)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(.bar)
        }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(nsImage: (AppIconStyle(rawValue: prefs.appIcon) ?? .paper).image(size: 256)).resizable().frame(width: 96, height: 96)
            Text(L("Windows that arrange themselves")).font(.largeTitle.weight(.semibold)).multilineTextAlignment(.center)
            Text(L("Open a window and it takes a tile. Close one and the rest fill the space. No dragging, no resizing, no layouts to set up."))
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
        }
    }

    private var access: some View {
        VStack(spacing: 16) {
            Image(systemName: model.accessibilityTrusted ? "checkmark.shield.fill" : "lock.shield")
                .font(.system(size: 56)).foregroundStyle(model.accessibilityTrusted ? .green : .accentColor)
            Text(L("Allow Accessibility access")).font(.title.weight(.semibold))
            Text(L("macOS asks you to approve any app that moves windows. Tessera uses it only to position and size windows. It never captures your screen, reads documents or saves window titles."))
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            if model.accessibilityTrusted {
                Label(L("Access granted"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(L("Open Privacy & Security")) {
                    AccessibilityPermission.prompt()
                    AccessibilityPermission.openSettings()
                }
                .controlSize(.large)
                Text(L("Turn on %@ in the list, then come back here. If it's already on but nothing happens, remove it with the − button and add it again.", AppConfig.appName))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
        }
    }

    private var layout: some View {
        VStack(spacing: 18) {
            Text(L("Pick a starting layout")).font(.title.weight(.semibold))
            HStack(spacing: 12) {
                ForEach(LayoutKind.allCases) { kind in
                    Button {
                        prefs.defaultLayout = kind
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: kind.symbol).font(.system(size: 34))
                            Text(kind.title)
                        }
                        .frame(width: 110, height: 96)
                        .background(prefs.defaultLayout == kind ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            Picker(L("Windows per screen"), selection: Binding(get: { prefs.defaultCapacity }, set: { prefs.defaultCapacity = $0 })) {
                ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
            Text(L("When a screen is full, new windows stack in the tile you're using. You can change all of this later."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var shortcuts: some View {
        let center = ShortcutCenter.shared
        let rows: [(String, ShortcutAction)] = [
            (L("Swap windows"), .swapLeft),
            (L("Make primary"), .makePrimary),
            (L("Focus mode"), .focusMode),
            (L("Switch windows"), .tabView),
            (L("Turn tiling on or off"), .toggleTiling),
            (L("See every shortcut"), .cheatSheet),
        ]
        return VStack(spacing: 16) {
            Text(L("A few keys to know")).font(.title.weight(.semibold))
            VStack(spacing: 8) {
                ForEach(rows.indices, id: \.self) { index in
                    let (title, action) = rows[index]
                    HStack {
                        Text(title)
                        Spacer()
                        Text(action == .swapLeft ? L("%@ + arrows", center.resolver.prefix.modifiers.symbols) : center.label(for: action))
                            .font(.system(size: 13).monospaced())
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                    }
                    .frame(width: 380)
                }
            }
            Text(L("Hold ⌘ and drag a window onto another to swap them."))
                .font(.caption).foregroundStyle(.secondary)
            Toggle(L("Open at login"), isOn: Binding(get: { prefs.openAtLogin }, set: { prefs.openAtLogin = $0 }))
        }
    }
}
