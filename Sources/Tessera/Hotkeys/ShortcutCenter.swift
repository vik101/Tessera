import AppKit
import Observation
import TesseraCore

extension ShortcutAction {
    /// What the action does, in plain words.
    var title: String {
        switch self {
        case .toggleTiling: L("Turn tiling on or off")
        case .cheatSheet: L("Show shortcut cheat sheet")
        case .swapLeft: L("Swap with the window on the left")
        case .swapRight: L("Swap with the window on the right")
        case .swapUp: L("Swap with the window above")
        case .swapDown: L("Swap with the window below")
        case .makePrimary: L("Make the active window primary")
        case .nextWindow: L("Activate the next window")
        case .previousWindow: L("Activate the previous window")
        case .stackNext: L("Show the next window in this tile")
        case .stackPrevious: L("Show the previous window in this tile")
        case .tabView: L("Open Tab View")
        case .tabViewBackward: L("Open Tab View, moving backwards")
        case .grow: L("Make the active window bigger")
        case .shrink: L("Make the active window smaller")
        case .resetSizes: L("Reset window sizes on this screen")
        case .layoutGrid: L("Grid layout")
        case .layoutColumns: L("Columns layout")
        case .layoutRows: L("Rows layout")
        case .layoutSide: L("Side layout")
        case .count1: L("Tile 1 window")
        case .count2: L("Tile up to 2 windows")
        case .count3: L("Tile up to 3 windows")
        case .count4: L("Tile up to 4 windows")
        case .count5: L("Tile up to 5 windows")
        case .float: L("Float the active window, or tile it again")
        case .alwaysFloat: L("Always float windows like the active one")
        case .focusMode: L("Focus mode")
        case .noPeek: L("No peek mode")
        case .cleanSpace: L("Clean Space")
        case .retile: L("Retile all windows")
        }
    }
}

extension ShortcutGroup {
    var title: String {
        switch self {
        case .general: L("Tessera")
        case .move: L("Move")
        case .activate: L("Activate")
        case .size: L("Size")
        case .layout: L("Layout")
        case .more: L("More")
        }
    }
}

extension LayoutKind {
    var title: String {
        switch self {
        case .grid: L("Grid")
        case .columns: L("Columns")
        case .rows: L("Rows")
        case .side: L("Side")
        }
    }

    var symbol: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .columns: "rectangle.split.3x1"
        case .rows: "rectangle.split.1x2"
        case .side: "rectangle.lefthalf.inset.filled"
        }
    }
}

/// Registers every shortcut and routes presses to actions.
@MainActor
@Observable
final class ShortcutCenter {
    static let shared = ShortcutCenter()

    private(set) var failed: Set<ShortcutAction> = []
    private(set) var leftToMacOS: Set<ShortcutAction> = []
    @ObservationIgnored private var tokens: [HotKeyCenter.Token] = []
    private let prefs = Preferences.shared

    var resolver: ShortcutResolver { prefs.shortcutResolver }

    /// The keys shown next to an action, or empty if it has none.
    func label(for action: ShortcutAction) -> String {
        guard prefs.shortcutsEnabled, !leftToMacOS.contains(action), let combo = resolver.combo(for: action) else { return "" }
        return KeyboardLayout.label(for: combo)
    }

    var hasProblems: Bool { !failed.isEmpty }

    /// Re-registers everything. Call after any keyboard setting changes.
    func reload() {
        HotKeyCenter.shared.unregister(tokens)
        tokens.removeAll()
        failed.removeAll()
        leftToMacOS.removeAll()
        guard prefs.shortcutsEnabled else {
            AppModel.shared.shortcutRegistrationFailed = false
            return
        }
        let system = ConflictChecker.systemShortcuts()
        let resolver = self.resolver
        var used: Set<KeyCombo> = []
        for action in ShortcutAction.allCases {
            guard let combo = resolver.combo(for: action), !used.contains(combo) else { continue }
            // A default that macOS already uses is left to macOS.
            if !resolver.isCustomized(action), !action.isDerived, system.contains(combo) {
                leftToMacOS.insert(action)
                continue
            }
            if let token = HotKeyCenter.shared.register(combo, handler: { AppActions.perform(action) }) {
                tokens.append(token)
                used.insert(combo)
            } else {
                failed.insert(action)
            }
        }
        for setup in SetupStore.shared.setups {
            guard let combo = setup.shortcut, !used.contains(combo) else { continue }
            let id = setup.id
            if let token = HotKeyCenter.shared.register(combo, handler: { SetupRunner.shared.open(id: id) }) {
                tokens.append(token)
                used.insert(combo)
            }
        }
        AppModel.shared.shortcutRegistrationFailed = !failed.isEmpty
        if !failed.isEmpty { Log.error("Some shortcuts could not be registered: \(failed.map(\.rawValue).sorted())") }
    }

    /// Temporarily claims keys (Tab View, cheat sheet). Release with `releaseTemporary`.
    func claimTemporary(_ entries: [(KeyCombo, @MainActor () -> Void)]) -> [HotKeyCenter.Token] {
        entries.compactMap { HotKeyCenter.shared.register($0.0, handler: $0.1) }
    }

    func releaseTemporary(_ tokens: [HotKeyCenter.Token]) {
        HotKeyCenter.shared.unregister(tokens)
    }
}

/// Every user action, from shortcuts, the menu bar panel or the hover bar.
@MainActor
enum AppActions {
    static func perform(_ action: ShortcutAction) {
        let tiling = TilingController.shared
        Preferences.shared.count(\.shortcutsUsed)
        if let direction = action.direction {
            tiling.swap(direction)
            return
        }
        if let layout = action.layout {
            tiling.setLayout(layout)
            return
        }
        if let count = action.countValue {
            tiling.setCapacity(count)
            return
        }
        switch action {
        case .toggleTiling: setAutomaticTiling(!Preferences.shared.automaticTiling)
        case .cheatSheet: CheatSheetController.shared.toggle()
        case .makePrimary: tiling.makePrimary()
        case .nextWindow: tiling.activateAdjacent(forward: true)
        case .previousWindow: tiling.activateAdjacent(forward: false)
        case .stackNext: tiling.cycleStack(forward: true)
        case .stackPrevious: tiling.cycleStack(forward: false)
        case .tabView: TabViewController.shared.open(backward: false)
        case .tabViewBackward: TabViewController.shared.open(backward: true)
        case .grow: tiling.resizeActive(grow: true)
        case .shrink: tiling.resizeActive(grow: false)
        case .resetSizes: tiling.resetSizes()
        case .float: tiling.toggleFloat()
        case .alwaysFloat: tiling.alwaysFloatLikeActive()
        case .focusMode: tiling.toggleFocusMode()
        case .noPeek: NoPeekController.shared.toggle()
        case .cleanSpace: toggleCleanSpace()
        case .retile: tiling.retile()
        default: break
        }
    }

    static func setAutomaticTiling(_ on: Bool) {
        Preferences.shared.automaticTiling = on
        TilingController.shared.statusChanged()
        StatusItemController.shared.refreshIcon()
        if !on { Notices.shared.toast(L("Tessera is paused. Windows stay where they are.")) }
    }

    static func toggleCleanSpace() {
        guard AppModel.shared.licenseState.hasFullVersion else {
            Notices.shared.toast(L("Clean Space comes with the full version."))
            return
        }
        CleanSpaceController.shared.toggle()
    }
}
