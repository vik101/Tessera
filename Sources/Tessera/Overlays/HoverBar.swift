import AppKit
import SwiftUI
import TesseraCore

/// What the hover bar shows.
@MainActor
@Observable
final class HoverBarModel {
    struct StackItem: Identifiable {
        let id: CGWindowID
        let appName: String
        let icon: NSImage
        let isShowing: Bool
    }

    var windowID: CGWindowID = 0
    var isFocusMode = false
    var isFloating = false
    var optionHeld = false
    struct ScreenRoom: Identifiable {
        let display: DisplayInfo
        let free: Int
        var id: String { display.stableID }
    }

    var stack: [StackItem] = []
    var screens: [ScreenRoom] = []
}

/// The grip above the active window, the quick-action bar it opens,
/// and the orange marks above stacked tiles.
@MainActor
final class HoverBarController {
    static let shared = HoverBarController()

    private let prefs = Preferences.shared
    private var tiling: TilingController { .shared }

    private var gripPanel: FloatingPanel?
    private var gripHost: FirstMouseHostingView<GripView>?
    private var gripRect: CGRect = .null
    private var barPanel: FloatingPanel?
    private var barRect: CGRect = .null
    private let model = HoverBarModel()
    private var dotPanels: [String: FloatingPanel] = [:]
    private var dotSignatures: [String: String] = [:]
    private var dwellTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var flagsMonitor: Any?
    private var barHovered = false

    // MARK: Refresh

    func refresh() {
        guard prefs.quickActions, tiling.isActive, !CleanSpaceController.shared.isOn,
              let id = tiling.focusedTiledWindow, let frame = tiling.tileFrame(of: id) else {
            hideAll()
            return
        }
        if barPanel != nil, model.windowID != id { hideBar() }
        showGrip(for: id, frame: frame)
        refreshDots(except: id)
    }

    private func hideAll() {
        gripPanel?.orderOut(nil)
        gripRect = .null
        hideBar()
        for (_, panel) in dotPanels { panel.orderOut(nil) }
        dotPanels.removeAll()
        dotSignatures.removeAll()
    }

    // MARK: Grip

    private func stackItems(for id: CGWindowID) -> [HoverBarModel.StackItem] {
        guard let key = tiling.keyOf(id), let state = tiling.state(forKey: key), let index = state.tileIndex(of: id) else { return [] }
        let tile = state.tiles[index]
        guard tile.isStack else { return [] }
        return tile.windows.compactMap { wid in
            guard let window = tiling.registry.window(wid) else { return nil }
            return HoverBarModel.StackItem(id: wid, appName: window.appName, icon: AppIcons.icon(bundleID: window.bundleID, pid: window.pid), isShowing: wid == tile.showing)
        }
    }

    private func showGrip(for id: CGWindowID, frame: CGRect) {
        let items = stackItems(for: id)
        let view = GripView(segments: items.map(\.isShowing), onTapSegment: { [weak self] index in
            guard let self, items.indices.contains(index) else { return }
            self.tiling.show(items[index].id)
        }, onHover: { [weak self] inside in
            if inside { self?.beginDwell() }
        })
        let width: CGFloat = items.isEmpty ? 56 : CGFloat(items.count) * 16 + 24
        let height: CGFloat = 12
        let gap = max(CGFloat(prefs.effectiveGap), 6)
        let rect = CGRect(x: frame.midX - width / 2, y: frame.minY - gap / 2 - height / 2, width: width, height: height)
        let panel: FloatingPanel
        if let gripPanel, let gripHost {
            panel = gripPanel
            gripHost.rootView = view
        } else {
            let made = makeHostingPanel(view, level: .overlayLow, interactive: true)
            panel = made.0
            gripPanel = made.0
            gripHost = made.1
        }
        // A plain grip lets clicks through; a stack grip has clickable segments.
        panel.ignoresMouseEvents = items.isEmpty
        panel.setAXFrame(rect)
        panel.orderFrontRegardless()
        gripRect = rect
    }

    /// Orange dots in the gap above stacked tiles that aren't active.
    private func refreshDots(except active: CGWindowID) {
        var wanted: [String: (frame: CGRect, windows: [CGWindowID])] = [:]
        for key in tiling.visibleKeys {
            guard let state = tiling.state(forKey: key), let frames = tiling.frames[key] else { continue }
            for (index, tile) in state.tiles.enumerated() where tile.isStack && !tile.windows.contains(active) {
                guard let frame = frames[index] else { continue }
                wanted["\(key)/\(index)"] = (frame, tile.windows)
            }
        }
        for (id, panel) in dotPanels {
            let signature = wanted[id].map { "\($0.frame)\($0.windows)" }
            if signature == nil || signature != dotSignatures[id] {
                panel.orderOut(nil)
                dotPanels.removeValue(forKey: id)
                dotSignatures.removeValue(forKey: id)
            }
        }
        for (id, entry) in wanted where dotPanels[id] == nil {
            let windows = entry.windows
            let view = StackDotsView(count: windows.count, showingIndex: windows.count - 1) { dot in
                guard windows.indices.contains(dot) else { return }
                TilingController.shared.show(windows[dot])
            }
            let (panel, host) = makeHostingPanel(view, level: .overlayLow, interactive: true)
            let size = host.fittingSize
            let gap = max(CGFloat(prefs.effectiveGap), 6)
            panel.setAXFrame(CGRect(x: entry.frame.midX - size.width / 2, y: entry.frame.minY - gap / 2 - size.height / 2, width: size.width, height: size.height))
            panel.orderFrontRegardless()
            dotPanels[id] = panel
            dotSignatures[id] = "\(entry.frame)\(windows)"
        }
    }

