import AppKit
import ApplicationServices

// AX references are thread-safe CF objects; we only use them on the main actor anyway.
extension AXUIElement: @retroactive @unchecked Sendable {}
extension AXObserver: @retroactive @unchecked Sendable {}

/// Gets the window server ID for an Accessibility window element.
/// Private but long-stable; used by most macOS window managers.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// A thin, readable wrapper around `AXUIElement`.
struct AXElement: Hashable, @unchecked Sendable {
    let ref: AXUIElement

    init(_ ref: AXUIElement) { self.ref = ref }

    static func application(_ pid: pid_t) -> AXElement { AXElement(AXUIElementCreateApplication(pid)) }
    static var systemWide: AXElement { AXElement(AXUIElementCreateSystemWide()) }

    static func == (lhs: AXElement, rhs: AXElement) -> Bool { CFEqual(lhs.ref, rhs.ref) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(ref)) }

    // MARK: Reading

    func value(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(ref, attribute as CFString, &value)
        return error == .success ? value : nil
    }

    func string(_ attribute: String) -> String? { value(attribute) as? String }

    func bool(_ attribute: String) -> Bool? {
        guard let value = value(attribute) else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    func int(_ attribute: String) -> Int? {
        (value(attribute) as? NSNumber)?.intValue
    }

    func element(_ attribute: String) -> AXElement? {
        guard let value = value(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(value as! AXUIElement)
    }

    func elements(_ attribute: String) -> [AXElement] {
        guard let value = value(attribute), let array = value as? [AnyObject] else { return [] }
        return array.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? AXElement(item as! AXUIElement) : nil
        }
    }

    var role: String? { string(kAXRoleAttribute) }
    var subrole: String? { string(kAXSubroleAttribute) }
    var title: String? { string(kAXTitleAttribute) }
    var isMinimized: Bool { bool(kAXMinimizedAttribute) ?? false }
    var isFullScreen: Bool { bool("AXFullScreen") ?? false }
    var isModal: Bool { bool(kAXModalAttribute) ?? false }

    var position: CGPoint? {
        guard let value = value(kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    var size: CGSize? {
        guard let value = value(kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    /// Frame in Accessibility coordinates (origin top-left of the main screen).
    var frame: CGRect? {
        guard let position, let size else { return nil }
        return CGRect(origin: position, size: size)
    }

    var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(ref, &pid) == .success ? pid : nil
    }

    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(ref, &id) == .success && id != 0 ? id : nil
    }

    func isSettable(_ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(ref, attribute as CFString, &settable) == .success && settable.boolValue
    }

    // MARK: Writing

    @discardableResult
    func set(_ attribute: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(ref, attribute as CFString, value)
    }

    @discardableResult
    func set(_ attribute: String, bool: Bool) -> AXError {
        let value: CFBoolean = bool ? kCFBooleanTrue : kCFBooleanFalse
        return set(attribute, value)
    }

    @discardableResult
    func setPosition(_ point: CGPoint) -> AXError {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return .failure }
        return set(kAXPositionAttribute, value)
    }

    @discardableResult
    func setSize(_ size: CGSize) -> AXError {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return .failure }
        return set(kAXSizeAttribute, value)
    }

    @discardableResult
    func perform(_ action: String) -> AXError {
        AXUIElementPerformAction(ref, action as CFString)
    }

    /// Stops a hung app from freezing us.
    func setMessagingTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(ref, seconds)
    }

    /// The element at a screen point (Accessibility coordinates).
    static func element(at point: CGPoint) -> AXElement? {
        var element: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element)
        guard error == .success, let element else { return nil }
        return AXElement(element)
    }

    /// Walks up to the containing window.
    var window: AXElement? {
        if role == kAXWindowRole { return self }
        return element(kAXWindowAttribute)
    }
}

/// Accessibility permission helpers.
enum AccessibilityPermission {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that offers to open System Settings.
    static func prompt() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @MainActor
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
