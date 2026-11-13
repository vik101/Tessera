import AppKit
import os

// MARK: - Logging

/// Logs to the macOS unified log (Console app, subsystem com.vikram.Tessera).
/// Keeps the last 200 lines for the debug dump. Never logs window titles.
@MainActor
enum Log {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Tessera", category: "app")
    private(set) static var recent: [String] = []

    static func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        remember("I " + message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        remember("E " + message)
    }

    private static func remember(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        recent.append("\(stamp) \(line)")
        if recent.count > 200 { recent.removeFirst(recent.count - 200) }
    }
}

// MARK: - Timing

/// Runs work on the main actor after a delay. Cancel the returned task to skip it.
@MainActor
@discardableResult
func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) -> Task<Void, Never> {
    Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
        guard !Task.isCancelled else { return }
        work()
    }
}

/// Collapses a burst of calls into one call after a quiet moment.
@MainActor
final class Debouncer {
    private var task: Task<Void, Never>?
    let delay: Double

    init(delay: Double) { self.delay = delay }

    func schedule(_ work: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = after(delay, work)
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// Calls back on the main actor every few seconds until stopped.
@MainActor
final class RepeatingTimer {
    private var task: Task<Void, Never>?

    func start(every seconds: Double, _ work: @escaping @MainActor () -> Void) {
        stop()
        task = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
                if Task.isCancelled { break }
                work()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

// MARK: - Apps

extension NSRunningApplication {
    var displayName: String { localizedName ?? bundleIdentifier ?? "App" }
}

/// Other window managers that use the same default shortcuts.
enum ConflictingApps {
    static let known: [String: String] = [
        "com.knollsoft.Rectangle": "Rectangle",
        "com.knollsoft.Hookshot": "Rectangle Pro",
        "com.divisiblebyzero.Spectacle": "Spectacle",
        "com.crowdcafe.windowmagnet": "Magnet",
    ]

    /// Running apps that will fight Tessera for shortcuts.
    @MainActor
    static var running: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            app.bundleIdentifier.map { known[$0] != nil } ?? false
        }
    }
}

/// macOS 15's own window tiling. Its "drag to screen edge" fights Tessera's drag-to-snap,
/// so Tessera offers to turn it off (the same switch as System Settings › Desktop & Dock ›
/// "Drag windows to screen edges to tile").
enum MacTiling {
    private static let domain = "com.apple.WindowManager"
    private static let keys = ["EnableTilingByEdgeDrag", "EnableTopTilingByEdgeDrag"]

    /// True if macOS also snaps windows dragged to a screen edge. A missing setting means on.
    static var edgeDragIsOn: Bool {
        let defaults = UserDefaults(suiteName: domain)
        return keys.contains { defaults?.object(forKey: $0) as? Bool ?? true }
    }

    static func turnOffEdgeDrag() {
        let defaults = UserDefaults(suiteName: domain)
        for key in keys { defaults?.set(false, forKey: key) }
    }

    @MainActor
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
