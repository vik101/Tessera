import AppKit
import Sparkle

/// Keeps Tessera up to date with Sparkle.
///
/// Updates are on only in builds that carry an update feed and a public key in Info.plist
/// (`SUFeedURL`, `SUPublicEDKey`; set by scripts/config.env or the CI release job).
/// Sparkle checks every update's signature against that key before installing it.
@MainActor
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    static let shared = Updater()

    private var controller: SPUStandardUpdaterController?

    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    /// The appcast address, or nil when this build can't update itself.
    var feed: String? {
        let feed = (info["SUFeedURL"] as? String) ?? ""
        let key = (info["SUPublicEDKey"] as? String) ?? ""
        return feed.isEmpty || key.isEmpty ? nil : feed
    }

    var isConfigured: Bool { feed != nil }

    func start() {
        guard isConfigured, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        Log.info("Updates on")
    }

    /// Shows Sparkle's "Check for Updates" window.
    func checkNow() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var debugState: [String: Any] {
        [
            "configured": isConfigured,
            "running": controller != nil,
            "automatic": checksAutomatically,
            "feed": feed ?? "",
        ]
    }

    // A menu bar app has no Dock icon to badge, so Sparkle's gentle reminders show the update window
    // only when the person isn't busy. Tessera says it supports them so Sparkle doesn't warn.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