    // MARK: Hover

    /// Called on every mouse move (global monitor).
    func pointerMoved(to point: CGPoint) {
        if barPanel != nil {
            let keep = barRect.insetBy(dx: -14, dy: -14).contains(point) || gripRect.insetBy(dx: -10, dy: -8).contains(point)
            if keep || barHovered {
                hideTask?.cancel()
            } else if hideTask == nil {
                hideTask = after(0.3) { [weak self] in
                    self?.hideTask = nil
                    if self?.barHovered == false { self?.hideBar() }
                }
            }
            return
        }
        if !gripRect.isNull, gripRect.insetBy(dx: -10, dy: -8).contains(point) {
            beginDwell()
        } else {
            dwellTask?.cancel()
            dwellTask = nil
        }
    }

    private func beginDwell() {
        guard dwellTask == nil, barPanel == nil else { return }
        dwellTask = after(0.35) { [weak self] in
            guard let self else { return }
            self.dwellTask = nil
            if self.gripRect.insetBy(dx: -12, dy: -10).contains(Screens.mouseLocation) { self.showBar() }
        }
    }

    // MARK: Bar

    private func showBar() {
        guard let id = tiling.focusedTiledWindow, let frame = tiling.tileFrame(of: id) else { return }
        model.windowID = id
        model.isFocusMode = tiling.focusMode?.window == id
        model.isFloating = tiling.isFloating(id)
        model.stack = stackItems(for: id)
        model.screens = tiling.otherScreens(for: id).map { HoverBarModel.ScreenRoom(display: $0.display, free: $0.free) }
        model.optionHeld = NSEvent.modifierFlags.contains(.option)

        let view = HoverBarView(model: model, actions: HoverBarView.Actions(
            primary: { [weak self] in self?.run { TilingController.shared.makePrimary(id) } },
            focus: { [weak self] in self?.run { TilingController.shared.toggleFocusMode() } },
            moveTo: { [weak self] display in self?.run { TilingController.shared.moveToScreen(id, display: display) } },
            float: { [weak self] in
                guard let self else { return }
                if self.model.optionHeld {
                    self.run { TilingController.shared.alwaysFloatLikeActive() }
                } else {
                    self.run { TilingController.shared.toggleFloat(id) }
                }
            },
            show: { [weak self] wid in self?.tiling.show(wid); self?.model.stack = self?.stackItems(for: wid) ?? [] },
            step: { [weak self] forward in
                TilingController.shared.cycleStack(forward: forward)
                if let current = TilingController.shared.focusedTiledWindow { self?.model.stack = self?.stackItems(for: current) ?? [] }
            },
            close: { wid in
                guard let window = TilingController.shared.registry.window(wid) else { return }
                if let button = window.element.element(kAXCloseButtonAttribute) {
                    button.perform(kAXPressAction)
                } else {
                    Notices.shared.toast(L("This window can't be closed from here."))
                }
            },
            dragChip: { wid, ended in
                let point = Screens.mouseLocation
                let tiling = TilingController.shared
                if let hit = tiling.tileHit(at: point), hit.window != wid {
                    if ended {
                        DropHighlight.shared.hide()
                        tiling.moveToTile(wid, hit: hit)
                    } else {
                        DropHighlight.shared.show(frame: hit.frame, label: L("Move here"))
                    }
                } else {
                    DropHighlight.shared.hide()
                }
            },
            hover: { [weak self] inside in self?.barHovered = inside }
        ))
        let (panel, host) = makeHostingPanel(view, level: .overlayHigh, interactive: true)
        let size = host.fittingSize
        var y = frame.minY - size.height - 2
        if let display = Screens.display(for: frame, in: tiling.displays), y < display.visibleFrame.minY {
            y = frame.minY + 4
        }
        let rect = CGRect(x: frame.midX - size.width / 2, y: y, width: size.width, height: size.height)
        panel.setAXFrame(rect)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        barPanel = panel
        barRect = rect
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.optionHeld = NSEvent.modifierFlags.contains(.option) }
        }
    }

    private func run(_ action: @MainActor () -> Void) {
        hideBar()
        action()
    }

    func hideBar() {
        barPanel?.orderOut(nil)
        barPanel = nil
        barRect = .null
        barHovered = false
        hideTask?.cancel()
        hideTask = nil
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
    }
}

