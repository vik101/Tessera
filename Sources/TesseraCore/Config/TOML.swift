import Foundation

/// A value in a TOML file.
public indirect enum TOMLValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case float(Double)
    case bool(Bool)
    /// Dates and times are kept as written.
    case datetime(String)
    case array([TOMLValue])
    case table(TOMLTable)

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var int: Int? { if case .integer(let i) = self { return i }; return nil }
    public var table: TOMLTable? { if case .table(let t) = self { return t }; return nil }
    public var array: [TOMLValue]? { if case .array(let a) = self { return a }; return nil }

    /// A number, whether written as an integer or a float.
    public var number: Double? {
        switch self {
        case .integer(let i): Double(i)
        case .float(let d): d
        default: nil
        }
    }

    /// A string, or an array of strings (TOML configs use both for "one or more commands").
    public var strings: [String]? {
        switch self {
        case .string(let s): [s]
        case .array(let items): items.allSatisfy { $0.string != nil } ? items.compactMap(\.string) : nil
        default: nil
        }
    }

    public var typeName: String {
        switch self {
        case .string: "string"
        case .integer: "integer"
        case .float: "float"
        case .bool: "boolean"
        case .datetime: "date"
        case .array: "array"
        case .table: "table"
        }
    }
}

/// A TOML table: keys in the order they were written, and the line each was written on.
public struct TOMLTable: Equatable, Sendable {
    public private(set) var keys: [String] = []
    public private(set) var values: [String: TOMLValue] = [:]
    /// The line (from 1) each key was set on, for error messages.
    public private(set) var lines: [String: Int] = [:]
    /// True for a table made only because a dotted key or header passed through it.
    var implicit = false
    /// True for a table defined by a [header] (it can't be defined again).
    var headed = false

    public init() {}

    public subscript(key: String) -> TOMLValue? { values[key] }

    /// Follows a dotted path of keys through nested tables: `table["gaps", "inner"]`.
    public subscript(path: String...) -> TOMLValue? { value(at: path) }

    public func value(at path: [String]) -> TOMLValue? {
        guard let first = path.first, let value = values[first] else { return nil }
        if path.count == 1 { return value }
        guard case .table(let inner) = value else { return nil }
        return inner.value(at: Array(path.dropFirst()))
    }

    public var isEmpty: Bool { keys.isEmpty }

    public mutating func set(_ key: String, _ value: TOMLValue, line: Int = 0) {
        if values[key] == nil { keys.append(key) }
        values[key] = value
        if line > 0 { lines[key] = line }
    }
}

public struct TOMLError: Error, Equatable, Sendable, CustomStringConvertible {
    public var line: Int
    public var column: Int
    public var message: String
    public var description: String { "line \(line), column \(column): \(message)" }
}

/// Reads TOML 1.0: tables, arrays of tables, dotted keys, inline tables, every string form,
/// integers (decimal, hex, octal, binary), floats, booleans. Dates are kept as text.
/// A place in the file, kept for errors found a little later.
struct Position: Sendable {
    var line: Int
    var column: Int
    func error(_ message: String) -> TOMLError { TOMLError(line: line, column: column, message: message) }
}

public enum TOML {
    public static func parse(_ text: String) throws -> TOMLTable {
        var parser = Parser(Array(text))
        return try parser.document()
    }

    private struct Parser {
        let chars: [Character]
        var index = 0
        var line = 1
        var lineStart = 0
        var root = TOMLTable()
        /// The table that `key = value` lines go into, as a path from the root.
        var current: [String] = []

        init(_ chars: [Character]) { self.chars = chars }

        var peek: Character? { index < chars.count ? chars[index] : nil }
        func peek(_ offset: Int) -> Character? { index + offset < chars.count ? chars[index + offset] : nil }

        func fail(_ message: String) -> TOMLError {
            TOMLError(line: line, column: index - lineStart + 1, message: message)
        }

        /// Where the parser is now, for errors raised later (inside table edits).
        var here: Position { Position(line: line, column: index - lineStart + 1) }

        mutating func advance() {
            if chars[index] == "\n" || chars[index] == "\r\n" {
                line += 1
                lineStart = index + 1
            }
            index += 1
        }

        mutating func skipSpaces() {
            while let c = peek, c == " " || c == "\t" { advance() }
        }

        mutating func skipComment() {
            if peek == "#" { while let c = peek, c != "\n", c != "\r\n" { advance() } }
        }

