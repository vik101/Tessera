import AppKit
import os

// MARK: - Localization

/// Looks up a user-facing string. Every visible string goes through `L` so the
/// extractor script (scripts/strings.py) can find it.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Looks up a format string and fills it in. Use %@ for text and %ld for whole numbers.
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), locale: Locale.current, arguments: args)
}

// MARK: - Logging

/// Logs to the unified log and keeps a short in-memory trail for problem reports.
/// Never logs window titles.
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

/// Collapses bursts of calls into one, after a quiet period.
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

/// A repeating timer that calls back on the main actor.
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

// MARK: - Geometry

extension CGRect {
    func isClose(to other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance &&
            abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }

    var center: CGPoint { CGPoint(x: midX, y: midY) }

    func intersectionArea(_ other: CGRect) -> CGFloat {
        let i = intersection(other)
        return i.isNull ? 0 : i.width * i.height
    }

    /// A rect of `size` centred in this rect.
    func centered(size: CGSize) -> CGRect {
        CGRect(x: midX - size.width / 2, y: midY - size.height / 2, width: size.width, height: size.height).integral
    }
}

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat { hypot(x - other.x, y - other.y) }
}

// MARK: - Colors

extension NSColor {
    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

// MARK: - Apps

extension NSRunningApplication {
    var displayName: String { localizedName ?? bundleIdentifier ?? "App" }
}

enum AppIcons {
    @MainActor
    static func icon(bundleID: String?, pid: pid_t? = nil) -> NSImage {
        if let pid, let app = NSRunningApplication(processIdentifier: pid), let icon = app.icon { return icon }
        if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
    }
}
