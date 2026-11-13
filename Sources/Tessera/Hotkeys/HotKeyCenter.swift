import AppKit
import Carbon.HIToolbox
import TesseraCore

/// Registers global shortcuts with macOS (Carbon hot keys).
///
/// macOS tells us only when one of *our* key combos is pressed, so Tessera
/// never sees anything else you type.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    struct Token: Hashable { let id: UInt32 }

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: @MainActor () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    /// While true (e.g. recording a new shortcut), presses are ignored.
    var paused = false

    private func installIfNeeded() -> Bool {
        if installed { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec, nil, nil)
        installed = status == noErr
        if !installed { Log.error("Couldn't install the hot key handler (\(status))") }
        return installed
    }

    /// Registers a combo. Returns nil if macOS refused it (another app may hold it).
    func register(_ combo: KeyCombo, handler: @escaping @MainActor () -> Void) -> Token? {
        guard installIfNeeded() else { return nil }
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5453_4852), id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers.carbonFlags, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        refs[id] = ref
        handlers[id] = handler
        return Token(id: id)
    }

    func unregister(_ token: Token) {
        if let ref = refs.removeValue(forKey: token.id) { UnregisterEventHotKey(ref) }
        handlers.removeValue(forKey: token.id)
    }

    func unregister(_ tokens: [Token]) { tokens.forEach(unregister) }

    fileprivate func fire(_ id: UInt32) {
        guard !paused else { return }
        handlers[id]?()
    }
}

private func hotKeyEventHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let id = hotKeyID.id
    MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) }
    return noErr
}

/// Is a password field (or a secure terminal) blocking shortcuts right now?
enum SecureInput {
    static var isOn: Bool { IsSecureEventInputEnabled() }
}

/// Reads the current keyboard layout to label keys and spot combos that type characters.
@MainActor
enum KeyboardLayout {
    /// The character a key types with these modifiers (only ⇧/⌥), e.g. ⌥R types "®".
    static func typedCharacter(keyCode: UInt32, modifiers: Modifiers) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, "TISPropertyUnicodeKeyLayoutData" as CFString) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let modifierState = (modifiers.carbonFlags >> 8) & 0xFF
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDown),
                modifierState,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                4,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length)
        guard text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && !$0.properties.isWhitespace }) else { return nil }
        return text
    }

    /// A label for a combo using the current layout where it helps (letters and symbols).
    static func label(for combo: KeyCombo) -> String {
        combo.description
    }
}
