// The `tessera` command line tool. It sends its words to the running Tessera app over a Unix socket
// and prints the answer. Built for scripts and AI agents: plain output by default, --json on every
// list, and exit codes that say what happened (0 done, 1 failed, 2 Tessera isn't running, 3 not understood).

import Darwin
import Foundation
import TesseraCore

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data(("tessera: " + message + "\n").utf8))
    exit(code)
}

var args = Array(CommandLine.arguments.dropFirst())
var windowID: UInt32?
if let index = args.firstIndex(of: "--window-id"), index == 0, args.count > 1 {
    guard let id = UInt32(args[1]) else { fail("--window-id needs a window number", Wire.Exit.usage) }
    windowID = id
    args.removeSubrange(0...1)
}

// Help and the version work without the app.
if args.isEmpty || ["help", "--help", "-h"].contains(args[0]) && args.count == 1 {
    print(CommandHelp.overview, terminator: "")
    exit(args.isEmpty ? Wire.Exit.usage : Wire.Exit.ok)
}
if args.count == 2, ["help", "--help", "-h"].contains(args[0]) {
    guard let text = CommandHelp.detail(args[1]) else { fail("no command “\(args[1])”; run `tessera help`", Wire.Exit.usage) }
    print(text)
    exit(Wire.Exit.ok)
}

// Check the words here first, so a typo gets a clear answer even when the app isn't running.
let isScript = args.count == 1 && args[0].contains(where: { $0 == " " || $0 == ";" })
do {
    if isScript { _ = try CommandParser.parse(args[0]) } else { _ = try CommandParser.invocation(args) }
} catch {
    fail("\(error)", Wire.Exit.usage)
}

let path = Wire.socketPath(uid: getuid())
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { fail("couldn't open a socket", Wire.Exit.unreachable) }
var noSigPipe: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(path.utf8CString)
withUnsafeMutableBytes(of: &address.sun_path) { raw in
    for (i, byte) in pathBytes.enumerated() where i < raw.count { raw[i] = UInt8(bitPattern: byte) }
}
let connected = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard connected == 0 else {
    fail("Tessera isn't running (or is older than 3.0). Open Tessera, then try again.", Wire.Exit.unreachable)
}

func writeAll(_ data: Data) -> Bool {
    data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}

func readExactly(_ count: Int) -> Data? {
    var data = Data(count: count)
    var offset = 0
    while offset < count {
        let n = data.withUnsafeMutableBytes { raw in read(fd, raw.baseAddress! + offset, count - offset) }
        if n <= 0 { return nil }
        offset += n
    }
    return data
}

guard let body = try? JSONEncoder().encode(Wire.Request(args: args, windowID: windowID)), writeAll(Wire.frame(body)) else {
    fail("couldn't send the command to Tessera", Wire.Exit.unreachable)
}
guard let header = readExactly(4), let length = Wire.length(header), length <= Wire.maximum,
      let reply = readExactly(length), let response = try? JSONDecoder().decode(Wire.Response.self, from: reply) else {
    fail("Tessera didn't answer", Wire.Exit.unreachable)
}
if !response.stdout.isEmpty { FileHandle.standardOutput.write(Data(response.stdout.utf8)) }
if !response.stderr.isEmpty { FileHandle.standardError.write(Data(response.stderr.utf8)) }

if response.streaming {
    // `subscribe`: print each event line as it arrives, until Tessera quits or you press ⌃C.
    setvbuf(stdout, nil, _IOLBF, 0)
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 { break }
        FileHandle.standardOutput.write(Data(buffer[0..<n]))
    }
}
close(fd)
exit(response.exitCode)
