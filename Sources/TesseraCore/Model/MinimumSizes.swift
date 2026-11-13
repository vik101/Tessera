import Foundation

/// A learned minimum size. A nil side means "no known limit".
public struct LearnedMinimum: Codable, Hashable, Sendable {
    public var width: Double?
    public var height: Double?

    public init(width: Double? = nil, height: Double? = nil) {
        self.width = width
        self.height = height
    }

    public var size: CGSize { CGSize(width: width ?? 0, height: height ?? 0) }
    public var isEmpty: Bool { width == nil && height == nil }

    public func merged(with other: LearnedMinimum) -> LearnedMinimum {
        LearnedMinimum(
            width: [width, other.width].compactMap { $0 }.max(),
            height: [height, other.height].compactMap { $0 }.max()
        )
    }
}

/// Decides when an app has truly refused a size.
///
/// macOS doesn't report minimum sizes, so we ask for a size, read back what the app
/// accepted, ask again a moment later, and only learn a limit if the app refuses
/// the same way twice.
public enum MinimumSizeLearner {
    /// Ignore results only a few points larger than requested.
    public static let tolerance: Double = 8

    /// What one refusal looked like.
    public struct Observation: Sendable, Equatable {
        public var requested: CGSize
        public var actual: CGSize
        public init(requested: CGSize, actual: CGSize) {
            self.requested = requested
            self.actual = actual
        }

        public var refusedWidth: Bool { actual.width > requested.width + MinimumSizeLearner.tolerance }
        public var refusedHeight: Bool { actual.height > requested.height + MinimumSizeLearner.tolerance }
        public var refused: Bool { refusedWidth || refusedHeight }
    }

    /// Returns a minimum to remember, or nil if the evidence isn't solid.
    ///
    /// - Parameters:
    ///   - first: the first refusal.
    ///   - second: the result of asking for the same size again.
    ///   - screen: the usable screen size (near-full-screen minimums are never recorded).
    public static func learn(first: Observation, second: Observation, screen: CGSize) -> LearnedMinimum? {
        guard first.refused, second.refused else { return nil }
        // Same request both times, and the app answered the same way.
        guard abs(first.requested.width - second.requested.width) < 1,
              abs(first.requested.height - second.requested.height) < 1,
              abs(first.actual.width - second.actual.width) <= 2,
              abs(first.actual.height - second.actual.height) <= 2
        else { return nil }
        var result = LearnedMinimum()
        if second.refusedWidth { result.width = second.actual.width.rounded(.up) }
        if second.refusedHeight { result.height = second.actual.height.rounded(.up) }
        // Never record near-full-screen minimums.
        if let w = result.width, w >= screen.width * 0.92 { result.width = nil }
        if let h = result.height, h >= screen.height * 0.92 { result.height = nil }
        return result.isEmpty ? nil : result
    }

    /// When the user drags a window smaller than the remembered size and the app complies,
    /// the remembered size drops right away.
    public static func lowered(_ current: LearnedMinimum, observedSize: CGSize) -> LearnedMinimum {
        var result = current
        if let w = current.width, observedSize.width + tolerance < w { result.width = observedSize.width }
        if let h = current.height, observedSize.height + tolerance < h { result.height = observedSize.height }
        return result
    }
}

/// Free trial and license state, computed from plain dates so it is easy to test.
public enum LicenseState: Equatable, Sendable {
    /// Licensing is turned off for this build (personal use). Everything works.
    case unlicensedBuild
    case trial(remaining: TimeInterval)
    case trialEnded
    case licensed
    /// A key was refunded or deactivated elsewhere.
    case revoked

    public var canTile: Bool {
        switch self {
        case .unlicensedBuild, .trial, .licensed: true
        case .trialEnded, .revoked: false
        }
    }

    /// Clean Space and Setups come with the full version, not the trial.
    public var hasFullVersion: Bool {
        switch self {
        case .unlicensedBuild, .licensed: true
        default: false
        }
    }

    public static func compute(
        licensingEnabled: Bool,
        firstLaunch: Date,
        now: Date,
        trialLength: TimeInterval,
        hasActiveKey: Bool,
        keyRevoked: Bool
    ) -> LicenseState {
        guard licensingEnabled else { return .unlicensedBuild }
        if keyRevoked { return .revoked }
        if hasActiveKey { return .licensed }
        let elapsed = now.timeIntervalSince(firstLaunch)
        if elapsed < trialLength { return .trial(remaining: trialLength - max(0, elapsed)) }
        return .trialEnded
    }
}
