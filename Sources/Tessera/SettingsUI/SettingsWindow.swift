import AppKit
import SwiftUI
import TesseraCore

enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case overview, general, layout, docks, highlight, focus, mouse, keyboard, apps, setups, activity, license, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: L("What Tessera can do")
        case .general: L("General")
        case .layout: L("Layout")
        case .docks: L("Docks and bars")
        case .highlight: L("Highlight")
        case .focus: L("Focus")
        case .mouse: L("Mouse")
        case .keyboard: L("Keyboard")
        case .apps: L("Apps")
        case .setups: L("Setups")
        case .activity: L("Activity")
        case .license: L("License")
        case .about: L("About")
        }
    }

    var symbol: String {
        switch self {
        case .overview: "sparkles"
        case .general: "gearshape"
        case .layout: "square.grid.2x2"
        case .docks: "dock.rectangle"
        case .highlight: "square.dashed"
        case .focus: "eye.slash"
        case .mouse: "computermouse"
        case .keyboard: "keyboard"
        case .apps: "app.badge"
        case .setups: "rectangle.3.group"
        case .activity: "chart.bar"
        case .license: "key"
        case .about: "info.circle"
        }
    }

    /// Each page explains its purpose in one line.
    var subtitle: String {
        switch self {
        case .overview: L("Every feature, with its shortcut.")
        case .general: L("Start-up, looks, language and updates.")
        case .layout: L("How windows share each screen.")
        case .docks: L("Keep room for another app's dock or bar.")
        case .highlight: L("Make the active window easy to spot.")
        case .focus: L("Tools for working on one thing, or sharing your screen.")
        case .mouse: L("What the pointer can do.")
        case .keyboard: L("Change any shortcut, or turn it off.")
        case .apps: L("Apps and windows Tessera leaves alone.")
        case .setups: L("Saved arrangements of your work apps.")
        case .activity: L("Simple counts, kept only on this Mac.")
        case .license: L("Your license and this Mac.")
        case .about: L("Version, updates and feedback.")
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    var page: SettingsPage = .overview
}

/// The Settings window. While it's open, Tessera shows in the Dock and ⌘-Tab.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private let navigation = SettingsNavigation()

    func show(page: SettingsPage? = nil) {
        if let page { navigation.page = page }
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView(navigation: navigation))
            let window = NSWindow(contentViewController: controller)
            window.title = L("%@ Settings", AppConfig.appName)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 820, height: 600))
            window.minSize = NSSize(width: 720, height: 480)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        AppIconStyle.apply(Preferences.shared.appIcon)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        OverlayEdgePreview.shared.hide()
        if !OnboardingWindowController.shared.isVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

struct SettingsView: View {
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: Binding<SettingsPage?>(
                get: { navigation.page },
                set: { if let page = $0 { navigation.page = page } }
            )) { page in
                Label(page.title, systemImage: page.symbol).tag(page)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(navigation.page.title).font(.title2.weight(.semibold))
                    Text(navigation.page.subtitle).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 4)
                page(navigation.page)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder private func page(_ page: SettingsPage) -> some View {
        switch page {
        case .overview: OverviewPage()
        case .general: GeneralPage()
        case .layout: LayoutPage()
        case .docks: DocksPage()
        case .highlight: HighlightPage()
        case .focus: FocusPage()
        case .mouse: MousePage()
        case .keyboard: KeyboardPage()
        case .apps: AppsPage()
        case .setups: SetupsPage()
        case .activity: ActivityPage()
        case .license: LicensePage()
        case .about: AboutPage()
        }
    }
}

/// Re-applies layout after a setting changes, without hammering on every slider tick.
@MainActor
enum SettingsEffects {
    private static let debouncer = Debouncer(delay: 0.12)

    static func retile() {
        debouncer.schedule { TilingController.shared.reconcileAll() }
    }
}

// MARK: - Overview

struct OverviewPage: View {
    private struct Feature: Identifiable {
        let symbol: String
        let name: String
        let detail: String
        let action: ShortcutAction?
        var id: String { name }
    }

    private struct FeatureGroup: Identifiable {
        let title: String
        let features: [Feature]
        var id: String { title }
    }

