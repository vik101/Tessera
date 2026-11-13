import Foundation

/// Modifier keys, in the order macOS shows them: ⌃ ⌥ ⇧ ⌘.
public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = Modifiers(rawValue: 1 << 0)
    public static let option = Modifiers(rawValue: 1 << 1)
    public static let shift = Modifiers(rawValue: 1 << 2)
    public static let command = Modifiers(rawValue: 1 << 3)

    public var symbols: String {
        var text = ""
        if contains(.control) { text += "⌃" }
        if contains(.option) { text += "⌥" }
        if contains(.shift) { text += "⇧" }
        if contains(.command) { text += "⌘" }
        return text
    }

    /// Carbon modifier bits (cmdKey, shiftKey, optionKey, controlKey).
    public var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= 0x0100 }
        if contains(.shift) { flags |= 0x0200 }
        if contains(.option) { flags |= 0x0800 }
        if contains(.control) { flags |= 0x1000 }
        return flags
    }

    public init(carbonFlags flags: UInt32) {
        var value: Modifiers = []
        if flags & 0x0100 != 0 { value.insert(.command) }
        if flags & 0x0200 != 0 { value.insert(.shift) }
        if flags & 0x0800 != 0 { value.insert(.option) }
        if flags & 0x1000 != 0 { value.insert(.control) }
        self = value
    }

    /// True when the combo cannot type a character: it has ⌃ or ⌘.
    public var preventsTyping: Bool { contains(.control) || contains(.command) }
}

/// A physical key (virtual key code) plus modifiers.
public struct KeyCombo: Codable, Hashable, Sendable, CustomStringConvertible {
    public var keyCode: UInt32
    public var modifiers: Modifiers

    public init(_ keyCode: UInt32, _ modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var description: String { modifiers.symbols + KeyCode.label(for: keyCode) }

    public var isFunctionKey: Bool { KeyCode.functionKeys.contains(keyCode) }

    /// Keep ⌃, ⌥ or ⌘ so normal typing still works. F-keys may stand alone.
    public var isAllowedAsShortcut: Bool {
        if isFunctionKey { return true }
        return modifiers.contains(.control) || modifiers.contains(.option) || modifiers.contains(.command)
    }

    public func adding(_ extra: Modifiers) -> KeyCombo { KeyCombo(keyCode, modifiers.union(extra)) }
}

/// Virtual key codes (US ANSI positions), matching Carbon's kVK_ constants.
public enum KeyCode {
    public static let a: UInt32 = 0x00, s: UInt32 = 0x01, d: UInt32 = 0x02, f: UInt32 = 0x03
    public static let h: UInt32 = 0x04, g: UInt32 = 0x05, z: UInt32 = 0x06, x: UInt32 = 0x07
    public static let c: UInt32 = 0x08, v: UInt32 = 0x09, b: UInt32 = 0x0B, q: UInt32 = 0x0C
    public static let w: UInt32 = 0x0D, e: UInt32 = 0x0E, r: UInt32 = 0x0F, y: UInt32 = 0x10
    public static let t: UInt32 = 0x11, o: UInt32 = 0x1F, u: UInt32 = 0x20, i: UInt32 = 0x22
    public static let p: UInt32 = 0x23, l: UInt32 = 0x25, j: UInt32 = 0x26, k: UInt32 = 0x28
    public static let n: UInt32 = 0x2D, m: UInt32 = 0x2E
    public static let one: UInt32 = 0x12, two: UInt32 = 0x13, three: UInt32 = 0x14, four: UInt32 = 0x15
    public static let five: UInt32 = 0x17, six: UInt32 = 0x16, seven: UInt32 = 0x1A, eight: UInt32 = 0x1C
    public static let nine: UInt32 = 0x19, zero: UInt32 = 0x1D
    public static let equal: UInt32 = 0x18, minus: UInt32 = 0x1B
    public static let rightBracket: UInt32 = 0x1E, leftBracket: UInt32 = 0x21
    public static let quote: UInt32 = 0x27, semicolon: UInt32 = 0x29, backslash: UInt32 = 0x2A
    public static let comma: UInt32 = 0x2B, slash: UInt32 = 0x2C, period: UInt32 = 0x2F, grave: UInt32 = 0x32
    public static let returnKey: UInt32 = 0x24, tab: UInt32 = 0x30, space: UInt32 = 0x31
    public static let delete: UInt32 = 0x33, escape: UInt32 = 0x35, forwardDelete: UInt32 = 0x75
    public static let home: UInt32 = 0x73, end: UInt32 = 0x77, pageUp: UInt32 = 0x74, pageDown: UInt32 = 0x79
    public static let leftArrow: UInt32 = 0x7B, rightArrow: UInt32 = 0x7C, downArrow: UInt32 = 0x7D, upArrow: UInt32 = 0x7E
    public static let f1: UInt32 = 0x7A, f2: UInt32 = 0x78, f3: UInt32 = 0x63, f4: UInt32 = 0x76
    public static let f5: UInt32 = 0x60, f6: UInt32 = 0x61, f7: UInt32 = 0x62, f8: UInt32 = 0x64
    public static let f9: UInt32 = 0x65, f10: UInt32 = 0x6D, f11: UInt32 = 0x67, f12: UInt32 = 0x6F
    public static let f13: UInt32 = 0x69, f14: UInt32 = 0x6B, f15: UInt32 = 0x71, f16: UInt32 = 0x6A
    public static let f17: UInt32 = 0x40, f18: UInt32 = 0x4F, f19: UInt32 = 0x50, f20: UInt32 = 0x5A

    public static let digits: [UInt32] = [one, two, three, four, five, six, seven, eight, nine]

    public static let functionKeys: Set<UInt32> = [f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20]

    /// F-keys offered as free alternatives, in order of preference.
    public static let suggestedFunctionKeys: [UInt32] = [f13, f14, f15, f16, f17, f18, f19, f5, f6, f7, f8, f9]

    private static let labels: [UInt32: String] = [
        a: "A", s: "S", d: "D", f: "F", h: "H", g: "G", z: "Z", x: "X", c: "C", v: "V", b: "B", q: "Q",
        w: "W", e: "E", r: "R", y: "Y", t: "T", o: "O", u: "U", i: "I", p: "P", l: "L", j: "J", k: "K",
        n: "N", m: "M",
        one: "1", two: "2", three: "3", four: "4", five: "5", six: "6", seven: "7", eight: "8", nine: "9", zero: "0",
        equal: "=", minus: "-", rightBracket: "]", leftBracket: "[", quote: "'", semicolon: ";",
        backslash: "\\", comma: ",", slash: "/", period: ".", grave: "`",
        returnKey: "↩", tab: "⇥", space: "Space", delete: "⌫", escape: "⎋", forwardDelete: "⌦",
        home: "↖", end: "↘", pageUp: "⇞", pageDown: "⇟",
        leftArrow: "←", rightArrow: "→", downArrow: "↓", upArrow: "↑",
        f1: "F1", f2: "F2", f3: "F3", f4: "F4", f5: "F5", f6: "F6", f7: "F7", f8: "F8", f9: "F9", f10: "F10",
        f11: "F11", f12: "F12", f13: "F13", f14: "F14", f15: "F15", f16: "F16", f17: "F17", f18: "F18",
        f19: "F19", f20: "F20",
    ]

    public static func label(for code: UInt32) -> String { labels[code] ?? "#\(code)" }

    /// Reverse lookup for menu shortcuts reported as characters (US layout).
    public static func code(forCharacter character: String) -> UInt32? {
        let upper = character.uppercased()
        return labels.first { $0.value == upper && $0.value.count == 1 }?.key
    }
}
