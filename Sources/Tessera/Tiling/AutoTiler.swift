import AppKit
import TesseraCore

/// Auto-tile: keeps every normal window on each screen arranged, with no overlaps and none hidden.
///
/// - Each screen has its own layout style (Auto, Columns, Rows, Grid, Main + Side).
/// - A window you snap by hand is "pinned": it keeps its spot and the others fill the rest.
/// - A "floating" window is left alone until you tile it again.
@MainActor
final class AutoTiler {
    static let shared = AutoTiler()

    private let registry = WindowRegistry.shared
    private let mover = WindowMover.shared
    private let settings = Settings.shared

    /// Tiled windows per screen (by screen id), main window first. May include windows on other Spaces.
    private var order: [String: [CGWindowID]] = [:]
    /// The screen each tiled window belongs to.
    private var home: [CGWindowID: String] = [:]
    private var floating: Set<CGWindowID> = []
    /// Windows snapped by hand while auto-tile is on, with the frame they hold.
    private var pinned: [CGWindowID: CGRect] = [:]
    /// Sizes windows refused to shrink below.
    private var minimums: [CGWindowID: CGSize] = [:]
    /// The frame each tiled window was last given.
    private var planned: [CGWindowID: CGRect] = [:]
    /// Windows known to be normal and resizable, cached to save Accessibility calls.
    private var kind: [CGWindowID: Bool] = [:]
    private var rescannedFor: Set<CGWindowID> = []
    /// Screens where some app's minimum window size makes overlap unavoidable.
    private var crowded: Set<String> = []

    /// What the last arrangement of each screen was, for the on-screen picture and the tests.
    private struct ScreenPlan {
        var style: LayoutStyle
        var ids: [CGWindowID]
        var frames: [CGRect]
        var area: CGRect
        var fits: Bool
    }
    private var plans: [String: ScreenPlan] = [:]

    private var running = false
    private var pendingAfterMouse = false
    private var lastSeen: Set<CGWindowID> = []
    private let debouncer = Debouncer(delay: 0.12)
    private let watchdog = RepeatingTimer()

    var isOn: Bool { settings.autoTile && AccessibilityPermission.isTrusted }

    // MARK: Starting and stopping

    func start() {
        registry.onEvent = { [weak self] event in self?.handle(event) }
        settings.observe { [weak self] change in
            if change == .tiling { self?.settingsChanged() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { AutoTiler.shared.scheduleRetile(delay: 0.6) } }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { AutoTiler.shared.scheduleRetile(delay: 0.3) } }
        settingsChanged()
    }

    private func settingsChanged() {
        if isOn && !running {
            running = true
            // Check once a second for windows that appeared or vanished without telling us.
            watchdog.start(every: 1.0) { [weak self] in self?.checkForChanges() }
            retile()
        } else if !isOn && running {
            running = false
            watchdog.stop()
            debouncer.cancel()
            order.removeAll()
            home.removeAll()
            pinned.removeAll()
            floating.removeAll()
            planned.removeAll()
            plans.removeAll()
            crowded.removeAll()
        } else {
            scheduleRetile()
        }
    }

    // MARK: Commands

    func toggle() {
        guard AccessibilityPermission.isTrusted else {
            PermissionWindow.shared.show()
            return
        }
        settings.autoTile.toggle()
        Notice.shared.show(settings.autoTile ? "Auto-tile on" : "Auto-tile off")
    }

    /// Switches the layout of the screen you're working on to the next style.
    func nextLayout() {
        guard let screen = currentScreen() else { return }
        setLayout(settings.layout(for: screen.stableID).next, for: screen)
    }

    func previousLayout() {
        guard let screen = currentScreen() else { return }
        setLayout(settings.layout(for: screen.stableID).previous, for: screen)
    }

    /// Switches the screen you're working on to one style (⌃⌥1–5).
    func chooseLayout(_ style: LayoutStyle) {
        guard let screen = currentScreen() else { return }
        setLayout(style, for: screen)
    }

    /// Sets a screen's style, turns auto-tile on, arranges the windows now and shows a picture of the result.
    func setLayout(_ style: LayoutStyle, for screen: DisplayInfo) {
        guard AccessibilityPermission.isTrusted else {
            PermissionWindow.shared.show()
            return
        }
        settings.layouts[screen.stableID] = style
        if !settings.autoTile { settings.autoTile = true }
        retile()
        var text = style.title
        if crowded.contains(screen.stableID) {
            text += " — some windows can't get that small, so they overlap"
        }
        let picture: NSImage
        if let plan = plans[screen.stableID], plan.style == style, !plan.frames.isEmpty {
            picture = MenuIcons.picture(of: plan.frames, in: plan.area, height: 90)
        } else {
            picture = MenuIcons.layoutIcon(style, on: screen, count: 3, height: 90)
        }
        Notice.shared.show(text, picture: picture)
    }