        /// Spaces, comments and line breaks (inside arrays).
        mutating func skipBlank() {
            while let c = peek {
                if c == " " || c == "\t" || c == "\n" || c == "\r\n" || c == "\r" {
                    advance()
                } else if c == "#" {
                    skipComment()
                } else {
                    break
                }
            }
        }

        mutating func endOfLine() throws {
            skipSpaces()
            skipComment()
            guard let c = peek else { return }
            if c == "\n" || c == "\r\n" {
                advance()
            } else if c == "\r", peek(1) == "\n" {
                advance(); advance()
            } else {
                throw fail("expected the end of the line, found “\(c)”")
            }
        }

        mutating func document() throws -> TOMLTable {
            while peek != nil {
                skipBlank()
                guard let c = peek else { break }
                if c == "[" {
                    try header()
                } else {
                    try keyValue(into: current)
                }
                try endOfLine()
            }
            return root
        }

        // MARK: Headers

        mutating func header() throws {
            let headerLine = line
            advance()
            let isArray = peek == "["
            if isArray { advance() }
            skipSpaces()
            let path = try key()
            skipSpaces()
            guard peek == "]" else { throw fail("expected “]” to close the table name") }
            advance()
            if isArray {
                guard peek == "]" else { throw fail("expected “]]” to close the array of tables") }
                advance()
                try appendTable(at: path, line: headerLine)
            } else {
                try defineTable(at: path, line: headerLine)
            }
            current = path
        }

        mutating func defineTable(at path: [String], line: Int) throws {
            let at = here
            let name = path.joined(separator: ".")
            var root = self.root
            try Self.edit(&root, path: Array(path.dropLast()), at: at) { parent in
                let last = path.last!
                if let existing = parent[last] {
                    guard case .table(var table) = existing else {
                        throw at.error("“\(name)” is already a \(existing.typeName)")
                    }
                    guard table.implicit, !table.headed else { throw at.error("table “\(name)” is defined twice") }
                    table.implicit = false
                    table.headed = true
                    parent.set(last, .table(table), line: line)
                } else {
                    var table = TOMLTable()
                    table.headed = true
                    parent.set(last, .table(table), line: line)
                }
            }
            self.root = root
        }

        mutating func appendTable(at path: [String], line: Int) throws {
            let at = here
            let name = path.joined(separator: ".")
            var root = self.root
            try Self.edit(&root, path: Array(path.dropLast()), at: at) { parent in
                let last = path.last!
                var list: [TOMLValue] = []
                if let existing = parent[last] {
                    guard case .array(let items) = existing, items.allSatisfy({ $0.table != nil }) else {
                        throw at.error("“\(name)” is already a \(existing.typeName)")
                    }
                    list = items
                }
                list.append(.table(TOMLTable()))
                parent.set(last, .array(list), line: line)
            }
            self.root = root
        }

        /// Runs `body` on the table at `path`, making tables on the way. An array of tables on the
        /// way means its last table, as TOML says.
        static func edit(_ table: inout TOMLTable, path: [String], at: Position,
                         _ body: (inout TOMLTable) throws -> Void) throws {
            guard let first = path.first else { return try body(&table) }
            let rest = Array(path.dropFirst())
            switch table[first] {
            case nil:
                var inner = TOMLTable()
                inner.implicit = true
                try edit(&inner, path: rest, at: at, body)
                table.set(first, .table(inner), line: at.line)
            case .table(var inner):
                try edit(&inner, path: rest, at: at, body)
                table.set(first, .table(inner))
            case .array(var items):
                guard let last = items.last, case .table(var inner) = last else {
                    throw at.error("“\(first)” is an array, not a table")
                }
                try edit(&inner, path: rest, at: at, body)
                items[items.count - 1] = .table(inner)
                table.set(first, .array(items))
            case .some(let other):
                throw at.error("“\(first)” is already a \(other.typeName)")
            }
        }

        // MARK: Keys and values

        mutating func keyValue(into tablePath: [String]) throws {
            let keyLine = line
            let path = try key()
            skipSpaces()
            guard peek == "=" else { throw fail("expected “=” after the key “\(path.joined(separator: "."))”") }
            advance()
            skipSpaces()
            let value = try self.value()
            let full = tablePath + path
            let at = here
            let name = path.joined(separator: ".")
            var root = self.root
            try Self.edit(&root, path: Array(full.dropLast()), at: at) { table in
                let last = full.last!
                if table[last] != nil { throw at.error("“\(name)” is set twice") }
                table.set(last, value, line: keyLine)
            }
            self.root = root
        }

