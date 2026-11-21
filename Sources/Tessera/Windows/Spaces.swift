import AppKit

/// Which desktop (Space) each screen shows, and which Space each window lives on.
///
/// macOS has no public API for this, so Tessera asks the window server directly, the same way
/// other tiling window managers (yabai, Amethyst) do. The functions are looked up when Tessera
/// starts; if a future macOS removes them, `isAvailable` is false and Tessera falls back to
/// "what's on screen now", waiting for the screen to settle before it moves anything.
@MainActor
enum Spaces {
    typealias SpaceID = UInt64

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private static let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func function<T>(_ names: [String], as type: T.Type) -> T? {
        for name in names {
            if let library, let pointer = dlsym(library, name) { return unsafeBitCast(pointer, to: type) }
            if let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) { return unsafeBitCast(pointer, to: type) }
        }
        return nil
    }

    private static let connection: Int32? = function(["SLSMainConnectionID", "CGSMainConnectionID"], as: MainConnection.self).map { $0() }
    private static let copyDisplaySpaces = function(["SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces"], as: CopyDisplaySpaces.self)
    private static let copySpacesForWindows = function(["SLSCopySpacesForWindows", "CGSCopySpacesForWindows"], as: CopySpacesForWindows.self)

    static var isAvailable: Bool { connection != nil && copyDisplaySpaces != nil && copySpacesForWindows != nil }

    /// The Space each screen is showing now, by display. Nil if macOS won't say.
    static func current(for displays: [DisplayInfo]) -> [CGDirectDisplayID: SpaceID]? {
        guard let connection, let copyDisplaySpaces,
              let list = copyDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        var byIdentifier: [String: SpaceID] = [:]
        for entry in list {
            guard let identifier = entry["Display Identifier"] as? String,
                  let current = entry["Current Space"] as? [String: Any],
                  let id = (current["ManagedSpaceID"] ?? current["id64"]) as? NSNumber else { continue }
            byIdentifier[identifier.uppercased()] = id.uint64Value
        }
        guard !byIdentifier.isEmpty else { return nil }
        var result: [CGDirectDisplayID: SpaceID] = [:]
        for display in displays {
            if let uuid = CGDisplayCreateUUIDFromDisplayID(display.displayID)?.takeRetainedValue(),
               let text = CFUUIDCreateString(nil, uuid).map({ $0 as String }),
               let id = byIdentifier[text.uppercased()] {
                result[display.displayID] = id
            } else if let shared = byIdentifier["MAIN"] {
                // "Main": all screens share one set of Spaces ("Displays have separate Spaces" is off).
                result[display.displayID] = shared
            } else if byIdentifier.count == 1, let only = byIdentifier.values.first {
                result[display.displayID] = only
            }
        }
        return result.isEmpty ? nil : result
    }

    /// All desktops, in order, for the tests.
    static func all() -> [[String: Any]] {
        guard let connection, let copyDisplaySpaces,
              let list = copyDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return list.map { entry in
            let zero = NSNumber(value: 0)
            let spaces = (entry["Spaces"] as? [[String: Any]] ?? []).map { space -> [String: Any] in
                let id = (space["ManagedSpaceID"] ?? space["id64"]) as? NSNumber
                return ["id": id ?? zero, "type": (space["type"] as? NSNumber) ?? zero]
            }
            let current = (entry["Current Space"] as? [String: Any]).flatMap { ($0["ManagedSpaceID"] ?? $0["id64"]) as? NSNumber }
            return ["display": (entry["Display Identifier"] as? String) ?? "", "current": current ?? zero, "spaces": spaces]
        }
    }

    /// The Spaces a window lives on. A window set to appear on every desktop lists several.
    static func spaces(of window: CGWindowID) -> Set<SpaceID> {
        guard let connection, let copySpacesForWindows else { return [] }
        let ids = [NSNumber(value: window)] as CFArray
        // 0x7: the current Space, other Spaces and fullscreen Spaces.
        guard let list = copySpacesForWindows(connection, 0x7, ids)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return Set(list.map(\.uint64Value))
    }
}
