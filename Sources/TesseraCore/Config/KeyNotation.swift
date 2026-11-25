import Foundation

/// Which keyboard layout key names in the config are read for. QWERTY reads `alt-h` as the key
/// in QWERTY's H position; Dvorak and Colemak read it as the key that types h on those layouts.
public enum KeyMapping: String, Sendable, CaseIterable {
    case qwerty, dvorak, colemak
}

/// Key combos written as text, the way AeroSpace writes them: `alt-shift-h`, `cmd-ctrl-f`, `esc`.
public enum KeyNotation {
    static let letterCodes: [Character: UInt32] = [
        "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E, "f": 0x03, "g": 0x05, "h": 0x04, "i": 0x22,
        "j": 0x26, "k": 0x28, "l": 0x25, "m": 0x2E, "n": 0x2D, "o": 0x1F, "p": 0x23, "q": 0x0C, "r": 0x0F,
        "s": 0x01, "t": 0x11, "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07, "y": 0x10, "z": 0x06,
    ]

    static let named: [String: UInt32] = {
        var keys: [String: UInt32] = [
            "0": 0x1D, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17, "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19,
            "minus": 0x1B, "equal": 0x18, "period": 0x2F, "comma": 0x2B, "slash": 0x2C, "backslash": 0x2A,
            "quote": 0x27, "semicolon": 0x29, "backtick": 0x32, "grave": 0x32,
            "leftsquarebracket": 0x21, "rightsquarebracket": 0x1E, "leftbracket": 0x21, "rightbracket": 0x1E,
            "space": 0x31, "enter": 0x24, "return": 0x24, "esc": 0x35, "escape": 0x35, "backspace": 0x33,
            "delete": 0x33, "tab": 0x30, "pageup": 0x74, "pagedown": 0x79, "home": 0x73, "end": 0x77,
            "forwarddelete": 0x75, "sectionsign": 0x0A,
            "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
            "keypad0": 0x52, "keypad1": 0x53, "keypad2": 0x54, "keypad3": 0x55, "keypad4": 0x56,
            "keypad5": 0x57, "keypad6": 0x58, "keypad7": 0x59, "keypad8": 0x5B, "keypad9": 0x5C,
            "keypadclear": 0x47, "keypaddecimalmark": 0x41, "keypaddivide": 0x4B, "keypadenter": 0x4C,
            "keypadequal": 0x51, "keypadminus": 0x4E, "keypadmultiply": 0x43, "keypadplus": 0x45,
        ]
        let functionKeys: [UInt32] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
                                      0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A]
        for (i, code) in functionKeys.enumerated() { keys["f\(i + 1)"] = code }
        for (letter, code) in letterCodes { keys[String(letter)] = code }
        return keys
    }()

    /// The QWERTY key that types each character on Dvorak and Colemak.
    static let layouts: [KeyMapping: [Character: Character]] = {
        func invert(_ qwertyToOther: [Character: Character]) -> [Character: Character] {
            Dictionary(uniqueKeysWithValues: qwertyToOther.map { ($0.value, $0.key) })
        }
        let dvorak: [Character: Character] = [
            "q": "'", "w": ",", "e": ".", "r": "p", "t": "y", "y": "f", "u": "g", "i": "c", "o": "r", "p": "l",
            "a": "a", "s": "o", "d": "e", "f": "u", "g": "i", "h": "d", "j": "h", "k": "t", "l": "n", ";": "s",
            "z": ";", "x": "q", "c": "j", "v": "k", "b": "x", "n": "b", "m": "m", ",": "w", ".": "v", "/": "z",
        ]
        let colemak: [Character: Character] = [
            "q": "q", "w": "w", "e": "f", "r": "p", "t": "g", "y": "j", "u": "l", "i": "u", "o": "y", "p": ";",
            "a": "a", "s": "r", "d": "s", "f": "t", "g": "d", "h": "h", "j": "n", "k": "e", "l": "i", ";": "o",
            "z": "z", "x": "x", "c": "c", "v": "v", "b": "b", "n": "k", "m": "m",
        ]
        return [.dvorak: invert(dvorak), .colemak: invert(colemak)]
    }()

    static let symbolKeys: [Character: String] = [";": "semicolon", ",": "comma", ".": "period", "/": "slash", "'": "quote"]

    /// Reads `alt-shift-h`. Modifiers: cmd, alt (opt, option), ctrl (control), shift.
    public static func parse(_ text: String, mapping: KeyMapping = .qwerty, aliases: [String: String] = [:]) throws -> KeyCombo {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.last, !last.isEmpty, !parts.contains("") else {
            throw CommandError("“\(text)” isn't a key: write it like alt-shift-h")
        }
        var modifiers: Modifiers = []
        for word in parts.dropLast() {
            switch word.lowercased() {
            case "cmd", "command": modifiers.insert(.command)
            case "alt", "opt", "option": modifiers.insert(.option)
            case "ctrl", "control": modifiers.insert(.control)
            case "shift": modifiers.insert(.shift)
            default: throw CommandError("“\(word)” in “\(text)” isn't a modifier: use cmd, alt, ctrl or shift")
            }
        }
        var key = aliases[last] ?? last
        if key.count == 1, let character = key.lowercased().first, let table = layouts[mapping], let qwerty = table[character] {
            key = symbolKeys[qwerty] ?? String(qwerty)
        }
        guard let code = named[key.lowercased()] else {
            throw CommandError("“\(last)” isn't a key name (letters, digits, f1–f20, left, right, up, down, space, enter, esc, tab, minus, equal, comma, period, slash, semicolon, quote…)")
        }
        return KeyCombo(code, modifiers)
    }

    /// A combo written back as text: `ctrl-alt-left`.
    public static func text(for combo: KeyCombo) -> String {
        var parts: [String] = []
        if combo.modifiers.contains(.command) { parts.append("cmd") }
        if combo.modifiers.contains(.control) { parts.append("ctrl") }
        if combo.modifiers.contains(.option) { parts.append("alt") }
        if combo.modifiers.contains(.shift) { parts.append("shift") }
        let names = named.filter { $0.value == combo.keyCode }.map(\.key).sorted { $0.count < $1.count }
        parts.append(names.first ?? "#\(combo.keyCode)")
        return parts.joined(separator: "-")
    }
}
