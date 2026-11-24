import AppKit
import TesseraCore

/// Auto-tile: keeps every normal window on each screen arranged, with no overlaps and none hidden.
///
/// - Each desktop (Space) on each screen has its own layout style (Auto, Columns, Rows, Grid, Main + Side).
/// - Only windows on the desktop a screen is showing take part. Windows on other desktops are never
///   moved, so swiping between desktops never makes windows jump.
/// - The latest command wins. A window you snap or maximise by hand is "pinned" and keeps that spot;
///   picking a layout afterwards puts it back into the layout, in its old place.
/// - A "floating" window (⌃⌥W) is left alone until you tile it again, even when you change layout.
/// - Only a few windows sit in front (Auto: as many as fit at a comfortable size). The rest wait
///   just off the screen's edge. Using a waiting window brings it forward: it takes the spot of
///   the front window used least lately, and no other window moves. See `FrontWindows`.
@MainActor
final class AutoTiler {
    static let shared = AutoTiler()

    private let registry = WindowRegistry.shared
    private let mover = WindowMover.shared
    private let settings = Settings.shared

    /// Windows per screen (by screen id), main window first. Includes windows on other desktops,
    /// floating and pinned ones, so each keeps its place for when it takes part again.
    private var order: [String: [CGWindowID]] = [:]
    /// The layout of each desktop, by `layoutKey`. A desktop gets the screen's layout the first time
    /// Tessera sees it, then keeps its own.
    private var spaceLayouts: [String: LayoutStyle] = [:]
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
        /// The front windows, in spot order.
        var ids: [CGWindowID]
        var frames: [CGRect]
        var area: CGRect
        var fits: Bool
        /// The desktop this was for (see `layoutKey`).
        var key: String
        /// Windows waiting off screen, the one used most lately first.
        var waiting: [CGWindowID]
        /// How many windows may sit in front (nil: no limit).
        var limit: Int?
    }
    private var plans: [String: ScreenPlan] = [:]
    /// How many points a window may come up short of its tile (Terminal sizes itself in whole characters).
    private static let slack: CGFloat = 16

    private var running = false
    private var pendingAfterMouse = false
    /// The windows that took part in the last arrangement.
    private var lastSeen: Set<CGWindowID> = []
    /// A different set of windows seen by the watchdog, waiting to be seen once more before Tessera acts.
    private var candidate: Set<CGWindowID>?
    /// No arranging until then: macOS is still animating a switch between desktops.
    private var quietUntil = Date.distantPast
    /// A layout picked while a window was in macOS full screen, by screen. It applies to the
    /// desktop that window goes back to.
    private var pendingLayout: [String: (window: CGWindowID, style: LayoutStyle, at: Date)] = [:]
    /// When windows from a desktop the screen isn't showing were first seen on screen.
    private var switchingSince: Date?
    /// The latest move or resize by something else, per window: only the last one counts.
    private var appMoveTicket: [CGWindowID: Int] = [:]

    // Front windows.
    /// When each window was last used: a bigger number is more recent.
    private var lastUsed: [CGWindowID: Int] = [:]
    private var clock = 0
    /// Windows to bring to the front at the next arrangement (just opened, or put back into the
    /// tiles), with when they asked.
    private var wanted: [CGWindowID: Date] = [:]
    /// Windows kept in front (⌃⌥P): they never step back to make room.
    private var kept: Set<CGWindowID> = []
    /// Where each window last sat in front, to put waiting windows back on screen when Tessera stops.
    private var lastFrontFrame: [CGWindowID: CGRect] = [:]
    /// Front windows that just closed. They stay in the order until the next arrangement has
    /// filled their spot (by then the app has chosen which window you're in next).
    private var closing: Set<CGWindowID> = []
    /// Until then, windows belong to the screen they're on now: a screen was just plugged in,
    /// unplugged or moved, and macOS is moving windows between screens.
    private var followScreensUntil = Date.distantPast
    /// Tiles you made larger or smaller (⌃⌥= and ⌃⌥-, or by dragging an edge): their width and
    /// height shares. A window that isn't here has an even share. See `TileSizes`.
    private var sizes: [CGWindowID: CGSize] = [:]
    /// Counts arrangements, so a resize can tell whether one happened.
    private var arrangements = 0
    /// When you last sent each window to a screen yourself (Next Display, or a drag). That
    /// choice wins over following macOS.
    private var sentAt: [CGWindowID: Date] = [:]
    /// A screen that was unplugged (or whose lid was closed): its windows in order, which were in front,
    /// and its layout. When it comes back, they go back to it, so nothing is lost.
    private struct ScreenMemory {
        var order: [CGWindowID]
        var front: [CGWindowID]
        var layout: LayoutStyle?
        var sizes: [CGWindowID: CGSize]
        var at: Date
    }
    private var remembered: [String: ScreenMemory] = [:]
    /// The screens seen at the last arrangement.
    private var knownScreens: Set<String> = []
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
        ) { _ in MainActor.assumeIsolated { AutoTiler.shared.screensChanged() } }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { AutoTiler.shared.spaceChanged() } }
        Log.info(Spaces.isAvailable ? "Desktops (Spaces) supported" : "Desktops (Spaces) unknown: waiting for the screen to settle instead")
        settingsChanged()
    }

    /// A screen was plugged in, unplugged, moved or changed size. macOS moves windows between
    /// screens over the next second or two: wait, then follow where it put them rather than
    /// pulling them back to their old screen.
    private func screensChanged() {
        quietUntil = Date().addingTimeInterval(1.5)
        followScreensUntil = Date().addingTimeInterval(5)
        candidate = nil
        scheduleRetile(delay: 1.6)
    }

    /// You switched desktop. Let the animation finish, then arrange the new desktop once.
    private func spaceChanged() {
        quietUntil = Date().addingTimeInterval(0.5)
        candidate = nil
        scheduleRetile(delay: 0.55)
    }

    private func settingsChanged() {
        if isOn && !running {
            running = true
            // Twice a second, look for windows that appeared or vanished without telling us.
            watchdog.start(every: 0.5) { [weak self] in self?.checkForChanges() }
            retile()
        } else if !isOn && running {
            running = false
            watchdog.stop()
            debouncer.cancel()
            releaseWaiting()
            order.removeAll()
            home.removeAll()
            pinned.removeAll()
            floating.removeAll()
            planned.removeAll()
            plans.removeAll()
            crowded.removeAll()
            candidate = nil
            wanted.removeAll()
            closing.removeAll()
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

    /// Switches the desktop you're working on to the next style.
    func nextLayout() {
        guard let screen = currentScreen() else { return }
        setLayout(layout(for: screen).next, for: screen)
    }

    func previousLayout() {
        guard let screen = currentScreen() else { return }
        setLayout(layout(for: screen).previous, for: screen)
    }

    /// The layout of the desktop a screen is showing now.
    func layout(for screen: DisplayInfo) -> LayoutStyle {
        spaceLayouts[layoutKey(screen, Spaces.current(for: Screens.all()))] ?? settings.layout(for: screen.stableID)
    }

    /// "Retile": arrange the screen you're working on again, putting snapped windows back in.
    func retileCommand() {
        guard isOn else {
            toggle()
            return
        }
        if let screen = currentScreen() {
            if leaveFullScreen(on: screen, style: nil) { return }
            unpinVisible(on: screen)
            evenOut(on: screen)
        }
        retile()
    }

    /// Switches the screen you're working on to one style (⌃⌥1–5).
    func chooseLayout(_ style: LayoutStyle) {
        guard let screen = currentScreen() else { return }
        setLayout(style, for: screen)
    }

    /// Sets the style of the desktop a screen is showing, arranges its windows now and shows a picture.
    ///
    /// The latest command wins: windows you snapped or maximised by hand join the new layout.
    /// Floating windows (⌃⌥W) stay floating.
    func setLayout(_ style: LayoutStyle, for screen: DisplayInfo, notify: Bool = true) {
        guard AccessibilityPermission.isTrusted else {
            if notify { PermissionWindow.shared.show() } else { settings.layouts[screen.stableID] = style }
            return
        }
        settings.layouts[screen.stableID] = style   // New desktops, and the next launch, start with it.
        if notify, !settings.autoTile { settings.autoTile = true }
        if notify, leaveFullScreen(on: screen, style: style) {
            Notice.shared.show(style.title, picture: MenuIcons.layoutIcon(style, on: screen, count: 3, height: 90))
            return
        }
        spaceLayouts[layoutKey(screen, Spaces.current(for: Screens.all()))] = style
        unpinVisible(on: screen)
        evenOut(on: screen)
        retile()
        guard notify else { return }
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

    /// How many windows are tiled on a screen now (the front ones).
    func tiledCount(on screen: DisplayInfo) -> Int { plans[screen.stableID]?.ids.count ?? 0 }

    // MARK: Front windows

    /// How many windows may sit in front on a screen (nil: no limit).
    func frontLimit(on screen: DisplayInfo) -> Int? { settings.frontLimit.count(for: screen.visibleFrame.size) }

    /// The windows on a screen's current desktop: in front (spot order) and waiting (used most lately first).
    func windows(on screen: DisplayInfo) -> (front: [TrackedWindow], waiting: [TrackedWindow]) {
        guard let plan = plans[screen.stableID] else { return ([], []) }
        return (plan.ids.compactMap(registry.window), plan.waiting.compactMap(registry.window))
    }

    /// The screen you're working on.
    var workingScreen: DisplayInfo? { currentScreen() }

    func isWaiting(_ id: CGWindowID) -> Bool { plans.values.contains { $0.waiting.contains(id) } }

    func isKept(_ id: CGWindowID) -> Bool { kept.contains(id) }

    /// The screen a window belongs to (its stable id), for the tests.
    func screenID(of id: CGWindowID) -> String? { home[id] }

    /// Sends a window to a screen's tiles, as Next Display does (for the tests).
    func send(_ id: CGWindowID, to screenID: String) {
        guard let window = registry.window(id), let display = Screens.all().first(where: { $0.stableID == screenID }) else { return }
        move(window, to: display)
    }

    /// Brings a window to the front (from the menu or the window picker) and switches to it.
    func bringForward(_ id: CGWindowID) {
        guard let window = registry.window(id) else { return }
        touch(id)
        if isWaiting(id) {
            wanted[id] = Date()
            retile()
        }
        focus(window)
    }

    /// ⌃⌥P: keep the focused window in front, or let it step back again.
    func toggleKeep() {
        guard isOn, let window = registry.focusedWindow(), canTile(window) else {
            NSSound.beep()
            return
        }
        let id = window.id
        if kept.remove(id) != nil {
            Notice.shared.show("Can step back again")
            return
        }
        // At least one front spot must stay free for the windows you use.
        if let screen = home[id], let display = Screens.all().first(where: { $0.stableID == screen }),
           let limit = frontLimit(on: display) {
            let keptHere = kept.filter { home[$0] == screen && registry.window($0) != nil }.count
            if keptHere >= max(limit - 1, 1) {
                NSSound.beep()
                Notice.shared.show("You can keep \(max(limit - 1, 1)) of \(limit) windows in front here")
                return
            }
        }
        kept.insert(id)
        rejoin(id)
        Notice.shared.show("Kept in front")
        retile()
    }

    /// When each window was last used, for the tests.
    private func touch(_ id: CGWindowID) {
        clock += 1
        lastUsed[id] = clock
    }

    /// A window comes back into the tiles (from floating or a hand snap): it asks for a front spot.
    private func rejoin(_ id: CGWindowID) {
        pinned[id] = nil
        floating.remove(id)
        wanted[id] = Date()
    }

    /// Floating: by ⌃⌥W, or because the app's rule says "Always Float".
    private func isFloating(_ id: CGWindowID) -> Bool {
        if floating.contains(id) { return true }
        guard let app = registry.window(id)?.bundleID else { return false }
        return settings.rule(for: app)?.float == true
    }

    /// Reverse All while auto-tile is on: the windows in front on this screen swap ends.
    /// Waiting windows keep their places in the order.
    func reverseOrder() {
        guard isOn, let window = registry.focusedWindow(), let screen = home[window.id], let list = order[screen] else {
            NSSound.beep()
            return
        }
        let front = Set(plans[screen]?.ids ?? list)
        let spots = list.indices.filter { front.contains(list[$0]) }
        var reversed = list
        for (i, spot) in spots.enumerated() { reversed[spot] = list[spots[spots.count - 1 - i]] }
        order[screen] = reversed
        retile()
    }

    /// Switches to a window: raises it and makes its app the active one.
    func focus(_ window: TrackedWindow) {
        window.element.set(kAXMainAttribute, bool: true)
        window.element.perform(kAXRaiseAction)
        AXElement.application(window.pid).set(kAXFrontmostAttribute, bool: true)
        NSRunningApplication(processIdentifier: window.pid)?.activate()
    }

    /// Puts every waiting window back on screen where it last sat in front (auto-tile off, or quitting).
    func releaseWaiting() {
        let displays = Screens.all()
        let screens = displays.map(\.frame)
        for plan in plans.values {
            for id in plan.waiting {
                guard let window = registry.window(id), let frame = window.frame,
                      FrontWindows.isWaiting(frame, screens: screens) else { continue }
                let area = home[id].flatMap { s in displays.first { $0.stableID == s } }?.visibleFrame
                    ?? displays.first?.visibleFrame ?? .zero
                mover.move(window, to: lastFrontFrame[id] ?? Self.centred(frame.size, in: area), within: area)
            }
        }
    }

    /// Windows left off screen by a Tessera that stopped without tidying up (a crash, or a force
    /// quit) come back to the middle of their screen.
    func rescueStranded() {
        let displays = Screens.all()
        let screens = displays.map(\.frame)
        for id in WindowServer.onScreenIDs() {
            guard let window = registry.window(id), let frame = window.frame,
                  FrontWindows.isWaiting(frame, screens: screens),
                  let display = Screens.display(for: frame, in: displays) else { continue }
            Log.info("Bringing window \(id) back on screen")
            mover.move(window, to: Self.centred(frame.size, in: display.visibleFrame), within: display.visibleFrame)
        }
    }

    private static func centred(_ size: CGSize, in area: CGRect) -> CGRect {
        let width = min(size.width, area.width), height = min(size.height, area.height)
        return CGRect(x: (area.midX - width / 2).rounded(), y: (area.midY - height / 2).rounded(), width: width, height: height)
    }

    /// Makes the focused window the main one (or swaps the main window with the next).
    func swapWithMain() {
        guard isOn, let window = registry.focusedWindow(), let screen = home[window.id], let list = order[screen] else {
            NSSound.beep()
            return
        }
        rejoin(window.id)
        let active = Set(plans[screen]?.ids ?? []).union([window.id])
        order[screen] = TileOrder.promote(window.id, in: list, among: active)
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
            rejoin(id)
            if let frame = window.frame { rehome(id, frame: frame) }   // You may have moved it to another screen.
            Notice.shared.show("Tiled")
        } else if canTile(window) {
            floating.insert(id)   // It keeps its place in the order for when you tile it again.
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
        home[window.id] != nil && pinned[window.id] == nil && !isFloating(window.id)
    }

    /// A window you snapped by hand keeps that spot; the others tile around it.
    /// It keeps its place in the order, so a later layout puts it back where it was.
    func pin(_ window: TrackedWindow, at frame: CGRect) {
        guard isOn, canTile(window) else { return }
        floating.remove(window.id)
        pinned[window.id] = frame
        rehome(window.id, frame: frame)
        scheduleRetile()
    }

    /// Puts a pinned window back into the tiles. Returns false if it wasn't pinned.
    func unpin(_ window: TrackedWindow) -> Bool {
        guard pinned[window.id] != nil else { return false }
        rejoin(window.id)
        retile()
        return true
    }

    /// Moves a tiled window to another screen's tiles.
    func move(_ window: TrackedWindow, to display: DisplayInfo, first: Bool = false) {
        removeFromOrder(window.id)
        home[window.id] = display.stableID
        if first {
            order[display.stableID, default: []].insert(window.id, at: 0)
        } else {
            order[display.stableID, default: []].append(window.id)
        }
        wanted[window.id] = Date()   // You sent it there to use it.
        sentAt[window.id] = Date()
        sizes[window.id] = nil       // A fresh, even share on its new screen.
        touch(window.id)
        retile()
    }

    /// An app rule may say which screen the app's new windows open on.
    private func applyScreenRule(_ id: CGWindowID) {
        guard let window = registry.window(id), let screenID = settings.rule(for: window.bundleID)?.screen,
              let target = Screens.all().first(where: { $0.stableID == screenID }) else { return }
        // Give the app a moment to finish placing its new window.
        after(0.4) { [weak self] in
            guard let self, let frame = window.frame, let current = Screens.display(for: frame, in: Screens.all()),
                  current != target else { return }
            Log.info("App rule: window \(id) opens on \(target.name)")
            if self.isOn, self.canTile(window) {
                self.move(window, to: target)
            } else {
                let moved = SnapCalculator.moveProportionally(frame, from: current.visibleFrame, to: target.visibleFrame)
                self.mover.move(window, to: moved, within: target.visibleFrame)
            }
        }
    }

    /// ⌃⌥ + arrow on a tiled window: it walks one spot that way through the layout, trading places with
    /// the window there. Each spot keeps its size, so the layout keeps its shape. Past the screen's edge
    /// it goes to the next screen that way. Returns false when the window isn't tiled (it snaps instead).
    func walk(_ window: TrackedWindow, _ direction: Direction) -> Bool {
        guard isOn, isTiled(window), let screen = home[window.id], let plan = plans[screen],
              let index = plan.ids.firstIndex(of: window.id), plan.frames.indices.contains(index) else { return false }
        touch(window.id)
        let others = zip(plan.ids, plan.frames).filter { $0.0 != window.id }.map { (id: UInt32($0.0), frame: $0.1) }
        if let next = Navigation.neighbour(of: plan.frames[index], direction: direction, among: others) {
            let other = CGWindowID(next)
            order[screen] = TileOrder.swap(window.id, other, in: order[screen] ?? [])
            (sizes[window.id], sizes[other]) = (sizes[other], sizes[window.id])
            retile()
            return true
        }
        // Past the edge: the screen next to this one that way, if there is one.
        let displays = Screens.all()
        guard let here = displays.first(where: { $0.stableID == screen }) else { return true }
        let neighbours = displays.filter { $0 != here }.map { (id: UInt32($0.displayID), frame: $0.frame) }
        guard let next = Navigation.neighbour(of: here.frame, direction: direction, among: neighbours),
              let target = displays.first(where: { $0.displayID == CGDirectDisplayID(next) }) else {
            NSSound.beep()
            return true
        }
        // It enters from the side it came from: moving right, it becomes the first (left-most) spot.
        move(window, to: target, first: direction == .right || direction == .down)
        return true
    }

    /// You dragged a window and let go at `point`: swap it with the window there, or move it to that screen.
    func userDropped(_ window: TrackedWindow, at point: CGPoint) {
        pendingAfterMouse = false
        let id = window.id
        guard isOn, !isFloating(id), canTile(window) else { return }
        rejoin(id)
        guard let target = Screens.display(containing: point, in: Screens.all()) else {
            retile()
            return
        }
        let source = home[id]
        sentAt[id] = Date()
        touch(id)
        // Only a window in the target's current layout can be swapped with.
        let other = (plans[target.stableID]?.ids ?? []).first { $0 != id && planned[$0]?.contains(point) == true }
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
    /// You resized a tile with the mouse: the edge you dragged stays where you let go, and the
    /// tiles on the other side of it give or take the room. (Dragging a screen edge snaps back.)
    func userResized(_ window: TrackedWindow, from old: CGRect, to new: CGRect) {
        pendingAfterMouse = false
        defer { retile() }
        guard isOn, let screen = home[window.id], let plan = plans[screen], let index = plan.ids.firstIndex(of: window.id),
              let display = Screens.all().first(where: { $0.stableID == screen }) else { return }
        let gap = CGFloat(settings.gap)
        let tile = plan.frames[index]
        if layout(for: display) == .mainAndSide, plan.ids.count > 1 {
            // The edge between the main window and the others is the main window's share of the screen.
            let area = plan.area
            let portrait = ScreenShape.of(area.size) == .portrait
            let moved = index == 0
                ? abs(portrait ? new.maxY - tile.maxY : new.maxX - tile.maxX)
                : abs(portrait ? new.minY - tile.minY : new.minX - tile.minX)
            if moved > 4 {
                let length = portrait ? area.height : area.width
                let ratio = index == 0
                    ? ((portrait ? new.height : new.width) + gap * 1.5) / length
                    : ((portrait ? new.minY - area.minY : new.minX - area.minX) - gap / 2) / length
                settings.mainRatio = Double(min(max(ratio, 0.2), 0.8))
                // Shares across that edge go back to even, so it lands where you let go.
                for id in plan.ids {
                    var share = sizes[id] ?? TileSizes.even
                    if portrait { share.height = 1 } else { share.width = 1 }
                    sizes[id] = share == TileSizes.even ? nil : share
                }
                return
            }
        }
        let shares = plan.ids.map { sizes[$0] ?? TileSizes.even }
        guard let updated = TileSizes.afterDrag(frames: plan.frames, shares: shares, index: index, to: new,
                                                area: plan.area, gap: gap) else { return }
        for (id, share) in zip(plan.ids, updated) { sizes[id] = share == TileSizes.even ? nil : share }
    }

    /// Make Larger (⌃⌥=) or Make Smaller (⌃⌥-) on a tile: its share grows or shrinks one step,
    /// and the tiles around it give or take the room. The layout keeps its shape.
    ///
    /// Returns false if the window isn't a tile with neighbours (then it's resized the usual way).
    func resizeTile(_ window: TrackedWindow, larger: Bool) -> Bool {
        guard isOn, isTiled(window), let screen = home[window.id], let plan = plans[screen],
              let index = plan.ids.firstIndex(of: window.id), plan.ids.count > 1 else { return false }
        let before = plan.frames[index]
        let old = sizes[window.id] ?? TileSizes.even
        guard let next = TileSizes.resized(old, larger: larger) else {
            NSSound.beep()
            Notice.shared.show(larger ? "As large as a tile gets" : "As small as a tile gets")
            return true
        }
        sizes[window.id] = next == TileSizes.even ? nil : next
        let count = arrangements
        retile()
        if arrangements != count, let after = plans[screen], let i = after.ids.firstIndex(of: window.id),
           after.frames[i].isClose(to: before, tolerance: 2) {
            // Nothing changed: the other windows can't give any more room (apps have a smallest size).
            sizes[window.id] = old == TileSizes.even ? nil : old
            NSSound.beep()
            Notice.shared.show(larger ? "The other windows can't get any smaller" : "This window can't get any smaller")
            retile()
        }
        return true
    }

    /// Restore (⌃⌥⌫) on a tile you made larger or smaller: back to an even share.
    func evenOut(_ window: TrackedWindow) -> Bool {
        guard isOn, isTiled(window), sizes.removeValue(forKey: window.id) != nil else { return false }
        retile()
        return true
    }

    /// Picking a layout, or Retile, evens out the windows on that screen's desktop.
    private func evenOut(on screen: DisplayInfo) {
        let visible = Set(currentMembers(Screens.all()).ids)
        for id in visible where home[id] == screen.stableID { sizes[id] = nil }
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
            // Floating and pinned windows go where you put them.
            guard running, !mover.isOwnMove(id), home[id] != nil, pinned[id] == nil, !isFloating(id) else { return }
            if DragSnapper.shared.isMouseDown {
                pendingAfterMouse = true
            } else {
                // Wait until the window stops changing (macOS animates "Fill"), then look once.
                let ticket = (appMoveTicket[id] ?? 0) + 1
                appMoveTicket[id] = ticket
                after(0.35) { [weak self] in
                    guard let self, self.appMoveTicket[id] == ticket else { return }
                    self.appMoveTicket[id] = nil
                    self.movedByApp(id)
                }
            }
        case .destroyed(let id):
            forget(id)
            scheduleRetile()
        case .appTerminated(_, let ids):
            ids.forEach(forget)
            scheduleRetile()
        case .created(let id), .deminimized(let id):
            if case .created = event { applyScreenRule(id) }
            // You just opened it (or brought it back from the Dock): it comes to the front.
            touch(id)
            wanted[id] = Date()
            scheduleRetile()
        case .minimized, .appHidden, .appShown, .appLaunched:
            scheduleRetile()
        case .focused, .appActivated:
            // You're using a window. If it was waiting, the next arrangement brings it forward
            // (the debounce means ⌘` or app switching only counts the window you end on).
            guard let window = registry.focusedWindow() else { return }
            touch(window.id)
            if isWaiting(window.id) { scheduleRetile() }
        case .titleChanged:
            break
        }
    }

    /// Something other than Tessera or your mouse moved a tiled window, such as macOS "Fill" or a
    /// double-click on the title bar. If the window now fills the screen, that was a "maximise"
    /// command: it wins, and the window keeps that spot until your next layout command. Anything
    /// else (an app nudging its own window) goes back to its tile.
    private func movedByApp(_ id: CGWindowID) {
        guard running else { return }
        if let window = registry.window(id), isTiled(window), !mover.isOwnMove(id), let frame = window.frame,
           let display = Screens.display(for: frame, in: Screens.all()),
           frame.isClose(to: display.visibleFrame, tolerance: 24),
           planned[id]?.isClose(to: display.visibleFrame, tolerance: 24) != true {
            Log.info("Window \(id) was maximised outside Tessera: it keeps that spot")
            pin(window, at: frame)
            return
        }
        scheduleRetile()
    }

    /// The watchdog: a change in which windows take part must be seen twice in a row (half a
    /// second apart) before Tessera moves anything. Brief in-between states, like the middle of a
    /// desktop swipe or Mission Control, never cause a rearrangement.
    private func checkForChanges() {
        guard running, Date() >= quietUntil, !DragSnapper.shared.isMouseDown else { return }
        let members = currentMembers(Screens.all())
        guard !stillSwitching(members.moving) else {
            candidate = nil
            return
        }
        let now = Set(members.ids)
        guard now != lastSeen else {
            candidate = nil
            return
        }
        if now == candidate {
            candidate = nil
            scheduleRetile()
        } else {
            candidate = now
        }
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
        let wait = quietUntil.timeIntervalSinceNow
        if wait > 0 {
            scheduleRetile(delay: wait + 0.05)
            return
        }
        let displays = Screens.all()
        guard !displays.isEmpty else { return }
        let (visibleIDs, spaces, moving) = currentMembers(displays)
        // Mid-swipe: wait for the desktop to land.
        if stillSwitching(moving) {
            scheduleRetile(delay: 0.3)
            return
        }
        lastSeen = Set(visibleIDs)
        candidate = nil
        // A window seen for the first time counts as used by its place in the stack: the one on top most lately.
        for id in visibleIDs.reversed() where lastUsed[id] == nil { touch(id) }
        wanted = wanted.filter { Date().timeIntervalSince($0.value) < 3 }
        // The window you're using belongs in front.
        let focusedID = registry.focusedWindow()?.id

        // Pick up windows Accessibility didn't tell us about.
        let unknown = Set(visibleIDs.filter { registry.window($0) == nil }).subtracting(rescannedFor)
        if !unknown.isEmpty {
            rescannedFor.formUnion(unknown)
            registry.rescan()
        }

        // Screens that are gone: remember what they held. Screens that came back: put it back.
        let screenIDs = Set(displays.map(\.stableID))
        for gone in Set(order.keys).union(plans.keys).subtracting(screenIDs) {
            let list = order[gone] ?? []
            remembered[gone] = ScreenMemory(order: list, front: plans[gone]?.ids ?? [], layout: plans[gone]?.style,
                                            sizes: sizes.filter { list.contains($0.key) }, at: Date())
            Log.info("Screen \(gone) gone: remembering \(list.count) windows")
        }
        for back in screenIDs.subtracting(knownScreens) {
            if let memory = remembered.removeValue(forKey: back) { restore(memory, to: back, displays: displays, spaces: spaces) }
        }
        knownScreens = screenIDs
        plans = plans.filter { screenIDs.contains($0.key) }
        order = order.filter { screenIDs.contains($0.key) }

        // Group the windows on each screen's current desktop by screen, front window first.
        var present: [String: [CGWindowID]] = [:]
        var windows: [CGWindowID: TrackedWindow] = [:]
        var arrived: Set<String> = []
        let following = Date() < followScreensUntil
        let screenFrames = displays.map(\.frame)
        for id in visibleIDs {
            guard let window = registry.window(id), canTile(window), let frame = window.frame else { continue }
            var screen = home[id].flatMap { s in displays.first { $0.stableID == s } }
            // Just after screens change, a window belongs to the screen macOS put it on. (A waiting
            // window stays with its screen while that screen is still there.)
            let youChose = sentAt[id].map { Date().timeIntervalSince($0) < 6 } ?? false
            if screen == nil || following && !youChose && !FrontWindows.isWaiting(frame, screens: screenFrames) {
                screen = Screens.display(for: frame, in: displays)
            }
            guard let screen else { continue }
            if let old = home[id], old != screen.stableID {
                removeFromOrder(id)   // It joins its new screen's list at the end.
                arrived.insert(screen.stableID)
            }
            home[id] = screen.stableID
            present[screen.stableID, default: []].append(id)
            windows[id] = window
        }

        let gap = CGFloat(settings.gap)
        var moved: [CGWindowID] = []
        arrangements += 1
        for display in displays {
            let screen = display.stableID
            let here = present[screen] ?? []
            // Keep the saved order (with windows on other desktops, floating and pinned ones);
            // new windows join at the end.
            var list = (order[screen] ?? []).filter { (registry.window($0) != nil || closing.contains($0)) && home[$0] == screen }
            for id in here where !list.contains(id) { list.append(id) }
            let taking = Set(here.filter { pinned[$0] == nil && !isFloating($0) })
            let key = layoutKey(display, spaces)
            // Front windows: the first few take part in the layout; the rest wait off screen.
            let limit = frontLimit(on: display)
            if limit != nil, let previous = plans[screen], previous.key == key {
                // A front window left (closed, minimised, hidden...). The window you're in now
                // takes its exact spot if it was waiting (apps pick another of their windows when
                // one closes); otherwise the waiting window used most lately does.
                let gone = previous.ids.filter { !taking.contains($0) }
                if !gone.isEmpty {
                    var recency = lastUsed
                    if let focusedID { recency[focusedID] = Int.max }
                    let others = list.filter { taking.contains($0) && !previous.ids.contains($0) }
                    list = FrontWindows.fillSpots(left: gone, in: list, waiting: others, recency: recency)
                }
            }
            list.removeAll { closing.contains($0) }
            var tiled = list.filter(taking.contains)
            guard !tiled.isEmpty else {
                order[screen] = list
                plans[screen] = nil
                continue
            }
            // Windows arrived from another screen (one was unplugged or moved): the windows you
            // used most lately get the front spots here.
            if arrived.contains(screen) {
                tiled = FrontWindows.refill(tiled, limit: limit, kept: kept, recency: lastUsed)
            }
            // Kept windows, windows just opened or put back, and the one you're using come to the front.
            var wish = wanted.filter { taking.contains($0.key) }.sorted { $0.value < $1.value }.map(\.key)
            if let focusedID, taking.contains(focusedID), !wish.contains(focusedID) { wish.append(focusedID) }
            // The window you're in never steps back to make room, even if you last clicked it long ago.
            // Nor do windows of apps whose rule keeps them in front, while a spot stays free.
            var staying = kept.union(focusedID.map { [$0] } ?? [])
            if let limit {
                let room = max(limit - 1, 1) - staying.count
                staying.formUnion(AppRules.kept(tiled, app: { self.registry.window($0)?.bundleID }, rules: settings.rulesByApp,
                                                room: room, recency: lastUsed))
            }
            tiled = FrontWindows.arrange(tiled, limit: limit, kept: staying, wanted: wish, recency: lastUsed)
            for id in wish { wanted[id] = nil }
            list = FrontWindows.merge(tiled, into: list)
            order[screen] = list
            let (active, waiting) = FrontWindows.split(tiled, limit: limit)

            if let pending = pendingLayout[screen] {
                if here.contains(pending.window) {
                    spaceLayouts[key] = pending.style
                    pendingLayout[screen] = nil
                } else if Date().timeIntervalSince(pending.at) > 5 {
                    pendingLayout[screen] = nil
                }
            }
            let style = spaceLayouts[key] ?? settings.layout(for: screen)
            spaceLayouts[key] = style
            let plan = TilePlanner.plan(
                count: active.count,
                in: freeArea(on: display),
                style: style,
                gap: gap,
                mainRatio: style == .mainAndSide ? CGFloat(settings.mainRatio) : 0.5,
                minimumSizes: active.map { minimums[$0] },
                sizes: active.map { sizes[$0] ?? TileSizes.even }
            )
            if plan.fits { crowded.remove(screen) } else { crowded.insert(screen) }
            plans[screen] = ScreenPlan(style: style, ids: active, frames: plan.frames, area: freeArea(on: display),
                                       fits: plan.fits, key: key, waiting: waiting, limit: limit)
            for (id, frame) in zip(active, plan.frames) {
                guard let window = windows[id] else { continue }
                planned[id] = frame
                lastFrontFrame[id] = frame
                let before = mover.moveCount
                mover.move(window, to: frame, within: display.visibleFrame, slack: Self.slack)
                if mover.moveCount != before { moved.append(id) }   // Only check windows that really moved.
            }
            // Waiting windows: just off the bottom corner, keeping their size.
            let otherScreens = displays.filter { $0.stableID != screen }.map(\.frame)
            let allScreens = displays.map(\.frame)
            for id in waiting {
                guard let window = windows[id], let frame = window.frame else { continue }
                planned[id] = nil
                // Already hanging out of sight off this screen: leave it.
                if FrontWindows.isOutOfSight(frame, on: display.frame, screens: allScreens) { continue }
                // macOS may refuse a spot (it keeps title bars above the Dock): try the next one.
                let spots = FrontWindows.waitingFrames(size: frame.size, screen: display.frame, otherScreens: otherScreens)
                for spot in spots.prefix(8) {
                    let got = mover.move(window, to: spot) ?? spot
                    if FrontWindows.isOutOfSight(got, on: display.frame, screens: allScreens) { break }
                }
            }
        }
        for id in closing { home[id] = nil }
        closing.removeAll()
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
            mover.noteSettled(id, at: actual)
            if var known = minimums[id] {
                if actual.width < known.width - 4 { known.width = actual.width }
                if actual.height < known.height - 4 { known.height = actual.height }
                minimums[id] = known
            }
            // Any overshoot gets a second try (an app rounding up even 2 points would poke into
            // its neighbour). Only a window still well over after that has a real minimum size.
            guard actual.width > target.width + 1 || actual.height > target.height + 1 else { continue }
            // Already known to be this big: nothing to learn, and asking again would only make it jump.
            if let known = minimums[id],
               actual.width <= max(target.width + 1, known.width + 4),
               actual.height <= max(target.height + 1, known.height + 4) { continue }
            guard confirming else {
                suspects.append(id)
                continue
            }
            // Still more than a few points over after asking for less: that's the app's minimum size.
            // (An app that only rounds to whole characters lands inside its tile on the second try.)
            let tooWide = actual.width > target.width + 4
            let tooTall = actual.height > target.height + 4
            guard tooWide || tooTall else { continue }
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
                guard let window = registry.window(id), let target = planned[id], let actual = window.frame else { continue }
                let overWide = max(0, actual.width - target.width)
                let overTall = max(0, actual.height - target.height)
                if overWide <= Self.slack && overTall <= Self.slack {
                    // Just over: ask for a little less, so an app that rounds up lands inside its tile.
                    let smaller = CGRect(x: target.minX, y: target.minY,
                                         width: target.width - overWide, height: target.height - overTall)
                    mover.move(window, to: smaller, force: true)
                } else {
                    mover.move(window, to: target, force: true)
                }
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
        guard !settings.isIgnored(window.bundleID), settings.rule(for: window.bundleID)?.float != true else { return false }
        if NSRunningApplication(processIdentifier: window.pid)?.isHidden == true { return false }
        if window.element.isFullScreen { return false }
        if kind[window.id] == true { return true }
        // Only "yes" is cached: some apps finish setting up a new window a moment after showing it.
        let ok = window.isStandard && window.isResizable
        if ok { kind[window.id] = true }
        return ok
    }

    /// The windows that take part now, front to back: normal windows on screen that live on the
    /// desktop their screen is showing. Also returns each screen's current desktop.
    ///
    /// During a desktop swipe, windows from both desktops are on screen for a moment; the desktop
    /// check keeps the other desktop's windows out, so nothing jumps.
    ///
    /// `moving` is true while a switch is still under way: some window on screen belongs only to a
    /// desktop the screen isn't showing.
    private func currentMembers(_ displays: [DisplayInfo])
        -> (ids: [CGWindowID], spaces: [CGDirectDisplayID: Spaces.SpaceID]?, moving: Bool) {
        let me = getpid()
        let visible = WindowServer.onScreen()
            .filter { $0.layer == 0 && $0.pid != me && $0.alpha > 0 && $0.bounds.width > 40 && $0.bounds.height > 40 }
            .map(\.id)
        guard let spaces = Spaces.current(for: displays) else { return (visible, nil, false) }
        let current = Set(spaces.values)
        var moving = false
        let members = visible.filter { id in
            let on = Spaces.spaces(of: id)
            // macOS didn't say: go by what's on screen.
            if on.isEmpty { return true }
            if on.isDisjoint(with: current) { moving = true }
            // A window shown on every desktop would push the others around on each one: leave it alone.
            return on.count == 1 && current.contains(on.first!)
        }
        return (members, spaces, moving)
    }

    /// True while a desktop switch is under way, for at most 2 seconds (in case some window
    /// always looks that way).
    private func stillSwitching(_ moving: Bool) -> Bool {
        guard moving else {
            switchingSince = nil
            return false
        }
        let since = switchingSince ?? Date()
        switchingSince = since
        return Date().timeIntervalSince(since) < 2
    }

    /// A screen came back: the windows it held go back to it in their old order (except ones you've
    /// since moved yourself), the ones that were in front come to the front, and it gets its old layout.
    /// They count as sent there, so Tessera doesn't follow wherever macOS happens to put them meanwhile.
    private func restore(_ memory: ScreenMemory, to screen: String, displays: [DisplayInfo],
                         spaces: [CGDirectDisplayID: Spaces.SpaceID]?) {
        let alive = memory.order.filter { id in
            registry.window(id) != nil && (sentAt[id].map { $0 < memory.at } ?? true)
        }
        if let style = memory.layout, let display = displays.first(where: { $0.stableID == screen }) {
            spaceLayouts[layoutKey(display, spaces)] = style
        }
        guard !alive.isEmpty else { return }
        let now = Date()
        for id in alive {
            removeFromOrder(id)
            home[id] = screen
            sentAt[id] = now
            if let size = memory.sizes[id] { sizes[id] = size }
        }
        order[screen] = alive + (order[screen] ?? []).filter { !alive.contains($0) }
        for id in memory.front where alive.contains(id) { wanted[id] = now }
        Log.info("Screen \(screen) back: \(alive.count) windows return to it")
    }

    /// Which layout a screen uses now: per desktop when macOS says which desktop it shows.
    private func layoutKey(_ display: DisplayInfo, _ spaces: [CGDirectDisplayID: Spaces.SpaceID]?) -> String {
        if let space = spaces?[display.displayID] { return "\(display.stableID)#\(space)" }
        return display.stableID
    }

    /// Puts windows snapped by hand on a screen's current desktop back into the layout.
    private func unpinVisible(on screen: DisplayInfo) {
        let visible = Set(currentMembers(Screens.all()).ids)
        for id in pinned.keys where visible.contains(id) && home[id] == screen.stableID {
            rejoin(id)
        }
    }

    /// The latest command wins over macOS full screen too: a layout picked while a full-screen
    /// window is in front takes it out of full screen, then arranges the desktop it goes back to.
    /// Returns true if that is happening.
    private func leaveFullScreen(on screen: DisplayInfo, style: LayoutStyle?) -> Bool {
        guard let window = registry.focusedWindow(), window.element.isFullScreen,
              !settings.isIgnored(window.bundleID), let frame = window.frame,
              Screens.display(for: frame, in: Screens.all())?.stableID == screen.stableID else { return false }
        Log.info("Taking window \(window.id) out of full screen for the new layout")
        window.element.set("AXFullScreen", bool: false)
        if let style { pendingLayout[screen.stableID] = (window.id, style, Date()) }
        // macOS animates back to the desktop; arrange once it has landed.
        quietUntil = Date().addingTimeInterval(1.2)
        scheduleRetile(delay: 1.25)
        return true
    }

    private func currentScreen() -> DisplayInfo? {
        let displays = Screens.all()
        if let window = registry.focusedWindow(), let frame = window.frame {
            return Screens.display(for: frame, in: displays)
        }
        return Screens.display(containing: Screens.mouseLocation, in: displays) ?? displays.first
    }

    /// A window now on another screen belongs to that screen's tiles (at the end).
    private func rehome(_ id: CGWindowID, frame: CGRect) {
        guard let display = Screens.display(for: frame, in: Screens.all()), home[id] != display.stableID else { return }
        removeFromOrder(id)
        home[id] = display.stableID
        order[display.stableID, default: []].append(id)
    }

    private func removeFromOrder(_ id: CGWindowID) {
        if let screen = home.removeValue(forKey: id) {
            order[screen]?.removeAll { $0 == id }
        }
    }

    private func forget(_ id: CGWindowID) {
        // A front window closed while others wait: keep its place until the next arrangement fills it.
        if let screen = home[id], let plan = plans[screen], plan.ids.contains(id), !plan.waiting.isEmpty {
            closing.insert(id)
        } else {
            removeFromOrder(id)
        }
        lastUsed[id] = nil
        wanted[id] = nil
        kept.remove(id)
        lastFrontFrame[id] = nil
        sentAt[id] = nil
        sizes[id] = nil
        floating.remove(id)
        pinned[id] = nil
        appMoveTicket[id] = nil
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
            "spacesSupported": Spaces.isAvailable,
            "spaceLayouts": spaceLayouts.mapValues(\.rawValue),
            "currentLayouts": Dictionary(Screens.all().map { ($0.stableID, layout(for: $0).rawValue) }, uniquingKeysWith: { a, _ in a }),
            "currentSpaces": (Spaces.current(for: Screens.all()) ?? [:]).map { "\($0.key):\($0.value)" },
            "moves": mover.moveCount,
            "desktops": Spaces.all(),
            "pendingLayout": pendingLayout.mapValues { "\($0.window):\($0.style.rawValue)" },
            "floating": floating.map(Int.init),
            "pinned": Dictionary(uniqueKeysWithValues: pinned.map { (String($0.key), NSStringFromRect($0.value)) }),
            "crowded": Array(crowded),
            "sizes": Dictionary(uniqueKeysWithValues: sizes.map { (String($0.key), [Double($0.value.width), Double($0.value.height)]) }),
            "frontLimit": settings.frontLimit.raw,
            "limits": Dictionary(Screens.all().map { ($0.stableID, frontLimit(on: $0) ?? 0) }, uniquingKeysWith: { a, _ in a }),
            "waiting": plans.mapValues { $0.waiting.map(Int.init) },
            "kept": kept.map(Int.init),
            "lastUsed": Dictionary(uniqueKeysWithValues: lastUsed.map { (String($0.key), $0.value) }),
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
