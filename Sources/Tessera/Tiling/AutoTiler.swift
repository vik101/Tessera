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
    struct ScreenPlan {
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
        /// The space between windows on this screen.
        var gap: CGFloat = 0
    }
    private var plans: [String: ScreenPlan] = [:]

    // The Tree layout.
    typealias Tree = TileTree<CGWindowID>
    /// One tree per desktop (by `layoutKey`).
    private var trees: [String: Tree] = [:]
    /// Where a window sat in its tree before it left (minimised, hidden, floated), so it goes back there.
    private var hints: [CGWindowID: (key: String, hint: Tree.Hint)] = [:]
    /// Where the next window opens beside this one (`preselect`).
    private var preselected: [CGWindowID: Direction] = [:]
    /// Windows filling their desktop until zoomed again (AeroSpace's `fullscreen`).
    private var zoomed: Set<CGWindowID> = []
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
        if running { rememberGoneScreens(Screens.all()) }
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
        let key = layoutKey(screen, Spaces.current(for: Screens.all()))
        let previous = plans[screen.stableID]
        if style == .tree {
            if let previous, previous.key == key, previous.style != .tree, !previous.ids.isEmpty {
                // Switching to Tree keeps every window where it is: the tree is cut from the layout on screen.
                trees[key] = Tree.fromFrames(Array(zip(previous.ids, previous.frames)).map { (id: $0.0, frame: $0.1) },
                                             in: previous.area, orientation: rootOrientation(previous.area))
            } else {
                trees[key]?.balance()
            }
        } else if let previous, previous.style == .tree, let tree = trees[key], let list = order[screen.stableID] {
            // Leaving Tree: the other layouts take the tree's order.
            let members = tree.windows.filter { list.contains($0) }
            order[screen.stableID] = FrontWindows.merge(members, into: list)
        }
        spaceLayouts[key] = style
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
        if let plan = plans[screen], plan.style == .tree, var tree = trees[plan.key] {
            tree.mirror(.horizontal)
            tree.mirror(.vertical)
            trees[plan.key] = tree
            retile()
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
        if let plan = plans[screen], plan.style == .tree, var tree = trees[plan.key], tree.contains(window.id) {
            // The first tile is the main one; the first window trades places with the second.
            let all = tree.windows
            if let other = all.first == window.id ? all.dropFirst().first : all.first {
                tree.swap(window.id, other)
                trees[plan.key] = tree
            }
            retile()
            return
        }
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
        guard let screen = home[window.id], pinned[window.id] == nil, !isFloating(window.id) else { return false }
        return plans[screen]?.style != .float
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
        // The Tree layout moves the window through its tree, like AeroSpace's `move`.
        if plan.style == .tree, var tree = trees[plan.key] {
            if tree.move(window.id, direction) {
                trees[plan.key] = tree
                retile()
                return true
            }
            return moveToNeighbourScreen(window, from: screen, direction)
        }
        let others = zip(plan.ids, plan.frames).filter { $0.0 != window.id }.map { (id: UInt32($0.0), frame: $0.1) }
        if let next = Navigation.neighbour(of: plan.frames[index], direction: direction, among: others) {
            let other = CGWindowID(next)
            order[screen] = TileOrder.swap(window.id, other, in: order[screen] ?? [])
            (sizes[window.id], sizes[other]) = (sizes[other], sizes[window.id])
            retile()
            return true
        }
        return moveToNeighbourScreen(window, from: screen, direction)
    }

    /// Past the edge: the window goes to the screen next to this one that way, if there is one.
    private func moveToNeighbourScreen(_ window: TrackedWindow, from screen: String, _ direction: Direction) -> Bool {
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

    /// You dragged a window and let go at `point`. On the middle of another tile, the two swap. Near a
    /// tile's edge, the window sits beside it on that side. Anywhere else on a screen, it joins that screen.
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
        let targetPlan = plans[target.stableID]
        // Only a window in the target's current layout can be dropped on.
        let other = (targetPlan?.ids ?? []).first { $0 != id && planned[$0]?.contains(point) == true }
        let zone = other.flatMap { planned[$0] }.flatMap { Self.dropZone(point, in: $0) }
        if let other, let source, let targetPlan, targetPlan.style == .tree {
            let sourceKey = plans[source]?.key
            if let zone {
                // Beside the tile: out of its old place, into a split of that tile.
                if let sourceKey, var tree = trees[sourceKey] {
                    tree.remove(id)
                    trees[sourceKey] = tree
                }
                if source != target.stableID {
                    removeFromOrder(id)
                    home[id] = target.stableID
                    order[target.stableID, default: []].append(id)
                }
                var tree = trees[targetPlan.key] ?? Tree()
                tree.insert(id, splitting: other, direction: zone)
                trees[targetPlan.key] = tree
            } else if source == target.stableID, var tree = trees[targetPlan.key] {
                tree.swap(id, other)
                trees[targetPlan.key] = tree
            } else {
                if let sourceKey, var tree = trees[sourceKey] {
                    tree.replace(id, with: other)
                    trees[sourceKey] = tree
                }
                if var tree = trees[targetPlan.key] {
                    tree.replace(other, with: id)
                    trees[targetPlan.key] = tree
                }
                order[source] = (order[source] ?? []).map { $0 == id ? other : $0 }
                order[target.stableID] = (order[target.stableID] ?? []).map { $0 == other ? id : $0 }
                home[id] = target.stableID
                home[other] = source
                sentAt[other] = Date()
            }
        } else if let other, let source {
            if let zone {
                // Beside the tile: just before it (left or above) or just after it in the order.
                removeFromOrder(id)
                home[id] = target.stableID
                var list = order[target.stableID] ?? []
                let at = list.firstIndex(of: other).map { zone.isForward ? $0 + 1 : $0 } ?? list.count
                list.insert(id, at: min(at, list.count))
                order[target.stableID] = list
            } else if source == target.stableID {
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

    /// Where on a tile a drop lands: its middle (nil: swap), or the edge it's nearest.
    static func dropZone(_ point: CGPoint, in frame: CGRect) -> Direction? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let x = (point.x - frame.minX) / frame.width
        let y = (point.y - frame.minY) / frame.height
        if (0.25...0.75).contains(x) && (0.25...0.75).contains(y) { return nil }
        let distances: [(Direction, CGFloat)] = [(.left, x), (.right, 1 - x), (.up, y), (.down, 1 - y)]
        return distances.min { $0.1 < $1.1 }?.0
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
        let gap = plan.gap
        let tile = plan.frames[index]
        // Tree: each edge you dragged moves, and only the neighbour across it gives way.
        if plan.style == .tree, var tree = trees[plan.key] {
            let edges: [(Direction, CGFloat)] = [(.left, tile.minX - new.minX), (.right, new.maxX - tile.maxX),
                                                 (.up, tile.minY - new.minY), (.down, new.maxY - tile.maxY)]
            var changed = false
            for (edge, growth) in edges where abs(growth) > 4 {
                if tree.moveEdge(window.id, edge, by: growth, in: plan.area, gap: gap) { changed = true }
            }
            if changed { trees[plan.key] = tree }
            return
        }
        if plan.style == .stack || plan.style == .float { return }
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
        if plan.style == .stack { return true }
        if plan.style == .tree {
            // A tenth of the screen at a time, along the way the window's container runs (then the other way).
            let parentWay = trees[plan.key]?.parent(of: window.id)?.orientation ?? .horizontal
            for way in [parentWay, parentWay.opposite] {
                let length = way == .horizontal ? plan.area.width : plan.area.height
                if resize(window, along: way, by: (larger ? 1 : -1) * (length / 10).rounded()) { return true }
            }
            NSSound.beep()
            return true
        }
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
        guard isOn, isTiled(window) else { return false }
        if let key = home[window.id].flatMap({ plans[$0] }).map(\.key), var tree = trees[key],
           plans[home[window.id]!]?.style == .tree {
            let before = tree
            tree.balance()
            guard tree != before else { return false }
            trees[key] = tree
            retile()
            return true
        }
        guard sizes.removeValue(forKey: window.id) != nil else { return false }
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

    // MARK: Commands for the Tree layout and the command language

    /// The plan of the screen a window is tiled on.
    private func planOf(_ window: TrackedWindow) -> ScreenPlan? { home[window.id].flatMap { plans[$0] } }

    /// The layout of the desktop a window is on.
    func style(of window: TrackedWindow) -> LayoutStyle? { planOf(window)?.style }

    /// Runs a change on the tree of the window's desktop. A desktop with another layout switches to
    /// Tree first, cut from what's on screen, so nothing moves before the change.
    @discardableResult
    func changeTree(_ window: TrackedWindow, _ change: (inout Tree, ScreenPlan) -> Bool) -> Bool {
        guard isOn, isTiled(window), let screen = home[window.id],
              let display = Screens.all().first(where: { $0.stableID == screen }) else { return false }
        if plans[screen]?.style != .tree { setLayout(.tree, for: display, notify: false) }
        guard let plan = plans[screen], plan.style == .tree, var tree = trees[plan.key], tree.contains(window.id) else { return false }
        touch(window.id)
        guard change(&tree, plan) else { return false }
        trees[plan.key] = tree
        retile()
        return true
    }

    /// The windows on a window's screen in layout order (depth first in a tree).
    func layoutOrder(of window: TrackedWindow) -> [CGWindowID] { planOf(window)?.ids ?? [] }

    /// The windows on a screen in layout order.
    func layoutOrder(on display: DisplayInfo) -> [CGWindowID] { plans[display.stableID]?.ids ?? [] }

    /// Swaps a window with its neighbour that way, or the next or previous one in layout order.
    func swap(_ window: TrackedWindow, _ target: SwapTarget, wrap: Bool) -> CGWindowID? {
        guard isOn, isTiled(window), let plan = planOf(window), let index = plan.ids.firstIndex(of: window.id),
              let screen = home[window.id] else { return nil }
        let other: CGWindowID?
        switch target {
        case .next, .previous:
            let step = target == .next ? 1 : -1
            let i = index + step
            if plan.ids.indices.contains(i) { other = plan.ids[i] } else if wrap, plan.ids.count > 1 {
                other = plan.ids[(i + plan.ids.count) % plan.ids.count]
            } else { other = nil }
        case .direction(let direction):
            let others = zip(plan.ids, plan.frames).filter { $0.0 != window.id }.map { (id: UInt32($0.0), frame: $0.1) }
            let found: UInt32? = Navigation.neighbour(of: plan.frames[index], direction: direction, among: others)
            other = found
        }
        guard let other, other != window.id else { return nil }
        touch(window.id)
        if plan.style == .tree, var tree = trees[plan.key] {
            tree.swap(window.id, other)
            trees[plan.key] = tree
        } else {
            order[screen] = TileOrder.swap(window.id, other, in: order[screen] ?? [])
            (sizes[window.id], sizes[other]) = (sizes[other], sizes[window.id])
        }
        retile()
        return other
    }

    /// Evens out the tiles on a window's desktop (AeroSpace's `balance-sizes`).
    func balance(_ window: TrackedWindow) -> Bool {
        guard isOn, let screen = home[window.id], let plan = plans[screen],
              let display = Screens.all().first(where: { $0.stableID == screen }) else { return false }
        if plan.style == .tree, var tree = trees[plan.key] {
            tree.balance()
            trees[plan.key] = tree
        } else {
            evenOut(on: display)
        }
        retile()
        return true
    }

    /// Where the next window opens beside this one (nil cancels).
    func preselect(_ window: TrackedWindow, _ direction: Direction?) {
        if let direction { preselected[window.id] = direction } else { preselected[window.id] = nil }
    }

    /// Grows a tiled window by points across `way` (AeroSpace's `resize`). Other layouts scale the window's share.
    @discardableResult
    func resize(_ window: TrackedWindow, along way: Orientation, by delta: CGFloat) -> Bool {
        guard isOn, isTiled(window), let plan = planOf(window), let index = plan.ids.firstIndex(of: window.id) else { return false }
        switch plan.style {
        case .tree:
            guard var tree = trees[plan.key], tree.resize(window.id, along: way, by: delta, in: plan.area, gap: plan.gap) else { return false }
            trees[plan.key] = tree
        case .stack, .float:
            return false
        default:
            let frame = plan.frames[index]
            let length = way == .horizontal ? frame.width : frame.height
            guard length > 0 else { return false }
            var share = sizes[window.id] ?? TileSizes.even
            let factor = max(length + delta, 40) / length
            if way == .horizontal { share.width = min(max(share.width * factor, TileSizes.range.lowerBound), TileSizes.range.upperBound) }
            else { share.height = min(max(share.height * factor, TileSizes.range.lowerBound), TileSizes.range.upperBound) }
            sizes[window.id] = share == TileSizes.even ? nil : share
        }
        touch(window.id)
        retile()
        return true
    }

    /// The size a tiled window has across `way` now.
    func tileLength(_ window: TrackedWindow, along way: Orientation) -> CGFloat? {
        guard let plan = planOf(window), let index = plan.ids.firstIndex(of: window.id) else { return nil }
        return way == .horizontal ? plan.frames[index].width : plan.frames[index].height
    }

    /// The way a window's tree container runs (or the screen's long side, outside the Tree layout).
    func containerWay(of window: TrackedWindow) -> Orientation {
        if let plan = planOf(window), plan.style == .tree, let parent = trees[plan.key]?.parent(of: window.id), !(trees[plan.key]?.count == 1) {
            return parent.orientation
        }
        return Orientation.along(planOf(window)?.area.size ?? CGSize(width: 2, height: 1))
    }

    /// Moves one edge of a tile by points (Spacetile's `border`): the right or bottom edge if there's a
    /// neighbour there, else the left or top. Only that neighbour gives way.
    @discardableResult
    func moveBorder(_ window: TrackedWindow, along way: Orientation, by delta: CGFloat) -> Bool {
        guard isOn, isTiled(window), let plan = planOf(window), let index = plan.ids.firstIndex(of: window.id) else { return false }
        let forward = way == .horizontal ? Direction.right : .down
        if plan.style == .tree {
            guard var tree = trees[plan.key] else { return false }
            guard tree.moveEdge(window.id, forward, by: delta, in: plan.area, gap: plan.gap)
                || tree.moveEdge(window.id, forward.opposite, by: delta, in: plan.area, gap: plan.gap) else { return false }
            trees[plan.key] = tree
            retile()
            return true
        }
        guard plan.style.isAdaptive else { return false }
        var frame = plan.frames[index]
        let area = plan.area
        let atFarEdge = way == .horizontal ? abs(frame.maxX - area.maxX) <= plan.gap + 2 : abs(frame.maxY - area.maxY) <= plan.gap + 2
        if way == .horizontal {
            if atFarEdge { frame.origin.x -= delta }
            frame.size.width += delta
        } else {
            if atFarEdge { frame.origin.y -= delta }
            frame.size.height += delta
        }
        let shares = plan.ids.map { sizes[$0] ?? TileSizes.even }
        guard let updated = TileSizes.afterDrag(frames: plan.frames, shares: shares, index: index, to: frame,
                                                area: area, gap: plan.gap) else { return false }
        for (id, share) in zip(plan.ids, updated) { sizes[id] = share == TileSizes.even ? nil : share }
        retile()
        return true
    }

    func isZoomed(_ id: CGWindowID) -> Bool { zoomed.contains(id) }

    /// A tiled window fills its desktop until you zoom it again. Returns false for windows that aren't tiled.
    func zoom(_ window: TrackedWindow, _ toggle: Toggle) -> Bool {
        guard isOn, isTiled(window) else { return false }
        if toggle.apply(to: zoomed.contains(window.id)) { zoomed.insert(window.id) } else { zoomed.remove(window.id) }
        touch(window.id)
        retile()
        return true
    }

    /// Stack layout: shows the next (or previous) window on this desktop.
    func stackStep(_ window: TrackedWindow?, forward: Bool) -> Bool {
        guard let window = window ?? registry.focusedWindow(), let plan = planOf(window), plan.ids.count > 1,
              let index = plan.ids.firstIndex(of: window.id) else { return false }
        let next = plan.ids[(index + (forward ? 1 : -1) + plan.ids.count) % plan.ids.count]
        guard let target = registry.window(next) else { return false }
        focus(target)
        return true
    }

    /// Floats a window or tiles it again.
    func setFloating(_ window: TrackedWindow, _ toggle: Toggle) -> Bool {
        guard isOn, canTile(window) || floating.contains(window.id) else { return false }
        let now = floating.contains(window.id)
        let want = toggle.apply(to: now)
        guard want != now || pinned[window.id] != nil else { return true }
        if want {
            floating.insert(window.id)
            window.element.perform(kAXRaiseAction)
        } else {
            rejoin(window.id)
            if let frame = window.frame { rehome(window.id, frame: frame) }
        }
        retile()
        return true
    }

    func isFloatingWindow(_ id: CGWindowID) -> Bool { isFloating(id) }

    /// Keeps a window in front (or lets it step back).
    func setKept(_ window: TrackedWindow, _ toggle: Toggle) -> Bool {
        let now = kept.contains(window.id)
        if toggle.apply(to: now) == now { return true }
        guard let focused = registry.focusedWindow(), focused.id == window.id else {
            if now { kept.remove(window.id) } else { kept.insert(window.id) }
            retile()
            return true
        }
        toggleKeep()
        return true
    }

    /// The tree of the desktop a screen shows, as text, for `tessera tree`.
    func treeText(on display: DisplayInfo) -> String? {
        guard let plan = plans[display.stableID], plan.style == .tree, let tree = trees[plan.key] else { return nil }
        return Self.describe(tree)
    }

    /// The layout of every screen's current desktop.
    func currentStyle(on display: DisplayInfo) -> LayoutStyle {
        plans[display.stableID]?.style ?? layout(for: display)
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
        rememberGoneScreens(displays)
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

        var moved: [CGWindowID] = []
        var raise: [TrackedWindow] = []
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
            let (gap, area) = planArea(on: display, displays: displays)
            // Front windows (adaptive layouts only): the first few take part in the layout; the rest wait off screen.
            let limit = style.isAdaptive ? frontLimit(on: display) : nil
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
                plans[screen] = ScreenPlan(style: style, ids: [], frames: [], area: area, fits: true, key: key,
                                           waiting: [], limit: limit, gap: gap)
                if style == .tree, var tree = trees[key] {
                    for id in tree.windows { if let hint = tree.remove(id) { hints[id] = (key, hint) } }
                    trees[key] = tree
                }
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
            var (active, waiting) = FrontWindows.split(tiled, limit: limit)

            // Where each window goes.
            var frames: [CGRect]
            var fits = true
            switch style {
            case .float:
                // Nothing is tiled here. Windows left waiting off screen by another layout come back.
                for id in tiled {
                    guard let window = windows[id], let frame = window.frame,
                          FrontWindows.isWaiting(frame, screens: screenFrames) else { continue }
                    mover.move(window, to: lastFrontFrame[id] ?? Self.centred(frame.size, in: display.visibleFrame),
                               within: display.visibleFrame)
                }
                plans[screen] = ScreenPlan(style: .float, ids: [], frames: [], area: area, fits: true, key: key,
                                           waiting: [], limit: nil, gap: gap)
                continue
            case .tree:
                let laid = treeLayout(key, active, area: area, gap: gap)
                active = laid.ids
                frames = laid.frames
                fits = laid.fits
                waiting = []
            case .stack:
                frames = Array(repeating: applyGap(area, in: area, gap: gap), count: active.count)
            default:
                let plan = TilePlanner.plan(
                    count: active.count,
                    in: area,
                    style: style,
                    gap: gap,
                    mainRatio: style == .mainAndSide ? CGFloat(settings.mainRatio) : 0.5,
                    minimumSizes: active.map { minimums[$0] },
                    sizes: active.map { sizes[$0] ?? TileSizes.even }
                )
                frames = plan.frames
                fits = plan.fits
            }
            // A zoomed window fills the desktop, on top of the others.
            for (i, id) in active.enumerated() where zoomed.contains(id) {
                frames[i] = applyGap(area, in: area, gap: gap)
                if let window = windows[id] { raise.append(window) }
            }
            if fits { crowded.remove(screen) } else { crowded.insert(screen) }
            plans[screen] = ScreenPlan(style: style, ids: active, frames: frames, area: area,
                                       fits: fits, key: key, waiting: waiting, limit: limit, gap: gap)
            for (id, frame) in zip(active, frames) {
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
        for window in raise { window.element.perform(kAXRaiseAction) }
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

    /// The gap between windows on a screen, and the area its layout plans in (see `Gaps.resolve`).
    private func planArea(on display: DisplayInfo, displays: [DisplayInfo]) -> (gap: CGFloat, area: CGRect) {
        let gaps = settings.gaps(for: display, in: displays)
        return gaps.resolve(visible: freeArea(on: display), display: Screens.context(of: display, in: displays))
    }

    /// Which way a new tree's root runs: the config's choice, or along the screen's long side.
    private func rootOrientation(_ area: CGRect) -> Orientation {
        ConfigStore.shared.config.defaultOrientation ?? Orientation.along(area.size)
    }

    /// A new window splits a tile along its long side: a wide tile side by side, a tall one top to bottom.
    private func splitDirection(for target: CGWindowID?, in area: CGRect) -> Direction {
        let frame = target.flatMap { planned[$0] } ?? area
        return frame.width >= frame.height ? .right : .down
    }

    /// The Tree layout for one desktop: windows that left come out of the tree (remembering where
    /// they were), new ones split the window you used last, then every window gets its frame.
    private func treeLayout(_ key: String, _ ids: [CGWindowID], area: CGRect, gap: CGFloat)
        -> (ids: [CGWindowID], frames: [CGRect], fits: Bool) {
        var tree = trees[key] ?? {
            var fresh = Tree(orientation: rootOrientation(area))
            if let layout = ConfigStore.shared.config.defaultContainerLayout { fresh.root.layout = layout }
            return fresh
        }()
        let present = Set(ids)
        for id in tree.windows where !present.contains(id) {
            if let hint = tree.remove(id) { hints[id] = (key, hint) }
        }
        for id in ids where !tree.contains(id) {
            let target = tree.windows.max { (lastUsed[$0] ?? 0) < (lastUsed[$1] ?? 0) }
            let direction = target.flatMap { preselected.removeValue(forKey: $0) } ?? splitDirection(for: target, in: area)
            let hint = hints.removeValue(forKey: id).flatMap { $0.key == key ? $0.hint : nil }
            if tree.isEmpty { tree.root.orientation = rootOrientation(area) }
            tree.insert(id, hint: hint, fallback: target, direction: direction)
        }
        trees[key] = tree
        var mins: [CGWindowID: CGSize] = [:]
        for id in tree.windows { if let size = minimums[id] { mins[id] = size } }
        let byID = tree.frames(in: area, gap: gap, padding: CGFloat(settings.accordionPadding), minimums: mins)
        let order = tree.windows
        let frames = order.map { byID[$0] ?? area }
        let fits = zip(order, frames).allSatisfy { id, frame in
            guard let need = minimums[id] else { return true }
            return need.width <= frame.width + 1 && need.height <= frame.height + 1
        }
        return (order, frames, fits)
    }

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

    /// Screens that are gone: remember what each held (every window whose home it was, in tile order),
    /// as early as possible, before macOS starts moving those windows and they get new homes.
    private func rememberGoneScreens(_ displays: [DisplayInfo]) {
        let present = Set(displays.map(\.stableID))
        for gone in Set(order.keys).union(plans.keys).union(home.values).subtracting(present) {
            // Already remembered moments ago (when the screens changed): keep that fuller picture.
            if let memory = remembered[gone], Date().timeIntervalSince(memory.at) < 30 { continue }
            let homed = Set(home.filter { $0.value == gone }.map(\.key))
            let saved = order[gone] ?? []
            let list = saved.filter { homed.contains($0) } + homed.subtracting(saved).sorted()
            guard !list.isEmpty || plans[gone] != nil else { continue }
            remembered[gone] = ScreenMemory(order: list, front: plans[gone]?.ids ?? [], layout: plans[gone]?.style,
                                            sizes: sizes.filter { list.contains($0.key) }, at: Date())
            Log.info("Screen \(gone) gone: remembering \(list.count) windows")
        }
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
        for (key, tree) in trees where tree.contains(id) {
            var copy = tree
            copy.remove(id)
            trees[key] = copy
        }
        hints[id] = nil
        preselected[id] = nil
        zoomed.remove(id)
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

    /// A tree as text: H[1 V[2 3]] (HA/VA for accordions).
    static func describe(_ tree: Tree) -> String {
        func text(_ node: Tree.Node) -> String {
            switch node {
            case .window(let id): return "\(id)"
            case .container(let c):
                let letter = (c.orientation == .horizontal ? "H" : "V") + (c.layout == .accordion ? "A" : "")
                return letter + "[" + c.children.map(text).joined(separator: " ") + "]"
            }
        }
        return text(.container(tree.root))
    }

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
            "trees": trees.mapValues { Self.describe($0) },
            "zoomed": zoomed.map(Int.init),
            "preselected": Dictionary(uniqueKeysWithValues: preselected.map { (String($0.key), $0.value.rawValue) }),
        ]
    }
}
