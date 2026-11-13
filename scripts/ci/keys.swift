// Presses key combos for the CI smoke test.
//   keys ctrl,opt 0x7C          press ⌃⌥→
//   keys tabview shot.png        hold ⌥, tap ⇥, take a screenshot, let go
import CoreGraphics
import Foundation

let source = CGEventSource(stateID: .hidSystemState)

func flags(_ text: String) -> CGEventFlags {
    var result: CGEventFlags = []
    for part in text.split(separator: ",") {
        switch part {
        case "ctrl": result.insert(.maskControl)
        case "opt": result.insert(.maskAlternate)
        case "shift": result.insert(.maskShift)
        case "cmd": result.insert(.maskCommand)
        case "fn": result.insert(.maskSecondaryFn)
        case "num": result.insert(.maskNumericPad)
        default: break
        }
    }
    return result
}

func key(_ code: CGKeyCode, down: Bool, _ flags: CGEventFlags) {
    let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)!
    event.flags = flags
    event.post(tap: .cghidEventTap)
    usleep(40_000)
}

let args = CommandLine.arguments
if args.count >= 3, args[1] == "tabview" {
    key(0x3A, down: true, .maskAlternate)      // ⌥ down
    key(0x30, down: true, .maskAlternate)      // ⇥
    key(0x30, down: false, .maskAlternate)
    usleep(1_500_000)
    let shot = Process()
    shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    shot.arguments = ["-x", args[2]]
    try? shot.run()
    shot.waitUntilExit()
    key(0x3A, down: false, [])                 // ⌥ up: picks the window
} else if args.count >= 3 {
    let mods = flags(args[1])
    let code = CGKeyCode(UInt16(args[2].replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0)
    key(code, down: true, mods)
    key(code, down: false, mods)
}

// keys windows   → id, app, title and frame of every normal on-screen window (front to back)
if args.count == 2, args[1] == "windows" {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for info in list where (info[kCGWindowLayer as String] as? Int) == 0 {
        let id = info[kCGWindowNumber as String] as? Int ?? 0
        let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
        let name = info[kCGWindowName as String] as? String ?? ""
        let b = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
        print("\(id)\t\(owner)\t\(name)\t\(b["X"] ?? 0),\(b["Y"] ?? 0) \(b["Width"] ?? 0)×\(b["Height"] ?? 0)")
    }
}

func mouse(_ type: CGEventType, _ x: Double, _ y: Double, _ flags: CGEventFlags = []) {
    let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)!
    event.flags = flags
    event.post(tap: .cghidEventTap)
}

// keys move X Y              → move the pointer
// keys drag X1 Y1 X2 Y2 cmd  → drag with modifiers held
if args.count == 4, args[1] == "move", let x = Double(args[2]), let y = Double(args[3]) {
    mouse(.mouseMoved, x - 3, y)
    usleep(50_000)
    mouse(.mouseMoved, x, y)
}
if args.count >= 6, args[1] == "drag", let x1 = Double(args[2]), let y1 = Double(args[3]), let x2 = Double(args[4]), let y2 = Double(args[5]) {
    let mods = args.count >= 7 ? flags(args[6]) : []
    if mods.contains(.maskCommand) { key(0x37, down: true, mods) }
    mouse(.mouseMoved, x1, y1, mods)
    usleep(100_000)
    mouse(.leftMouseDown, x1, y1, mods)
    usleep(150_000)
    for step in 1...30 {
        let t = Double(step) / 30
        mouse(.leftMouseDragged, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, mods)
        usleep(30_000)
    }
    usleep(400_000)
    mouse(.leftMouseUp, x2, y2, mods)
    usleep(100_000)
    if mods.contains(.maskCommand) { key(0x37, down: false, []) }
}
