import AppKit
import TesseraCore

/// A full-screen sheet that sits just below one window: dims, blurs, or paints a plain background.
final class ScreenSheetView: NSView {
    private let blurView = NSVisualEffectView()
    private let tintView = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        blurView.blendingMode = .behindWindow
        blurView.material = .fullScreenUI
        blurView.state = .active
        blurView.autoresizingMask = [.width, .height]
        blurView.frame = bounds
        tintView.wantsLayer = true
        tintView.autoresizingMask = [.width, .height]
        tintView.frame = bounds
        addSubview(blurView)
        addSubview(tintView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Dim (and optionally blur) what's behind.
    func configureDim(amount: Double, blur: Bool) {
        blurView.isHidden = !blur
        tintView.layer?.backgroundColor = NSColor.black.withAlphaComponent(amount).cgColor
    }

    /// A plain, opaque background.
    func configurePlain(_ background: CleanSpaceBackground) {
        blurView.isHidden = true
        let (r, g, b) = background.rgb
        tintView.layer?.backgroundColor = NSColor(srgbRed: r, green: g, blue: b, alpha: 1).cgColor
    }
}

@MainActor
private func makeSheetPanel() -> FloatingPanel {
    let panel = FloatingPanel(level: .normal, ignoresMouse: true)
    panel.contentView = ScreenSheetView(frame: .zero)
    return panel
}

/// Orders a sheet just below a window, or above everything normal if there's none.
@MainActor
private func order(_ panel: FloatingPanel, below windowID: CGWindowID?) {
    if NSApp.isActive, let key = NSApp.keyWindow, key !== panel {
        panel.order(.below, relativeTo: key.windowNumber)
    } else if let windowID {
        panel.order(.below, relativeTo: Int(windowID))
    } else {
        panel.orderFrontRegardless()
    }
}

// MARK: - No peek mode

/// Dims every window except the active one, so nobody nearby (or on a screen share) can read them.
@MainActor
final class NoPeekController {
    static let shared = NoPeekController()

    private var panels: [String: FloatingPanel] = [:]
    private let prefs = Preferences.shared
    private var tiling: TilingController { .shared }

    var isOn: Bool { prefs.noPeek }

    func toggle() {
        set(!prefs.noPeek)
    }

    func set(_ on: Bool) {
        prefs.noPeek = on
        if on { prefs.count(\.noPeekSessions) }
        AppModel.shared.noPeekOn = on
        refresh()
    }

    func refresh() {
        guard prefs.noPeek, AppModel.shared.accessibilityTrusted, !AppModel.shared.stageManagerOn else {
            clear()
            return
        }
        let active = tiling.focusedID
        let activeFrame = active.flatMap { tiling.registry.window($0)?.frame }
        let displays = tiling.displays
        for display in displays {
            let panel = panels[display.stableID] ?? makeSheetPanel()
            panels[display.stableID] = panel
            panel.setFrame(display.cocoaFrame, display: false)
            (panel.contentView as? ScreenSheetView)?.configureDim(amount: prefs.dimAmount, blur: prefs.blurOthers)
            let activeHere = activeFrame.map { display.frame.intersects($0) } ?? false
            order(panel, below: activeHere ? active : nil)
        }
        let live = Set(displays.map(\.stableID))
        for (id, panel) in panels where !live.contains(id) {
            panel.orderOut(nil)
            panels.removeValue(forKey: id)
        }
    }

    func clear() {
        for (_, panel) in panels { panel.orderOut(nil) }
        panels.removeAll()
    }
}

// MARK: - Clean Space

/// Makes one screen plain for sharing or presenting: the active window fills it,
/// everything else waits behind a plain background. Nothing is hidden, moved or closed.
@MainActor
final class CleanSpaceController {
    static let shared = CleanSpaceController()

    private(set) var isOn = false
    private(set) var displayStableID: String?
    private var panel: FloatingPanel?
    private var shown: [CGWindowID] = []
    private var savedFrames: [CGWindowID: CGRect] = [:]
    private var observers: [NSObjectProtocol] = []
    private let prefs = Preferences.shared
    private var tiling: TilingController { .shared }

    func toggle() {
        isOn ? turnOff() : turnOn()
    }