        /// A key, possibly dotted: a.b."c d".'e'
        mutating func key() throws -> [String] {
            var parts: [String] = []
            while true {
                skipSpaces()
                guard let c = peek else { throw fail("expected a key") }
                if c == "\"" {
                    parts.append(try basicString())
                } else if c == "'" {
                    parts.append(try literalString())
                } else {
                    var bare = ""
                    while let c = peek, c.isASCII, c.isLetter || c.isNumber || c == "_" || c == "-" {
                        bare.append(c)
                        advance()
                    }
                    guard !bare.isEmpty else { throw fail("expected a key, found “\(c)”") }
                    parts.append(bare)
                }
                skipSpaces()
                guard peek == "." else { return parts }
                advance()
            }
        }

        mutating func value() throws -> TOMLValue {
            guard let c = peek else { throw fail("expected a value") }
            switch c {
            case "\"":
                if peek(1) == "\"", peek(2) == "\"" { return .string(try multilineBasic()) }
                return .string(try basicString())
            case "'":
                if peek(1) == "'", peek(2) == "'" { return .string(try multilineLiteral()) }
                return .string(try literalString())
            case "[":
                return try array()
            case "{":
                return try inlineTable()
            case "t", "f":
                if match("true") { return .bool(true) }
                if match("false") { return .bool(false) }
                throw fail("expected a value")
            default:
                return try numberOrDate()
            }
        }

        mutating func match(_ word: String) -> Bool {
            let letters = Array(word)
            guard index + letters.count <= chars.count, Array(chars[index..<index + letters.count]) == letters else { return false }
            if let after = peek(letters.count), after.isLetter || after.isNumber || after == "_" || after == "-" { return false }
            for _ in letters { advance() }
            return true
        }

        mutating func numberOrDate() throws -> TOMLValue {
            var text = ""
            while let c = peek, !(c == " " || c == "\t" || c == "\n" || c == "\r\n" || c == "\r" || c == "," || c == "]" || c == "}" || c == "#") {
                text.append(c)
                advance()
            }
            // A date with a time after a space: 1979-05-27 07:32:00
            if text.count == 10, text.dropFirst(4).first == "-", peek == " ", let next = peek(1), next.isNumber {
                advance()
                while let c = peek, !(c == " " || c == "\t" || c == "\n" || c == "\r\n" || c == "," || c == "]" || c == "}" || c == "#") {
                    text.append(c)
                    advance()
                }
            }
            guard !text.isEmpty else { throw fail("expected a value") }
            if let date = Self.date(text) { return .datetime(date) }
            if let int = Self.integer(text) { return .integer(int) }
            if let float = Self.float(text) { return .float(float) }
            throw fail("“\(text)” is not a value (strings need quotes)")
        }

        static func date(_ text: String) -> String? {
            let digits = text.prefix(4)
            guard text.count >= 8, digits.allSatisfy(\.isNumber),
                  text.dropFirst(4).first == "-" || text.dropFirst(2).first == ":" else { return nil }
            return text
        }

        static func integer(_ raw: String) -> Int? {
            var text = raw
            guard !text.hasPrefix("_"), !text.hasSuffix("_"), !text.contains("__") else { return nil }
            text = text.replacingOccurrences(of: "_", with: "")
            for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where text.hasPrefix(prefix) {
                return Int(text.dropFirst(2), radix: radix)
            }
            var digits = text
            if digits.hasPrefix("+") || digits.hasPrefix("-") { digits.removeFirst() }
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
            if digits.count > 1, digits.hasPrefix("0") { return nil }
            return Int(text)
        }

