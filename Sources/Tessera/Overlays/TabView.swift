import AppKit
import Carbon.HIToolbox
import SwiftUI
import TesseraCore

/// Tab View: switch between individual windows, laid out screen by screen.
@MainActor
@Observable
final class TabSwitcherModel {
    struct Item: Identifiable {
        let id: CGWindowID
        let appName: String
        let title: String
        let icon: NSImage
        /// Position inside its screen, 0–1.
        let unitFrame: CGRect
        /// Real frame, for arrow-key navigation (minimized windows get a row below their screen).
        let navFrame: CGRect
        let minimized: Bool
    }

    struct ScreenGroup: Identifiable {
        let id: String
        let name: String
        let aspect: CGFloat
        var items: [Item]
        var minimized: [Item]
    }

    var groups: [ScreenGroup] = []
    var selected: CGWindowID?

    var allItems: [Item] { groups.flatMap { $0.items + $0.minimized } }
}

@MainActor
final class TabViewController {
    static let shared = TabViewController()

    private let model = TabSwitcherModel()
    private var panel: FloatingPanel?
    private var order: [CGWindowID] = []
    private var tokens: [HotKeyCenter.Token] = []
    private var monitors: [Any] = []
    private var holdModifiers: Modifiers = [.option]
    private var tiling: TilingController { .shared }

    var isOpen: Bool { panel != nil }

    func open(backward: Bool) {
        guard AppModel.shared.accessibilityTrusted else { return }
        if isOpen {
            step(backward ? -1 : 1)
            return
        }
        collect()
        guard !order.isEmpty else { return }
        // The window you used before the current one is selected first.
        let start = order.count > 1 ? 1 : 0
        model.selected = backward ? order.last : order[start]
        holdModifiers = ShortcutCenter.shared.resolver.combo(for: .tabView)?.modifiers ?? [.option]

        // A quick tap (keys already released) switches straight away.
        guard holdIsDown else {
            commit()
            return
        }
        show()
    }

    private var holdIsDown: Bool {
        let flags = NSEvent.modifierFlags
        var held: Modifiers = []
        if flags.contains(.control) { held.insert(.control) }
        if flags.contains(.option) { held.insert(.option) }
        if flags.contains(.command) { held.insert(.command) }
        let needed = holdModifiers.subtracting(.shift)
        return !needed.isEmpty && held.isSuperset(of: needed)
    }

    // MARK: Collecting windows

    private func collect() {
        let registry = tiling.registry
        let visible = WindowServer.onScreenIDs()
        let displays = tiling.displays
        var candidates: [TrackedWindow] = []
        for window in registry.windows.values {
            let element = window.element
            guard element.subrole == kAXStandardWindowSubrole else { continue }
            if let app = registry.app(window.pid), app.isHidden { continue }
            if visible.contains(window.id) || element.isMinimized { candidates.append(window) }
        }
        // Most recently used first.
        let recent = tiling.recent
        candidates.sort { a, b in
            let ia = recent.firstIndex(of: a.id) ?? Int.max
            let ib = recent.firstIndex(of: b.id) ?? Int.max
            return ia == ib ? a.id > b.id : ia < ib
        }
        order = candidates.map(\.id)

        var groups: [String: TabSwitcherModel.ScreenGroup] = [:]
        var minimizedCount: [String: Int] = [:]
        for window in candidates {
            guard let frame = window.frame, let display = Screens.display(for: frame, in: displays) else { continue }
            let screen = display.frame
            var group = groups[display.stableID] ?? TabSwitcherModel.ScreenGroup(
                id: display.stableID, name: display.name, aspect: screen.width / max(1, screen.height), items: [], minimized: []
            )
            // Titles are read only while Tab View is open, never saved.
            let minimized = window.element.isMinimized
            let unit = CGRect(
                x: (frame.minX - screen.minX) / screen.width,
                y: (frame.minY - screen.minY) / screen.height,
                width: frame.width / screen.width,
                height: frame.height / screen.height
            )
            var nav = frame
            if minimized {
                let index = minimizedCount[display.stableID, default: 0]
                minimizedCount[display.stableID] = index + 1
                nav = CGRect(x: screen.minX + CGFloat(index) * 160, y: screen.maxY + 20, width: 150, height: 60)
            }
            let item = TabSwitcherModel.Item(
                id: window.id,
                appName: window.appName,
                title: window.title,
                icon: AppIcons.icon(bundleID: window.bundleID, pid: window.pid),
                unitFrame: unit,
                navFrame: nav,
                minimized: minimized
            )
            if minimized { group.minimized.append(item) } else { group.items.append(item) }
            groups[display.stableID] = group
        }
        let arrangement = Navigation.arrangementOrder(Dictionary(uniqueKeysWithValues: displays.map { ($0.stableID, $0.frame) }))
        model.groups = arrangement.compactMap { groups[$0] }
    }

    // MARK: Showing