    private var groups: [FeatureGroup] {
        [
            FeatureGroup(title: L("Arrange"), features: [
                Feature(symbol: "square.grid.2x2", name: L("Automatic tiling"), detail: L("Windows place themselves as they open. Closing one lets the rest fill the space."), action: .toggleTiling),
                Feature(symbol: "rectangle.split.3x1", name: L("Four layouts"), detail: L("Grid, Columns, Rows and Side, set per screen."), action: .layoutGrid),
                Feature(symbol: "square.stack", name: L("Stacks"), detail: L("When a screen is full, new windows wait in the tile you're using."), action: .stackNext),
                Feature(symbol: "arrow.left.arrow.right", name: L("Swap"), detail: L("Hold ⌘ and drag a window onto another, or use the arrow keys."), action: .swapRight),
                Feature(symbol: "arrow.up.left.and.arrow.down.right", name: L("Resize"), detail: L("Drag the edge between windows, or grow and shrink with the keyboard."), action: .grow),
                Feature(symbol: "rectangle.3.group", name: L("Setups"), detail: L("Save the apps you work with and open them all, arranged, in one click."), action: nil),
            ]),
            FeatureGroup(title: L("Focus"), features: [
                Feature(symbol: "viewfinder", name: L("Focus mode"), detail: L("The active window fills its screen. Press again to restore."), action: .focusMode),
                Feature(symbol: "eye.slash", name: L("No peek mode"), detail: L("Dims and blurs every other window."), action: .noPeek),
                Feature(symbol: "rectangle.dashed", name: L("Clean Space"), detail: L("One window on a plain background, for sharing or presenting."), action: .cleanSpace),
                Feature(symbol: "square.dashed", name: L("Borders and glow"), detail: L("Make the active window easy to spot."), action: nil),
            ]),
            FeatureGroup(title: L("Get around"), features: [
                Feature(symbol: "rectangle.on.rectangle", name: L("Tab View"), detail: L("Switch between windows, laid out screen by screen."), action: .tabView),
                Feature(symbol: "cursorarrow.rays", name: L("Hover focus"), detail: L("A window activates when the pointer rests on it."), action: nil),
                Feature(symbol: "ellipsis.rectangle", name: L("Quick actions"), detail: L("Rest on the grip above a window for Primary, Focus, Move and Float."), action: nil),
                Feature(symbol: "display.2", name: L("Multiple displays"), detail: L("Each screen has its own layout. Arrow keys move windows across."), action: .swapRight),
                Feature(symbol: "keyboard", name: L("Cheat sheet"), detail: L("See every shortcut from any app."), action: .cheatSheet),
            ]),
        ]
    }

    var body: some View {
        Form {
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.features) { feature in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: feature.symbol).font(.system(size: 18)).frame(width: 28).foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feature.name).font(.system(size: 13, weight: .semibold))
                                Text(feature.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let action = feature.action {
                                Text(ShortcutCenter.shared.label(for: action)).font(.system(size: 12).monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - General

struct GeneralPage: View {
    private var prefs: Preferences { .shared }
    private var model: AppModel { .shared }
    @State private var languageChanged = false

    var body: some View {
        Form {
            Section {
                Toggle(L("Automatic tiling"), isOn: Binding(get: { prefs.automaticTiling }, set: { AppActions.setAutomaticTiling($0) }))
                Toggle(L("Open at login"), isOn: Binding(get: { prefs.openAtLogin }, set: { prefs.openAtLogin = $0; LaunchAtLogin.set($0) }))
            }
            Section(L("Appearance")) {
                Picker(L("Light or dark"), selection: Binding(get: { prefs.appearance }, set: { prefs.appearance = $0; AppAppearance.apply($0) })) {
                    Text(L("Match the Mac")).tag(AppearanceChoice.matchMac)
                    Text(L("Light")).tag(AppearanceChoice.light)
                    Text(L("Dark")).tag(AppearanceChoice.dark)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("App icon"))
                    HStack(spacing: 10) {
                        ForEach(AppIconStyle.allCases) { style in
                            Button {
                                prefs.appIcon = style.rawValue
                                AppIconStyle.apply(style.rawValue)
                            } label: {
                                VStack(spacing: 4) {
                                    Image(nsImage: style.image(size: 96)).resizable().frame(width: 52, height: 52)
                                    Text(style.title).font(.system(size: 10))
                                }
                                .padding(4)
                                .background(prefs.appIcon == style.rawValue ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Section(L("Accessibility access")) {
                HStack {
                    Image(systemName: model.accessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.accessibilityTrusted ? .green : .orange)
                    Text(model.accessibilityTrusted ? L("Granted. Tessera can arrange windows.") : L("Needed to move and resize windows."))
                    Spacer()
                    if !model.accessibilityTrusted {
                        Button(L("Grant Access")) {
                            AccessibilityPermission.prompt()
                            AccessibilityPermission.openSettings()
                        }
                    }
                }
            }
            Section(L("Updates")) {
                Toggle(L("Check for updates automatically"), isOn: Binding(get: { prefs.checkForUpdatesAutomatically }, set: {
                    prefs.checkForUpdatesAutomatically = $0
                    UpdateController.shared.setAutomatic($0)
                }))
                .disabled(!UpdateController.shared.isAvailable)
                if !UpdateController.shared.isAvailable {
                    Text(L("Updates are off in this build.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L("Language")) {
                Picker(L("Language"), selection: Binding(get: { prefs.language }, set: {
                    prefs.language = $0
                    AppLanguage.apply($0)
                    languageChanged = true
                })) {
                    ForEach(LanguageChoice.allCases) { choice in
                        Text(choice == .system ? L("System") : choice.nativeName).tag(choice)
                    }
                }
                if languageChanged {
                    HStack {
                        Text(L("Restart Tessera to use the new language.")).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Restart Now")) { AppLanguage.relaunch() }
                    }
                }
            }
            Section(L("Welcome tour")) {
                Button(L("Open Tour")) { OnboardingWindowController.shared.show() }
            }
        }
        .formStyle(.grouped)
    }
}

/// Light, dark, or match the Mac — independent of the system setting.
@MainActor
enum AppAppearance {
    static func apply(_ choice: AppearanceChoice) {
        switch choice {
        case .matchMac: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// Language override, applied at the next launch.
@MainActor
enum AppLanguage {
    static func apply(_ choice: LanguageChoice) {
        if choice == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([choice.rawValue], forKey: "AppleLanguages")
        }
    }

    static func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
