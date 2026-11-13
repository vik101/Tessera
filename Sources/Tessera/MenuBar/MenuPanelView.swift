import AppKit
import SwiftUI
import TesseraCore

/// The menu bar panel: status, layout for this screen, quick switches, modes and setups.
struct MenuPanelView: View {
    let onClose: @MainActor () -> Void

    private var prefs: Preferences { .shared }
    private var model: AppModel { .shared }
    private var tiling: TilingController { .shared }
    @State private var savingSetup = false
    @State private var setupName = ""

    private var key: String? { StatusItemController.shared.panelKey ?? tiling.keyUnderPointer }
    private var display: DisplayInfo? { key.flatMap { tiling.display(forKey: $0) } }

    var body: some View {
        let _ = model.layoutRevision
        VStack(alignment: .leading, spacing: 12) {
            header
            cards
            if model.canArrange || model.status == .off {
                Divider()
                layoutSection
                Divider()
                switches
                Divider()
                modes
                Divider()
                setups
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        .background(VisualEffectBackground(material: .menu, blending: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(nsColor: model.status.color)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(AppConfig.appName).font(.system(size: 13, weight: .semibold))
                Text(model.status.message).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { prefs.automaticTiling },
                set: { AppActions.setAutomaticTiling($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .help(L("Automatic tiling"))
        }
    }

    // MARK: Cards

    @ViewBuilder private var cards: some View {
        switch model.status {
        case .needsAccessibility:
            PanelCard(text: L("Tessera needs Accessibility access to move windows."), button: L("Grant Access")) {
                AccessibilityPermission.prompt()
                AccessibilityPermission.openSettings()
            }
        case .needsLicense:
            PanelCard(text: L("Your free trial has ended."), button: L("Activate")) {
                onClose()
                SettingsWindowController.shared.show(page: .license)
            }
        case .waitingForSetup:
            PanelCard(text: L("Finish the welcome tour to start tiling."), button: L("Continue")) {
                onClose()
                OnboardingWindowController.shared.show()
            }
        default:
            EmptyView()
        }
        if model.secureInputOn {
            PanelCard(text: L("Shortcuts are paused while a password field or another app uses Secure Input."), button: nil) {}
        }
        if model.shortcutRegistrationFailed {
            PanelCard(text: L("Some shortcuts are used by another app."), button: L("Review")) {
                onClose()
                SettingsWindowController.shared.show(page: .keyboard)
            }
        }
        if case .trial(let remaining) = model.licenseState {
            Text(L("Free trial: %ld hours left", Int(remaining / 3600))).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    // MARK: Layout

    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let key, let display {
                LayoutPreviewView(key: key, display: display)
                    .frame(height: 120)
                    .overlay(alignment: .bottomTrailing) {
                        if tiling.hasCustomSizes(key: key) {
                            Button(L("Reset sizes")) { tiling.resetSizes(key: key) }
                                .controlSize(.small)
                                .padding(6)
                        }
                    }
                let state = tiling.stateOrDefault(forKey: key)
                HStack(spacing: 6) {
                    ForEach(LayoutKind.allCases) { layout in
                        let available = display.shape.availableLayouts.contains(layout)
                        Button {
                            tiling.setLayout(layout, key: key)
                        } label: {
                            Image(systemName: layout.symbol)
                                .font(.system(size: 15))
                                .frame(maxWidth: .infinity, minHeight: 28)
                                .background(state?.layout == layout ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(!available)
                        .help(available ? layout.title : L("Columns isn't offered on tall screens."))
                    }
                }
                countPicker(key: key, display: display, state: state)
            }
        }
    }

    private func countPicker(key: String, display: DisplayInfo, state: ScreenState?) -> some View {
        let layout = state?.layout ?? .grid
        let allowed = LayoutEngine.allowedCounts(
            layout: layout,
            shape: display.shape,
            area: tiling.usableArea(display),
            gap: prefs.effectiveGap,
            mainSize: prefs.mainSize
        )
        let maxShown = display.shape == .landscape ? 4 : 5
        return VStack(alignment: .leading, spacing: 4) {
            Text(L("Windows on this screen")).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(1...maxShown, id: \.self) { count in
                    let ok = allowed[count] ?? false || (count == 5 && display.shape != .landscape)
                    Button {
                        tiling.setCapacity(count, key: key)
                    } label: {
                        Text("\(count)")
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .background(state?.capacity == count ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(!ok)
                    .help(ok ? L("Tile up to %ld windows", count) : L("Too small for %ld windows in this layout", count))
                }
            }
        }
    }

    // MARK: Switches

    private var switches: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    tiling.retile()
                } label: {
                    Label(L("Retile"), systemImage: "arrow.triangle.2.circlepath")
                }
                .help(ShortcutCenter.shared.label(for: .retile))
                Spacer()
            }
            Toggle(L("Borders"), isOn: Binding(
                get: { prefs.highlight != .none },
                set: { on in
                    if on {
                        prefs.highlight = prefs.lastBorderStyle == .none ? .borderOnAll : prefs.lastBorderStyle
                    } else {
                        if prefs.highlight != .none { prefs.lastBorderStyle = prefs.highlight }
                        prefs.highlight = .none
                    }
                    TilingController.shared.reconcileAll()
                }
            ))
            Toggle(L("Hover focus"), isOn: Binding(
                get: { prefs.hoverFocus },
                set: { prefs.hoverFocus = $0; PointerTracker.shared.update() }
            ))
            if let name = model.frontAppName, let bundleID = model.frontAppBundleID {
                Toggle(L("Tile %@", name), isOn: Binding(
                    get: { !prefs.isExcluded(bundleID) },
                    set: { tile in
                        prefs.setExcluded(bundleID, name: name, excluded: !tile)
                        TilingController.shared.reconcileAll()
                    }
                ))
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    // MARK: Modes

    private var modes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L("No peek mode"), isOn: Binding(get: { prefs.noPeek }, set: { NoPeekController.shared.set($0) }))
            if prefs.noPeek {
                HStack {
                    Image(systemName: "sun.min")
                    Slider(value: Binding(get: { prefs.dimAmount }, set: { prefs.dimAmount = $0; NoPeekController.shared.refresh() }), in: 0.1...0.9)
                    Image(systemName: "moon.fill")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Toggle(L("Clean Space"), isOn: Binding(get: { model.cleanSpaceOn }, set: { _ in AppActions.toggleCleanSpace() }))
                .disabled(!model.licenseState.hasFullVersion)
            Toggle(L("Focus mode"), isOn: Binding(get: { model.focusModeActive }, set: { _ in tiling.toggleFocusMode() }))
                .disabled(tiling.focusedTiledWindow == nil && !model.focusModeActive)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    // MARK: Setups

    private var setups: some View {
        let runner = SetupRunner.shared
        let store = SetupStore.shared
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(L("Setups")).font(.system(size: 12, weight: .semibold))
                Text(L("Beta")).font(.system(size: 9, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.2), in: Capsule())
                if runner.hasUnsavedArrangement {
                    Circle().fill(Color.blue).frame(width: 7, height: 7).help(L("Your tiled apps aren't saved as a setup yet."))
                }
                Spacer()
                if let last = runner.lastSetup {
                    Text(last.name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            ForEach(store.setups) { setup in
                HStack {
                    Button(setup.name) {
                        onClose()
                        runner.open(setup)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    switch runner.status(of: setup) {
                    case .onScreen:
                        Text(L("ON SCREEN")).font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
                    case .changed:
                        Text(L("CHANGED")).font(.system(size: 9, weight: .bold)).foregroundStyle(.orange)
                        Button(L("Put Back")) { runner.open(setup) }.controlSize(.mini)
                        Button(L("Update")) { runner.updateFromScreen(setup) }.controlSize(.mini)
                    case .idle:
                        if let shortcut = setup.shortcut { Text(shortcut.description).font(.system(size: 11)).foregroundStyle(.secondary) }
                    }
                }
                .font(.system(size: 12))
            }
            if savingSetup {
                HStack {
                    TextField(L("Name"), text: $setupName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveSetup)
                    Button(L("Save"), action: saveSetup).disabled(setupName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)
            } else {
                Button(L("Save this arrangement as a setup…")) {
                    setupName = ""
                    savingSetup = true
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
                .disabled(!model.licenseState.hasFullVersion)
            }
        }
    }

    private func saveSetup() {
        let name = setupName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        SetupRunner.shared.saveCurrent(named: name)
        savingSetup = false
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button(L("Settings…")) {
                onClose()
                SettingsWindowController.shared.show()
            }
            .keyboardShortcut(",", modifiers: .command)
            Button(L("Shortcuts")) {
                onClose()
                CheatSheetController.shared.show()
            }
            .overlay(alignment: .topTrailing) {
                if model.shortcutRegistrationFailed {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 9)).offset(x: 4, y: -4)
                }
            }
            Spacer()
            Button(L("Quit %@", AppConfig.appName)) { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
    }
}

private struct PanelCard: View {
    let text: String
    let button: String?
    let action: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let button {
                Button(button) { action() }.controlSize(.small).buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A miniature of one screen, with each tiled window's app icon in its spot.
struct LayoutPreviewView: View {
    let key: String
    let display: DisplayInfo
    private var tiling: TilingController { .shared }

    var body: some View {
        let _ = AppModel.shared.layoutRevision
        GeometryReader { geometry in
            let screen = display.frame
            let scale = min(geometry.size.width / screen.width, geometry.size.height / screen.height)
            let width = screen.width * scale
            let height = screen.height * scale
            let originX = (geometry.size.width - width) / 2
            let focus = tiling.focusMode
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07))
                    .frame(width: width, height: height)
                ForEach(tiling.preview(for: key)) { entry in
                    let rect = CGRect(
                        x: (entry.frame.minX - screen.minX) * scale,
                        y: (entry.frame.minY - screen.minY) * scale,
                        width: entry.frame.width * scale,
                        height: entry.frame.height * scale
                    )
                    let showing = entry.windows.last
                    let isActive = showing.map { $0.id == tiling.focusedID } ?? false
                    let dimmed = focus != nil && focus?.window != showing?.id
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.12))
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(isActive ? Color.accentColor : .clear, lineWidth: 2)
                        if let window = showing {
                            Image(nsImage: AppIcons.icon(bundleID: window.bundleID, pid: window.pid))
                                .resizable()
                                .frame(width: min(28, rect.height * 0.6), height: min(28, rect.height * 0.6))
                        }
                        if entry.windows.count > 1 {
                            Text("\(entry.windows.count)")
                                .font(.system(size: 9, weight: .bold))
                                .padding(3)
                                .background(Color.orange, in: Circle())
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                .padding(3)
                        }
                        if focus?.window == showing?.id, focus != nil {
                            Text(L("Focus")).font(.system(size: 9, weight: .bold)).padding(3)
                                .background(Color.accentColor, in: Capsule())
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                                .padding(3)
                        }
                    }
                    .opacity(dimmed ? 0.4 : 1)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                }
            }
            .offset(x: originX)
        }
    }
}