    func turnOn() {
        guard !isOn, AppModel.shared.accessibilityTrusted else { return }
        let activeWindow = tiling.focusedID.flatMap { tiling.registry.window($0) }
        let display: DisplayInfo?
        if let frame = activeWindow?.frame {
            display = Screens.display(for: frame, in: tiling.displays)
        } else {
            display = tiling.displayUnderPointer
        }
        guard let display else { return }
        isOn = true
        displayStableID = display.stableID
        shown = []
        savedFrames = [:]
        if let activeWindow { add(activeWindow) }
        AppModel.shared.cleanSpaceOn = true
        prefs.count(\.cleanSpaceSessions)

        let panel = makeSheetPanel()
        // The plain background swallows clicks, so hidden windows can't pop up by accident.
        panel.ignoresMouseEvents = false
        (panel.contentView as? ScreenSheetView)?.configurePlain(prefs.cleanSpaceBackground)
        panel.setFrame(display.cocoaFrame, display: false)
        panel.alphaValue = 0
        self.panel = panel
        layoutShown()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 1
        }
        watchForSleep()
        HighlightController.shared.refresh()
        StatusItemController.shared.refreshIcon()
    }

    func turnOff() {
        guard isOn else { return }
        isOn = false
        AppModel.shared.cleanSpaceOn = false
        panel?.orderOut(nil)
        panel = nil
        for token in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            DistributedNotificationCenter.default().removeObserver(token)
        }
        observers.removeAll()
        // Everything returns to where it was.
        for (id, frame) in savedFrames where !tiling.isTiled(id) {
            if let window = tiling.registry.window(id) { tiling.applier.set(window, to: frame, force: true) }
        }
        let key = displayStableID.flatMap { id in tiling.displays.first { $0.stableID == id } }.map { tiling.key(for: $0) }
        displayStableID = nil
        shown = []
        savedFrames = [:]
        if let key { tiling.apply(key) }
        HighlightController.shared.refresh()
        StatusItemController.shared.refreshIcon()
    }

    /// Called when focus changes: windows brought to this screen share it.
    func refresh() {
        guard isOn, let display = currentDisplay else { return }
        shown.removeAll { tiling.registry.window($0) == nil }
        if let id = tiling.focusedID, !shown.contains(id), let window = tiling.registry.window(id),
           let frame = window.frame, display.frame.intersects(frame) {
            add(window)
            layoutShown()
        } else if let panel {
            order(panel, below: bottomMostShown())
        }
    }

    func screensChanged() {
        guard isOn else { return }
        if currentDisplay == nil { turnOff() }
    }

    func isManaging(_ display: DisplayInfo) -> Bool { isOn && display.stableID == displayStableID }

    private var currentDisplay: DisplayInfo? {
        guard let displayStableID else { return nil }
        return Screens.all().first { $0.stableID == displayStableID }
    }

    private func add(_ window: TrackedWindow) {
        if savedFrames[window.id] == nil, let frame = window.frame { savedFrames[window.id] = frame }
        shown.append(window.id)
        if shown.count > 4 { shown.removeFirst() }
    }

    private func layoutShown() {
        guard let display = currentDisplay, let panel else { return }
        let area = tiling.usableArea(display)
        let windows = shown.compactMap { tiling.registry.window($0) }
        if !windows.isEmpty {
            let tree = LayoutEngine.tree(layout: .grid, shape: display.shape, count: windows.count, mainSize: .half)
            let solver = LayoutSolver(gap: prefs.effectiveGap)
            if case .success(let frames) = solver.solve(tree, in: area) {
                for (index, window) in windows.enumerated() {
                    if let frame = frames[index] { tiling.applier.set(window, to: frame) }
                }
            }
            for window in windows.reversed() { tiling.applier.raise(window) }
        }
        order(panel, below: bottomMostShown())
    }

    /// The shown window lowest in the stacking order; the background goes just below it.
    private func bottomMostShown() -> CGWindowID? {
        let set = Set(shown)
        return WindowServer.onScreen().last { set.contains($0.id) }?.id ?? shown.last
    }

    private func watchForSleep() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.turnOff() }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.turnOff() }
        })
    }
}
