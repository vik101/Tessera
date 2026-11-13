import AppKit
import SwiftUI
import TesseraCore

extension MainSize {
    var title: String {
        switch self {
        case .half: L("Half")
        case .sixty: L("60%")
        case .twoThirds: L("Two-thirds")
        }
    }
}

// MARK: - Layout

struct LayoutPage: View {
    private var prefs: Preferences { .shared }

    var body: some View {
        Form {
            Section {
                Picker(L("Layout"), selection: Binding(get: { prefs.defaultLayout }, set: { prefs.defaultLayout = $0; SettingsEffects.retile() })) {
                    ForEach(LayoutKind.allCases) { layout in
                        Label(layout.title, systemImage: layout.symbol).tag(layout)
                    }
                }
                Picker(L("Main window size"), selection: Binding(get: { prefs.mainSize }, set: { prefs.mainSize = $0; SettingsEffects.retile() })) {
                    ForEach(MainSize.allCases) { size in Text(size.title).tag(size) }
                }
                .pickerStyle(.segmented)
                Picker(L("Windows per screen"), selection: Binding(get: { prefs.defaultCapacity }, set: { prefs.defaultCapacity = $0; SettingsEffects.retile() })) {
                    ForEach(1...4, id: \.self) { count in Text("\(count)").tag(count) }
                }
                .pickerStyle(.segmented)
                Text(L("These set the starting choice for every screen. Changes made in the menu bar panel or with the shortcuts override them per screen."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("New windows")) {
                Picker(L("New windows go to"), selection: Binding(get: { prefs.newWindowPlacement }, set: { prefs.newWindowPlacement = $0 })) {
                    Text(L("Next free tile")).tag(NewWindowPlacement.nextFreeTile)
                    Text(L("Main tile")).tag(NewWindowPlacement.mainTile)
                }
                Picker(L("When a screen is full"), selection: Binding(get: { prefs.whenFull }, set: { prefs.whenFull = $0 })) {
                    Text(L("Stack in the active tile")).tag(WhenScreenFull.stack)
                    Text(L("Float in the middle")).tag(WhenScreenFull.float)
                }
                Picker(L("Moving into a full screen"), selection: Binding(get: { prefs.moveIntoFull }, set: { prefs.moveIntoFull = $0 })) {
                    Text(L("Swap places")).tag(MoveIntoFullScreen.swap)
                    Text(L("Stack on top")).tag(MoveIntoFullScreen.stack)
                }
            }
            Section(L("Spacing")) {
                HStack {
                    Text(L("Space between windows"))
                    Slider(value: Binding(get: { prefs.gap }, set: { prefs.gap = $0.rounded(); SettingsEffects.retile() }), in: 0...24, step: 1)
                    Text(L("%ld pt", Int(prefs.gap))).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                Text(L("The same space is kept at the screen edges.")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button(L("Use these settings on every screen")) {
                    prefs.screenPrefs.removeAll()
                    for key in TilingController.shared.visibleKeys {
                        TilingController.shared.setLayout(prefs.defaultLayout, key: key)
                        TilingController.shared.setCapacity(prefs.defaultCapacity, key: key)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Docks and bars

struct DocksPage: View {
    private var prefs: Preferences { .shared }
    @State private var screenID: String = TilingController.shared.displays.first?.stableID ?? ""

    private var displays: [DisplayInfo] { TilingController.shared.displays }

    var body: some View {
        Form {
            Section {
                if displays.count > 1 {
                    Picker(L("Screen"), selection: $screenID) {
                        ForEach(displays) { display in Text(display.name).tag(display.stableID) }
                    }
                }
                Toggle(L("Same on every screen"), isOn: Binding(get: { prefs.sameEdgesOnEveryScreen }, set: {
                    prefs.sameEdgesOnEveryScreen = $0
                    SettingsEffects.retile()
                }))
            }
            Section(L("Keep space free")) {
                edgeSlider(L("Top"), \.top)
                edgeSlider(L("Bottom"), \.bottom)
                edgeSlider(L("Left"), \.left)
                edgeSlider(L("Right"), \.right)
                Text(L("Some apps draw their own dock or bar that macOS doesn't know about. Drag the edge where the bar sits until it's visible. A blue strip marks the space. For a bar about 70 points tall, start near 80."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear { OverlayEdgePreview.shared.hide() }
    }

    private func edgeSlider(_ title: String, _ keyPath: WritableKeyPath<ReservedEdges, Double>) -> some View {
        let edges = prefs.reservedEdges(for: screenID)
        return HStack {
            Text(title).frame(width: 70, alignment: .leading)
            Slider(value: Binding(get: { edges[keyPath: keyPath] }, set: { value in
                var updated = prefs.reservedEdges(for: screenID)
                updated[keyPath: keyPath] = value.rounded()
                prefs.setReservedEdges(updated, for: screenID)
                OverlayEdgePreview.shared.show(screenID: prefs.sameEdgesOnEveryScreen ? nil : screenID)
                SettingsEffects.retile()
            }), in: 0...200, step: 1)
            Text(L("%ld pt", Int(edges[keyPath: keyPath]))).monospacedDigit().frame(width: 52, alignment: .trailing)
        }
    }
}

/// Blue strips showing reserved space while the Docks and bars sliders move.
@MainActor
final class OverlayEdgePreview {
    static let shared = OverlayEdgePreview()
    private var panels: [FloatingPanel] = []
    private var hideTask: Task<Void, Never>?

    func show(screenID: String?) {
        hide()
        let prefs = Preferences.shared
        for display in TilingController.shared.displays where screenID == nil || display.stableID == screenID {
            let edges = prefs.reservedEdges(for: display.stableID)
            let area = display.visibleFrame
            var strips: [CGRect] = []
            if edges.top > 0 { strips.append(CGRect(x: area.minX, y: area.minY, width: area.width, height: edges.top)) }
            if edges.bottom > 0 { strips.append(CGRect(x: area.minX, y: area.maxY - edges.bottom, width: area.width, height: edges.bottom)) }
            if edges.left > 0 { strips.append(CGRect(x: area.minX, y: area.minY, width: edges.left, height: area.height)) }
            if edges.right > 0 { strips.append(CGRect(x: area.maxX - edges.right, y: area.minY, width: edges.right, height: area.height)) }
            for strip in strips {
                let panel = FloatingPanel(level: .overlayHigh, ignoresMouse: true)
                let view = NSView()
                view.wantsLayer = true
                view.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.35).cgColor
                panel.contentView = view
                panel.setAXFrame(strip)
                panel.orderFrontRegardless()
                panels.append(panel)
            }
        }
        hideTask = after(1.5) { [weak self] in self?.hide() }
    }

    func hide() {
        hideTask?.cancel()
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }
}

// MARK: - Highlight

extension HighlightStyle {
    var title: String {
        switch self {
        case .none: L("None")
        case .borderOnActive: L("Border on active")
        case .borderOnAll: L("Border on all")
        case .glowOnActive: L("Glow on active")
        }
    }
}

struct HighlightPage: View {
    private var prefs: Preferences { .shared }
    @State private var customColor: Color = .orange

    var body: some View {
        Form {
            Section {
                Picker(L("Highlight"), selection: Binding(get: { prefs.highlight }, set: { style in
                    if style != .none { prefs.lastBorderStyle = style }
                    prefs.highlight = style
                    SettingsEffects.retile()
                })) {
                    ForEach(HighlightStyle.allCases) { style in Text(style.title).tag(style) }
                }
                .pickerStyle(.radioGroup)
                HStack {
                    Text(L("Border thickness"))
                    Slider(value: Binding(get: { prefs.borderThickness }, set: { prefs.borderThickness = $0.rounded(); SettingsEffects.retile() }), in: 2...6, step: 1)
                    Text(L("%ld pt", Int(prefs.borderThickness))).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                .disabled(prefs.highlight == .none || prefs.highlight == .glowOnActive)
                Text(L("Borders and glow sit in the space between windows, so they never cover what's inside. If a border is thicker than that space, the space widens to fit it."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Color")) {
                HStack(spacing: 8) {
                    swatch(.accent, color: Color(nsColor: .controlAccentColor), label: L("Accent"))
                    ForEach(HighlightColor.presets, id: \.self) { hex in
                        swatch(.custom(hex: hex), color: Color(nsColor: NSColor(hex: hex) ?? .orange), label: nil)
                    }
                    ColorPicker("", selection: Binding(get: { customColor }, set: { color in
                        customColor = color
                        prefs.highlightColor = .custom(hex: NSColor(color).hexString)
                        HighlightController.shared.refresh()
                    }), supportsOpacity: false)
                    .labelsHidden()
                }
                Text(L("Borders and the glow use the same color.")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func swatch(_ choice: HighlightColor, color: Color, label: String?) -> some View {
        Button {
            prefs.highlightColor = choice
            HighlightController.shared.refresh()
        } label: {
            VStack(spacing: 2) {
                Circle().fill(color).frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(prefs.highlightColor == choice ? Color.primary : .clear, lineWidth: 2))
                if let label { Text(label).font(.system(size: 9)) }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Focus

extension CleanSpaceBackground {
    var title: String {
        switch self {
        case .graphite: L("Graphite")
        case .mist: L("Mist")
        case .stone: L("Stone")
        }
    }
}

struct FocusPage: View {
    private var prefs: Preferences { .shared }
    private var center: ShortcutCenter { .shared }

    var body: some View {
        Form {
            Section(L("No peek mode")) {
                Toggle(L("No peek mode"), isOn: Binding(get: { prefs.noPeek }, set: { NoPeekController.shared.set($0) }))
                Text(L("Dims every window except the one you're working in, and the desktop too. Stops people nearby, or viewers of a screen share, from reading your other windows. %@", center.label(for: .noPeek)))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(L("Dim amount"))
                    Slider(value: Binding(get: { prefs.dimAmount }, set: { prefs.dimAmount = $0; NoPeekController.shared.refresh() }), in: 0.1...0.9)
                    Text("\(Int(prefs.dimAmount * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                Toggle(L("Blur other windows"), isOn: Binding(get: { prefs.blurOthers }, set: { prefs.blurOthers = $0; NoPeekController.shared.refresh() }))
            }
            Section(L("Clean Space")) {
                Text(L("Makes one screen plain for sharing or presenting. The active window fills it and everything else waits behind a plain background. %@", center.label(for: .cleanSpace)))
                    .font(.caption).foregroundStyle(.secondary)
                Picker(L("Background"), selection: Binding(get: { prefs.cleanSpaceBackground }, set: { prefs.cleanSpaceBackground = $0 })) {
                    ForEach(CleanSpaceBackground.allCases) { background in
                        let (r, g, b) = background.rgb
                        HStack {
                            RoundedRectangle(cornerRadius: 3).fill(Color(red: r, green: g, blue: b)).frame(width: 18, height: 12)
                            Text(background.title)
                        }
                        .tag(background)
                    }
                }
            }
            Section(L("Focus mode")) {
                Text(L("The active window fills its screen, inside the usual gaps. It ends when you press the shortcut again, switch windows on that screen, open a window there, change layout, or drag the window. %@", center.label(for: .focusMode)))
                    .font(.caption).foregroundStyle(.secondary)
                Button(TilingController.shared.focusMode == nil ? L("Focus the active window") : L("Exit focus")) {
                    TilingController.shared.toggleFocusMode()
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Mouse

struct MousePage: View {
    private var prefs: Preferences { .shared }

    var body: some View {
        Form {
            Section {
                Toggle(L("Quick actions above windows"), isOn: Binding(get: { prefs.quickActions }, set: {
                    prefs.quickActions = $0
                    PointerTracker.shared.update()
                    HoverBarController.shared.refresh()
                }))
                Text(L("Rest the pointer on the grip just above the active window to open a bar with Primary, Focus, Next screen and Float. Hold ⌥ for Always float."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L("Activate windows on hover"), isOn: Binding(get: { prefs.hoverFocus }, set: {
                    prefs.hoverFocus = $0
                    PointerTracker.shared.update()
                }))
                Text(L("A tiled window activates when the pointer rests on it. After a key press, the pointer must move first, so typing is never interrupted."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Always available")) {
                LabeledContent(L("Swap two windows"), value: L("Hold ⌘ and drag"))
                LabeledContent(L("Add a window to a stack"), value: L("Hold ⌥⌘ and drag"))
                LabeledContent(L("Resize"), value: L("Drag the edge between windows"))
                LabeledContent(L("Move to another screen"), value: L("Drag a window onto it"))
            }
        }
        .formStyle(.grouped)
    }
}
