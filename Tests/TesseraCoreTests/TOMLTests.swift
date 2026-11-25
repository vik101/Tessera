import Foundation
import Testing
@testable import TesseraCore

@Suite("TOML")
struct TOMLTests {
    @Test func readsTheKindsOfValue() throws {
        let t = try TOML.parse("""
        # A comment
        name = "Tessera"          # after a value
        literal = 'C:\\Users\\me'
        count = 42
        negative = -17
        big = 1_000
        hex = 0xff
        octal = 0o17
        binary = 0b101
        ratio = 0.5
        exp = 1e3
        on = true
        off = false
        when = 1979-05-27T07:32:00Z
        list = [1, 2, 3]
        mixed = ["a", 'b']
        """)
        #expect(t["name"] == .string("Tessera"))
        #expect(t["literal"] == .string("C:\\Users\\me"))
        #expect(t["count"] == .integer(42))
        #expect(t["negative"] == .integer(-17))
        #expect(t["big"] == .integer(1000))
        #expect(t["hex"] == .integer(255))
        #expect(t["octal"] == .integer(15))
        #expect(t["binary"] == .integer(5))
        #expect(t["ratio"] == .float(0.5))
        #expect(t["exp"] == .float(1000))
        #expect(t["on"] == .bool(true))
        #expect(t["off"] == .bool(false))
        #expect(t["when"] == .datetime("1979-05-27T07:32:00Z"))
        #expect(t["list"] == .array([.integer(1), .integer(2), .integer(3)]))
        #expect(t["mixed"]?.strings == ["a", "b"])
        #expect(t.keys.first == "name")
    }

    @Test func escapesAndMultilineStrings() throws {
        let t = try TOML.parse(#"""
        a = "tab\there \"quoted\" \u00e9"
        b = """
        first
        second"""
        c = '''
        raw \n stays'''
        d = """one \
            two"""
        e = """""five quotes"""""
        """#)
        #expect(t["a"] == .string("tab\there \"quoted\" é"))
        #expect(t["b"] == .string("first\nsecond"))
        #expect(t["c"] == .string("raw \\n stays"))
        #expect(t["d"] == .string("one two"))
        #expect(t["e"] == .string("\"\"five quotes\"\""))
    }

    @Test func tablesDottedKeysAndArraysOfTables() throws {
        let t = try TOML.parse("""
        gaps.inner.horizontal = 8
        gaps.inner.vertical = 8

        [mode.main.binding]
        alt-h = 'focus left'
        "alt-shift-h" = ['move left', 'mode main']

        [mode.service.binding]
        esc = 'mode main'

        [[on-window-detected]]
        if.app-id = 'com.apple.finder'
        run = 'layout floating'

        [[on-window-detected]]
        if.app-name-regex-substring = 'chrome'
        run = ['layout tiling', 'move-node-to-workspace 2']
        check-further-callbacks = true

        [gaps.outer]
        left = 10
        """)
        #expect(t["gaps", "inner", "horizontal"] == .integer(8))
        #expect(t["gaps", "outer", "left"] == .integer(10))
        #expect(t["mode", "main", "binding", "alt-h"] == .string("focus left"))
        #expect(t["mode", "main", "binding", "alt-shift-h"]?.strings == ["move left", "mode main"])
        #expect(t["mode", "service", "binding", "esc"] == .string("mode main"))
        let rules = t["on-window-detected"]?.array ?? []
        #expect(rules.count == 2)
        #expect(rules[0].table?["if", "app-id"] == .string("com.apple.finder"))
        #expect(rules[1].table?["check-further-callbacks"] == .bool(true))
        #expect(rules[1].table?["run"]?.strings == ["layout tiling", "move-node-to-workspace 2"])
    }

    @Test func inlineTablesAndMultilineArrays() throws {
        let t = try TOML.parse("""
        outer.top = [
            { monitor."LG" = 24 },   # a big screen
            { monitor.main = 16 },
            10,
        ]
        point = { x = 1, y = 2 }
        empty = {}
        """)
        let top = t["outer", "top"]?.array ?? []
        #expect(top.count == 3)
        #expect(top[0].table?["monitor", "LG"] == .integer(24))
        #expect(top[1].table?["monitor", "main"] == .integer(16))
        #expect(top[2] == .integer(10))
        #expect(t["point", "x"] == .integer(1))
        #expect(t["empty"]?.table?.isEmpty == true)
    }

    @Test func remembersTheLineOfEachKey() throws {
        let t = try TOML.parse("a = 1\n\n\nb = 2\r\nc = 3\n")
        #expect(t.lines["a"] == 1)
        #expect(t.lines["b"] == 4)
        #expect(t.lines["c"] == 5)
    }

    @Test(arguments: [
        ("a = ", 1),
        ("a = hello", 1),
        ("a = 1\na = 2", 2),
        ("a = \"open", 1),
        ("[t]\n[t]", 2),
        ("a = [1, 2", 1),
        ("a = 1 b = 2", 1),
        ("x = 1\n[x]", 2),
        ("a = { b = 1", 1),
        ("a = 007", 1),
        ("[[a]]\n[a]", 2),
    ])
    func reportsMistakesWithTheirLine(text: String, line: Int) {
        do {
            _ = try TOML.parse(text)
            Issue.record("expected an error for \(text.debugDescription)")
        } catch let error as TOMLError {
            #expect(error.line == line, "\(text.debugDescription): \(error)")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func readsAeroSpacesDefaultConfig() throws {
        let t = try TOML.parse(AeroSpaceSamples.defaultConfig)
        #expect(t["config-version"] == .integer(2))
        #expect(t["after-startup-command"] == .array([]))
        #expect(t["mode", "main", "binding", "alt-slash"] == .string("layout tiles horizontal vertical"))
        #expect(t["mode", "service", "binding", "esc"]?.strings == ["reload-config", "mode main"])
        #expect(t["gaps", "outer", "top"] == .integer(0))
        #expect(t["key-mapping", "preset"] == .string("qwerty"))
    }
}