// MARK: - Views

struct GripView: View {
    let segments: [Bool]
    let onTapSegment: @MainActor (Int) -> Void
    let onHover: @MainActor (Bool) -> Void

    var body: some View {
        HStack(spacing: 4) {
            if segments.isEmpty {
                Capsule().fill(Color.secondary.opacity(0.55)).frame(width: 40, height: 5)
            } else {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, showing in
                    Capsule()
                        .fill(Color.orange.opacity(showing ? 1 : 0.5))
                        .frame(width: showing ? 20 : 10, height: 5)
                        .contentShape(Rectangle().inset(by: -4))
                        .onTapGesture { onTapSegment(index) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { onHover($0) }
    }
}

struct StackDotsView: View {
    let count: Int
    let showingIndex: Int
    let onTap: @MainActor (Int) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(Color.orange.opacity(index == showingIndex ? 1 : 0.55))
                    .frame(width: 6, height: 6)
                    .contentShape(Rectangle().inset(by: -3))
                    .onTapGesture { onTap(index) }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }
}

struct HoverBarView: View {
    struct Actions {
        let primary: @MainActor () -> Void
        let focus: @MainActor () -> Void
        let moveTo: @MainActor (DisplayInfo) -> Void
        let float: @MainActor () -> Void
        let show: @MainActor (CGWindowID) -> Void
        let step: @MainActor (Bool) -> Void
        let close: @MainActor (CGWindowID) -> Void
        let dragChip: @MainActor (CGWindowID, Bool) -> Void
        let hover: @MainActor (Bool) -> Void
    }

    @Bindable var model: HoverBarModel
    let actions: Actions

    private func shortcut(_ action: ShortcutAction) -> String { ShortcutCenter.shared.label(for: action) }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                BarButton(symbol: "rectangle.lefthalf.inset.filled", title: L("Primary"), shortcut: shortcut(.makePrimary), action: { actions.primary() })
                BarButton(
                    symbol: model.isFocusMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    title: model.isFocusMode ? L("Exit focus") : L("Focus"),
                    shortcut: shortcut(.focusMode),
                    action: { actions.focus() }
                )
                screenButton
                BarButton(
                    symbol: model.isFloating ? "square.grid.2x2" : "macwindow.on.rectangle",
                    title: model.isFloating ? L("Tile") : (model.optionHeld ? L("Always float") : L("Float")),
                    shortcut: shortcut(model.optionHeld && !model.isFloating ? .alwaysFloat : .float),
                    action: { actions.float() }
                )
            }
            if !model.stack.isEmpty {
                HStack(spacing: 4) {
                    Button { actions.step(false) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                    ForEach(model.stack) { item in
                        StackChip(item: item, onTap: { actions.show(item.id) }, onClose: { actions.close(item.id) }, onDrag: { ended in actions.dragChip(item.id, ended) })
                    }
                    Button { actions.step(true) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
                }
            }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12)))
        .onHover { actions.hover($0) }
        .padding(4)
        .fixedSize()
    }

    @ViewBuilder private var screenButton: some View {
        if model.screens.count == 1, let only = model.screens.first {
            BarButton(symbol: "rectangle.portrait.and.arrow.right", title: L("Next screen"), shortcut: "", action: { actions.moveTo(only.display) })
                .disabled(only.free == 0)
        } else if model.screens.count > 1 {
            Menu {
                ForEach(model.screens) { entry in
                    Button(L("%@ — room for %ld", entry.display.name, entry.free)) { actions.moveTo(entry.display) }
                        .disabled(entry.free == 0)
                }
            } label: {
                Label(L("Move to"), systemImage: "rectangle.portrait.and.arrow.right")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

private struct BarButton: View {
    let symbol: String
    let title: String
    let shortcut: String
    let action: @MainActor () -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(title).font(.system(size: 12, weight: .medium))
                if !shortcut.isEmpty {
                    Text(shortcut).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(hovering ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct StackChip: View {
    let item: HoverBarModel.StackItem
    let onTap: @MainActor () -> Void
    let onClose: @MainActor () -> Void
    let onDrag: @MainActor (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: item.icon)
                .resizable()
                .frame(width: 24, height: 24)
                .padding(4)
                .background(item.isShowing ? Color.orange.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .help(item.appName)
                .onTapGesture { onTap() }
                .gesture(DragGesture(minimumDistance: 6)
                    .onChanged { _ in onDrag(false) }
                    .onEnded { _ in onDrag(true) })
            if hovering {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .offset(x: 3, y: -3)
            }
        }
        .onHover { hovering = $0 }
    }
}
