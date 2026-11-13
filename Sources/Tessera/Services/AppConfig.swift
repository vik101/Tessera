import AppKit
import ServiceManagement
import Sparkle

/// Build-time settings, read from Info.plist. Edit them in `scripts/config.env`;
/// the build script writes them into the app. Empty values switch a feature off.
enum AppConfig {
    private static func string(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }

    static var appName: String { string("CFBundleName") ?? "Tessera" }
    static var version: String { string("CFBundleShortVersionString") ?? "1.0.0" }
    static var build: String { string("CFBundleVersion") ?? "1" }

    static var websiteURL: URL? { string("TesseraWebsiteURL").flatMap(URL.init(string:)) }
    static var docsURL: URL? { string("TesseraDocsURL").flatMap(URL.init(string:)) }
    static var supportEmail: String { string("TesseraSupportEmail") ?? "" }

    /// Licensing is on only when both a checkout page and a license API are set.
    static var checkoutURL: URL? { string("TesseraCheckoutURL").flatMap(URL.init(string:)) }
    static var licenseAPI: URL? { string("TesseraLicenseAPI").flatMap(URL.init(string:)) }
    static var licensingEnabled: Bool { checkoutURL != nil && licenseAPI != nil }
    static var trialLength: TimeInterval {
        let days = Double(string("TesseraTrialDays") ?? "2") ?? 2
        return days * 86_400
    }

    /// Updates are on only with a feed URL and a public signing key (Sparkle refuses unsigned updates).
    static var updatesEnabled: Bool { string("SUFeedURL") != nil && string("SUPublicEDKey") != nil }
}

/// Open at login, through the system's login items.
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            Log.error("Open at login failed: \(error.localizedDescription)")
        }
    }
}

/// Signed updates through Sparkle. Asks before installing.
@MainActor
final class UpdateController {
    static let shared = UpdateController()

    private var controller: SPUStandardUpdaterController?

    var isAvailable: Bool { controller != nil }

    func start() {
        guard AppConfig.updatesEnabled else {
            Log.info("Updates are off for this build (no feed or key configured).")
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.automaticallyChecksForUpdates = Preferences.shared.checkForUpdatesAutomatically
        controller.updater.updateCheckInterval = 86_400
        controller.startUpdater()
        self.controller = controller
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func setAutomatic(_ on: Bool) {
        controller?.updater.automaticallyChecksForUpdates = on
    }
}