    /// How many windows are tiled on a screen now.
    func tiledCount(on screen: DisplayInfo) -> Int { plans[screen.stableID]?.ids.count ?? 0 }

    /// Makes the focused window the main one (or swaps the main window with the next).
    func swapWithMain() {
        guard isOn, let window = registry.focusedWindow(), let screen = home[window.id], let list = order[screen] else {
            NSSound.beep()
            return
        }
        order[screen] = TileOrder.promote(window.id, in: list)
        retile()
    }

    /// Floats the focused window, or puts a floating or pinned window back into the tiles.
    func toggleFloat() {
        guard isOn, let window = registry.focusedWindow() else {
            NSSound.beep()
            return
        }
        let id = window.id
        if floating.contains(id) || pinned[id] != nil {
            floating.remove(id)
            pinned[id] = nil
            Notice.shared.show("Tiled")
        } else if canTile(window) {
            floating.insert(id)
            removeFromOrder(id)
            window.element.perform(kAXRaiseAction)
            Notice.shared.show("Floating")
        } else {
            NSSound.beep()
            return
        }
        retile()
    }

    // MARK: Called by snapping and dragging

    var currentLayoutScreen: DisplayInfo? { currentScreen() }

    func isTiled(_ window: TrackedWindow) -> Bool {
        home[window.id] != nil && pinned[window.id] == nil && !floating.contains(window.id)
    }

    /// A window you snapped by hand keeps that spot; the others tile around it.
    func pin(_ window: TrackedWindow, at frame: CGRect) {
        guard isOn, canTile(window) else { return }
        floating.remove(window.id)
        removeFromOrder(window.id)
        pinned[window.id] = frame
        scheduleRetile()
    }

    /// Puts a pinned window back into the tiles. Returns false if it wasn't pinned.
    func unpin(_ window: TrackedWindow) -> Bool {
        guard pinned.removeValue(forKey: window.id) != nil else { return false }
        retile()
        return true
    }

    /// Moves a tiled window to another screen's tiles.
    func move(_ window: TrackedWindow, to display: DisplayInfo) {
        removeFromOrder(window.id)
        home[window.id] = display.stableID
        order[display.stableID, default: []].append(window.id)
        retile()
    }

    /// You dragged a window and let go at `point`: swap it with the window there, or move it to that screen.
    func userDropped(_ window: TrackedWindow, at point: CGPoint) {
        pendingAfterMouse = false
        let id = window.id
        guard isOn, !floating.contains(id), canTile(window) else { return }
        pinned[id] = nil
        guard let target = Screens.display(containing: point, in: Screens.all()) else {
            retile()
            return
        }
        let source = home[id]
        let other = (order[target.stableID] ?? []).first { $0 != id && planned[$0]?.contains(point) == true }
        if let other, let source {
            if source == target.stableID {
                order[source] = TileOrder.swap(id, other, in: order[source] ?? [])
            } else {
                order[source] = (order[source] ?? []).map { $0 == id ? other : $0 }
                order[target.stableID] = (order[target.stableID] ?? []).map { $0 == other ? id : $0 }
                home[id] = target.stableID
                home[other] = source
            }
        } else if source != target.stableID {
            removeFromOrder(id)
            home[id] = target.stableID
            order[target.stableID, default: []].append(id)
        }
        retile()
    }

    /// You resized a tiled window with the mouse. In Main + Side this sets the main window's size;
    /// otherwise the window goes back to its tile.
    func userResized(_ window: TrackedWindow, from old: CGRect, to new: CGRect) {
        pendingAfterMouse = false
        defer { retile() }
        guard isOn, let screen = home[window.id], settings.layout(for: screen) == .mainAndSide,
              let list = order[screen], let display = Screens.all().first(where: { $0.stableID == screen }) else { return }
        let area = freeArea(on: display)
        let gap = CGFloat(settings.gap)
        let portrait = ScreenShape.of(area.size) == .portrait
        let length = portrait ? area.height : area.width
        let ratio: CGFloat
        if list.first == window.id {
            ratio = ((portrait ? new.height : new.width) + gap * 1.5) / length
        } else if list.contains(window.id) {
            ratio = ((portrait ? new.minY - area.minY : new.minX - area.minX) - gap / 2) / length
        } else {
            return
        }
        settings.mainRatio = Double(min(max(ratio, 0.2), 0.8))
    }