        static func float(_ raw: String) -> Double? {
            let text = raw.replacingOccurrences(of: "_", with: "")
            switch text {
            case "inf", "+inf": return .infinity
            case "-inf": return -.infinity
            case "nan", "+nan", "-nan": return .nan
            default: break
            }
            guard text.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }),
                  !text.hasPrefix("."), !text.hasSuffix("."),
                  !text.contains(".e"), !text.contains(".E") else { return nil }
            return Double(text)
        }

        // MARK: Strings

        mutating func basicString() throws -> String {
            advance()   // "
            var out = ""
            while true {
                guard let c = peek else { throw fail("unterminated string") }
                if c == "\n" || c == "\r\n" { throw fail("a string in double quotes must end on the same line") }
                advance()
                if c == "\"" { return out }
                if c == "\\" { out += try escape() } else { out.append(c) }
            }
        }

        mutating func literalString() throws -> String {
            advance()   // '
            var out = ""
            while true {
                guard let c = peek else { throw fail("unterminated string") }
                if c == "\n" || c == "\r\n" { throw fail("a string in single quotes must end on the same line") }
                advance()
                if c == "'" { return out }
                out.append(c)
            }
        }

        mutating func multilineBasic() throws -> String {
            advance(); advance(); advance()
            if peek == "\n" || peek == "\r\n" { advance() }
            var out = ""
            while true {
                guard let c = peek else { throw fail("unterminated multi-line string") }
                if c == "\"", peek(1) == "\"", peek(2) == "\"" {
                    // Three quotes close the string; up to two more before them belong to it.
                    var quotes = 0
                    while peek == "\"" { quotes += 1; advance() }
                    guard quotes <= 5 else { throw fail("too many quotes at the end of a multi-line string") }
                    out += String(repeating: "\"", count: quotes - 3)
                    return out
                }
                advance()
                if c == "\\" {
                    // A backslash at the end of a line trims the break and the spaces after it.
                    var look = index
                    while look < chars.count, chars[look] == " " || chars[look] == "\t" { look += 1 }
                    if look < chars.count, chars[look] == "\n" || chars[look] == "\r\n" {
                        while let n = peek, n == " " || n == "\t" || n == "\n" || n == "\r\n" { advance() }
                        continue
                    }
                    out += try escape()
                } else {
                    out.append(c)
                }
            }
        }

        mutating func multilineLiteral() throws -> String {
            advance(); advance(); advance()
            if peek == "\n" || peek == "\r\n" { advance() }
            var out = ""
            while true {
                guard let c = peek else { throw fail("unterminated multi-line string") }
                if c == "'", peek(1) == "'", peek(2) == "'" {
                    var quotes = 0
                    while peek == "'" { quotes += 1; advance() }
                    guard quotes <= 5 else { throw fail("too many quotes at the end of a multi-line string") }
                    out += String(repeating: "'", count: quotes - 3)
                    return out
                }
                advance()
                out.append(c)
            }
        }

        /// After a backslash.
        mutating func escape() throws -> String {
            guard let c = peek else { throw fail("unterminated escape") }
            advance()
            switch c {
            case "b": return "\u{08}"
            case "t": return "\t"
            case "n": return "\n"
            case "f": return "\u{0C}"
            case "r": return "\r"
            case "e": return "\u{1B}"
            case "\"": return "\""
            case "\\": return "\\"
            case "u", "U":
                let count = c == "u" ? 4 : 8
                var hex = ""
                for _ in 0..<count {
                    guard let h = peek, h.isHexDigit else { throw fail("expected \(count) hex digits after \\\(c)") }
                    hex.append(h)
                    advance()
                }
                guard let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else {
                    throw fail("\\\(c)\(hex) is not a character")
                }
                return String(Character(scalar))
            default:
                throw fail("unknown escape \\\(c)")
            }
        }

        // MARK: Arrays and inline tables

        mutating func array() throws -> TOMLValue {
            advance()   // [
            var items: [TOMLValue] = []
            while true {
                skipBlank()
                guard let c = peek else { throw fail("unterminated array") }
                if c == "]" {
                    advance()
                    return .array(items)
                }
                items.append(try value())
                skipBlank()
                if peek == "," {
                    advance()
                } else if peek == "]" {
                    continue
                } else {
                    throw fail("expected “,” or “]” in the array")
                }
            }
        }

        mutating func inlineTable() throws -> TOMLValue {
            advance()   // {
            var table = TOMLTable()
            skipSpaces()
            if peek == "}" {
                advance()
                return .table(table)
            }
            while true {
                skipSpaces()
                let keyLine = line
                let path = try key()
                skipSpaces()
                guard peek == "=" else { throw fail("expected “=” in the inline table") }
                advance()
                skipSpaces()
                let value = try self.value()
                let at = here
                let name = path.joined(separator: ".")
                try Self.edit(&table, path: Array(path.dropLast()), at: at) { inner in
                    if inner[path.last!] != nil { throw at.error("“\(name)” is set twice") }
                    inner.set(path.last!, value, line: keyLine)
                }
                skipSpaces()
                if peek == "," {
                    advance()
                } else if peek == "}" {
                    advance()
                    return .table(table)
                } else {
                    throw fail("expected “,” or “}” in the inline table")
                }
            }
        }
    }
}
