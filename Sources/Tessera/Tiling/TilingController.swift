import AppKit
import TesseraCore

/// The brain: keeps a model of every screen's tiles and applies it to real windows.
///
/// Flow: Accessibility events → `handle(_:)` → change a `ScreenState` → `apply(_:)`.
@MainActor
final class TilingController {
    static let shared = TilingController()

    let registry = WindowRegistry()
    let applier = FrameApplier()
    private let prefs = Preferences.shared
    private let model = AppModel.shared

    // MARK: State

    private(set) var displays: [DisplayInfo] = []
    private var spaceByDisplay: [CGDirectDisplayID: UInt64] = [:]
    /// Screen models, keyed by "stableScreenID#spaceID".
    private(set) var states: [String: ScreenState] = [:]
    /// The tile frames last applied, per screen key.
    private(set) var frames: [String: [Int: CGRect]] = [:]
    /// The window showing in each tile at the last apply, to spot stacks whose top changed.
    private var lastShowing: [String: [CGWindowID]] = [:]

    enum FloatReason { case full, tooBig }

    /// Windows the user floated.
    private(set) var floating: Set<CGWindowID> = []
    /// Windows Tessera floated because there was no room.
    private(set) var autoFloating: [CGWindowID: FloatReason] = [:]
    private var minimizedOrigin: [CGWindowID: (key: String, tile: Int)] = [:]
    private(set) var focusedID: CGWindowID?
    /// Most recently focused first.
    private(set) var recent: [CGWindowID] = []
    private(set) var focusMode: (window: CGWindowID, key: String)?

    /// Set by the drag controller while the user drags a tiled window.
    var dragInProgress: CGWindowID?
    /// Called after anything visible changes (overlays redraw).
    var onChange: (() -> Void)?

    // Setups place windows by app.
    var pendingPlacements: [String: [SetupPlanner.Placement]] = [:]
    var onSetupWindowPlaced: ((String) -> Void)?
    private var setupSlots: [CGWindowID: Int] = [:]

    private var learningChecks: [CGWindowID: MinimumSizeLearner.Observation] = [:]
    private var learningGaveUp: Set<CGWindowID> = []
    private var resistance: [CGWindowID: (count: Int, since: Date)] = [:]
    private var verifyDebouncers: [String: Debouncer] = [:]
    private var snapDebouncers: [CGWindowID: Debouncer] = [:]
    private let reconcileDebouncer = Debouncer(delay: 0.2)
    private var notificationTokens: [NSObjectProtocol] = []

    static let tileMinimum = CGSize(width: 120, height: 80)

    var isActive: Bool { model.canArrange }

    // MARK: Start

