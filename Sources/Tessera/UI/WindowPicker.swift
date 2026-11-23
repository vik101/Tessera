import AppKit
import SwiftUI
import TesseraCore

/// ⌃⌥Space: every window on the desktop you're working on, the front ones first. Press a number
/// (or ↑ ↓ and Return, or click) to bring that window to the front and switch to it.
@MainActor
final class WindowPicker {
    static let shared = WindowPicker()

    private let model = PickerModel()
    private var panel: PickerPanel?
    /// The app you were in, to go back to if you close the picker without picking.
    private var previousApp: NSRunningApplication?

    var isShowing: Bool { panel?.isVisible == true }

    func toggle() {
        if isShowing {
            close(goBack: true)
        } else {
            show()
        }
    }

    func show() {
        let tiler = AutoTiler.shared
        guard tiler.isOn, let screen = tiler.workingScreen else {
            Notice.shared.show("Turn on auto-tile (⌃⌥A) to bring windows forward")
            return
        }
        let (front, waiting) = tiler.windows(on: screen)
        guard !(front.isEmpty && waiting.isEmpty) else {
            NSSound.beep()
            return
        }
        let limit = tiler.frontLimit(on: screen)
        model.entries = (front.map { ($0, true) } + waiting.map { ($0, false) }).enumerated().map { index, pair in
            PickerModel.Entry(
                id: pair.0.id,
                number: index < 9 ? index + 1 : nil,
                app: pair.0.appName,
                title: pair.0.title,
                icon: NSRunningApplication(processIdentifier: pair.0.pid)?.icon ?? NSImage(),
                inFront: pair.1,
                kept: tiler.isKept(pair.0.id)
            )
        }
        model.summary = limit.map { "\(front.count) of \($0) in front · \(waiting.count) waiting" } ?? "\(front.count) in front"
        // Start on the first waiting window: that's usually the one you want.
        model.selection = front.count < model.entries.count ? front.count : 0

        previousApp = NSWorkspace.shared.frontmostApplication
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Header and footer, 50 points a row, and room for the line between front and waiting.
        let size = NSSize(width: 520, height: min(96 + CGFloat(model.entries.count) * 50 + (waiting.isEmpty ? 0 : 10), 720))
        let area = NSScreen.screens.first { Screens.toAX($0.frame) == screen.frame }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2 + 60).rounded(),
                              width: size.width, height: size.height), display: true)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Brings the entry at `index` forward.
    func pick(_ index: Int) {
        guard model.entries.indices.contains(index) else {
            NSSound.beep()
            return
        }
        let id = model.entries[index].id
        close(goBack: false)
        AutoTiler.shared.bringForward(id)
    }

    func close(goBack: Bool) {
        guard isShowing else { return }
        panel?.orderOut(nil)
        if goBack { previousApp?.activate() }
    }

    private func makePanel() -> PickerPanel {
        let panel = PickerPanel()
        panel.contentView = NSHostingView(rootView: PickerView(model: model) { [weak self] index in self?.pick(index) })
        panel.onKey = { [weak self] event in self?.handle(event) ?? false }
        panel.onLoseFocus = { [weak self] in self?.close(goBack: false) }
        return panel
    }

    private func handle(_ event: NSEvent) -> Bool {
        let code = UInt32(event.keyCode)
        if let digit = KeyCode.digits.firstIndex(of: code) {
            pick(model.entries.firstIndex { $0.number == digit + 1 } ?? -1)
        } else if code == KeyCode.downArrow || code == KeyCode.tab {
            model.selection = min(model.selection + 1, model.entries.count - 1)
        } else if code == KeyCode.upArrow {
            model.selection = max(model.selection - 1, 0)
        } else if code == KeyCode.returnKey || code == KeyCode.space {
            pick(model.selection)
        } else if code == KeyCode.escape {
            close(goBack: true)
        } else {
            return false
        }
        return true
    }

    func debugState() -> [String: Any] {
        [
            "showing": isShowing,
            "entries": model.entries.map { ["id": Int($0.id), "number": $0.number ?? 0, "app": $0.app, "inFront": $0.inFront] },
            "selection": model.selection,
        ]
    }
}

@MainActor
final class PickerModel: ObservableObject {
    struct Entry: Identifiable {
        let id: CGWindowID
        let number: Int?
        let app: String
        let title: String
        let icon: NSImage
        let inFront: Bool
        let kept: Bool
    }

    @Published var entries: [Entry] = []
    @Published var selection = 0
    @Published var summary = ""
}

/// A panel that takes the keyboard while it's open.
final class PickerPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onLoseFocus: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .modalPanel
        collectionBehavior = [.moveToActiveSpace, .transient, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func resignKey() {
        super.resignKey()
        onLoseFocus?()
    }
}

private struct PickerView: View {
    @ObservedObject var model: PickerModel
    let onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Bring a window forward").font(.system(size: 17, weight: .semibold))
                Spacer()
                Text(model.summary).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0, !entry.inFront, model.entries[index - 1].inFront {
                            Divider().padding(.vertical, 4).padding(.horizontal, 12)
                        }
                        row(entry, selected: index == model.selection)
                            .contentShape(Rectangle())
                            .onTapGesture { onPick(index) }
                            .onHover { inside in if inside { model.selection = index } }
                    }
                }
                .padding(.horizontal, 8)
            }
            Text("1–9 or ↑ ↓ and Return to bring forward · Esc to close")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.vertical, 10)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
    }

    private func row(_ entry: PickerModel.Entry, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Text(entry.number.map(String.init) ?? " ")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .frame(width: 22, height: 22)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            Image(nsImage: entry.icon).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.app).font(.system(size: 14, weight: .medium)).lineLimit(1)
                if !entry.title.isEmpty, entry.title != entry.app {
                    Text(entry.title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(entry.kept ? "Kept in front" : entry.inFront ? "In front" : "Waiting")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(entry.inFront ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(entry.inFront ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 10).frame(height: 48)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    }
}
