// A small helper for the CI tests: presses keys, drags the mouse, lists windows.
//
//   keys press ctrl,opt 0x7B          press ⌃⌥← (add fn,num for arrow keys)
//   keys windows                       JSON list of normal on-screen windows, front to back
//   keys activate com.apple.TextEdit   bring an app to the front
//   keys post dump                     send a test command to Tessera
//   keys drag X1 Y1 X2 Y2              drag with the left button
//   keys click X Y
//   keys displays                      list screens and their frames
//   keys trusted                       does this tool have Accessibility? (needed for the next four)
//   keys menu-list                     Tessera's open menu: titles and shortcut keys, as JSON
//   keys menu-press "Columns"          click an item in Tessera's open menu
//   keys unminimize com.apple.TextEdit un-minimise an app's windows
//   keys hide com.apple.finder         hide an app (from the background, like ⌘H on it)
//   keys unhide com.apple.finder       show a hidden app again
//   keys space-add                     add a desktop (Space) through Mission Control
//   keys space-go 2                    go to desktop 2 through Mission Control
//   keys space-tree                    Mission Control's Accessibility tree, for debugging
//   keys app-menu com.apple.TextEdit Window "Fill|Zoom"   click an app's menu item (first title found)
//   keys close-untitled com.apple.TextEdit                close an app's new "Untitled" windows
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

// MARK: Mission Control (desktops, also called Spaces)

func dockElement() -> AXUIElement? {
    guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
    let element = AXUIElementCreateApplication(dock.processIdentifier)
    AXUIElementSetMessagingTimeout(element, 3)
    return element
}

func find(_ element: AXUIElement, identifier: String, depth: Int = 0) -> AXUIElement? {
    if (ax(element, "AXIdentifier") as? String) == identifier { return element }
    guard depth < 8 else { return nil }
    for child in axChildren(element) {
        if let hit = find(child, identifier: identifier, depth: depth + 1) { return hit }
    }
    return nil
}

func tree(_ element: AXUIElement, depth: Int = 0) -> [String] {
    let line = String(repeating: "  ", count: depth) + [
        ax(element, kAXRoleAttribute) as? String ?? "?",
        (ax(element, "AXIdentifier") as? String).map { "id=\($0)" } ?? "",
        (ax(element, kAXTitleAttribute) as? String).map { "title=\($0)" } ?? "",
        (ax(element, kAXDescriptionAttribute) as? String).map { "desc=\($0)" } ?? "",
    ].filter { !$0.isEmpty }.joined(separator: " ")
    guard depth < 7 else { return [line] }
    return [line] + axChildren(element).flatMap { tree($0, depth: depth + 1) }
}

func run(_ path: String, _ arguments: [String]) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = arguments
    try? task.run()
    task.waitUntilExit()
}

/// Opens Mission Control and returns its Accessibility element once it shows.
func openMissionControl() -> AXUIElement? {
    run("/usr/bin/open", ["-a", "Mission Control"])
    for _ in 0..<25 {
        usleep(150_000)
        if let dock = dockElement(), let mc = find(dock, identifier: "mc"), find(mc, identifier: "mc.spaces") != nil {
            usleep(400_000)   // Let it finish opening.
            return mc
        }
    }
    return nil
}

func closeMissionControl() {
    key(0x35, down: true, [])
    key(0x35, down: false, [])
    usleep(900_000)
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

case "displays":
    for screen in NSScreen.screens {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
        print("display \(id) \(screen.localizedName) frame=\(screen.frame) visible=\(screen.visibleFrame)")
    }

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

case "hide" where args.count >= 2:
    // Hides an app without bringing anything forward (hiding the front app makes macOS bring
    // forward the next one, and that can un-hide an app hidden earlier).
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[1]).first {
        app.hide()
        usleep(500_000)
        print("\(args[1]) hidden: \(app.isHidden)")
    }

case "unhide" where args.count >= 2:
    NSRunningApplication.runningApplications(withBundleIdentifier: args[1]).first?.unhide()
    usleep(400_000)

case "space-add":
    guard let mc = openMissionControl() else {
        print("no Mission Control")
        if let dock = dockElement() { print(tree(dock).joined(separator: "\n")) }
        closeMissionControl()
        break
    }
    if let add = find(mc, identifier: "mc.spaces.add") {
        let result = AXUIElementPerformAction(add, kAXPressAction as CFString)
        print("added: \(result.rawValue)")
        usleep(1_200_000)
    } else {
        print("no add button")
        print(tree(mc).joined(separator: "\n"))
    }
    closeMissionControl()

case "space-go" where args.count >= 2:
    let index = (Int(args[1]) ?? 1) - 1
    guard let mc = openMissionControl() else {
        print("no Mission Control")
        closeMissionControl()
        break
    }
    let buttons = find(mc, identifier: "mc.spaces.list").map(axChildren) ?? []
    if buttons.indices.contains(index) {
        let result = AXUIElementPerformAction(buttons[index], kAXPressAction as CFString)
        print("went to desktop \(index + 1) of \(buttons.count): \(result.rawValue)")
        usleep(1_200_000)
    } else {
        print("no desktop \(index + 1); found \(buttons.count)")
        print(tree(mc).joined(separator: "\n"))
        closeMissionControl()
    }

case "space-tree":
    if let mc = openMissionControl() {
        print(tree(mc).joined(separator: "\n"))
    } else if let dock = dockElement() {
        print(tree(dock).joined(separator: "\n"))
    }
    closeMissionControl()

case "app-menu" where args.count >= 4:
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[1]).first else {
        print("not running: \(args[1])")
        break
    }
    let element = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(element, 3)
    let wanted = args[3].split(separator: "|").map(String.init)
    let bar = ax(element, kAXMenuBarAttribute).map { $0 as! AXUIElement }
    let menus = bar.map(axChildren) ?? []
    var pressed = false
    for barItem in menus where (ax(barItem, kAXTitleAttribute) as? String) == args[2] {
        let items = axChildren(barItem).flatMap(axChildren)
        for title in wanted {
            if let item = items.first(where: { (ax($0, kAXTitleAttribute) as? String) == title }) {
                let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
                print("pressed \(args[2]) › \(title): \(result.rawValue)")
                pressed = true
                break
            }
        }
        if !pressed {
            print("in \(args[2]): " + items.compactMap { ax($0, kAXTitleAttribute) as? String }.joined(separator: ", "))
        }
    }
    if !pressed { print("not found: \(args[2]) › \(args[3])") }

case "close-untitled" where args.count >= 2:
    // Closes an app's new, unsaved "Untitled" windows (they close without asking).
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[1]).first else { break }
    let element = AXUIElementCreateApplication(app.processIdentifier)
    var closed = 0
    for window in (ax(element, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    where (ax(window, kAXTitleAttribute) as? String)?.hasPrefix("Untitled") == true {
        if let button = ax(window, kAXCloseButtonAttribute) {
            _ = AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            closed += 1
            usleep(400_000)
        }
    }
    print("closed \(closed)")

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
