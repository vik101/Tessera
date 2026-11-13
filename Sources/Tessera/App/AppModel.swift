import AppKit
import Observation
import TesseraCore

/// Live app state the UI watches: permissions, pause reasons, modes.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var accessibilityTrusted = AccessibilityPermission.isTrusted
    var stageManagerOn = false
    var secureInputOn = false
    var licenseState: LicenseState = .unlicensedBuild
    var updateAvailable = false
    var shortcutRegistrationFailed = false

    var noPeekOn = false
    var cleanSpaceOn = false
    var focusModeActive = false

    /// The app that was in front before the menu bar panel opened.
    var frontAppName: String?
    var frontAppBundleID: String?

    /// Bumped whenever the arrangement changes, so previews redraw.
    var layoutRevision = 0

    enum Status: Equatable {
        case needsAccessibility
        case needsLicense
        case waitingForSetup
        case stageManager
        case off
        case active
        case focus

        var color: NSColor {
            switch self {
            case .active, .focus: .systemGreen
            case .waitingForSetup, .stageManager: .systemOrange
            case .off: .systemGray
            case .needsAccessibility, .needsLicense: .systemRed
            }
        }

        var message: String {
            switch self {
            case .needsAccessibility: L("Needs Accessibility access")
            case .needsLicense: L("Needs a license")
            case .waitingForSetup: L("Waiting for setup to finish")
            case .stageManager: L("Paused while Stage Manager is on")
            case .off: L("Automatic tiling is off")
            case .active: L("Arranging windows")
            case .focus: L("Focus mode")
            }
        }
    }

    var status: Status {
        if !accessibilityTrusted { return .needsAccessibility }
        if !licenseState.canTile { return .needsLicense }
        if !Preferences.shared.onboardingComplete { return .waitingForSetup }
        if stageManagerOn { return .stageManager }
        if !Preferences.shared.automaticTiling { return .off }
        if focusModeActive { return .focus }
        return .active
    }

    /// True when Tessera may move windows.
    var canArrange: Bool {
        switch status {
        case .active, .focus: true
        default: false
        }
    }
}
