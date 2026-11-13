import AppKit
import Observation
import SwiftUI
import TesseraCore

/// Saved setups, stored as JSON in Application Support. Apps and layout only.
@MainActor
@Observable
final class SetupStore {
    static let shared = SetupStore()

    private(set) var setups: [Setup] = []

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Tessera", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("setups.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Setup].self, from: data) {
            setups = decoded
        }
    }

    func setup(_ id: UUID) -> Setup? { setups.first { $0.id == id } }

    func add(_ setup: Setup) {
        setups.append(setup)
        save()
    }

    func update(_ setup: Setup) {
        guard let index = setups.firstIndex(where: { $0.id == setup.id }) else { return }
        var updated = setup
        updated.updatedAt = Date()
        setups[index] = updated
        save()
    }

    func delete(_ id: UUID) {
        setups.removeAll { $0.id == id }
        save()
        ShortcutCenter.shared.reload()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(setups) { try? data.write(to: fileURL, options: .atomic) }
    }
}

/// Opens setups: launches apps, hides the rest, and puts windows in their tiles.
@MainActor
@Observable
final class SetupRunner {
    static let shared = SetupRunner()

    enum SetupStatus { case onScreen, changed, idle }

    private(set) var isOpening = false
    @ObservationIgnored private var waiting: Set<String> = []
    @ObservationIgnored private var currentName = ""
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    private let curtain = SetupCurtain()
    private var tiling: TilingController { .shared }
    private var prefs: Preferences { .shared }

    var lastSetup: Setup? {
        prefs.lastSetupID.flatMap { UUID(uuidString: $0) }.flatMap { SetupStore.shared.setup($0) }
    }

    func status(of setup: Setup) -> SetupStatus {
        guard setup.id == lastSetup?.id else { return .idle }
        return setup.matches(current: tiling.currentSignature()) ? .onScreen : .changed
    }

    /// True when two or more tiled apps aren't yet saved as a setup.
    var hasUnsavedArrangement: Bool {
        let apps = Set(tiling.currentArrangement().flatMap { $0.tiles.compactMap { $0.apps.first?.bundleID } })
        guard apps.count >= 2 else { return false }
        return !SetupStore.shared.setups.contains { $0.bundleIDs == apps }
    }

    // MARK: Saving

    func saveCurrent(named name: String) {
        let screens = tiling.currentArrangement()
        guard !screens.isEmpty else {
            Notices.shared.toast(L("Nothing is tiled yet. Arrange some apps first."))
            return
        }
        let setup = Setup(name: name, screens: screens)
        SetupStore.shared.add(setup)
        prefs.lastSetupID = setup.id.uuidString
        Notices.shared.toast(L("Saved “%@”.", name))
    }

    /// Replaces a setup's apps and layout with what's on screen; keeps its name and shortcut.
    func updateFromScreen(_ setup: Setup) {
        var updated = setup
        updated.screens = tiling.currentArrangement()
        SetupStore.shared.update(updated)
        prefs.lastSetupID = setup.id.uuidString
    }

    // MARK: Opening

    func open(id: UUID) {
        guard let setup = SetupStore.shared.setup(id) else { return }
        open(setup)
    }

