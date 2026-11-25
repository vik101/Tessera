import AppKit

/// Puts the `tessera` command (inside the app, Contents/Resources/bin/tessera) on your PATH with a link.
/// Homebrew installs link it already.
@MainActor
enum CommandLineTool {
    static var bundled: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/tessera") }

    /// Folders tried, in order. The first two are usually on your PATH; ~/.local/bin is the fallback.
    static var folders: [URL] {
        [URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")]
    }

    static var isInstalled: Bool {
        folders.contains { folder in
            let link = folder.appendingPathComponent("tessera")
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else {
                return FileManager.default.isExecutableFile(atPath: link.path)
            }
            return FileManager.default.fileExists(atPath: target)
        }
    }

    /// Makes the link. Returns what happened, to show.
    static func install() -> String {
        guard FileManager.default.isExecutableFile(atPath: bundled.path) else {
            return "This copy of Tessera has no command line tool inside it"
        }
        let manager = FileManager.default
        for folder in folders {
            let isFallback = folder == folders.last
            if isFallback { try? manager.createDirectory(at: folder, withIntermediateDirectories: true) }
            guard manager.isWritableFile(atPath: folder.path) else { continue }
            let link = folder.appendingPathComponent("tessera")
            try? manager.removeItem(at: link)
            do {
                try manager.createSymbolicLink(at: link, withDestinationURL: bundled)
            } catch {
                continue
            }
            let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
            let onPath = path.split(separator: ":").contains { $0 == folder.path } || !isFallback
            Log.info("Command line tool linked at \(link.path)")
            return onPath
                ? "Installed: try `tessera help` in Terminal"
                : "Installed in ~/.local/bin. Add it to your PATH, then try `tessera help`"
        }
        return "Couldn't install the command line tool (no folder could be written)"
    }
}
