import AppKit
import TesseraCore

/// A connected display, with frames in Accessibility coordinates
/// (origin top-left of the main screen, y grows downward).
struct DisplayInfo: Equatable, Identifiable {
    let displayID: CGDirectDisplayID
    /// Survives restarts and reconnects: vendor-model-serial.
    let stableID: String
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect
    let cocoaFrame: CGRect
    let isMain: Bool

    var id: String { stableID }
}

@MainActor
enum Screens {
    /// Height of the screen with the menu bar; anchors both coordinate systems.
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// Cocoa (bottom-left origin) → Accessibility (top-left origin). The formula is its own inverse.
    static func toAX(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func toCocoa(_ rect: CGRect) -> CGRect { toAX(rect) }

    static func toAX(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: primaryHeight - point.y) }

    /// Mouse location in Accessibility coordinates.
    static var mouseLocation: CGPoint { toAX(NSEvent.mouseLocation) }

    static func all() -> [DisplayInfo] {
        var seen: [String: Int] = [:]
        return NSScreen.screens.enumerated().map { index, screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            var stable = "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
            if CGDisplayIsBuiltin(id) != 0 { stable = "builtin-" + stable }
            let count = seen[stable, default: 0]
            seen[stable] = count + 1
            if count > 0 { stable += "-\(count)" }
            return DisplayInfo(
                displayID: id,
                stableID: stable,
                name: screen.localizedName,
                frame: toAX(screen.frame),
                visibleFrame: toAX(screen.visibleFrame),
                cocoaFrame: screen.frame,
                isMain: index == 0
            )
        }
    }

    /// Screens counted left to right (then top to bottom), from 1.
    static func ordered(_ displays: [DisplayInfo]) -> [DisplayInfo] {
        displays.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
    }

    /// What config patterns (main, secondary, 2, a name) see of a screen.
    static func context(of display: DisplayInfo, in displays: [DisplayInfo]) -> DisplayContext {
        let index = (ordered(displays).firstIndex(of: display) ?? 0) + 1
        return DisplayContext(name: display.name, index: index, isMain: display.isMain, count: displays.count)
    }

    static func display(containing point: CGPoint, in displays: [DisplayInfo]) -> DisplayInfo? {
        displays.first { $0.frame.contains(point) }
    }

    /// The display a window mostly sits on.
    static func display(for rect: CGRect, in displays: [DisplayInfo]) -> DisplayInfo? {
        if let best = displays.max(by: { $0.frame.intersectionArea(rect) < $1.frame.intersectionArea(rect) }),
           best.frame.intersectionArea(rect) > 0 {
            return best
        }
        return displays.min { $0.frame.center.distance(to: rect.center) < $1.frame.center.distance(to: rect.center) }
    }
}

/// Window server facts that Accessibility doesn't give us: on-screen state, layer, z-order.
struct WindowServerInfo {
    let id: CGWindowID
    let pid: pid_t
    let layer: Int
    let bounds: CGRect
    let alpha: Double
}

@MainActor
enum WindowServer {
    /// On-screen windows, front to back.
    static func onScreen() -> [WindowServerInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int
            else { return nil }
            var bounds = CGRect.zero
            if let dict = info[kCGWindowBounds as String] as? NSDictionary {
                bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) ?? .zero
            }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            return WindowServerInfo(id: id, pid: pid, layer: layer, bounds: bounds, alpha: alpha)
        }
    }

    static func onScreenIDs() -> Set<CGWindowID> { Set(onScreen().map(\.id)) }
}
