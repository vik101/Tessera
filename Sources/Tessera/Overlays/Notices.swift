import AppKit
import SwiftUI
import TesseraCore

/// Short messages near the bottom of the screen, and small cards with buttons.
@MainActor
final class Notices {
    static let shared = Notices()

    private var toastPanel: FloatingPanel?
    private var toastTask: Task<Void, Never>?
    private var cardPanel: FloatingPanel?
    private var cardTask: Task<Void, Never>?
    private var cardHovered = false

    private var screen: NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: Toasts

    func toast(_ text: String, duration: Double = 2.6) {
        Log.info("Notice shown")
        let view = ToastView(text: text)
        let panel = toastPanel ?? FloatingPanel(level: .overlayHigh, ignoresMouse: true)
        toastPanel = panel
        let host = NSHostingView(rootView: view)
        panel.contentView = host
        let size = host.fittingSize
        let visible = screen.visibleFrame
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.minY + 72, width: size.width, height: size.height), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        toastTask?.cancel()
        toastTask = after(duration) { [weak self] in self?.hideToast() }
    }

    private func hideToast() {
        toastPanel?.orderOut(nil)
    }

    /// "Maximum size reached" / "Minimum size reached", with the system alert sound.
    func limitReached(grow: Bool) {
        NSSound.beep()
        toast(grow ? L("Maximum size reached") : L("Minimum size reached"), duration: 1.4)
    }

    // MARK: Cards

    struct CardButton {
        let title: String
        let isPrimary: Bool
        let action: @MainActor () -> Void
    }

    /// A small card with buttons. It never takes keyboard focus and waits while the pointer is over it.
    func card(title: String, message: String? = nil, icon: NSImage? = nil, buttons: [CardButton], timeout: Double = 10, anchor: CGRect? = nil) {
        dismissCard()
        let view = CardView(title: title, message: message, icon: icon, buttons: buttons.map { button in
            CardView.Button(title: button.title, isPrimary: button.isPrimary) { [weak self] in
                self?.dismissCard()
                button.action()
            }
        }, onHover: { [weak self] hovering in self?.cardHovered = hovering })
        let (panel, host) = makeHostingPanel(view, level: .overlayHigh, interactive: true)
        let size = host.fittingSize
        let origin: NSPoint
        if let anchor {
            let cocoa = Screens.toCocoa(anchor)
            origin = NSPoint(x: cocoa.midX - size.width / 2, y: cocoa.maxY - 44 - size.height)
        } else {
            let visible = screen.visibleFrame
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 120)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        cardPanel = panel
        scheduleCardTimeout(timeout)
    }

    private func scheduleCardTimeout(_ seconds: Double) {
        cardTask?.cancel()
        cardTask = after(seconds) { [weak self] in
            guard let self else { return }
            if self.cardHovered {
                self.scheduleCardTimeout(2)
            } else {
                self.dismissCard()
            }
        }
    }

    func dismissCard() {
        cardTask?.cancel()
        cardPanel?.orderOut(nil)
        cardPanel = nil
        cardHovered = false
    }

    func confirm(title: String, confirm: String, cancel: String, timeout: Double, action: @escaping @MainActor () -> Void) {
        card(title: title, buttons: [
            CardButton(title: cancel, isPrimary: false) {},
            CardButton(title: confirm, isPrimary: true, action: action),
        ], timeout: timeout)
    }

    /// Shown when an app can't shrink enough for its tile. At most once a day per app.
    func needsMoreRoom(window: TrackedWindow, display: DisplayInfo) {
        let prefs = Preferences.shared
        guard prefs.hiddenRoomNotices[window.bundleID] == nil else { return }
        if let last = prefs.roomNoticeShownOn[window.bundleID], Date().timeIntervalSince(last) < 86_400 { return }
        prefs.roomNoticeShownOn[window.bundleID] = Date()

        let tiling = TilingController.shared
        let id = window.id
        var buttons: [CardButton] = []
        if let target = tiling.otherScreens(for: id).first(where: { $0.free > 0 }) {
            buttons.append(CardButton(title: L("Move to %@", target.display.name), isPrimary: false) {
                tiling.toggleFloat(id)
                after(0.2) { tiling.moveToScreen(id, display: target.display) }
            })
        }
        let k = tiling.key(for: display)
        let count = max(1, (tiling.state(forKey: k)?.tiles.count ?? 1))
        buttons.append(CardButton(title: L("Use %ld windows here", count), isPrimary: false) {
            tiling.setCapacity(count, key: k)
            tiling.toggleFloat(id)
            after(0.2) { tiling.makePrimary(id) }
        })
        buttons.append(CardButton(title: L("Keep it floating"), isPrimary: true) {})
        let name = window.appName
        let bundleID = window.bundleID
        buttons.append(CardButton(title: L("Don't show again for %@", name), isPrimary: false) {
            Preferences.shared.hiddenRoomNotices[bundleID] = name
        })
        card(
            title: L("%@ needs more room", name),
            message: L("It can't shrink enough to fit beside the other windows, so it floats in the middle."),
            icon: AppIcons.icon(bundleID: bundleID, pid: window.pid),
            buttons: buttons,
            timeout: 8,
            anchor: window.frame
        )
    }
}

// MARK: - Views

private struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
            .fixedSize()
            .padding(8)
    }
}

struct CardView: View {
    struct Button: Identifiable {
        let id = UUID()
        let title: String
        let isPrimary: Bool
        let action: @MainActor () -> Void
    }

    let title: String
    let message: String?
    let icon: NSImage?
    let buttons: [Button]
    let onHover: @MainActor (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                if let icon {
                    Image(nsImage: icon).resizable().frame(width: 32, height: 32)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if let message {
                        Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 8) {
                ForEach(buttons) { button in
                    if button.isPrimary {
                        SwiftUI.Button(button.title) { button.action() }.buttonStyle(.borderedProminent)
                    } else {
                        SwiftUI.Button(button.title) { button.action() }.buttonStyle(.bordered)
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
        .onHover { onHover($0) }
        .padding(10)
    }
}
