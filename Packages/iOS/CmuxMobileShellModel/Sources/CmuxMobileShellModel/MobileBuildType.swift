import Foundation

/// The distribution channel the running iOS app was built for.
///
/// Derived from the same signal the push-registration `apnsEnvironment` uses:
/// `#if DEBUG` is a development build, and any Release build is a distribution
/// build. Both `beta` and `prod` are Release configurations, so the split can
/// never be a compile flag and must be resolved at runtime.
///
/// The beta/internal TestFlight lane and the future App Store lane ship the same
/// `com.cmux-mochi.ios` bundle id, so the bundle can no longer tell them apart.
/// The channel is carried instead by the `CMUXBuildChannel` Info.plist key
/// (`CMUX_IOS_BUILD_CHANNEL` in `ios/Config/*.xcconfig`), which `Release.xcconfig`
/// sets to `beta`. The legacy upstream bundle id is still honored so an older
/// installed build keeps reporting itself correctly.
public enum MobileBuildType: String, Equatable, Sendable {
    /// A local DEBUG build (Xcode / `ios/scripts/reload.sh`).
    case dev
    /// A Release build distributed for beta/internal TestFlight dogfooding
    /// (`CMUXBuildChannel` = `beta`).
    case beta
    /// A Release build distributed to production (App Store).
    case prod

    /// The bundle id the beta lane used before it moved to `com.cmux-mochi.ios`.
    /// Retained only so an already-installed upstream-id build still resolves to
    /// ``beta``; new builds are identified by ``buildChannel``.
    private static let legacyBetaBundleIdentifier = "dev.cmux.app.beta"

    /// Resolve the build type from compile configuration, the declared channel,
    /// and the bundle id.
    ///
    /// `#if DEBUG` short-circuits to ``dev`` so a local build is never mistaken
    /// for a distribution build. In Release an explicit `buildChannel` wins;
    /// otherwise the legacy beta bundle id is honored, and anything else is
    /// treated as ``prod``.
    ///
    /// - Parameters:
    ///   - isDebugBuild: `true` when compiled with `DEBUG` defined. Injected so
    ///     the resolution is testable without a real DEBUG/Release toggle.
    ///   - bundleIdentifier: The running bundle's identifier, or `nil` when it
    ///     cannot be read.
    ///   - buildChannel: The `CMUXBuildChannel` Info.plist value, or `nil`/empty
    ///     when the build declares no channel.
    /// - Returns: The resolved build type.
    public static func resolve(
        isDebugBuild: Bool,
        bundleIdentifier: String?,
        buildChannel: String? = nil
    ) -> MobileBuildType {
        if isDebugBuild {
            return .dev
        }
        let declared = buildChannel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let declared, !declared.isEmpty, let channel = MobileBuildType(rawValue: declared) {
            return channel
        }
        if bundleIdentifier == legacyBetaBundleIdentifier {
            return .beta
        }
        return .prod
    }

    /// A short, stable, lowercase token (`"dev"` / `"beta"` / `"prod"`) for
    /// machine-readable stamps (the email subject suffix, the agent bundle).
    public var token: String { rawValue }

    /// A human-facing label for the feedback email subject and body.
    public var displayLabel: String {
        switch self {
        case .dev: return "Dev"
        case .beta: return "Beta"
        case .prod: return "Prod"
        }
    }
}
