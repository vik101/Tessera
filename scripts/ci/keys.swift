// A small helper for the CI tests: presses keys, drags the mouse, lists windows.
//
//   keys press ctrl,opt 0x7B          press ⌃⌥← (add fn,num for arrow keys)
//   keys windows                       JSON list of normal on-screen windows, front to back
//   keys activate com.apple.TextEdit   bring an app to the front
//   keys post dump                     send a test command to Tessera
//   keys drag X1 Y1 X2 Y2              drag with the left button
//   keys click X Y
//   keys trusted                       does this tool have Accessibility? (needed for the next four)
//   keys menu-list                     Tessera's open menu: titles and shortcut keys, as JSON
//   keys menu-press "Columns"          click an item in Tessera's open menu
//   keys unminimize com.apple.TextEdit un-minimise an app's windows
//   keys unhide com.apple.finder       show a hidden app again
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
    event.flags = []   // No leftover ⌃ from earlier key presses: ⌃-click is a right-click.
    event.post(tap: .cghidEventTap)
}


// MARK: Accessibility helpers (for checking Tessera's menu like a person would)

func ax(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
}

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    (ax(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

/// The items of Tessera's menu, if it is open.
func tesseraMenuItems() -> [AXUIElement] {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.vikram.Tessera").first else { return [] }
    let element = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(element, 3)
    guard let extras = ax(element, "AXExtrasMenuBar") else { return [] }
    var items: [AXUIElement] = []
    for barItem in axChildren(extras as! AXUIElement) {
        for menu in axChildren(barItem) where (ax(menu, kAXRoleAttribute) as? String) == kAXMenuRole {
            items += axChildren(menu)
        }
    }
    return items
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

case "trusted":
    print(AXIsProcessTrusted() ? "yes" : "no")

case "menu-list":
    var out: [[String: Any]] = []
    for item in tesseraMenuItems() {
        out.append([
            "title": ax(item, kAXTitleAttribute) as? String ?? "",
            "key": ax(item, "AXMenuItemCmdChar") as? String ?? "",
            "mods": (ax(item, "AXMenuItemCmdModifiers") as? Int) ?? -1,
            "checked": (ax(item, "AXMenuItemMarkChar") as? String) ?? "",
            "enabled": (ax(item, kAXEnabledAttribute) as? Bool) ?? false,
        ])
    }
    let data = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))

case "menu-press" where args.count >= 2:
    if let item = tesseraMenuItems().first(where: { (ax($0, kAXTitleAttribute) as? String) == args[1] }) {
        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        print("pressed \(args[1]): \(result.rawValue)")
    } else {
        print("not found: \(args[1])")
    }

case "unminimize" where args.count >= 2:
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[1]).first {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        for window in (ax(element, kAXWindowsAttribute) as? [AXUIElement]) ?? [] where (ax(window, kAXMinimizedAttribute) as? Bool) == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            usleep(300_000)
        }
    }

case "unhide" where args.count >= 2:
    NSRunningApplication.runningApplications(withBundleIdentifier: args[1]).first?.unhide()
    usleep(400_000)

case "resolution":
    // Make the test screen bigger if the virtual display allows it.
    let display = CGMainDisplayID()
    let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    let modes = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
    for mode in modes { print("mode \(mode.width)x\(mode.height) usable=\(mode.isUsableForDesktopGUI())") }
    if let best = modes.filter({ $0.isUsableForDesktopGUI() && $0.width <= 1920 && $0.height <= 1200 })
        .max(by: { $0.width * $0.height < $1.width * $1.height }) {
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayWithDisplayMode(config, display, best, nil)
        let result = CGCompleteDisplayConfiguration(config, .permanently)
        print("set \(best.width)x\(best.height): \(result.rawValue)")
    }

default:
    print("usage: keys press|windows|activate|post|click|drag …")
    exit(2)
}