    /// The mouse button went up. Catch up on anything that happened during the drag.
    func mouseReleased() {
        guard pendingAfterMouse else { return }
        pendingAfterMouse = false
        scheduleRetile()
    }

    // MARK: Events

    private func handle(_ event: WindowEvent) {
        switch event {
        case .moved(let id), .resized(let id):
            guard running, !mover.isOwnMove(id), home[id] != nil else { return }
            if DragSnapper.shared.isMouseDown {
                pendingAfterMouse = true
            } else {
                scheduleRetile(delay: 0.3)
            }
        case .destroyed(let id):
            forget(id)
            scheduleRetile()
        case .appTerminated(_, let ids):
            ids.forEach(forget)
            scheduleRetile()
        case .created, .minimized, .deminimized, .appHidden, .appShown, .appLaunched:
            scheduleRetile()
        case .focused, .titleChanged, .appActivated:
            break
        }
    }

    private func checkForChanges() {
        guard running else { return }
        // Only which windows are visible matters, not their stacking order.
        if Set(visibleWindowIDs()) != lastSeen { scheduleRetile() }
    }

    func scheduleRetile(delay: Double? = nil) {
        guard running else { return }
        if let delay {
            after(delay) { [weak self] in self?.retile() }
        } else {
            debouncer.schedule { [weak self] in self?.retile() }
        }
    }

    // MARK: Tiling

    /// Arranges every screen now.
    func retile() {
        guard isOn else { return }
        if DragSnapper.shared.isMouseDown {
            pendingAfterMouse = true
            return
        }
        let displays = Screens.all()
        guard !displays.isEmpty else { return }
        let visibleIDs = visibleWindowIDs()
        lastSeen = Set(visibleIDs)

        // Pick up windows Accessibility didn't tell us about.
        let unknown = Set(visibleIDs.filter { registry.window($0) == nil }).subtracting(rescannedFor)
        if !unknown.isEmpty {
            rescannedFor.formUnion(unknown)
            registry.rescan()
        }

        // Group tileable windows by screen, front window first.
        var present: [String: [CGWindowID]] = [:]
        var windows: [CGWindowID: TrackedWindow] = [:]
        for id in visibleIDs {
            guard let window = registry.window(id), pinned[id] == nil, !floating.contains(id), canTile(window),
                  let frame = window.frame else { continue }
            let screen = home[id].flatMap { s in displays.first { $0.stableID == s } }
                ?? Screens.display(for: frame, in: displays)
            guard let screen else { continue }
            home[id] = screen.stableID
            present[screen.stableID, default: []].append(id)
            windows[id] = window
        }

        let gap = CGFloat(settings.gap)
        var moved: [CGWindowID] = []
        for display in displays {
            let screen = display.stableID
            let here = present[screen] ?? []
            if here.isEmpty { plans[screen] = nil }
            // Keep the saved order (including windows on other Spaces); new windows join at the end.
            var list = (order[screen] ?? []).filter { registry.window($0) != nil && home[$0] == screen && pinned[$0] == nil && !floating.contains($0) }
            for id in here where !list.contains(id) { list.append(id) }
            order[screen] = list
            let active = list.filter { here.contains($0) }
            guard !active.isEmpty else { continue }

            let style = settings.layout(for: screen)
            let plan = TilePlanner.plan(
                count: active.count,
                in: freeArea(on: display),
                style: style,
                gap: gap,
                mainRatio: style == .mainAndSide ? CGFloat(settings.mainRatio) : 0.5,
                minimumSizes: active.map { minimums[$0] }
            )
            if plan.fits { crowded.remove(screen) } else { crowded.insert(screen) }
            plans[screen] = ScreenPlan(style: style, ids: active, frames: plan.frames, area: freeArea(on: display), fits: plan.fits)
            for (id, frame) in zip(active, plan.frames) {
                guard let window = windows[id] else { continue }
                planned[id] = frame
                mover.move(window, to: frame, within: display.visibleFrame)
                moved.append(id)
            }
        }
        if !moved.isEmpty {
            after(0.35) { [weak self] in self?.learnMinimums(moved) }
        }
    }

