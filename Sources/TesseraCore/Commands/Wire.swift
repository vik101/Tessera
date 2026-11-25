import Foundation

/// How the `tessera` command line tool talks to the app: a Unix socket only you can open
/// (/tmp/tessera-<your user id>.sock). Each message is 4 bytes of length (little-endian), then JSON.
public enum Wire {
    public static let version = 1

    public static func socketPath(uid: UInt32) -> String { "/tmp/tessera-\(uid).sock" }

    public struct Request: Codable, Equatable, Sendable {
        public var version: Int
        /// The command line's words, as typed: ["focus", "left"], or one string with a whole script.
        public var args: [String]
        /// For commands that act on a window: this one instead of the focused one.
        public var windowID: UInt32?

        public init(args: [String], windowID: UInt32? = nil) {
            version = Wire.version
            self.args = args
            self.windowID = windowID
        }
    }

    public struct Response: Codable, Equatable, Sendable {
        /// 0: done. 1: the command failed. 3: Tessera didn't understand it.
        public var exitCode: Int32
        public var stdout: String
        public var stderr: String
        public var serverVersion: String
        /// True when more lines follow, one event per line, until the connection closes (`subscribe`).
        public var streaming: Bool

        public init(exitCode: Int32, stdout: String = "", stderr: String = "", serverVersion: String, streaming: Bool = false) {
            self.exitCode = exitCode
            self.stdout = stdout
            self.stderr = stderr
            self.serverVersion = serverVersion
            self.streaming = streaming
        }
    }

    /// Exit codes: 2 means the app couldn't be reached at all.
    public enum Exit {
        public static let ok: Int32 = 0
        public static let failed: Int32 = 1
        public static let unreachable: Int32 = 2
        public static let usage: Int32 = 3
    }

    /// 4 bytes of length, then the bytes.
    public static func frame(_ data: Data) -> Data {
        var length = UInt32(data.count).littleEndian
        var out = Data(bytes: &length, count: 4)
        out.append(data)
        return out
    }

    /// The length from a 4-byte header.
    public static func length(_ header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        let value = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return Int(UInt32(littleEndian: value))
    }

    /// The largest message either side accepts (8 MB).
    public static let maximum = 8 << 20
}

/// Fills `%{name}` placeholders: `%{window-id} %{app-name}`. `%%` is a percent sign.
public enum ListFormat {
    public static func render(_ format: String, _ values: [String: String]) -> String {
        var out = ""
        var rest = Substring(format)
        while let start = rest.range(of: "%") {
            out += rest[..<start.lowerBound]
            let after = rest[start.upperBound...]
            if after.hasPrefix("%") {
                out += "%"
                rest = after.dropFirst()
            } else if after.hasPrefix("{"), let close = after.firstIndex(of: "}") {
                let name = String(after[after.index(after: after.startIndex)..<close])
                out += values[name] ?? ""
                rest = after[after.index(after: close)...]
            } else {
                out += "%"
                rest = after
            }
        }
        return out + rest
    }

    /// Rows as aligned columns separated by " | ".
    public static func table(_ rows: [[String]]) -> String {
        guard let width = rows.map(\.count).max(), width > 0 else { return "" }
        var widths = Array(repeating: 0, count: width)
        for row in rows { for (i, cell) in row.enumerated() where i < width - 1 { widths[i] = max(widths[i], cell.count) } }
        return rows.map { row in
            row.enumerated().map { i, cell in
                i < row.count - 1 ? cell.padding(toLength: widths[i], withPad: " ", startingAt: 0) : cell
            }.joined(separator: " | ")
        }.joined(separator: "\n")
    }
}