    func start() {
        registry.onEvent = { [weak self] event in self?.handle(event) }
        registry.start()
        refreshDisplays()

        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        notificationTokens.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReconcile() }
        })
        notificationTokens.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReconcile() }
        })
        focusedID = registry.focusedWindowID()
        reconcileAll()
    }

    /// Call when anything that affects `isActive` changes.
    func statusChanged() {
        if isActive {
            reconcileAll()
        } else {
            if focusMode != nil {
                focusMode = nil
                model.focusModeActive = false
            }
            onChange?()
        }
    }

    // MARK: Keys and geometry

    func key(for display: DisplayInfo) -> String {
        "\(display.stableID)#\(spaceByDisplay[display.displayID] ?? 0)"
    }

    var visibleKeys: [String] { displays.map { key(for: $0) } }

    func display(forKey key: String) -> DisplayInfo? {
        displays.first { self.key(for: $0) == key }
    }

    func keyOf(_ id: CGWindowID) -> String? {
        for k in visibleKeys where states[k]?.contains(id) == true { return k }
        return states.first { $0.value.contains(id) }?.key
    }

    func state(forKey key: String) -> ScreenState? { states[key] }

    /// The display under the mouse pointer.
    var displayUnderPointer: DisplayInfo? {
        Screens.display(containing: Screens.mouseLocation, in: displays) ?? displays.first
    }

    var keyUnderPointer: String? { displayUnderPointer.map { key(for: $0) } }

    /// Where windows may go on a display: visible frame, minus reserved edges and outer gap.
    func usableArea(_ display: DisplayInfo) -> CGRect {
        let gap = prefs.effectiveGap
        return prefs.reservedEdges(for: display.stableID).inset(display.visibleFrame).insetBy(dx: gap, dy: gap)
    }

    func effectiveCapacity(_ state: ScreenState, on display: DisplayInfo) -> Int {
        LayoutEngine.effectiveCapacity(
            layout: state.layout,
            shape: display.shape,
            requested: state.capacity,
            area: usableArea(display),
            gap: prefs.effectiveGap,
            mainSize: prefs.mainSize
        )
    }

    private func makeState(for display: DisplayInfo) -> ScreenState {
        let saved = prefs.screenPrefs[display.stableID]
        let wanted = (display.shape == .vertical ? saved?.verticalLayout : saved?.landscapeLayout) ?? prefs.defaultLayout
        let layout = display.shape.availableLayouts.contains(wanted) ? wanted : .grid
        return ScreenState(layout: layout, capacity: saved?.capacity ?? prefs.defaultCapacity)
    }

    func stateOrDefault(forKey key: String) -> ScreenState? {
        if let state = states[key] { return state }
        return display(forKey: key).map { makeState(for: $0) }
    }

    private func refreshDisplays() {
        displays = Screens.all()
        for display in displays {
            spaceByDisplay[display.displayID] = Spaces.current(on: display.displayID)
        }
    }

    /// Frame of the tile a window sits in (or the zoomed frame in focus mode).
    func tileFrame(of id: CGWindowID) -> CGRect? {
        if let focusMode, focusMode.window == id, let display = self.display(forKey: focusMode.key) {
            return usableArea(display)
        }
        guard let k = keyOf(id), let index = states[k]?.tileIndex(of: id) else { return nil }
        return frames[k]?[index]
    }

    func isTiled(_ id: CGWindowID) -> Bool { keyOf(id) != nil }
    func isFloating(_ id: CGWindowID) -> Bool { floating.contains(id) || autoFloating[id] != nil }

    var focusedTiledWindow: CGWindowID? {
        guard let focusedID, isTiled(focusedID) else { return nil }
        return focusedID
    }

    /// The tile the user is working in on a screen.
    func activeTile(in key: String) -> Int? {
        guard let state = states[key] else { return nil }
        if let focusedID, let index = state.tileIndex(of: focusedID) { return index }
        for id in recent { if let index = state.tileIndex(of: id) { return index } }
        return nil
    }

    // MARK: Tileable windows

    private func layerZeroOnScreen() -> Set<CGWindowID> {
        Set(WindowServer.onScreen().filter { $0.layer == 0 && $0.alpha > 0 }.map(\.id))
    }

    /// Ordinary app windows with standard controls. Dialogs, sheets, panels, minimized,
    /// full-screen, non-resizable and excluded windows are left alone.
    func isTileCandidate(_ window: TrackedWindow, onScreen: Set<CGWindowID>?) -> Bool {
        if prefs.isExcluded(window.bundleID) || isFloating(window.id) { return false }
        let element = window.element
        guard element.role == kAXWindowRole, element.subrole == kAXStandardWindowSubrole else { return false }
        if element.isMinimized || element.isFullScreen || element.isModal { return false }
        guard element.isSettable(kAXSizeAttribute), element.isSettable(kAXPositionAttribute) else { return false }
        if let app = registry.app(window.pid), app.isHidden { return false }
        if let size = element.size, size.width < 140 || size.height < 90 { return false }
        if let onScreen, !onScreen.contains(window.id) { return false }
        if !prefs.floatRules.isEmpty, let title = element.title,
           prefs.floatRules.contains(where: { $0.matches(bundleID: window.bundleID, title: title) }) {
            return false
        }
        return true
    }

    // MARK: Reconciling

    func scheduleReconcile() {
        reconcileDebouncer.schedule { [weak self] in self?.reconcileAll() }
    }

    private func screensChanged() {
        refreshDisplays()
        CleanSpaceController.shared.screensChanged()
        scheduleReconcile()
    }

    /// Re-reads every window and fixes up every visible screen.
    func reconcileAll() {
        refreshDisplays()
        guard isActive else {
            onChange?()
            return
        }
        registry.rescan()
        let visible = layerZeroOnScreen()
        let keys = visibleKeys
        var buckets: [String: [CGWindowID]] = Dictionary(uniqueKeysWithValues: keys.map { ($0, []) })

        for window in registry.windows.values.sorted(by: { $0.id < $1.id }) {
            guard isTileCandidate(window, onScreen: visible),
                  let frame = window.frame,
                  let display = Screens.display(for: frame, in: displays) else { continue }
            if let existing = keyOf(window.id), buckets[existing] != nil, focusMode?.window != window.id {
                // Keep windows on the screen we put them on, unless they clearly moved.
                if let current = self.display(forKey: existing), current.frame.intersects(frame) {
                    buckets[existing, default: []].append(window.id)
                    continue
                }
            }
            buckets[key(for: display), default: []].append(window.id)
        }

        for display in displays {
            let k = key(for: display)
            let present = buckets[k] ?? []
            for id in present {
                for (otherKey, var other) in states where otherKey != k && other.contains(id) {
                    other.remove(id, rebalanceTo: nil)
                    states[otherKey] = other
                }
            }
            var state = states[k] ?? makeState(for: display)
            let floated = state.reconcile(present: present, capacity: effectiveCapacity(state, on: display), whenFull: prefs.whenFull)
            states[k] = state
            for id in floated { autoFloat(id, on: display, reason: .full) }
        }
        for k in keys { apply(k) }
        onChange?()
    }

    // MARK: Applying

    /// Lays out one screen and moves its windows into place.
    func apply(_ key: String, raise raiseID: CGWindowID? = nil) {
        guard isActive, var state = states[key], let display = self.display(forKey: key) else { return }
        // Clean Space owns this screen until it ends.
        guard !CleanSpaceController.shared.isManaging(display) else {
            onChange?()
            return
        }
        let area = usableArea(display)
        let gap = prefs.effectiveGap
        state.rebalance(capacity: effectiveCapacity(state, on: display))

        var result: [Int: CGRect] = [:]
        solving: while !state.tiles.isEmpty {
            let count = state.tiles.count
            let tree = LayoutEngine.tree(layout: state.layout, shape: display.shape, count: count, mainSize: prefs.mainSize)
            let solver = LayoutSolver(
                gap: gap,
                overrides: state.customSizes(layout: state.layout, shape: display.shape, count: count),
                minimumSizes: minimums(for: state),
                defaultMinimum: Self.tileMinimum
            )
            switch solver.solve(tree, in: area) {
            case .success(let solved):
                result = solved
                break solving
            case .failure(.doesNotFit(let culprits)):
                // Float the window that can't fit; never reorder to make room.
                var victimTile = culprits.max() ?? count - 1
                if victimTile == 0, count > 1 { victimTile = count - 1 }
                guard let victim = state.tiles[victimTile].showing else { break solving }
                state.remove(victim, rebalanceTo: nil)
                states[key] = state
                autoFloat(victim, on: display, reason: .tooBig)
            }
        }

        states[key] = state
        frames[key] = result
        for (index, tile) in state.tiles.enumerated() {
            guard let frame = result[index] else { continue }
            // The showing window last, so it lands on top.
            for id in tile.windows {
                if let window = registry.window(id) { applier.set(window, to: frame) }
            }
        }
        // A stack whose top window changed (after a swap, say) brings that window forward.
        let showing = state.showingWindows
        let before = lastShowing[key] ?? []
        for (index, tile) in state.tiles.enumerated() where tile.isStack {
            let previous = before.indices.contains(index) ? before[index] : nil
            if let top = tile.showing, top != previous, top != raiseID, let window = registry.window(top) {
                applier.raise(window)
            }
        }
        lastShowing[key] = showing
        if let focusMode, focusMode.key == key, let window = registry.window(focusMode.window) {
            applier.set(window, to: area)
            applier.raise(window)
        }
        if let raiseID, let window = registry.window(raiseID) {
            applier.raise(window)
        }
        scheduleVerification(key)
        model.layoutRevision += 1
        onChange?()
    }

    private func minimums(for state: ScreenState) -> [Int: CGSize] {
        var result: [Int: CGSize] = [:]
        for (index, tile) in state.tiles.enumerated() {
            var merged = LearnedMinimum()
            for id in tile.windows {
                guard let window = registry.window(id), prefs.neverLearn[window.bundleID] == nil,
                      let learned = prefs.learnedMinimums[window.bundleID] else { continue }
                merged = merged.merged(with: learned)
            }
            if !merged.isEmpty { result[index] = merged.size }
        }
        return result
    }

    /// True if the state can be laid out on the display without floating anything.
    private func fits(_ state: ScreenState, on display: DisplayInfo) -> Bool {
        guard !state.tiles.isEmpty else { return true }
        let count = state.tiles.count
        let tree = LayoutEngine.tree(layout: state.layout, shape: display.shape, count: count, mainSize: prefs.mainSize)
        let solver = LayoutSolver(
            gap: prefs.effectiveGap,
            overrides: state.customSizes(layout: state.layout, shape: display.shape, count: count),
            minimumSizes: minimums(for: state),
            defaultMinimum: Self.tileMinimum
        )
        if case .success = solver.solve(tree, in: usableArea(display)) { return true }
        return false
    }

    // MARK: Floating

    private func autoFloat(_ id: CGWindowID, on display: DisplayInfo, reason: FloatReason) {
        autoFloating[id] = reason
        guard let window = registry.window(id) else { return }
        let area = usableArea(display)
        let size = window.frame?.size ?? CGSize(width: area.width * 0.6, height: area.height * 0.7)
        let fitted = CGSize(width: min(size.width, area.width), height: min(size.height, area.height))
        applier.set(window, to: area.centered(size: fitted))
        applier.raise(window)
        switch reason {
        case .full:
            Notices.shared.toast(L("This Space is full. The new window floats until there's room."))
        case .tooBig:
            Notices.shared.needsMoreRoom(window: window, display: display)
        }
    }

    /// Gives floating overflow windows a tile when room opens up.
    private func readmitFloaters(_ key: String) {
        guard let display = self.display(forKey: key), var state = states[key] else { return }
        let capacity = effectiveCapacity(state, on: display)
        for (id, reason) in autoFloating where reason == .full && state.tiles.count < capacity {
            guard let window = registry.window(id), let frame = window.frame,
                  display.frame.intersects(frame), isTileCandidateIgnoringFloat(window) else { continue }
            autoFloating.removeValue(forKey: id)
            state.insert(id, capacity: capacity, placement: .nextFreeTile, whenFull: .stack, activeTile: nil)
        }
        states[key] = state
    }

    private func isTileCandidateIgnoringFloat(_ window: TrackedWindow) -> Bool {
        let saved = autoFloating.removeValue(forKey: window.id)
        defer { if let saved { autoFloating[window.id] = saved } }
        return isTileCandidate(window, onScreen: nil)
    }

    /// ⌃⌥F: float the window, or tile it again.
    func toggleFloat(_ target: CGWindowID? = nil) {
        guard isActive, let id = target ?? focusedID, let window = registry.window(id) else { return }
        if isFloating(id) {
            floating.remove(id)
            autoFloating.removeValue(forKey: id)
            guard let frame = window.frame, let display = Screens.display(for: frame, in: displays) else { return }
            let k = key(for: display)
            var state = states[k] ?? makeState(for: display)
            // Rejoins the end of its screen's order.
            state.insert(id, capacity: effectiveCapacity(state, on: display), placement: .nextFreeTile, whenFull: .stack, activeTile: nil)
            states[k] = state
            apply(k, raise: id)
        } else {
            guard let k = keyOf(id), var state = states[k], let display = self.display(forKey: k) else { return }
            if focusMode?.window == id { clearFocusMode() }
            state.remove(id, rebalanceTo: effectiveCapacity(state, on: display))
            states[k] = state
            floating.insert(id)
            let area = usableArea(display)
            let size = CGSize(
                width: min(max(area.width * 0.55, 640), area.width),
                height: min(max(area.height * 0.7, 480), area.height)
            )
            applier.set(window, to: area.centered(size: size))
            apply(k)
            applier.raise(window)
        }
    }

    /// ⌃⌥⇧F: always float windows like this one (same app, same first two title words).
    func alwaysFloatLikeActive() {
        guard let id = focusedID, let window = registry.window(id) else { return }
        guard let words = FloatRule.words(from: window.title) else {
            Notices.shared.toast(L("This window has no title. Float it with %@ each time, or stop tiling the whole app.", ShortcutCenter.shared.label(for: .float)))
            return
        }
        if prefs.floatRules.contains(where: { $0.matches(bundleID: window.bundleID, title: window.title) }) {
            Notices.shared.toast(L("This window already floats every time."))
            return
        }
        Notices.shared.confirm(
            title: L("Always float “%@” windows in %@?", words, window.appName),
            confirm: L("Always float"),
            cancel: L("Not now"),
            timeout: 12
        ) { [weak self] in
            guard let self else { return }
            self.prefs.floatRules.append(FloatRule(bundleID: window.bundleID, appName: window.appName, titleWords: words))
            if self.isTiled(id) { self.toggleFloat(id) }
        }
    }

    // MARK: Events

    private func handle(_ event: WindowEvent) {
        switch event {
        case .created(let id):
            windowAppeared(id, attempt: 0)
        case .destroyed(let id):
            windowGone(id, reason: .closed)
        case .minimized(let id):
            windowGone(id, reason: .minimized)
        case .deminimized(let id):
            windowReturned(id)
        case .appHidden(let pid):
            for window in registry.windows(of: pid) { windowGone(window.id, reason: .hidden) }
        case .appShown:
            after(0.25) { [weak self] in self?.reconcileAll() }
        case .appTerminated(_, let ids):
            for id in ids { windowGone(id, reason: .closed) }
        case .appLaunched:
            break
        case .appActivated:
            focusChanged(registry.focusedWindowID())
        case .focused(let id):
            focusChanged(id)
        case .moved(let id), .resized(let id):
            geometryChanged(id)
        case .titleChanged(let id):
            titleChanged(id)
        }
    }

    private func windowAppeared(_ id: CGWindowID, attempt: Int) {
        guard isActive else { return }
        after(attempt == 0 ? 0.12 : 0.25) { [weak self] in
            self?.placeNewWindow(id, attempt: attempt)
        }
    }

    private func placeNewWindow(_ id: CGWindowID, attempt: Int) {
        guard isActive, let window = registry.window(id), keyOf(id) == nil, !isFloating(id) else { return }
        let subrole = window.element.subrole
        guard isTileCandidate(window, onScreen: nil) else {
            if attempt < 3, subrole == nil || subrole == kAXUnknownSubrole {
                windowAppeared(id, attempt: attempt + 1)
            }
            return
        }
        let visible = layerZeroOnScreen()
        guard visible.contains(id) else {
            if attempt < 4 { windowAppeared(id, attempt: attempt + 1) }
            return
        }
        guard let frame = window.frame, let display = Screens.display(for: frame, in: displays) else { return }
        let k = key(for: display)

        // A setup is waiting for this app.
        if let placement = takePlacement(for: window.bundleID) {
            place(id, placement: placement)
            return
        }

        // A new native tab joins its window's tile.
        if let sibling = tabSibling(of: window, visible: visible), let siblingKey = keyOf(sibling),
           var state = states[siblingKey], let tile = state.tileIndex(of: sibling) {
            state.stack(id, onto: tile)
            states[siblingKey] = state
            apply(siblingKey)
            return
        }

        if let focusMode, focusMode.key == k { clearFocusMode() }

        var state = states[k] ?? makeState(for: display)
        let result = state.insert(
            id,
            capacity: effectiveCapacity(state, on: display),
            placement: prefs.newWindowPlacement,
            whenFull: prefs.whenFull,
            activeTile: activeTile(in: k)
        )
        states[k] = state
        switch result {
        case .floated:
            autoFloat(id, on: display, reason: .full)
            return
        case .stacked:
            if !prefs.seenStackNotice {
                prefs.seenStackNotice = true
                Notices.shared.toast(L("Screen full: the new window joined a stack. Press %@ to see the one behind it.", ShortcutCenter.shared.label(for: .stackNext)))
            }
        default:
            break
        }
        prefs.count(\.windowsArranged)
        apply(k, raise: id)
    }

    /// A tab opened in the same native tab group shares the frame of a window that just went off screen.
    private func tabSibling(of window: TrackedWindow, visible: Set<CGWindowID>) -> CGWindowID? {
        guard let frame = window.frame else { return nil }
        return registry.windows(of: window.pid).first { other in
            other.id != window.id && isTiled(other.id) && !visible.contains(other.id) &&
                (other.frame.map { $0.isClose(to: frame, tolerance: 3) } ?? false)
        }?.id
    }

    private enum GoneReason { case closed, minimized, hidden }

    private func windowGone(_ id: CGWindowID, reason: GoneReason) {
        if reason == .closed {
            applier.forget(id)
            floating.remove(id)
            recent.removeAll { $0 == id }
            learningChecks.removeValue(forKey: id)
            learningGaveUp.remove(id)
            setupSlots.removeValue(forKey: id)
        }
        autoFloating.removeValue(forKey: id)
        if focusMode?.window == id { clearFocusMode(applyLayout: false) }
        guard let k = keyOf(id), var state = states[k], let tile = state.tileIndex(of: id) else {
            onChange?()
            return
        }
        let wasShowing = state.tiles[tile].showing == id
        let others = state.tiles[tile].windows.filter { $0 != id }
        if reason == .minimized { minimizedOrigin[id] = (k, tile) }
        let capacity = self.display(forKey: k).map { effectiveCapacity(state, on: $0) }
        state.remove(id, rebalanceTo: capacity)
        states[k] = state
        readmitFloaters(k)
        // Closing the showing window brings forward the most recent one in that tile.
        let reveal = wasShowing ? states[k]?.tiles.first(where: { $0.windows.contains(others.last ?? 0) })?.showing : nil
        apply(k, raise: reveal)
    }

    private func windowReturned(_ id: CGWindowID) {
        guard isActive, let window = registry.window(id) else { return }
        if let origin = minimizedOrigin.removeValue(forKey: id), var state = states[origin.key],
           let display = self.display(forKey: origin.key), visibleKeys.contains(origin.key) {
            if state.tiles.indices.contains(origin.tile), state.tiles.count >= effectiveCapacity(state, on: display) {
                // Returns to the top of the same tile.
                state.tiles[origin.tile].windows.append(id)
            } else {
                state.insertTile(id, at: origin.tile)
            }
            states[origin.key] = state
            apply(origin.key, raise: id)
            return
        }
        _ = window
        windowAppeared(id, attempt: 0)
    }

    private func focusChanged(_ id: CGWindowID?) {
        focusedID = id
        guard let id else {
            onChange?()
            return
        }
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > 64 { recent.removeLast(recent.count - 64) }

        if let k = keyOf(id), var state = states[k] {
            state.markShowing(id)
            states[k] = state
            if let focusMode, focusMode.key == k, focusMode.window != id { clearFocusMode() }
        } else if isActive, !isFloating(id), let window = registry.window(id), isTileCandidate(window, onScreen: nil) {
            // A window we never saw being created.
            windowAppeared(id, attempt: 0)
        }
        onChange?()
    }

    private func titleChanged(_ id: CGWindowID) {
        guard !prefs.floatRules.isEmpty, isTiled(id), let window = registry.window(id) else { return }
        if prefs.floatRules.contains(where: { $0.matches(bundleID: window.bundleID, title: window.title) }) {
            toggleFloat(id)
        }
    }

    /// An app moved or resized a tiled window on its own (not the user dragging).
    private func geometryChanged(_ id: CGWindowID) {
        guard isActive, !applier.isOurs(id), dragInProgress != id, isTiled(id) else {
            if dragInProgress == nil, NSEvent.pressedMouseButtons & 1 == 0 { onChange?() }
            return
        }
        if NSEvent.pressedMouseButtons & 1 != 0 { return }
        let debouncer = snapDebouncers[id] ?? Debouncer(delay: 0.35)
        snapDebouncers[id] = debouncer
        debouncer.schedule { [weak self] in self?.snapBack(id) }
    }

    private func snapBack(_ id: CGWindowID) {
        guard isActive, let k = keyOf(id), let window = registry.window(id), let frame = window.frame else { return }
        // The app sent its window to another screen.
        if let display = Screens.display(for: frame, in: displays), key(for: display) != k,
           let current = self.display(forKey: k), !current.frame.intersects(frame.insetBy(dx: 40, dy: 40)) {
            moveWindow(id, to: key(for: display), mode: .join)
            return
        }
        let now = Date()
        var entry = resistance[id] ?? (0, now)
        if now.timeIntervalSince(entry.since) > 4 { entry = (0, now) }
        entry.count += 1
        resistance[id] = entry
        // Don't fight an app forever.
        guard entry.count <= 3 else { return }
        apply(k)
    }

    // MARK: Learning minimum sizes

    private func scheduleVerification(_ key: String) {
        let debouncer = verifyDebouncers[key] ?? Debouncer(delay: 0.4)
        verifyDebouncers[key] = debouncer
        debouncer.schedule { [weak self] in self?.verify(key) }
    }

    /// Checks whether apps accepted their sizes; learns the ones that refuse twice.
    private func verify(_ key: String) {
        guard isActive, let state = states[key], let display = self.display(forKey: key), let tileFrames = frames[key] else { return }
        let screen = usableArea(display).size
        for (index, tile) in state.tiles.enumerated() {
            guard let target = tileFrames[index], let id = tile.showing, focusMode?.window != id,
                  let window = registry.window(id), let actual = window.frame,
                  prefs.neverLearn[window.bundleID] == nil, !learningGaveUp.contains(id) else { continue }
            let observation = MinimumSizeLearner.Observation(requested: target.size, actual: actual.size)
            guard observation.refused else {
                learningChecks.removeValue(forKey: id)
                continue
            }
            if let first = learningChecks.removeValue(forKey: id) {
                if let learned = MinimumSizeLearner.learn(first: first, second: observation, screen: screen) {
                    let merged = (prefs.learnedMinimums[window.bundleID] ?? LearnedMinimum()).merged(with: learned)
                    prefs.learnedMinimums[window.bundleID] = merged
                    prefs.learnedMinimumNames[window.bundleID] = window.appName
                    Log.info("Learned a minimum size for \(window.bundleID)")
                    apply(key)
                    return
                }
                learningGaveUp.insert(id)
            } else {
                learningChecks[id] = observation
                after(0.5) { [weak self] in
                    guard let self, let window = self.registry.window(id) else { return }
                    self.applier.set(window, to: target, force: true)
                    after(0.4) { [weak self] in self?.verify(key) }
                }
            }
        }
    }

    // MARK: Moving between screens

    enum MoveMode {
        /// Plain drag: join as the newest window, or go back if full.
        case join
        /// Keyboard: swap or stack on the tile it lands on if full.
        case keyboard(Direction)
        /// Add to a specific tile's stack.
        case stack(tile: Int)
        /// ⌘-drop onto an empty area of another screen.
        case dropEmpty
    }

    func moveWindow(_ id: CGWindowID, to targetKey: String, mode: MoveMode) {
        guard let sourceKey = keyOf(id), sourceKey != targetKey,
              let targetDisplay = self.display(forKey: targetKey),
              let window = registry.window(id) else { return }
        if focusMode?.window == id { clearFocusMode(applyLayout: false) }
        var target = states[targetKey] ?? makeState(for: targetDisplay)
        let capacity = effectiveCapacity(target, on: targetDisplay)

        if case .stack(let tile) = mode, target.tiles.indices.contains(tile) {
            target.tiles[tile].windows.append(id)
        } else if target.tiles.count < capacity {
            var trial = target
            trial.tiles.append(Tile(id))
            var probe = trial
            probe.capacity = max(probe.capacity, trial.tiles.count)
            guard fits(probe, on: targetDisplay) else {
                Notices.shared.toast(L("%@ needs more room on that screen. Try fewer windows or another layout.", window.appName))
                apply(sourceKey)
                return
            }
            target = trial
        } else {
            switch mode {
            case .join:
                Notices.shared.toast(L("That screen is full."))
                apply(sourceKey)
                return
            case .keyboard(let direction):
                guard let landing = landingTile(in: targetKey, entering: direction, from: tileFrame(of: id)) ?? target.tiles.indices.last,
                      let other = target.tiles[landing].showing else { return }
                switch prefs.moveIntoFull {
                case .swap:
                    swapAcrossScreens(id, other)
                    return
                case .stack:
                    target.tiles[landing].windows.append(id)
                }
            case .stack, .dropEmpty:
                guard let last = target.tiles.indices.last else { return }
                target.tiles[last].windows.append(id)
            }
        }

        if var source = states[sourceKey] {
            let capacity = self.display(forKey: sourceKey).map { effectiveCapacity(source, on: $0) }
            source.remove(id, rebalanceTo: capacity)
            states[sourceKey] = source
        }
        states[targetKey] = target
        apply(sourceKey)
        apply(targetKey, raise: id)
        applier.focus(window)
    }

    /// The tile a window lands on when it enters a screen from one side.
    private func landingTile(in key: String, entering direction: Direction, from source: CGRect?) -> Int? {
        guard let tileFrames = frames[key], !tileFrames.isEmpty, let display = self.display(forKey: key) else { return nil }
        let midY = source?.midY ?? display.frame.midY
        let midX = source?.midX ?? display.frame.midX
        let probe: CGRect
        switch direction {
        case .right: probe = CGRect(x: display.frame.minX - 2, y: midY - 1, width: 1, height: 2)
        case .left: probe = CGRect(x: display.frame.maxX + 1, y: midY - 1, width: 1, height: 2)
        case .down: probe = CGRect(x: midX - 1, y: display.frame.minY - 2, width: 2, height: 1)
        case .up: probe = CGRect(x: midX - 1, y: display.frame.maxY + 1, width: 2, height: 1)
        }
        return Navigation.neighbor(of: probe, direction: direction, among: tileFrames)
    }

    /// Trades places between two tiled windows, on the same or different screens.
    func swapAcrossScreens(_ a: CGWindowID, _ b: CGWindowID) {
        guard let ka = keyOf(a), let kb = keyOf(b) else { return }
        if ka == kb {
            guard var state = states[ka] else { return }
            state.swapWindows(a, b)
            states[ka] = state
            prefs.count(\.swaps)
            apply(ka, raise: a)
            return
        }
        guard var sa = states[ka], var sb = states[kb] else { return }
        sa.replace(a, with: b)
        sb.replace(b, with: a)
        states[ka] = sa
        states[kb] = sb
        prefs.count(\.swaps)
        apply(ka, raise: b)
        apply(kb, raise: a)
        if let window = registry.window(a) { applier.focus(window) }
    }

    // MARK: Hit testing (for drags and hover)

    struct TileHit {
        let key: String
        let tile: Int
        let window: CGWindowID
        let frame: CGRect
    }

    func tileHit(at point: CGPoint) -> TileHit? {
        for display in displays where display.frame.contains(point) {
            let k = key(for: display)
            guard let tileFrames = frames[k], let state = states[k],
                  let index = Navigation.hit(point, in: tileFrames),
                  state.tiles.indices.contains(index),
                  let window = state.tiles[index].showing,
                  let frame = tileFrames[index] else { continue }
            return TileHit(key: k, tile: index, window: window, frame: frame)
        }
        return nil
    }

    // MARK: Drags

    /// Called by the drag controller when the user lets go.
    func finishDrag(_ id: CGWindowID, resized: Bool, command: Bool, option: Bool, at point: CGPoint) {
        dragInProgress = nil
        guard isActive, let sourceKey = keyOf(id), var source = states[sourceKey],
              let sourceTile = source.tileIndex(of: id), let display = self.display(forKey: sourceKey) else { return }
        if focusMode?.window == id { clearFocusMode(applyLayout: false) }

        if resized {
            guard let window = registry.window(id), let newFrame = window.frame else {
                apply(sourceKey)
                return
            }
            let count = source.tiles.count
            let tree = LayoutEngine.tree(layout: source.layout, shape: display.shape, count: count, mainSize: prefs.mainSize)
            let solver = LayoutSolver(
                gap: prefs.effectiveGap,
                overrides: source.customSizes(layout: source.layout, shape: display.shape, count: count),
                minimumSizes: minimums(for: source),
                defaultMinimum: Self.tileMinimum
            )
            let overrides = solver.overridesAfterDrag(tile: sourceTile, to: newFrame, tree: tree, in: usableArea(display))
            source.setCustomSizes(overrides, layout: source.layout, shape: display.shape, count: count)
            states[sourceKey] = source
            if let learned = prefs.learnedMinimums[window.bundleID] {
                let lowered = MinimumSizeLearner.lowered(learned, observedSize: newFrame.size)
                if lowered != learned { prefs.learnedMinimums[window.bundleID] = lowered.isEmpty ? nil : lowered }
            }
            apply(sourceKey)
            return
        }

        let targetDisplay = Screens.display(containing: point, in: displays) ?? display
        let targetKey = key(for: targetDisplay)
        let hit = tileHit(at: point)
        Log.info("Drag finished: window \(id) from tile \(sourceTile), drop on \(hit.map { "tile \($0.tile) (window \($0.window))" } ?? "no tile")")

        if command {
            if let hit, hit.window != id, !isFloating(hit.window) {
                if option {
                    if hit.key == sourceKey {
                        source.stack(id, onto: hit.tile)
                        states[sourceKey] = source
                        apply(sourceKey, raise: id)
                    } else {
                        moveWindow(id, to: hit.key, mode: .stack(tile: hit.tile))
                    }
                } else {
                    swapAcrossScreens(id, hit.window)
                }
                return
            }
            if targetKey != sourceKey {
                moveWindow(id, to: targetKey, mode: .dropEmpty)
                return
            }
            apply(sourceKey)
            return
        }

        if targetKey != sourceKey {
            moveWindow(id, to: targetKey, mode: .join)
        } else {
            // A plain drag on the same screen puts the window back.
            apply(sourceKey)
        }
    }

    /// Moves a stacked window (from a hover-bar chip) onto another tile.
    func moveToTile(_ id: CGWindowID, hit: TileHit) {
        guard let sourceKey = keyOf(id), hit.window != id else { return }
        if hit.key == sourceKey, var state = states[sourceKey] {
            state.stack(id, onto: hit.tile)
            states[sourceKey] = state
            apply(sourceKey, raise: id)
        } else {
            moveWindow(id, to: hit.key, mode: .stack(tile: hit.tile))
        }
    }

    // MARK: Keyboard actions

    /// ⌃⌥ + arrow: swap with the neighbour, or move to the next screen that way.
    func swap(_ direction: Direction) {
        guard isActive, let id = focusedTiledWindow, let k = keyOf(id), var state = states[k],
              let index = state.tileIndex(of: id), let tileFrames = frames[k], let source = tileFrames[index] else { return }
        clearFocusMode(applyLayout: false)
        var candidates = tileFrames
        candidates.removeValue(forKey: index)
        if let target = Navigation.neighbor(of: source, direction: direction, among: candidates) {
            state.swapShowing(index, target)
            states[k] = state
            prefs.count(\.swaps)
            apply(k, raise: id)
            return
        }
        guard let display = self.display(forKey: k) else { return }
        var others: [String: CGRect] = [:]
        for other in displays where other.stableID != display.stableID {
            others[key(for: other)] = other.frame
        }
        if let next = Navigation.neighbor(of: display.frame, direction: direction, among: others) {
            moveWindow(id, to: next, mode: .keyboard(direction))
        }
    }

    /// Moves the active window to another screen (hover bar "Next screen" / "Move to").
    func moveToScreen(_ id: CGWindowID, display target: DisplayInfo) {
        moveWindow(id, to: key(for: target), mode: .join)
    }

    /// Screens other than the window's own, with how much room each has.
    func otherScreens(for id: CGWindowID) -> [(display: DisplayInfo, free: Int)] {
        let own = keyOf(id)
        return displays.compactMap { display in
            let k = key(for: display)
            guard k != own else { return nil }
            let state = states[k] ?? makeState(for: display)
            return (display, max(0, effectiveCapacity(state, on: display) - state.tiles.count))
        }
    }

    /// ⌃⌥↩: make the active window primary.
    func makePrimary(_ target: CGWindowID? = nil) {
        guard isActive, let id = target ?? focusedTiledWindow, let k = keyOf(id), var state = states[k] else { return }
        clearFocusMode(applyLayout: false)
        state.makePrimary(id)
        states[k] = state
        prefs.count(\.swaps)
        apply(k, raise: id)
    }

    /// ⌃⌥] / ⌃⌥[: activate the next or previous tiled window, in layout order.
    func activateAdjacent(forward: Bool) {
        guard isActive, let k = focusedTiledWindow.flatMap({ keyOf($0) }) ?? keyUnderPointer,
              let state = states[k], !state.tiles.isEmpty else { return }
        let order = state.showingWindows
        let current = focusedID.flatMap { id in order.firstIndex(of: id) }
        let next: Int
        if let current {
            next = (current + (forward ? 1 : -1) + order.count) % order.count
        } else {
            next = 0
        }
        if let window = registry.window(order[next]) { applier.focus(window) }
    }

    /// ⌃⌥` / ⌃⌥⇧`: show the next or previous window in the active tile.
    func cycleStack(forward: Bool, key requestedKey: String? = nil, tile requestedTile: Int? = nil) {
        guard isActive else { return }
        let k: String
        let tile: Int
        if let requestedKey, let requestedTile {
            k = requestedKey
            tile = requestedTile
        } else {
            guard let id = focusedTiledWindow, let found = keyOf(id), let index = states[found]?.tileIndex(of: id) else { return }
            k = found
            tile = index
        }
        guard var state = states[k], state.tiles.indices.contains(tile), state.tiles[tile].isStack else { return }
        if forward { state.tiles[tile].cycleForward() } else { state.tiles[tile].cycleBackward() }
        states[k] = state
        if let id = state.tiles[tile].showing, let window = registry.window(id) {
            applier.focus(window)
        }
        onChange?()
    }

    /// Shows a specific window in its stack.
    func show(_ id: CGWindowID) {
        guard let window = registry.window(id) else { return }
        if let k = keyOf(id), var state = states[k] {
            state.markShowing(id)
            states[k] = state
        }
        applier.focus(window)
        onChange?()
    }

    /// ⌃⌥= / ⌃⌥-: grow or shrink the active window.
    func resizeActive(grow: Bool) {
        guard isActive, let id = focusedTiledWindow, let k = keyOf(id), var state = states[k],
              let display = self.display(forKey: k), let index = state.tileIndex(of: id) else { return }
        let count = state.tiles.count
        guard count > 1 else {
            Notices.shared.limitReached(grow: grow)
            return
        }
        let tree = LayoutEngine.tree(layout: state.layout, shape: display.shape, count: count, mainSize: prefs.mainSize)
        let solver = LayoutSolver(
            gap: prefs.effectiveGap,
            overrides: state.customSizes(layout: state.layout, shape: display.shape, count: count),
            minimumSizes: minimums(for: state),
            defaultMinimum: CGSize(width: 240, height: 160)
        )
        let step = 48.0
        let result = solver.overridesAfterStep(tile: index, step: grow ? step : -step, tree: tree, in: usableArea(display))
        guard result.changed else {
            Notices.shared.limitReached(grow: grow)
            return
        }
        state.setCustomSizes(result.overrides, layout: state.layout, shape: display.shape, count: count)
        states[k] = state
        apply(k)
    }

    /// ⌃⌥0: windows on this screen go back to their starting sizes.
    func resetSizes(key requested: String? = nil) {
        guard isActive, let k = requested ?? focusedTiledWindow.flatMap({ keyOf($0) }) ?? keyUnderPointer,
              var state = states[k] else { return }
        state.resetSizes()
        states[k] = state
        apply(k)
    }

    func hasCustomSizes(key: String) -> Bool {
        guard let state = states[key], let display = self.display(forKey: key) else { return false }
        return state.hasCustomSizes(layout: state.layout, shape: display.shape, count: state.tiles.count)
    }

    /// Layout for one screen (⌃⌥⇧1–4 or the menu bar panel).
    func setLayout(_ layout: LayoutKind, key requested: String? = nil) {
        guard let k = requested ?? targetKeyForShortcut(), let display = self.display(forKey: k) else { return }
        guard display.shape.availableLayouts.contains(layout) else {
            Notices.shared.toast(L("Columns isn't offered on tall screens."))
            return
        }
        var state = stateOrDefault(forKey: k) ?? makeState(for: display)
        if let focusMode, focusMode.key == k { clearFocusMode(applyLayout: false) }
        state.layout = layout
        states[k] = state
        var saved = prefs.screenPrefs[display.stableID] ?? ScreenPrefs()
        if display.shape == .vertical { saved.verticalLayout = layout } else { saved.landscapeLayout = layout }
        prefs.screenPrefs[display.stableID] = saved
        prefs.count(\.layoutChanges)
        apply(k)
    }

    /// Window count for one screen (⌃⌥⌘1–5 or the menu bar panel).
    func setCapacity(_ count: Int, key requested: String? = nil) {
        guard let k = requested ?? targetKeyForShortcut(), let display = self.display(forKey: k) else { return }
        var state = stateOrDefault(forKey: k) ?? makeState(for: display)
        var wanted = max(1, min(5, count))
        if wanted == 5, display.shape == .landscape {
            // Elsewhere, five fits as many as possible.
            wanted = 4
        } else if wanted == 5, state.layout != .side {
            state.layout = .side
        }
        if let focusMode, focusMode.key == k { clearFocusMode(applyLayout: false) }
        state.capacity = wanted
        states[k] = state
        var saved = prefs.screenPrefs[display.stableID] ?? ScreenPrefs()
        saved.capacity = wanted
        prefs.screenPrefs[display.stableID] = saved
        prefs.count(\.layoutChanges)
        apply(k)
    }

    /// The screen a shortcut acts on: the active window's screen, else the one under the pointer.
    private func targetKeyForShortcut() -> String? {
        if let id = focusedID, let window = registry.window(id), let frame = window.frame,
           let display = Screens.display(for: frame, in: displays) {
            return key(for: display)
        }
        return keyUnderPointer
    }

    /// ⌃⌥R: retile everything and say whether anything moved.
    func retile() {
        guard isActive else { return }
        floating.removeAll()
        autoFloating.removeAll()
        learningGaveUp.removeAll()
        resistance.removeAll()
        let before = applier.moveCount
        reconcileAll()
        let moved = applier.moveCount != before
        Notices.shared.toast(moved ? L("Windows rearranged.") : L("Everything was already in place."))
    }

    // MARK: Focus mode

    /// ⌃⌥Z: fill the screen with the active window; press again to restore.
    func toggleFocusMode() {
        if focusMode != nil {
            clearFocusMode()
            return
        }
        guard isActive, let id = focusedTiledWindow, let k = keyOf(id), let display = self.display(forKey: k),
              let window = registry.window(id) else { return }
        focusMode = (id, k)
        model.focusModeActive = true
        prefs.count(\.focusSessions)
        applier.set(window, to: usableArea(display))
        applier.raise(window)
        onChange?()
    }

    func clearFocusMode(applyLayout: Bool = true) {
        guard let current = focusMode else { return }
        focusMode = nil
        model.focusModeActive = false
        if applyLayout { apply(current.key) } else { onChange?() }
    }

    // MARK: Setups

    /// What's on screen now, as setup screens. Only apps — never titles.
    func currentArrangement() -> [SetupScreen] {
        displays.compactMap { display in
            let k = key(for: display)
            guard let state = states[k], !state.tiles.isEmpty else { return nil }
            let tiles = state.tiles.map { tile in
                SetupTile(apps: tile.windows.reversed().compactMap { id in
                    registry.window(id).map { SetupApp(bundleID: $0.bundleID, name: $0.appName) }
                })
            }
            return SetupScreen(
                screenID: display.stableID,
                screenName: display.name,
                layout: state.layout,
                capacity: state.capacity,
                sizes: state.sizes,
                tiles: tiles
            )
        }
    }

    /// The showing app of each tile, per screen — to tell if a setup is still on screen.
    func currentSignature() -> [String: [String]] {
        var result: [String: [String]] = [:]
        for display in displays {
            guard let state = states[key(for: display)] else { continue }
            result[display.stableID] = state.tiles.compactMap { $0.showing.flatMap { registry.window($0)?.bundleID } }
        }
        return result
    }

    /// Applies a setup's layouts and prepares tiles to be filled as windows arrive.
    func beginSetup(screens: [String: SetupScreen], placements: [SetupPlanner.Placement]) {
        pendingPlacements = Dictionary(grouping: placements, by: \.bundleID)
        setupSlots.removeAll()
        for display in displays {
            let k = key(for: display)
            guard let saved = screens[display.stableID] else { continue }
            var state = states[k] ?? makeState(for: display)
            state.layout = display.shape.availableLayouts.contains(saved.layout) ? saved.layout : state.layout
            state.capacity = saved.capacity
            state.sizes = saved.sizes
            // Windows of apps not in this screen's plan leave the layout (their apps get hidden).
            state.tiles.removeAll()
            states[k] = state
            var screenPrefs = prefs.screenPrefs[display.stableID] ?? ScreenPrefs()
            screenPrefs.capacity = saved.capacity
            if display.shape == .vertical { screenPrefs.verticalLayout = state.layout } else { screenPrefs.landscapeLayout = state.layout }
            prefs.screenPrefs[display.stableID] = screenPrefs
        }
        // Existing windows of setup apps take their places now.
        let visible = layerZeroOnScreen()
        for window in registry.windows.values.sorted(by: { $0.id < $1.id }) where pendingPlacements[window.bundleID] != nil {
            guard isTileCandidate(window, onScreen: visible), let placement = takePlacement(for: window.bundleID) else { continue }
            place(window.id, placement: placement)
        }
    }

    func endSetup() {
        pendingPlacements.removeAll()
        setupSlots.removeAll()
    }

    private func takePlacement(for bundleID: String) -> SetupPlanner.Placement? {
        guard var list = pendingPlacements[bundleID], !list.isEmpty else { return nil }
        let placement = list.removeFirst()
        pendingPlacements[bundleID] = list.isEmpty ? nil : list
        return placement
    }

    private func place(_ id: CGWindowID, placement: SetupPlanner.Placement) {
        guard let display = displays.first(where: { $0.stableID == placement.screenID }) else { return }
        let k = key(for: display)
        for (otherKey, var other) in states where other.contains(id) {
            other.remove(id, rebalanceTo: nil)
            states[otherKey] = other
        }
        var state = states[k] ?? makeState(for: display)
        setupSlots[id] = placement.tile
        if placement.stacked, let tile = state.tiles.firstIndex(where: { tile in tile.windows.contains { setupSlots[$0] == placement.tile } }) {
            state.tiles[tile].windows.insert(id, at: 0)
        } else {
            state.tiles.append(Tile(id))
            state.tiles.sort { a, b in
                (a.windows.compactMap { setupSlots[$0] }.min() ?? Int.max) < (b.windows.compactMap { setupSlots[$0] }.min() ?? Int.max)
            }
        }
        states[k] = state
        apply(k)
        if let window = registry.window(id) { onSetupWindowPlaced?(window.bundleID) }
    }

    // MARK: Queries for the UI

    struct PreviewTile: Identifiable {
        let tile: Int
        let frame: CGRect
        let windows: [TrackedWindow]
        var id: Int { tile }
    }

    /// Windows on a screen in tile order, for the menu bar preview.
    func preview(for key: String) -> [PreviewTile] {
        guard let state = states[key], let tileFrames = frames[key] else { return [] }
        return state.tiles.enumerated().compactMap { index, tile in
            guard let frame = tileFrames[index] else { return nil }
            return PreviewTile(tile: index, frame: frame, windows: tile.windows.compactMap { registry.window($0) })
        }
    }
}