    private func show() {
        let view = TabSwitcherView(model: model) { [weak self] id in
            self?.model.selected = id
            self?.commit()
        }
        let (panel, host) = makeHostingPanel(view, level: .overlayHigh, interactive: true)
        let size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        self.panel = panel

        let hold = holdModifiers.subtracting(.shift)
        tokens = ShortcutCenter.shared.claimTemporary([
            (KeyCombo(KeyCode.leftArrow, hold), { [weak self] in self?.arrow(.left) }),
            (KeyCombo(KeyCode.rightArrow, hold), { [weak self] in self?.arrow(.right) }),
            (KeyCombo(KeyCode.upArrow, hold), { [weak self] in self?.arrow(.up) }),
            (KeyCombo(KeyCode.downArrow, hold), { [weak self] in self?.arrow(.down) }),
            (KeyCombo(KeyCode.escape, hold), { [weak self] in self?.cancel() }),
            (KeyCombo(KeyCode.escape, []), { [weak self] in self?.cancel() }),
            (KeyCombo(KeyCode.returnKey, hold), { [weak self] in self?.commit() }),
            (KeyCombo(KeyCode.returnKey, []), { [weak self] in self?.commit() }),
        ])
        let released: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isOpen, !self.holdIsDown else { return }
                self.commit()
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: released) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in released(event); return event }) {
            monitors.append(local)
        }
    }

    private func close() {
        panel?.orderOut(nil)
        panel = nil
        ShortcutCenter.shared.releaseTemporary(tokens)
        tokens.removeAll()
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func step(_ delta: Int) {
        guard !order.isEmpty else { return }
        let current = model.selected.flatMap { order.firstIndex(of: $0) } ?? 0
        model.selected = order[(current + delta + order.count) % order.count]
    }

    private func arrow(_ direction: Direction) {
        let items = model.allItems
        guard let selected = model.selected, let source = items.first(where: { $0.id == selected })?.navFrame else { return }
        var frames: [CGWindowID: CGRect] = [:]
        for item in items where item.id != selected { frames[item.id] = item.navFrame }
        if let next = Navigation.neighbor(of: source, direction: direction, among: frames) { model.selected = next }
    }

    private func cancel() { close() }

    private func commit() {
        let target = model.selected
        close()
        guard let target, let window = tiling.registry.window(target) else { return }
        if window.element.isMinimized { window.element.set(kAXMinimizedAttribute, bool: false) }
        tiling.applier.focus(window)
        Preferences.shared.count(\.tabViewSwitches)
    }
}

// MARK: - Views

struct TabSwitcherView: View {
    @Bindable var model: TabSwitcherModel
    let onPick: @MainActor (CGWindowID) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            ForEach(model.groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    screenBox(group)
                    if !group.minimized.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(group.minimized) { item in card(item, compact: true) }
                        }
                    }
                }
            }
        }
        .padding(22)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.12)))
        .padding(10)
        .fixedSize()
    }

    private func screenBox(_ group: TabSwitcherModel.ScreenGroup) -> some View {
        let height: CGFloat = 300
        let width = min(640, height * group.aspect)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06))
            ForEach(group.items) { item in
                card(item, compact: false)
                    .frame(width: max(90, item.unitFrame.width * width - 6), height: max(60, item.unitFrame.height * (width / group.aspect) - 6))
                    .offset(x: item.unitFrame.minX * width + 3, y: item.unitFrame.minY * (width / group.aspect) + 3)
            }
        }
        .frame(width: width, height: width / group.aspect)
    }

    private func card(_ item: TabSwitcherModel.Item, compact: Bool) -> some View {
        let selected = model.selected == item.id
        return VStack(spacing: 4) {
            Image(nsImage: item.icon).resizable().frame(width: compact ? 22 : 34, height: compact ? 22 : 34)
            Text(item.appName).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            if !compact && !item.title.isEmpty {
                Text(item.title).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(width: compact ? 120 : nil)
        .background(selected ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture { onPick(item.id) }
    }
}

// MARK: - Cheat sheet

/// Every Tessera shortcut, including custom keys. ⌃⌥/ from any app; Esc or a click closes it.
@MainActor
final class CheatSheetController {
    static let shared = CheatSheetController()

    private var panel: FloatingPanel?
    private var tokens: [HotKeyCenter.Token] = []
    private var monitor: Any?

    func toggle() {
        panel == nil ? show() : close()
    }

    func show() {
        let view = CheatSheetView()
        let (panel, host) = makeHostingPanel(view, level: .overlayHigh, interactive: true)
        let size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        tokens = ShortcutCenter.shared.claimTemporary([
            (KeyCombo(KeyCode.escape, []), { [weak self] in self?.close() }),
        ])
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        ShortcutCenter.shared.releaseTemporary(tokens)
        tokens.removeAll()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

struct CheatSheetView: View {
    private let center = ShortcutCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Keyboard shortcuts")).font(.system(size: 17, weight: .semibold))
            HStack(alignment: .top, spacing: 28) {
                column([.general, .move, .activate])
                column([.size, .layout, .more])
            }
            Text(L("Press Esc or click anywhere to close."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(24)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.12)))
        .padding(10)
        .fixedSize()
    }

    private func column(_ groups: [ShortcutGroup]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 5) {
                    Text(group.title.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    ForEach(ShortcutAction.allCases.filter { $0.group == group }) { action in
                        HStack {
                            Text(action.title).font(.system(size: 12))
                            Spacer(minLength: 16)
                            let label = center.label(for: action)
                            Text(label.isEmpty ? L("Off") : label)
                                .font(.system(size: 12, design: .rounded).monospaced())
                                .foregroundStyle(label.isEmpty ? .tertiary : .primary)
                        }
                        .frame(width: 330)
                    }
                }
            }
        }
    }
}
