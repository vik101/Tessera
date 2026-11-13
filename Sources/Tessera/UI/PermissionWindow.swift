import AppKit
import SwiftUI

/// Explains the one permission Tessera needs, and closes itself once you've given it.
@MainActor
final class PermissionWindow: ObservableObject {
    static let shared = PermissionWindow()

    @Published private(set) var granted = AccessibilityPermission.isTrusted
    @Published private(set) var didReset = false
    /// Runs once, when permission arrives.
    var onGranted: (@MainActor () -> Void)?

    private var window: NSWindow?
    private let timer = RepeatingTimer()

    /// Starts watching for the permission. Shows the window if it's missing.
    func begin() {
        if AccessibilityPermission.isTrusted {
            grant()
        } else {
            show()
        }
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: PermissionView(model: self)))
            window.title = "Tessera"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        timer.start(every: 1) { [weak self] in
            if AccessibilityPermission.isTrusted { self?.grant() }
        }
    }

    func openSystemSettings() {
        AccessibilityPermission.prompt()
        AccessibilityPermission.openSettings()
    }

    /// Clears a stale entry. After an update, macOS can show Tessera as allowed while ignoring it.
    func resetAndAskAgain() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "com.vikram.Tessera"]
        do {
            try process.run()
            process.waitUntilExit()
            Log.info("tccutil reset finished with status \(process.terminationStatus)")
        } catch {
            Log.error("tccutil reset failed: \(error.localizedDescription)")
        }
        didReset = true
        openSystemSettings()
    }

    private func grant() {
        timer.stop()
        granted = true
        let wasShowing = window?.isVisible == true
        window?.close()
        if let onGranted {
            self.onGranted = nil
            onGranted()
        }
        if wasShowing { Notice.shared.show("Tessera is ready") }
    }
}

private struct PermissionView: View {
    @ObservedObject var model: PermissionWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tessera needs one permission").font(.title2.bold())
                    Text("To move and resize windows, macOS asks you to allow Tessera in Accessibility.")
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Label("Click **Open System Settings**.", systemImage: "1.circle.fill")
                Label("Turn on **Tessera** in the list.", systemImage: "2.circle.fill")
                Label("This window closes by itself when it works.", systemImage: "3.circle.fill")
            }
            HStack {
                Button("Open System Settings") { model.openSystemSettings() }
                    .keyboardShortcut(.defaultAction)
                Spacer()
                if model.granted {
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Waiting…").foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Tessera is already on, but this window stays?").font(.headline)
                Text("macOS sometimes keeps an old entry after an update. Click below to clear it, then turn Tessera on again.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(model.didReset ? "Cleared — now turn Tessera on again" : "Clear the Old Entry") {
                    model.resetAndAskAgain()
                }
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
