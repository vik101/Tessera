import AppKit
import Darwin
import TesseraCore

/// Listens for the `tessera` command line tool on a Unix socket only you can open, runs what it
/// asks on the main thread, and answers. `subscribe` keeps the connection open and sends events.
final class CommandServer: @unchecked Sendable {
    static let shared = CommandServer()

    private var listener: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "tessera.cli.accept")
    private let clientQueue = DispatchQueue(label: "tessera.cli.clients", attributes: .concurrent)
    private(set) var path = ""

    func start() {
        path = Wire.socketPath(uid: getuid())
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return report("socket() failed: \(errno)") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return report("socket path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, byte) in bytes.enumerated() { raw[i] = UInt8(bitPattern: byte) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else { close(fd); return report("bind() failed: \(errno)") }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { close(fd); return report("listen() failed: \(errno)") }
        listener = fd
        acceptQueue.async { [weak self] in self?.acceptLoop() }
        Task { @MainActor in Log.info("Command line tool: listening on \(self.path)") }
    }

    private func report(_ message: String) {
        Task { @MainActor in Log.error("Command line tool: \(message)") }
    }

    private func acceptLoop() {
        while listener >= 0 {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            clientQueue.async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        guard let header = readExactly(client, 4), let length = Wire.length(header), length <= Wire.maximum,
              let body = readExactly(client, length) else {
            close(client)
            return
        }
        let version = AppInfo.version
        guard let request = try? JSONDecoder().decode(Wire.Request.self, from: body) else {
            send(client, Wire.Response(exitCode: Wire.Exit.usage, stderr: "tessera: couldn't read the request\n", serverVersion: version))
            close(client)
            return
        }
        // Subscribe keeps the connection: events are written as they happen, one JSON line each.
        if let subscribe = Self.subscription(request.args) {
            send(client, Wire.Response(exitCode: 0, serverVersion: version, streaming: true))
            let writer = DispatchQueue(label: "tessera.cli.subscriber")
            let alive = Flag()
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    Events.shared.subscribe(subscribe) { line in
                        guard alive.value else { return false }
                        writer.async {
                            let data = Array((line + "\n").utf8)
                            let written = data.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                            if written < 0 { alive.value = false; close(client) }
                        }
                        return true
                    }
                }
            }
            return
        }
        let response: Wire.Response = DispatchQueue.main.sync {
            MainActor.assumeIsolated { Self.answer(request) }
        }
        send(client, response)
        close(client)
    }

    /// The events asked for by `subscribe`, or nil for any other command.
    static func subscription(_ args: [String]) -> Set<String>? {
        let words = args.count == 1 ? args[0].split(separator: " ").map(String.init) : args
        guard words.first?.lowercased() == "subscribe" else { return nil }
        return Set(words.dropFirst().filter { !$0.hasPrefix("--") })
    }

    @MainActor
    static func answer(_ request: Wire.Request) -> Wire.Response {
        let version = AppInfo.version
        let script: Script
        do {
            if request.args.count == 1, request.args[0].contains(where: { $0 == " " || $0 == ";" }) {
                script = try CommandParser.parse(request.args[0])
            } else {
                script = Script(statements: [[[try CommandParser.invocation(request.args)]]])
            }
        } catch {
            return Wire.Response(exitCode: Wire.Exit.usage, stderr: "tessera: \(error)\n", serverVersion: version)
        }
        let outcome = CommandRunner.run(script, window: request.windowID)
        func text(_ lines: [String]) -> String { lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n" }
        return Wire.Response(exitCode: outcome.ok ? Wire.Exit.ok : Wire.Exit.failed, stdout: text(outcome.output),
                             stderr: text(outcome.errors.map { "tessera: " + $0 }), serverVersion: version)
    }

    private func send(_ client: Int32, _ response: Wire.Response) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        let framed = Wire.frame(data)
        framed.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(client, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    private func readExactly(_ fd: Int32, _ count: Int) -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let got = data.withUnsafeMutableBytes { raw in read(fd, raw.baseAddress! + offset, count - offset) }
            if got <= 0 { return nil }
            offset += got
        }
        return data
    }

    func stop() {
        if listener >= 0 { close(listener) }
        listener = -1
        unlink(path)
    }
}

/// A thread-safe true/false.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = true
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
