// A small helper for the CI tests: presses keys, drags the mouse, lists windows.
//
//   keys press ctrl,opt 0x7B          press ⌃⌥← (add fn,num for arrow keys)
//   keys windows                       JSON list of normal on-screen windows, front to back
//   keys activate com.apple.TextEdit   bring an app to the front
//   keys post dump                     send a test command to Tessera
//   keys drag X1 Y1 X2 Y2              drag with the left button
//   keys click X Y
import AppKit
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
    usleep(30_000)
}

func mouse(_ type: CGEventType, _ x: Double, _ y: Double) {
    let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)!
    event.post(tap: .cghidEventTap)
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "press" where args.count >= 3:
    let mods = flags(args[1])
    let code = CGKeyCode(UInt16(args[2].replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0)
    key(code, down: true, mods)
    key(code, down: false, mods)

case "windows":
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    var out: [[String: Any]] = []
    for info in list where (info[kCGWindowLayer as String] as? Int) == 0 {
        let b = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
        out.append([
            "id": info[kCGWindowNumber as String] as? Int ?? 0,
            "pid": info[kCGWindowOwnerPID as String] as? Int ?? 0,
            "owner": info[kCGWindowOwnerName as String] as? String ?? "?",
            "frame": [b["X"], b["Y"], b["Width"], b["Height"]].map { ($0 as? Double) ?? 0 },
        ])
    }
    let front = NSWorkspace.shared.frontmostApplication
    let result: [String: Any] = ["frontPid": Int(front?.processIdentifier ?? 0), "frontApp": front?.bundleIdentifier ?? "", "windows": out]
    let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))

case "activate" where args.count >= 2:
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[1]).first {
        app.activate()
        usleep(400_000)
    } else {
        print("not running: \(args[1])")
    }

case "post" where args.count >= 2:
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.vikram.Tessera.test"), object: args[1], userInfo: nil, deliverImmediately: true)
    usleep(100_000)

case "click" where args.count >= 3:
    let x = Double(args[1])!, y = Double(args[2])!
    mouse(.mouseMoved, x, y)
    usleep(80_000)
    mouse(.leftMouseDown, x, y)
    usleep(80_000)
    mouse(.leftMouseUp, x, y)

case "drag" where args.count >= 5:
    let x1 = Double(args[1])!, y1 = Double(args[2])!, x2 = Double(args[3])!, y2 = Double(args[4])!
    mouse(.mouseMoved, x1, y1)
    usleep(150_000)
    mouse(.leftMouseDown, x1, y1)
    usleep(200_000)
    for step in 1...40 {
        let t = Double(step) / 40
        mouse(.leftMouseDragged, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t)
        usleep(25_000)
    }
    // Hold still at the end, as a person would, so the snap preview shows.
    for _ in 0..<10 {
        mouse(.leftMouseDragged, x2, y2)
        usleep(50_000)
    }
    mouse(.leftMouseUp, x2, y2)
    usleep(150_000)

default:
    print("usage: keys press|windows|activate|post|click|drag …")
    exit(2)
}