    /// Some windows can't get as small as their tile. Remember their size and arrange again so they fit.
    ///
    /// A window still too big after 0.35 s gets asked again, and only counts if it refuses twice:
    /// slow or animating apps would otherwise teach Tessera a size that's far too big.
    /// A remembered size also shrinks if the window is ever seen smaller.
    private func learnMinimums(_ ids: [CGWindowID], confirming: Bool = false) {
        var learned = false
        var suspects: [CGWindowID] = []
        for id in ids {
            guard let window = registry.window(id), let target = planned[id], let actual = window.frame else { continue }
            if var known = minimums[id] {
                if actual.width < known.width - 4 { known.width = actual.width }
                if actual.height < known.height - 4 { known.height = actual.height }
                minimums[id] = known
            }
            let tooWide = actual.width > target.width + 4
            let tooTall = actual.height > target.height + 4
            guard tooWide || tooTall else { continue }
            guard confirming else {
                suspects.append(id)
                continue
            }
            let old = minimums[id] ?? .zero
            let new = CGSize(
                width: tooWide ? max(old.width, actual.width) : old.width,
                height: tooTall ? max(old.height, actual.height) : old.height
            )
            if new != old {
                minimums[id] = new
                learned = true
                Log.info("Window \(id) (\(window.bundleID)) needs at least \(Int(new.width))×\(Int(new.height))")
            }
        }
        if !suspects.isEmpty {
            for id in suspects {
                if let window = registry.window(id), let target = planned[id] { mover.move(window, to: target) }
            }
            after(0.4) { [weak self] in self?.learnMinimums(suspects, confirming: true) }
        }
        if learned { retile() }
    }

    // MARK: Helpers

    /// The area left for tiles on a screen after pinned windows.
    private func freeArea(on display: DisplayInfo) -> CGRect {
        let rects = pinned.filter { lastSeen.contains($0.key) && display.frame.intersects($0.value) }.map(\.value)
        return TilePlanner.freeArea(display.visibleFrame, excluding: rects, tolerance: CGFloat(settings.gap) + 2)
    }

    /// Whether auto-tile can manage this window at all (ignoring float and pin choices).
    private func canTile(_ window: TrackedWindow) -> Bool {
        guard !settings.isIgnored(window.bundleID) else { return false }
        if NSRunningApplication(processIdentifier: window.pid)?.isHidden == true { return false }
        if window.element.isFullScreen { return false }
        if kind[window.id] == true { return true }
        // Only "yes" is cached: some apps finish setting up a new window a moment after showing it.
        let ok = window.isStandard && window.isResizable
        if ok { kind[window.id] = true }
        return ok
    }

    /// Normal windows on screen now (this Space), front to back.
    private func visibleWindowIDs() -> [CGWindowID] {
        let me = getpid()
        return WindowServer.onScreen()
            .filter { $0.layer == 0 && $0.pid != me && $0.alpha > 0 && $0.bounds.width > 40 && $0.bounds.height > 40 }
            .map(\.id)
    }

    private func currentScreen() -> DisplayInfo? {
        let displays = Screens.all()
        if let window = registry.focusedWindow(), let frame = window.frame {
            return Screens.display(for: frame, in: displays)
        }
        return Screens.display(containing: Screens.mouseLocation, in: displays) ?? displays.first
    }

    private func removeFromOrder(_ id: CGWindowID) {
        if let screen = home.removeValue(forKey: id) {
            order[screen]?.removeAll { $0 == id }
        }
    }

    private func forget(_ id: CGWindowID) {
        removeFromOrder(id)
        floating.remove(id)
        pinned[id] = nil
        minimums[id] = nil
        planned[id] = nil
        kind[id] = nil
        mover.forget(id)
    }

    // MARK: Debug

    func debugState() -> [String: Any] {
        [
            "on": isOn,
            "order": order.mapValues { $0.map(Int.init) },
            "floating": floating.map(Int.init),
            "pinned": Dictionary(uniqueKeysWithValues: pinned.map { (String($0.key), NSStringFromRect($0.value)) }),
            "crowded": Array(crowded),
            "plans": plans.mapValues { plan -> [String: Any] in
                [
                    "style": plan.style.rawValue,
                    "ids": plan.ids.map(Int.init),
                    "frames": plan.frames.map { [$0.minX, $0.minY, $0.width, $0.height].map(Double.init) },
                    "area": [plan.area.minX, plan.area.minY, plan.area.width, plan.area.height].map(Double.init),
                    "fits": plan.fits,
                ]
            },
            "minimums": Dictionary(uniqueKeysWithValues: minimums.map { (String($0.key), NSStringFromSize($0.value)) }),
        ]
    }
}