    func open(_ setup: Setup) {
        guard AppModel.shared.licenseState.hasFullVersion else {
            Notices.shared.toast(L("Setups come with the full version."))
            return
        }
        guard tiling.isActive else {
            Notices.shared.toast(L("Turn tiling on to open a setup."))
            return
        }
        cancelTasks()
        isOpening = true
        currentName = setup.name
        prefs.lastSetupID = setup.id.uuidString
        prefs.count(\.setupsOpened)
        curtain.show(name: setup.name) { [weak self] in self?.revealScreen() }

        let wanted = setup.bundleIDs
        // Apps not in the setup are hidden, never quit.
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular
            && app.processIdentifier != getpid()
            && !wanted.contains(app.bundleIdentifier ?? "") {
            _ = app.hide()
        }

        let main = tiling.displays.first(where: \.isMain)?.stableID ?? tiling.displays.first?.stableID ?? ""
        let plan = SetupPlanner.plan(setup: setup, connected: tiling.displays.map(\.stableID), main: main)
        waiting = Set(plan.placements.map(\.bundleID))
        tiling.onSetupWindowPlaced = { [weak self] bundleID in self?.placed(bundleID) }

        // Show or launch each app.
        for app in setup.allApps {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first {
                _ = running.unhide()
            }
        }
        tiling.beginSetup(screens: plan.screens, placements: plan.placements)

        for app in setup.allApps where waiting.contains(app.bundleID) {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else {
                waiting.remove(app.bundleID)
                Notices.shared.toast(L("%@ isn't installed.", app.name))
                continue
            }
            // Opening a running app asks it for a window, which may open a new one.
            tasks.append(Task { @MainActor in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            })
        }
        checkDone()

        // The blur clears after 20 seconds if an app is slow.
        tasks.append(after(20) { [weak self] in self?.revealScreen() })
        // Name apps that show no window within a minute; keep placing late windows for a few minutes.
        tasks.append(after(60) { [weak self] in
            guard let self, !self.waiting.isEmpty else { return }
            let names = setup.allApps.filter { self.waiting.contains($0.bundleID) }.map(\.name).joined(separator: ", ")
            Notices.shared.toast(L("No window yet from: %@", names), duration: 5)
        })
        tasks.append(after(240) { [weak self] in self?.endPlacing() })
    }

    private func placed(_ bundleID: String) {
        if tiling.pendingPlacements[bundleID] == nil { waiting.remove(bundleID) }
        checkDone()
    }

    private func checkDone() {
        guard isOpening, waiting.isEmpty else { return }
        isOpening = false
        curtain.hide()
        NSSound(named: "Glass")?.play()
        endPlacing()
    }

    /// Esc or "Show My Screen": the blur goes away, apps keep moving into their tiles.
    func revealScreen() {
        curtain.hide()
        isOpening = false
    }

    private func endPlacing() {
        tiling.endSetup()
        tiling.onSetupWindowPlaced = nil
        waiting.removeAll()
    }

    private func cancelTasks() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }
}

/// Blurs screens while a setup opens. The menu bar and Dock stay usable.
@MainActor
final class SetupCurtain {
    private var panels: [FloatingPanel] = []
    private var token: [HotKeyCenter.Token] = []
    private let model = CurtainModel()
    private var countdown: Task<Void, Never>?

    func show(name: String, onReveal: @escaping @MainActor () -> Void) {
        hide()
        model.name = name
        model.secondsLeft = 20
        for screen in NSScreen.screens {
            let view = CurtainView(model: model, onReveal: onReveal)
            let (panel, _) = makeHostingPanel(view, level: .floating, interactive: true)
            panel.setFrame(screen.visibleFrame, display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        token = ShortcutCenter.shared.claimTemporary([(KeyCombo(KeyCode.escape, []), onReveal)])
        countdown = Task { @MainActor [model] in
            while model.secondsLeft > 0, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                model.secondsLeft -= 1
            }
        }
    }

    func hide() {
        countdown?.cancel()
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        ShortcutCenter.shared.releaseTemporary(token)
        token.removeAll()
    }
}

@MainActor
@Observable
final class CurtainModel {
    var name = ""
    var secondsLeft = 20
}

struct CurtainView: View {
    @Bindable var model: CurtainModel
    let onReveal: @MainActor () -> Void

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .fullScreenUI)
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text(L("Opening %@…", model.name)).font(.system(size: 22, weight: .semibold))
                if model.secondsLeft <= 10 {
                    Text(L("Showing your screen in %ld s", model.secondsLeft)).foregroundStyle(.secondary)
                }
                Button(L("Show My Screen")) { onReveal() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
            }
        }
    }
}

/// NSVisualEffectView for SwiftUI.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}
