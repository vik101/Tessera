import AppKit

/// Reads the current macOS Space per display.
///
/// Uses private SkyLight calls, loaded at runtime so a future macOS that removes
/// them simply falls back to "one Space" instead of crashing.
@MainActor
enum Spaces {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias ActiveSpace = @convention(c) (Int32) -> UInt64
    private typealias DisplayCurrentSpace = @convention(c) (Int32, CFString) -> UInt64
    private typealias DisplayUUID = @convention(c) (UInt32) -> Unmanaged<CFUUID>?

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let colorSync = dlopen("/System/Library/Frameworks/ColorSync.framework/ColorSync", RTLD_LAZY)

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private static let mainConnection = symbol(skyLight, "SLSMainConnectionID", as: MainConnection.self)
        ?? symbol(skyLight, "CGSMainConnectionID", as: MainConnection.self)
    private static let activeSpace = symbol(skyLight, "SLSGetActiveSpace", as: ActiveSpace.self)
        ?? symbol(skyLight, "CGSGetActiveSpace", as: ActiveSpace.self)
    private static let displayCurrentSpace = symbol(skyLight, "SLSManagedDisplayGetCurrentSpace", as: DisplayCurrentSpace.self)
        ?? symbol(skyLight, "CGSManagedDisplayGetCurrentSpace", as: DisplayCurrentSpace.self)
    private static let displayUUID = symbol(colorSync, "CGDisplayCreateUUIDFromDisplayID", as: DisplayUUID.self)

    private static let connection: Int32 = mainConnection?() ?? 0

    /// The Space showing on a display, or 0 if unknown.
    static func current(on displayID: CGDirectDisplayID) -> UInt64 {
        guard connection != 0 else { return 0 }
        if let displayCurrentSpace, let displayUUID, let uuid = displayUUID(displayID)?.takeRetainedValue(),
           let text = CFUUIDCreateString(nil, uuid) {
            let space = displayCurrentSpace(connection, text)
            if space != 0 { return space }
        }
        return activeSpace?(connection) ?? 0
    }
}
